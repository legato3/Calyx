// ActiveAISuggestionEngine.swift
// CTerm
//
// Warp-style "Active AI" — proactively generates contextual prompt suggestions
// after a command block finishes, based on its output and the current project context.
// Suggestions appear as clickable chips above the input bar.
//
// v2: Confidence-gated, ranked, deduplicated. Suppresses generic junk.
//     Incorporates failure streaks, memory, and workflow phase.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ActiveAI")

// MARK: - Model

struct ActiveAISuggestion: Identifiable, Sendable {
    let id: UUID
    let prompt: String
    let icon: String
    let kind: Kind
    let blockID: UUID?
    let confidence: Double

    enum Kind: Sendable {
        case fix
        case explain
        case nextStep
        case continueAgent
        case custom(String)
    }

    init(prompt: String, icon: String, kind: Kind, blockID: UUID? = nil, confidence: Double = 0.5) {
        self.id = UUID()
        self.prompt = prompt
        self.icon = icon
        self.kind = kind
        self.blockID = blockID
        self.confidence = confidence
    }
}

// MARK: - Engine

@Observable
@MainActor
final class ActiveAISuggestionEngine {

    /// Current suggestions for the active tab. Replaced on each new block.
    private(set) var suggestions: [ActiveAISuggestion] = []
    /// True while generating suggestions.
    private(set) var isGenerating = false

    private var generationTask: Task<Void, Never>?
    private var lastBlockID: UUID?
    private var planObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

    /// Recent command blocks for context (set by the window controller).
    var recentBlocks: [TerminalCommandBlock] = []

    // MARK: - Lifecycle

    func startObserving() {
        guard planObserver == nil else { return }
        planObserver = NotificationCenter.default.addObserver(
            forName: .agentPlanCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let goal = note.userInfo?["goal"] as? String ?? "the previous task"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let chip = ActiveAISuggestion(
                    prompt: "Continue from: \(goal)",
                    icon: "arrow.right.circle.fill",
                    kind: .continueAgent,
                    confidence: 0.7
                )
                self.suggestions.append(chip)
            }
        }

        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .agentSessionCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let nextActions = note.userInfo?["nextActions"] as? [String] ?? []
            let summary = note.userInfo?["summary"] as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasContinueChip = self.suggestions.contains { s in
                    if case .continueAgent = s.kind { return true }
                    return false
                }
                guard self.suggestions.isEmpty || !hasContinueChip else { return }
                if !summary.isEmpty {
                    self.suggestions.append(ActiveAISuggestion(
                        prompt: summary,
                        icon: "checkmark.circle.fill",
                        kind: .continueAgent,
                        confidence: 0.65
                    ))
                }
                for action in nextActions.prefix(2) {
                    guard !ConfidenceScorer.isGenericSuggestion(action) else { continue }
                    self.suggestions.append(ActiveAISuggestion(
                        prompt: action,
                        icon: "arrow.right.circle",
                        kind: .nextStep,
                        confidence: 0.55
                    ))
                }
            }
        }
    }

    func stopObserving() {
        if let observer = planObserver {
            NotificationCenter.default.removeObserver(observer)
            planObserver = nil
        }
        if let observer = sessionObserver {
            NotificationCenter.default.removeObserver(observer)
            sessionObserver = nil
        }
    }

    // MARK: - Public API

    /// Called when a command block finishes. Generates contextual suggestions.
    func onBlockFinished(_ block: TerminalCommandBlock, pwd: String?) {
        guard UserDefaults.standard.bool(forKey: AppStorageKeys.activeAIEnabled) else { return }
        guard block.id != lastBlockID else { return }
        lastBlockID = block.id

        // Skip trivial commands entirely — no chips for `ls`, `pwd`, etc.
        if ConfidenceScorer.isTrivialCommand(block.titleText) {
            suggestions = []
            ActiveAITelemetry.log(event: .suggestionSuppressed, command: block.titleText)
            return
        }

        // Build static candidates, then filter and rank
        let candidates = staticSuggestions(for: block)
        let hasMemory = hasRelevantMemory(pwd: pwd)
        suggestions = SuggestionFilter.filterAndRank(
            candidates,
            block: block,
            recentCommands: recentBlocks,
            hasRelevantMemory: hasMemory
        )

        // Log shown suggestions for telemetry
        for suggestion in suggestions {
            ActiveAITelemetry.log(
                event: .suggestionShown,
                command: block.titleText,
                suggestionText: suggestion.prompt,
                confidence: suggestion.confidence
            )
        }

        // Then enrich with an LLM-generated "next step" suggestion
        generateNextStepSuggestion(for: block, pwd: pwd)
    }

    /// Clear suggestions (e.g. when user starts typing or sends a prompt).
    func clear() {
        generationTask?.cancel()
        generationTask = nil
        suggestions = []
        isGenerating = false
    }

    /// Inject a suggestion from the agent loop pipeline.
    func injectSuggestion(_ suggestion: ActiveAISuggestion) {
        guard !SuggestionFilter.isDuplicate(suggestion, existingSuggestions: suggestions) else { return }
        suggestions.append(suggestion)
        // Re-cap to max visible
        if suggestions.count > SuggestionFilter.maxVisibleChips {
            suggestions = Array(suggestions.suffix(SuggestionFilter.maxVisibleChips))
        }
    }

    // MARK: - Static Suggestions

    private func staticSuggestions(for block: TerminalCommandBlock) -> [ActiveAISuggestion] {
        var chips: [ActiveAISuggestion] = []

        if block.status == .failed {
            let hasActionable = block.errorSnippet.map { ConfidenceScorer.containsActionableError($0) } ?? false
            let fixConfidence: Double = hasActionable ? 0.75 : 0.5

            // Build a specific fix prompt that references the actual error
            let fixPrompt: String
            if let snippet = block.errorSnippet, ConfidenceScorer.containsKnownErrorPattern(snippet) {
                // Extract the first meaningful error line
                let errorLine = snippet.components(separatedBy: "\n")
                    .first(where: { line in
                        let l = line.lowercased()
                        return l.contains("error") || l.contains("failed") || l.contains("not found")
                    }) ?? block.titleText
                fixPrompt = "Fix: \(String(errorLine.prefix(60)))"
            } else {
                fixPrompt = "Fix this error: \(block.titleText)"
            }

            chips.append(ActiveAISuggestion(
                prompt: fixPrompt,
                icon: "wrench.and.screwdriver",
                kind: .fix,
                blockID: block.id,
                confidence: fixConfidence
            ))

            // Only offer "explain" for failures with substantial output
            if let snippet = block.primarySnippet, snippet.count > 50 {
                chips.append(ActiveAISuggestion(
                    prompt: "Explain why \(block.titleText) failed",
                    icon: "questionmark.circle",
                    kind: .explain,
                    blockID: block.id,
                    confidence: 0.45
                ))
            }
        } else if block.status == .succeeded {
            // Only offer explain for commands with substantial, non-trivial output
            if let snippet = block.outputSnippet, snippet.count > 200 {
                chips.append(ActiveAISuggestion(
                    prompt: "Explain the output of: \(block.titleText)",
                    icon: "text.magnifyingglass",
                    kind: .explain,
                    blockID: block.id,
                    confidence: 0.35
                ))
            }
        }

        return chips
    }

    // MARK: - LLM Next-Step Suggestion

    private func generateNextStepSuggestion(for block: TerminalCommandBlock, pwd: String?) {
        generationTask?.cancel()
        isGenerating = true

        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGenerating = false }

            let context = await TerminalContextGatherer.gather(pwd: pwd)
            let predContext = PredictionContextBuilder.build(
                blocks: self.recentBlocks,
                pwd: pwd,
                terminalContext: context
            )
            let prompt = self.buildNextStepPrompt(block: block, context: predContext)

            do {
                let suggestion = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
                guard !Task.isCancelled else { return }
                let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)

                // Gate: check if the LLM suggestion is worth showing
                guard SuggestionFilter.isLLMSuggestionWorthShowing(
                    trimmed, block: block, existingSuggestions: self.suggestions
                ) else {
                    ActiveAITelemetry.log(
                        event: .suggestionSuppressed,
                        command: block.titleText,
                        suggestionText: trimmed
                    )
                    return
                }

                // Score the LLM suggestion
                let hasMemory = self.hasRelevantMemory(pwd: pwd)
                let score = ConfidenceScorer.scoreSuggestion(
                    block: block,
                    suggestionText: trimmed,
                    recentCommands: self.recentBlocks,
                    hasRelevantMemory: hasMemory
                )
                guard score.isAboveLLMThreshold else {
                    ActiveAITelemetry.log(
                        event: .suggestionSuppressed,
                        command: block.titleText,
                        suggestionText: trimmed,
                        confidence: score.value,
                        confidenceReason: score.reason
                    )
                    return
                }

                let chip = ActiveAISuggestion(
                    prompt: trimmed,
                    icon: "arrow.right.circle",
                    kind: .nextStep,
                    blockID: block.id,
                    confidence: score.value
                )
                self.suggestions.append(chip)

                // Re-cap
                if self.suggestions.count > SuggestionFilter.maxVisibleChips {
                    self.suggestions = Array(self.suggestions
                        .sorted { $0.confidence > $1.confidence }
                        .prefix(SuggestionFilter.maxVisibleChips))
                }

                ActiveAITelemetry.log(
                    event: .suggestionShown,
                    command: block.titleText,
                    suggestionText: trimmed,
                    confidence: score.value,
                    confidenceReason: score.reason,
                    workflowPhase: predContext.workflowPhase.rawValue
                )

                logger.debug("ActiveAI: generated next-step (conf=\(score.value, format: .fixed(precision: 2))): \(trimmed.prefix(60))")
            } catch {
                logger.debug("ActiveAI: suggestion generation failed: \(error.localizedDescription)")
            }
        }
    }

    private func buildNextStepPrompt(block: TerminalCommandBlock, context: PredictionContext) -> String {
        let status = block.status == .failed ? "failed (exit \(block.exitCode ?? -1))" : "succeeded"
        let snippet = block.primarySnippet.map { "\n\nOutput (last 500 chars):\n\(String($0.suffix(500)))" } ?? ""

        return """
        Based on this terminal session, suggest the single most useful next action \
        as a short natural-language prompt (max 12 words). \
        The prompt will be sent to an AI coding agent.

        Rules:
        - Be specific to the actual error or output. Reference file names, error codes, or test names.
        - Do NOT suggest generic actions like "try again", "check logs", "read docs", or "review the error".
        - If the command succeeded and the output is unremarkable, respond with just "SKIP".
        - If you're not confident, respond with just "SKIP".

        Context:
        \(context.enrichedContextBlock)

        Recent commands:
        \(context.historyBlock)

        Last command: \(block.titleText) [\(status)]\(snippet)

        Respond with only the prompt text (or "SKIP"), no explanation.
        """
    }

    // MARK: - Helpers

    private func hasRelevantMemory(pwd: String?) -> Bool {
        guard let pwd else { return false }
        let key = AgentMemoryStore.key(for: pwd)
        return !AgentMemoryStore.shared.listAll(projectKey: key).isEmpty
    }
}
