// TaskLifecycle.swift
// CTerm
//
// Explicit state machine for task execution. Defines valid transitions,
// retry policy, cancellation tokens, and partial result accumulation.
// Sits between TaskQueueStore (queue management) and AgentLoopCoordinator
// (execution pipeline). Each task gets its own lifecycle instance.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "TaskLifecycle")

// MARK: - Task Phase (state machine)

enum TaskPhase: String, Sendable, Codable {
    case queued           // waiting in the queue
    case planning         // agent is generating a plan
    case awaitingApproval // plan ready, user must approve
    case executing        // steps are running
    case paused           // user paused execution
    case observing        // waiting for command output
    case summarizing      // generating summary + next actions
    case completed        // all done
    case failed           // terminal failure
    case cancelled        // user cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .planning, .executing, .observing, .summarizing: return true
        default: return false
        }
    }

    var canPause: Bool {
        switch self {
        case .executing, .observing: return true
        default: return false
        }
    }

    var canCancel: Bool { !isTerminal }

    var icon: String {
        switch self {
        case .queued:           return "clock"
        case .planning:         return "list.bullet.clipboard"
        case .awaitingApproval: return "hand.raised"
        case .executing:        return "play.fill"
        case .paused:           return "pause.fill"
        case .observing:        return "eye"
        case .summarizing:      return "text.magnifyingglass"
        case .completed:        return "checkmark.circle.fill"
        case .failed:           return "xmark.circle.fill"
        case .cancelled:        return "stop.circle.fill"
        }
    }

    var tintName: String {
        switch self {
        case .queued:           return "secondary"
        case .planning:         return "blue"
        case .awaitingApproval: return "orange"
        case .executing:        return "purple"
        case .paused:           return "yellow"
        case .observing:        return "teal"
        case .summarizing:      return "indigo"
        case .completed:        return "green"
        case .failed:           return "red"
        case .cancelled:        return "gray"
        }
    }

    /// Valid transitions from this phase.
    var validTransitions: Set<TaskPhase> {
        switch self {
        case .queued:           return [.planning, .cancelled]
        case .planning:         return [.awaitingApproval, .executing, .failed, .cancelled]
        case .awaitingApproval: return [.executing, .cancelled]
        case .executing:        return [.observing, .paused, .summarizing, .failed, .cancelled]
        case .paused:           return [.executing, .cancelled]
        case .observing:        return [.executing, .summarizing, .failed, .cancelled]
        case .summarizing:      return [.completed, .failed]
        case .completed:        return []
        case .failed:           return [.queued] // retry re-queues
        case .cancelled:        return []
        }
    }
}

// MARK: - Retry Policy

struct TaskRetryPolicy: Sendable {
    let maxAttempts: Int
    let backoffSeconds: [TimeInterval]

    static let `default` = TaskRetryPolicy(
        maxAttempts: 3,
        backoffSeconds: [2, 5, 15]
    )

    static let none = TaskRetryPolicy(maxAttempts: 1, backoffSeconds: [])

    func delay(forAttempt attempt: Int) -> TimeInterval {
        let idx = min(attempt, backoffSeconds.count - 1)
        return idx >= 0 ? backoffSeconds[idx] : 0
    }
}

// MARK: - Task Priority

enum TaskPriority: Int, Sendable, Codable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .low:    return "Low"
        case .normal: return "Normal"
        case .high:   return "High"
        case .urgent: return "Urgent"
        }
    }

    var icon: String {
        switch self {
        case .low:    return "arrow.down"
        case .normal: return "minus"
        case .high:   return "arrow.up"
        case .urgent: return "exclamationmark.2"
        }
    }
}

// MARK: - Partial Result

struct TaskPartialResult: Identifiable, Sendable {
    let id: UUID
    let stepIndex: Int
    let output: String
    let exitCode: Int?
    let timestamp: Date
    let artifactKind: AgentArtifact.Kind?

    init(stepIndex: Int, output: String, exitCode: Int? = nil, artifactKind: AgentArtifact.Kind? = nil) {
        self.id = UUID()
        self.stepIndex = stepIndex
        self.output = output
        self.exitCode = exitCode
        self.timestamp = Date()
        self.artifactKind = artifactKind
    }
}

// MARK: - Task Execution Mode

enum TaskExecutionMode: String, Sendable, Codable {
    /// Foreground: task owns the terminal, user sees output live.
    case foreground
    /// Background: task runs in a hidden pane, user can switch away.
    case background

    var label: String {
        switch self {
        case .foreground: return "Foreground"
        case .background: return "Background"
        }
    }
}
