// AgentSessionState.swift
// CTerm
//
// Explicit state machine for the agent loop pipeline:
// intent → plan → execute → observe → summarize → suggest next step.
//
// Tracks the full lifecycle of a single user request through the agent system.
// Observable so views can bind directly; all mutations on @MainActor.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentSessionState")

// MARK: - Phase

enum AgentPhase: String, Sendable {
    case idle
    case classifying      // IntentRouter is determining intent type
    case planning         // PlanBuilder is generating steps
    case awaitingApproval // plan ready, waiting for user to approve
    case executing        // ExecutionCoordinator is running steps
    case observing        // waiting for command output / observation
    case summarizing      // ResultSummarizer is producing summary
    case completed
    case failed

    var label: String {
        switch self {
        case .idle:             return "Idle"
        case .classifying:      return "Classifying…"
        case .planning:         return "Planning…"
        case .awaitingApproval: return "Awaiting Approval"
        case .executing:        return "Executing"
        case .observing:        return "Observing…"
        case .summarizing:      return "Summarizing…"
        case .completed:        return "Completed"
        case .failed:           return "Failed"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed
    }

    var isActive: Bool {
        switch self {
        case .classifying, .planning, .executing, .observing, .summarizing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Approval Requirement

enum ApprovalRequirement: String, Sendable {
    case none           // auto-approved (safe read-only ops)
    case perStep        // each step needs individual approval
    case planLevel      // approve the whole plan at once
}

// MARK: - Artifact

struct AgentArtifact: Identifiable, Sendable {
    let id: UUID
    let kind: Kind
    let value: String
    let createdAt: Date

    enum Kind: String, Sendable {
        case fileChanged
        case commandOutput
        case memoryWritten
        case peerMessage
        case diffGenerated
    }

    init(kind: Kind, value: String) {
        self.id = UUID()
        self.kind = kind
        self.value = value
        self.createdAt = Date()
    }
}

// MARK: - Session State

@Observable
@MainActor
final class AgentSessionState: Identifiable {
    let id: UUID
    let userIntent: String
    let tabID: UUID?
    let startedAt: Date

    /// Current phase in the pipeline.
    private(set) var phase: AgentPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            updatedAt = Date()
            logger.info("AgentSession [\(self.id.uuidString.prefix(8))]: \(oldValue.rawValue) → \(self.phase.rawValue)")
            SessionAuditLogger.log(
                type: .agentPhaseChanged,
                detail: "Agent phase: \(oldValue.rawValue) → \(phase.rawValue)"
            )
        }
    }

    /// Classified intent (set after classifying phase).
    var classifiedIntent: IntentCategory?

    /// The plan steps (set after planning phase).
    var planSteps: [AgentPlanStep] = []

    /// Index of the currently executing step.
    var currentStepIndex: Int?

    /// What level of approval is required.
    var approvalRequirement: ApprovalRequirement = .planLevel

    /// Accumulated artifacts from execution.
    var artifacts: [AgentArtifact] = []

    /// Completion summary (set after summarizing phase).
    var summary: String?

    /// Suggested next actions (set after summarizing phase).
    var nextActions: [String] = []

    /// Error message if failed.
    var errorMessage: String?

    var updatedAt: Date

    init(userIntent: String, tabID: UUID? = nil) {
        self.id = UUID()
        self.userIntent = userIntent
        self.tabID = tabID
        self.startedAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Phase Transitions

    func transitionTo(_ newPhase: AgentPhase) {
        phase = newPhase
    }

    func fail(message: String) {
        errorMessage = message
        phase = .failed
    }

    func addArtifact(_ artifact: AgentArtifact) {
        artifacts.append(artifact)
    }

    // MARK: - Derived

    var displayIntent: String {
        let trimmed = userIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\n\n<cterm_agent_context>") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    var progress: Double {
        guard !planSteps.isEmpty else { return 0 }
        let done = planSteps.filter { $0.status.isTerminal }.count
        return Double(done) / Double(planSteps.count)
    }

    var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }
}
