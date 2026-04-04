// NextCommandPredictor.swift
// Calyx
//
// Warp-style "Next Command" — predicts the next shell command as ghost text
// based on command history, current directory, and git context.
// Prediction is debounced and cancelled when the user types.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.terminal", category: "NextCommand")

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

    // Debounce: wait this long after the last keystroke before predicting.
    private static let debounceNanoseconds: UInt64 = 600_000_000  // 600ms

    // MARK: - Public API

    /// Call when the user's draft text changes. Triggers debounced prediction.
    func onTextChanged(_ text: String, commandHistory: [TerminalCommandBlock], pwd: String?) {
        guard UserDefaults.standard.bool(forKey: AppStorageKeys.nextCommandEnabled) else {
            suggestion = nil
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clear suggestion if text is empty or user is typing something different
        if trimmed.isEmpty {
            suggestion = nil
            predictionTask?.cancel()
            isPredicting = false
            return
        }

        // If the current suggestion already starts with what the user typed, keep it
        if let current = suggestion, current.lowercased().hasPrefix(trimmed.lowercased()), current != trimmed {
            return
        }

        lastInputText = trimmed
        lastPwd = pwd
        schedulePrediction(text: trimmed, history: commandHistory, pwd: pwd)
    }

    /// Accept the current suggestion — returns the full suggested text.
    func accept() -> String? {
        let s = suggestion
        suggestion = nil
        return s
    }

    /// Dismiss the current suggestion without accepting.
    func dismiss() {
        suggestion = nil
        predictionTask?.cancel()
        isPredicting = false
    }

    // MARK: - Prediction

    private func schedulePrediction(text: String, history: [TerminalCommandBlock], pwd: String?) {
        predictionTask?.cancel()
        isPredicting = false

        predictionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Debounce
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled, self.lastInputText == text else { return }

            self.isPredicting = true
            defer { self.isPredicting = false }

            let predicted = await self.predict(prefix: text, history: history, pwd: pwd)
            guard !Task.isCancelled, self.lastInputText == text else { return }

            if let predicted, !predicted.isEmpty, predicted != text {
                self.suggestion = predicted
                logger.debug("NextCommand: predicted '\(predicted.prefix(60))'")
            } else {
                self.suggestion = nil
            }
        }
    }

    private func predict(prefix: String, history: [TerminalCommandBlock], pwd: String?) async -> String? {
        // Build history context (last 8 commands)
        let historyLines = history.prefix(8).reversed().map { block -> String in
            let status = block.status == .failed ? "[failed]" : "[ok]"
            return "\(status) \(block.titleText)"
        }.joined(separator: "\n")

        let context = await TerminalContextGatherer.gather(pwd: pwd)

        let prompt = """
        Complete this shell command prefix. Return only the completed command, nothing else.
        Do not add explanation. If you cannot complete it confidently, return the prefix unchanged.

        Context:
        \(context.contextBlock)

        Recent command history:
        \(historyLines.isEmpty ? "(none)" : historyLines)

        Command prefix to complete: \(prefix)
        """

        do {
            let result = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only return if it's a valid completion of the prefix
            guard trimmed.lowercased().hasPrefix(prefix.lowercased()) || trimmed.count > prefix.count else {
                return nil
            }
            return trimmed
        } catch {
            return nil
        }
    }
}
