// AgentPlanStore.swift
// CTerm
//
// Manages the active agent plan for a tab. Coordinates plan generation,
// step approval, execution dispatch, and completion detection.
// Lives alongside the existing OllamaAgentSession — the plan is the
// structured layer on top.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentPlanStore")

@Observable
@MainActor
final class AgentPlanStore {

    /// The active plan for the current tab. Nil when no plan is running.
    private(set) var activePlan: AgentPlan?

    /// True while the LLM is generating the plan steps.
    var isGenerating: Bool { activePlan?.status == .planning }

    // MARK: - Plan Lifecycle

    func createPlan(goal: String, backend: AgentPlanningBackend) -> AgentPlan {
        let plan = AgentPlan(goal: goal, backend: backend)
        activePlan = plan
        logger.info("AgentPlan created: \(plan.displayGoal.prefix(80))")
        return plan
    }

    /// Point the store at an existing plan (used when the plan was created by
    /// another subsystem, e.g. owned by an AgentSession).
    func adoptPlan(_ plan: AgentPlan) {
        activePlan = plan
    }

    func setPlanReady() {
        guard let plan = activePlan, plan.status == .planning else { return }
        plan.status = plan.steps.isEmpty ? .failed : .ready
        plan.streamingPreview = nil
        if plan.steps.isEmpty {
            plan.summary = "Could not generate a plan for this goal."
        }
    }

    func updateStreamingPreview(_ text: String) {
        activePlan?.streamingPreview = text
    }

    func addStep(_ step: AgentPlanStep) {
        activePlan?.steps.append(step)
    }

    func setSteps(_ steps: [AgentPlanStep]) {
        activePlan?.steps = steps
        setPlanReady()
    }

    // MARK: - Step Mutations

    func approveStep(id: UUID) {
        guard let plan = activePlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }),
              plan.steps[idx].status == .pending
        else { return }
        plan.steps[idx].status = .approved
        if plan.status == .ready { plan.status = .executing }
    }

    func approveAllPending() {
        guard let plan = activePlan else { return }
        for i in plan.steps.indices where plan.steps[i].status == .pending {
            plan.steps[i].status = .approved
        }
        if plan.status == .ready { plan.status = .executing }
    }

    /// Approve only the pending steps flagged as !willAsk. The risky ones stay
    /// pending so the user can answer them individually.
    func approveSafeSteps() {
        guard let plan = activePlan else { return }
        for i in plan.steps.indices
            where plan.steps[i].status == .pending && !plan.steps[i].willAsk {
            plan.steps[i].status = .approved
        }
        if plan.status == .ready { plan.status = .executing }
    }

    func skipStep(id: UUID) {
        guard let plan = activePlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }),
              plan.steps[idx].status == .pending || plan.steps[idx].status == .approved
        else { return }
        plan.steps[idx].status = .skipped
    }

    func markStepRunning(id: UUID) {
        guard let plan = activePlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id })
        else { return }
        plan.steps[idx].status = .running
        plan.status = .executing
    }

    func markStepSucceeded(id: UUID, output: String?, durationMs: Int?) {
        guard let plan = activePlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id })
        else { return }
        plan.steps[idx].status = .succeeded
        plan.steps[idx].output = output
        plan.steps[idx].durationMs = durationMs
        checkPlanCompletion()
    }

    func markStepFailed(id: UUID, output: String?) {
        guard let plan = activePlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id })
        else { return }
        plan.steps[idx].status = .failed
        plan.steps[idx].output = output
        // Don't auto-fail the whole plan — let the user decide to continue or stop
    }

    // MARK: - Plan Control

    func pausePlan() {
        guard let plan = activePlan, plan.status == .executing else { return }
        plan.status = .paused
    }

    func resumePlan() {
        guard let plan = activePlan, plan.status == .paused else { return }
        plan.status = .executing
    }

    func stopPlan(summary: String? = nil) {
        guard let plan = activePlan else { return }
        plan.status = .completed
        plan.summary = summary ?? "Plan stopped by user."
        // Skip remaining pending steps
        for i in plan.steps.indices where !plan.steps[i].status.isTerminal {
            plan.steps[i].status = .skipped
        }
        postAgentLifecycleNotification(.agentPlanCompleted)
        logger.info("AgentPlan stopped: \(plan.displayGoal.prefix(60))")
    }

    func failPlan(message: String) {
        guard let plan = activePlan else { return }
        plan.status = .failed
        plan.summary = message
        postAgentLifecycleNotification(.agentPlanFailed)
        logger.info("AgentPlan failed: \(message.prefix(80))")
    }

    func clearPlan() {
        activePlan = nil
    }

    /// Returns the next step that is approved and ready to execute.
    func nextExecutableStep() -> AgentPlanStep? {
        activePlan?.steps.first(where: { $0.status == .approved })
    }

    // MARK: - Completion Check

    private func checkPlanCompletion() {
        guard let plan = activePlan else { return }
        let allDone = plan.steps.allSatisfy { $0.status.isTerminal }
        guard allDone else { return }

        let anyFailed = plan.steps.contains { $0.status == .failed }
        if anyFailed {
            plan.status = .failed
            plan.summary = "Plan completed with errors."
            postAgentLifecycleNotification(.agentPlanFailed)
        } else {
            plan.status = .completed
            plan.summary = "All steps completed successfully."
            postAgentLifecycleNotification(.agentPlanCompleted)
        }
        logger.info("AgentPlan finished: \(plan.status.label)")
    }

    // MARK: - Notifications

    private func postAgentLifecycleNotification(_ name: Notification.Name) {
        guard let plan = activePlan else { return }
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [
                "goal": plan.displayGoal,
                "status": plan.status.rawValue,
                "completedSteps": plan.completedCount,
                "totalSteps": plan.steps.count,
            ]
        )
    }
}

// MARK: - Agent Lifecycle Notification Names

extension Notification.Name {
    static let agentPlanCompleted = Notification.Name("com.legato3.cterm.agentPlanCompleted")
    static let agentPlanFailed = Notification.Name("com.legato3.cterm.agentPlanFailed")
    static let agentPlanApproved = Notification.Name("com.legato3.cterm.agentPlanApproved")
}
