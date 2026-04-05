// ActiveAITelemetry.swift
// CTerm
//
// Local-only telemetry for evaluating Active AI suggestion quality.
// Logs suggestion events to ~/.cterm/telemetry/activeai.jsonl for offline analysis.
// No network calls. Opt-in via AppStorageKeys.activeAITelemetryEnabled.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ActiveAITelemetry")

// MARK: - Event Types

enum ActiveAITelemetryEvent: String, Sendable, Codable {
    case suggestionShown        // chip was displayed
    case suggestionAccepted     // user clicked a chip
    case suggestionDismissed    // user dismissed chips
    case suggestionSuppressed   // chip was filtered out by confidence/dedup
    case predictionShown        // ghost text was displayed
    case predictionAccepted     // user accepted ghost text (Tab/→)
    case predictionDismissed    // ghost text was dismissed (kept typing)
    case predictionSuppressed   // prediction was filtered by confidence
}

struct ActiveAITelemetryEntry: Codable, Sendable {
    let timestamp: Date
    let event: ActiveAITelemetryEvent
    let command: String?            // the triggering command (truncated)
    let suggestionText: String?     // the suggestion/prediction text (truncated)
    let confidence: Double?
    let confidenceReason: String?
    let workflowPhase: String?
    let projectType: String?
    let failureStreak: Int?
}

// MARK: - Logger

enum ActiveAITelemetry {
    private static let maxLineLength = 500
    private static var fileHandle: FileHandle?
    private static let queue = DispatchQueue(label: "com.legato3.cterm.activeai-telemetry")

    /// Log a telemetry event. No-op if telemetry is disabled.
    static func log(
        event: ActiveAITelemetryEvent,
        command: String? = nil,
        suggestionText: String? = nil,
        confidence: Double? = nil,
        confidenceReason: String? = nil,
        workflowPhase: String? = nil,
        projectType: String? = nil,
        failureStreak: Int? = nil
    ) {
        guard UserDefaults.standard.bool(forKey: AppStorageKeys.activeAITelemetryEnabled) else { return }

        let entry = ActiveAITelemetryEntry(
            timestamp: Date(),
            event: event,
            command: command.map { String($0.prefix(80)) },
            suggestionText: suggestionText.map { String($0.prefix(80)) },
            confidence: confidence,
            confidenceReason: confidenceReason,
            workflowPhase: workflowPhase,
            projectType: projectType,
            failureStreak: failureStreak
        )

        queue.async {
            writeEntry(entry)
        }
    }

    /// Convenience: log a suggestion that was shown.
    static func logSuggestionShown(
        _ suggestion: ActiveAISuggestion,
        command: String,
        confidence: ConfidenceScore,
        context: PredictionContext
    ) {
        log(
            event: .suggestionShown,
            command: command,
            suggestionText: suggestion.prompt,
            confidence: confidence.value,
            confidenceReason: confidence.reason,
            workflowPhase: context.workflowPhase.rawValue,
            projectType: context.terminalContext.projectType,
            failureStreak: context.failureStreak
        )
    }

    /// Convenience: log a prediction that was shown as ghost text.
    static func logPredictionShown(
        _ prediction: String,
        prefix: String,
        confidence: ConfidenceScore,
        context: PredictionContext
    ) {
        log(
            event: .predictionShown,
            command: prefix,
            suggestionText: prediction,
            confidence: confidence.value,
            confidenceReason: confidence.reason,
            workflowPhase: context.workflowPhase.rawValue,
            projectType: context.terminalContext.projectType,
            failureStreak: context.failureStreak
        )
    }

    // MARK: - File I/O

    private static func writeEntry(_ entry: ActiveAITelemetryEntry) {
        do {
            let data = try JSONEncoder().encode(entry)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"

            let handle = try getOrCreateFileHandle()
            handle.write(Data(line.utf8))
        } catch {
            logger.debug("ActiveAITelemetry: write failed: \(error.localizedDescription)")
        }
    }

    private static func getOrCreateFileHandle() throws -> FileHandle {
        if let handle = fileHandle { return handle }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cterm/telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = dir.appendingPathComponent("activeai.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        fileHandle = handle
        return handle
    }
}
