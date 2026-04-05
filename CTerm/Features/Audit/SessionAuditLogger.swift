// SessionAuditLogger.swift
// CTerm
//
// Append-only log of significant events in the current session.
// Persisted to ~/.cterm/sessions/{date}-{sessionID}.json on every append.
// Provides summary stats for the sidebar view and the get_session_summary MCP tool.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "SessionAuditLogger")

// MARK: - Model

enum AuditEventType: String, Codable, Sendable, CaseIterable {
    case commandInjected    = "commandInjected"
    case errorRouted        = "errorRouted"
    case memoryWritten      = "memoryWritten"
    case memoryDeleted      = "memoryDeleted"
    case testRunCompleted   = "testRunCompleted"
    case peerConnected      = "peerConnected"
    case taskCompleted      = "taskCompleted"
    case checkpointCreated  = "checkpointCreated"
    case agentPhaseChanged  = "agentPhaseChanged"

    var displayName: String {
        switch self {
        case .commandInjected:   return "Command"
        case .errorRouted:       return "Error routed"
        case .memoryWritten:     return "Memory written"
        case .memoryDeleted:     return "Memory deleted"
        case .testRunCompleted:  return "Test run"
        case .peerConnected:     return "Peer connected"
        case .taskCompleted:     return "Task completed"
        case .checkpointCreated: return "Checkpoint"
        case .agentPhaseChanged: return "Agent phase"
        }
    }

    var icon: String {
        switch self {
        case .commandInjected:   return "terminal"
        case .errorRouted:       return "exclamationmark.triangle.fill"
        case .memoryWritten:     return "brain.head.profile"
        case .memoryDeleted:     return "brain.head.profile"
        case .testRunCompleted:  return "testtube.2"
        case .peerConnected:     return "person.fill.badge.plus"
        case .taskCompleted:     return "checkmark.circle.fill"
        case .checkpointCreated: return "arrow.triangle.branch"
        case .agentPhaseChanged: return "arrow.triangle.turn.up.right.diamond"
        }
    }

    var color: String {   // SwiftUI color name
        switch self {
        case .commandInjected:   return "blue"
        case .errorRouted:       return "orange"
        case .memoryWritten:     return "purple"
        case .memoryDeleted:     return "purple"
        case .testRunCompleted:  return "teal"
        case .peerConnected:     return "green"
        case .taskCompleted:     return "green"
        case .checkpointCreated: return "yellow"
        case .agentPhaseChanged: return "indigo"
        }
    }

    // Filter groups
    var filterGroup: AuditFilter {
        switch self {
        case .commandInjected:              return .commands
        case .errorRouted:                  return .errors
        case .memoryWritten, .memoryDeleted: return .memory
        case .testRunCompleted:             return .tests
        case .peerConnected, .taskCompleted, .checkpointCreated, .agentPhaseChanged: return .events
        }
    }
}

enum AuditFilter: String, CaseIterable {
    case all      = "All"
    case commands = "Commands"
    case errors   = "Errors"
    case memory   = "Memory"
    case tests    = "Tests"
    case events   = "Events"
}

struct AuditEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let type: AuditEventType
    let detail: String
    let tabTitle: String?

    init(type: AuditEventType, detail: String, tabTitle: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.detail = detail
        self.tabTitle = tabTitle
    }

    var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: timestamp)
    }
}

// MARK: - Logger

@Observable
@MainActor
final class SessionAuditLogger {
    static let shared = SessionAuditLogger()

    let sessionID: UUID = UUID()
    let startedAt: Date = Date()

    private(set) var events: [AuditEvent] = []

    // Summary counters (derived, not stored separately)
    var commandCount:    Int { events.filter { $0.type == .commandInjected }.count }
    var errorCount:      Int { events.filter { $0.type == .errorRouted }.count }
    var memoryCount:     Int { events.filter { $0.type == .memoryWritten }.count }
    var testRunCount:    Int { events.filter { $0.type == .testRunCompleted }.count }
    var taskCount:       Int { events.filter { $0.type == .taskCompleted }.count }
    var checkpointCount: Int { events.filter { $0.type == .checkpointCreated }.count }
    var peerCount:       Int { events.filter { $0.type == .peerConnected }.count }

    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cterm/sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let dateStr = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        fileURL = sessionsDir.appendingPathComponent("\(dateStr)-\(UUID().uuidString.prefix(8)).json")
    }

    // MARK: - Start

    func start() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default

        notificationTokens = [
            center.addObserver(forName: .peerRegistered, object: nil, queue: .main) { [weak self] note in
                let name = note.userInfo?["name"] as? String ?? "agent"
                self?.append(.init(type: .peerConnected, detail: "Agent \"\(name)\" connected"))
            },
            center.addObserver(forName: .testRunnerFinished, object: nil, queue: .main) { [weak self] _ in
                let store = TestRunnerStore.shared
                let detail = "\(store.passCount) passed, \(store.failCount) failed"
                self?.append(.init(type: .testRunCompleted, detail: detail))
            },
        ]
    }

    // MARK: - Appending

    /// Thread-safe entry point — safe to call from any actor or thread.
    nonisolated static func log(type: AuditEventType, detail: String, tabTitle: String? = nil) {
        let event = AuditEvent(type: type, detail: detail, tabTitle: tabTitle)
        Task { @MainActor in
            SessionAuditLogger.shared.append(event)
        }
    }

    func append(_ event: AuditEvent) {
        events.append(event)
        scheduleSave()
    }

    // MARK: - Persistence (debounced)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s debounce
            guard !Task.isCancelled, let self else { return }
            await self.persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Summary

    /// Returns the most recent entries of a given type.
    func recentEntries(ofType type: AuditEventType, limit: Int = 5) -> [AuditEvent] {
        Array(events.reversed().filter { $0.type == type }.prefix(limit))
    }

    func summaryDict() -> [String: Any] {
        let duration = Int(Date().timeIntervalSince(startedAt) / 60)
        return [
            "session_id": sessionID.uuidString,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "duration_minutes": duration,
            "events": [
                "total":               events.count,
                "commands_injected":   commandCount,
                "errors_routed":       errorCount,
                "memories_written":    memoryCount,
                "test_runs":           testRunCount,
                "tasks_completed":     taskCount,
                "checkpoints_created": checkpointCount,
                "peers_connected":     peerCount,
            ]
        ]
    }

    func markdownExport() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let start = fmt.string(from: startedAt)
        let end   = fmt.string(from: Date())

        var lines = [
            "# Session Audit — \(start) → \(end)",
            "",
            "| Metric | Count |",
            "|---|---|",
            "| Commands injected | \(commandCount) |",
            "| Errors routed | \(errorCount) |",
            "| Memories written | \(memoryCount) |",
            "| Test runs | \(testRunCount) |",
            "| Tasks completed | \(taskCount) |",
            "| Checkpoints | \(checkpointCount) |",
            "| Peers connected | \(peerCount) |",
            "",
            "## Timeline",
            "",
        ]

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        for event in events.reversed() {
            let time = timeFmt.string(from: event.timestamp)
            let tab  = event.tabTitle.map { " [\($0)]" } ?? ""
            lines.append("- `\(time)` **\(event.type.displayName)**\(tab) — \(event.detail)")
        }

        return lines.joined(separator: "\n")
    }
}
