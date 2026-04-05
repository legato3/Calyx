// NextCommandPredictor.swift
// CTerm
//
// Warp-style "Next Command" — predicts the next shell command as ghost text
// based on command history, current directory, and git context.
//
// v2: Confidence-gated predictions. Aggressive cancellation on typing changes.
//     Shell-realistic completions only — rejects natural language, multi-line,
//     and predictions that repeat recent failures. Prefers commands that fit
//     the current project type and workflow phase.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "NextCommand")

@Observable
@MainActor
final class NextCommandPredictor {

    /// The current ghost-text suggestion. Nil when no suggestion is available.
    private(set) var suggestion: String? = nil
    /// True while a prediction is in flight.
    private(set) var isPredicting = false

    private var predictionTask: Task<Void, Never>?
    private var lastInputText: String = ""
    private var lastPwd: String? = nil
    /// Monotonically increasing generation counter — used to discard stale results.
    private var generation: UInt64 = 0

    // Debounce: wait this long after the last keystroke before predicting.
    private static let debounceNanoseconds: UInt64 = 600_000_000  // 600ms
    // Minimum prefix length before we attempt prediction.
    private static let minPrefixLength = 2

    // MARK: - Public API

    /// Call when the user's draft text changes. Triggers debounced prediction.
    func onTextChanged(_ text: String, commandHistory: [TerminalCommandBlock], pwd: String?) {
        guard UserDefaults.standard.bool(forKey: AppStorageKeys.nextCommandEnabled) else {
            suggestion = nil
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clear immediately on empty input
        if trimmed.isEmpty {
            cancelAndClear()
            return
        }

        // Too short to predict meaningfully
        if trimmed.count < Self.minPrefixLength {
            cancelAndClear()
            return
        }

        // If the current suggestion already starts with what the user typed, keep it
        if let current = suggestion,
           current.lowercased().hasPrefix(trimmed.lowercased()),
           current != trimmed {
            return
        }

        // User typed something that diverges from the current suggestion → cancel immediately
        if suggestion != nil {
            suggestion = nil
            ActiveAITelemetry.log(event: .predictionDismissed, command: trimmed)
        }

        lastInputText = trimmed
        lastPwd = pwd
        generation &+= 1
        schedulePrediction(text: trimmed, history: commandHistory, pwd: pwd, gen: generation)
    }

    /// Accept the current suggestion — returns the full suggested text.
    func accept() -> String? {
        guard let s = suggestion else { return nil }
        suggestion = nil
        ActiveAITelemetry.log(event: .predictionAccepted, suggestionText: s)
        return s
    }

    /// Dismiss the current suggestion without accepting.
    func dismiss() {
        if let s = suggestion {
            ActiveAITelemetry.log(event: .predictionDismissed, suggestionText: s)
        }
        cancelAndClear()
    }

    // MARK: - Prediction

    private func cancelAndClear() {
        predictionTask?.cancel()
        predictionTask = nil
        suggestion = nil
        isPredicting = false
    }

    private func schedulePrediction(
        text: String,
        history: [TerminalCommandBlock],
        pwd: String?,
        gen: UInt64
    ) {
        predictionTask?.cancel()
        isPredicting = false

        predictionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Debounce
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled, self.generation == gen else { return }

            self.isPredicting = true
            defer { self.isPredicting = false }

            // Try fast local completion first (history-based)
            if let localMatch = self.localHistoryCompletion(prefix: text, history: history) {
                guard !Task.isCancelled, self.generation == gen else { return }
                self.suggestion = localMatch
                ActiveAITelemetry.log(
                    event: .predictionShown,
                    command: text,
                    suggestionText: localMatch,
                    confidence: 0.8
                )
                logger.debug("NextCommand: local match '\(localMatch.prefix(60))'")
                return
            }

            // Fall back to LLM prediction
            let predicted = await self.predict(prefix: text, history: history, pwd: pwd)
            guard !Task.isCancelled, self.generation == gen else { return }

            if let predicted {
                self.suggestion = predicted
                logger.debug("NextCommand: predicted '\(predicted.prefix(60))'")
            } else {
                self.suggestion = nil
            }
        }
    }

    // MARK: - Local History Completion

    /// Fast, zero-latency completion from recent command history.
    /// Returns the most recent command that starts with the prefix.
    private func localHistoryCompletion(
        prefix: String,
        history: [TerminalCommandBlock]
    ) -> String? {
        let lowerPrefix = prefix.lowercased()

        // Search recent history for a matching command
        for block in history.prefix(20) {
            let cmd = block.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty, cmd != prefix else { continue }
            guard cmd.lowercased().hasPrefix(lowerPrefix) else { continue }

            // Don't suggest commands that recently failed (unless user is explicitly re-typing)
            if block.status == .failed {
                // Only skip if there's a more recent successful version
                let hasSuccessful = history.prefix(20).contains {
                    $0.status == .succeeded &&
                    ConfidenceScorer.normalizeCommand($0.titleText) == ConfidenceScorer.normalizeCommand(cmd)
                }
                if !hasSuccessful { continue }
            }

            return cmd
        }
        return nil
    }

    // MARK: - LLM Prediction

    private func predict(
        prefix: String,
        history: [TerminalCommandBlock],
        pwd: String?
    ) async -> String? {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let predContext = PredictionContextBuilder.build(
            blocks: history,
            pwd: pwd,
            terminalContext: context
        )

        let prompt = buildPredictionPrompt(prefix: prefix, context: predContext)

        do {
            let result = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

            // Validate: must be a valid completion of the prefix
            guard trimmed.lowercased().hasPrefix(prefix.lowercased()),
                  trimmed.count > prefix.count else {
                return nil
            }

            // Confidence gate
            let score = ConfidenceScorer.scorePrediction(
                prefix: prefix,
                predicted: trimmed,
                recentCommands: history,
                pwd: pwd,
                projectType: context.projectType
            )

            guard score.isAboveGhostTextThreshold else {
                ActiveAITelemetry.log(
                    event: .predictionSuppressed,
                    command: prefix,
                    suggestionText: trimmed,
                    confidence: score.value,
                    confidenceReason: score.reason
                )
                logger.debug("NextCommand: suppressed (conf=\(score.value, format: .fixed(precision: 2)), \(score.reason)): \(trimmed.prefix(60))")
                return nil
            }

            ActiveAITelemetry.log(
                event: .predictionShown,
                command: prefix,
                suggestionText: trimmed,
                confidence: score.value,
                confidenceReason: score.reason,
                workflowPhase: predContext.workflowPhase.rawValue,
                projectType: context.projectType
            )

            return trimmed
        } catch {
            return nil
        }
    }

    private func buildPredictionPrompt(prefix: String, context: PredictionContext) -> String {
        """
        Complete this shell command prefix. Return ONLY the completed command, nothing else.
        Do not add explanation, commentary, or markdown. If you cannot complete it \
        confidently, return the prefix unchanged.

        Rules:
        - Output must be a single valid shell command (one line).
        - Output must start with the exact prefix provided.
        - Prefer commands the user has run recently in this session.
        - Prefer commands appropriate for the detected project type.
        - Do NOT output natural language, notes, or multi-line text.
        - Do NOT suggest a command that just failed unless you're adding a fix flag.

        Context:
        \(context.enrichedContextBlock)

        Recent commands:
        \(context.historyBlock)

        Command prefix to complete: \(prefix)
        """
    }
}
