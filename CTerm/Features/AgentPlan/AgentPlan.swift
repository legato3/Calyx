// AgentPlan.swift
// CTerm
//
// Structured multi-step agent plan model. Replaces the single-decision agent loop
// with a visible, approvable sequence of steps. Each step has a lifecycle:
// pending → approved → running → succeeded/failed/skipped.

import Foundation
import Observation

// MARK: - Step

struct AgentPlanStep: Identifiable, Sendable {
    let id: UUID
    var title: String
    var command: String?
    var status: StepStatus
    var output: String?
    var durationMs: Int?
    /// Authoritative dispatch kind (shell / browser / peer / manual).
    /// Set by PlanBuilder; defaults to .shell for back-compat.
    var kind: StepKind
    /// Pre-computed hint: will ApprovalGate prompt the user when this step
    /// reaches dispatch? Used by the run panel to flag risky rows up front.
    var willAsk: Bool

    enum StepStatus: String, Sendable {
        case pending
        case approved
        case running
        case succeeded
        case failed
        case skipped

        var label: String {
            switch self {
            case .pending:   return "Pending"
            case .approved:  return "Approved"
            case .running:   return "Running"
            case .succeeded: return "Done"
            case .failed:    return "Failed"
            case .skipped:   return "Skipped"
            }
        }

        var icon: String {
            switch self {
            case .pending:   return "circle"
            case .approved:  return "checkmark.circle"
            case .running:   return "arrow.trianglehead.clockwise"
            case .succeeded: return "checkmark.circle.fill"
            case .failed:    return "xmark.circle.fill"
            case .skipped:   return "forward.circle"
            }
        }

        var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .skipped: return true
            case .pending, .approved, .running: return false
            }
        }
    }

    init(title: String, command: String? = nil, kind: StepKind? = nil, willAsk: Bool = false) {
        self.id = UUID()
        self.title = title
        self.command = command
        self.status = .pending
        self.kind = kind ?? StepKind.infer(from: command)
        self.willAsk = willAsk
    }
}

// MARK: - Plan Status

enum AgentPlanStatus: String, Sendable {
    case planning
    case ready
    case executing
    case paused
    case completed
    case failed

    var label: String {
        switch self {
        case .planning:  return "Planning…"
        case .ready:     return "Ready"
        case .executing: return "Executing"
        case .paused:    return "Paused"
        case .completed: return "Completed"
        case .failed:    return "Failed"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

// MARK: - Plan

@Observable
@MainActor
final class AgentPlan: Identifiable {
    let id: UUID
    let goal: String
    let backend: AgentPlanningBackend
    var steps: [AgentPlanStep] = []
    var status: AgentPlanStatus = .planning
    var summary: String?
    var streamingPreview: String?
    let createdAt: Date

    init(goal: String, backend: AgentPlanningBackend) {
        self.id = UUID()
        self.goal = goal
        self.backend = backend
        self.createdAt = Date()
    }

    /// The user-visible goal with context envelope stripped.
    var displayGoal: String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\n\n<cterm_agent_context>") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    var currentStepIndex: Int? {
        steps.firstIndex(where: { $0.status == .running })
    }

    var nextPendingIndex: Int? {
        steps.firstIndex(where: { $0.status == .pending })
    }

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let done = steps.filter { $0.status.isTerminal }.count
        return Double(done) / Double(steps.count)
    }

    var completedCount: Int {
        steps.filter { $0.status == .succeeded }.count
    }

    var hasUnapprovedSteps: Bool {
        steps.contains { $0.status == .pending }
    }
}
