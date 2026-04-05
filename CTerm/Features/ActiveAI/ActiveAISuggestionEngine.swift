// ActiveAISuggestionEngine.swift
// CTerm
//
// Warp-style "Active AI" — proactively generates contextual prompt suggestions
// after a command block finishes, based on its output and the current project context.
// Suggestions appear as clickable chips above the input bar.

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
    let blockID: UUID?   // the command block that triggered this suggestion

    enum Kind: Sendable {
        case fix            // fix an error
        case explain        // explain output
        case nextStep       // suggest what to do next
        case continueAgent  // continue from a completed agent plan
        case custom(String)
    }

    init(prompt: String, icon: String, kind: Kind, blockID: UUID? = nil) {
        self.id = UUID()
        self.prompt = prompt
        self.icon = icon
        self.kind = kind
        self.blockID = blockID
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

    // MARK: - Lifecycle

    /// Start listening for agent plan completions to offer continuation chips.
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
                    kind: .continueAgent
                )
                self.suggestions.append(chip)
            }
        }

        // Listen for agent loop session completions (pipeline output)
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
                // Only add chips if the pipeline coordinator hasn't already injected them
                let hasContinueChip = self.suggestions.contains { s in
                    if case .continueAgent = s.kind { return true }
                    return false
                }
                guard self.suggestions.isEmpty || !hasContinueChip else { return }
                if !summary.isEmpty {
                    self.suggestions.append(ActiveAISuggestion(
                        prompt: summary,
                        icon: "checkmark.circle.fill",
                        kind: .continueAgent
                    ))
                }
                for action in nextActions.prefix(2) {
                    self.suggestions.append(ActiveAISuggestion(
                        prompt: action,
                        icon: "arrow.right.circle",
                        kind: .nextStep
                    ))
                }
            }
        }
    }

    private var sessionObserver: NSObjectProtocol?

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

        // Always offer static suggestions immediately
        suggestions = staticSuggestions(for: block)

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

    /// Inject a suggestion from the agent loop pipeline (e.g. after session completion).
    func injectSuggestion(_ suggestion: ActiveAISuggestion) {
        suggestions.append(suggestion)
    }

    // MARK: - Static Suggestions

    private func staticSuggestions(for block: TerminalCommandBlock) -> [ActiveAISuggestion] {
        var chips: [ActiveAISuggestion] = []

        if block.status == .failed {
            chips.append(ActiveAISuggestion(
                prompt: "Fix this error: \(block.titleText)",
                icon: "wrench.and.screwdriver",
                kind: .fix,
                blockID: block.id
            ))
            chips.append(ActiveAISuggestion(
                prompt: "Explain why this failed: \(block.titleText)",
                icon: "questionmark.circle",
                kind: .explain,
                blockID: block.id
            ))
        } else if block.status == .succeeded {
            if let snippet = block.outputSnippet, !snippet.isEmpty {
                chips.append(ActiveAISuggestion(
                    prompt: "Explain the output of: \(block.titleText)",
                    icon: "text.magnifyingglass",
                    kind: .explain,
                    blockID: block.id
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
            let prompt = buildNextStepPrompt(block: block, context: context)

            do {
                let suggestion = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
                guard !Task.isCancelled else { return }
                let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("NOTE:") else { return }

                // Add as a "next step" chip
                let chip = ActiveAISuggestion(
                    prompt: trimmed,
                    icon: "arrow.right.circle",
                    kind: .nextStep,
                    blockID: block.id
                )
                // Insert after static suggestions
                self.suggestions.append(chip)
                logger.debug("ActiveAI: generated next-step suggestion: \(trimmed.prefix(60))")
            } catch {
                logger.debug("ActiveAI: suggestion generation failed: \(error.localizedDescription)")
            }
        }
    }

    private func buildNextStepPrompt(block: TerminalCommandBlock, context: TerminalContext) -> String {
        let status = block.status == .failed ? "failed (exit \(block.exitCode ?? -1))" : "succeeded"
        let snippet = block.primarySnippet.map { "\n\nOutput:\n\($0.prefix(500))" } ?? ""
        return """
        Based on this terminal session, suggest the single most useful next action as a short natural-language prompt (max 12 words).
        The prompt will be sent to an AI coding agent.

        Context:
        \(context.contextBlock)

        Last command: \(block.titleText) [\(status)]\(snippet)

        Respond with only the prompt text, no explanation.
        """
    }
}
