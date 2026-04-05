// ManagedTask.swift
// CTerm
//
// Rich task model that wraps the existing QueuedTask with lifecycle state,
// partial results, retry tracking, and agent session binding.
// Observable so views can bind directly to individual task state.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ManagedTask")

@Observable
@MainActor
final class ManagedTask: Identifiable {
    let id: UUID
    let prompt: String
    let createdAt: Date

    // MARK: - Configuration

    var priority: TaskPriority
    var executionMode: TaskExecutionMode
    var retryPolicy: TaskRetryPolicy
    var model: TaskModel
    var targetPeerName: String?

    // MARK: - Lifecycle State

    private(set) var phase: TaskPhase = .queued {
        didSet {
            guard oldValue != phase else { return }
            updatedAt = Date()
            phaseHistory.append(PhaseTransition(from: oldValue, to: phase, at: updatedAt))
            logger.info("ManagedTask [\(self.id.uuidString.prefix(8))]: \(oldValue.rawValue) → \(self.phase.rawValue)")
            SessionAuditLogger.log(
                type: .agentPhaseChanged,
                detail: "Task \(self.displayPrompt.prefix(40)): \(oldValue.rawValue) → \(self.phase.rawValue)"
            )
        }
    }

    var updatedAt: Date

    // MARK: - Execution Tracking

    /// The agent session driving this task (set when execution starts).
    var agentSession: AgentSessionState?

    /// Plan steps (mirrored from agent session for direct binding).
    var planSteps: [AgentPlanStep] = []

    /// Streaming plan preview during generation.
    var streamingPreview: String?

    /// Partial results accumulated during execution.
    private(set) var partialResults: [TaskPartialResult] = []

    /// Completion summary.
    var summary: String?

    /// Suggested next actions after completion.
    var nextActions: [String] = []

    /// Error message if failed.
    var errorMessage: String?

    // MARK: - Retry Tracking

    private(set) var attemptCount: Int = 0
    private(set) var lastFailureMessage: String?

    // MARK: - Phase History (for debugging)

    struct PhaseTransition: Sendable {
        let from: TaskPhase
        let to: TaskPhase
        let at: Date
    }

    private(set) var phaseHistory: [PhaseTransition] = []

    // MARK: - Init

    init(
        prompt: String,
        priority: TaskPriority = .normal,
        executionMode: TaskExecutionMode = .foreground,
        retryPolicy: TaskRetryPolicy = .default,
        model: TaskModel = .auto,
        targetPeerName: String? = nil
    ) {
        self.id = UUID()
        self.prompt = prompt
        self.createdAt = Date()
        self.updatedAt = Date()
        self.priority = priority
        self.executionMode = executionMode
        self.retryPolicy = retryPolicy
        self.model = model
        self.targetPeerName = targetPeerName
    }

    // MARK: - Phase Transitions

    @discardableResult
    func transitionTo(_ newPhase: TaskPhase) -> Bool {
        guard phase.validTransitions.contains(newPhase) else {
            logger.warning("ManagedTask: invalid transition \(self.phase.rawValue) → \(newPhase.rawValue)")
            return false
        }
        phase = newPhase
        return true
    }

    func fail(message: String) {
        lastFailureMessage = message
        errorMessage = message
        _ = transitionTo(.failed)
    }

    func cancel() {
        _ = transitionTo(.cancelled)
    }

    // MARK: - Retry

    var canRetry: Bool {
        phase == .failed && attemptCount < retryPolicy.maxAttempts
    }

    var retryDelay: TimeInterval {
        retryPolicy.delay(forAttempt: attemptCount)
    }

    func prepareForRetry() -> Bool {
        guard canRetry else { return false }
        attemptCount += 1
        errorMessage = nil
        lastFailureMessage = nil
        agentSession = nil
        planSteps = []
        streamingPreview = nil
        summary = nil
        nextActions = []
        // Keep partial results from previous attempts for debugging
        return transitionTo(.queued)
    }

    // MARK: - Partial Results

    func addPartialResult(_ result: TaskPartialResult) {
        partialResults.append(result)
        // Cap at 100 results to prevent unbounded growth
        if partialResults.count > 100 {
            partialResults = Array(partialResults.suffix(100))
        }
    }

    // MARK: - Derived

    var displayPrompt: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\n\n<cterm_agent_context>") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    var progress: Double {
        guard !planSteps.isEmpty else {
            return phase == .completed ? 1.0 : 0.0
        }
        let done = planSteps.filter { $0.status.isTerminal }.count
        return Double(done) / Double(planSteps.count)
    }

    var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }

    var elapsedFormatted: String {
        let s = elapsedSeconds
        if s < 60 { return "\(Int(s))s" }
        return "\(Int(s / 60))m \(Int(s.truncatingRemainder(dividingBy: 60)))s"
    }

    var succeededStepCount: Int {
        planSteps.filter { $0.status == .succeeded }.count
    }

    var failedStepCount: Int {
        planSteps.filter { $0.status == .failed }.count
    }

    var isWaitingForUser: Bool {
        phase == .awaitingApproval || phase == .paused
    }
}
