// AgentPlanExecutor.swift
// CTerm
//
// Drives execution of an AgentPlan's steps through the terminal.
// Coordinates with AgentPlanStore for state, AgentPermissionsStore for
// approval policy, and CheckpointManager for pre/post checkpoints.
// Also handles browser actions and handoff persistence.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentPlanExecutor")

@MainActor
final class AgentPlanExecutor {

    let planStore: AgentPlanStore

    /// Callback to dispatch a shell command to the terminal. Returns the command block ID.
    var dispatchCommand: ((_ command: String) -> UUID?)?

    /// Callback to notify the UI that state changed.
    var onStateChanged: (() -> Void)?

    private var executionTask: Task<Void, Never>?
    private var currentStepStartTime: Date?

    // Safe auto-run is now delegated to RiskScorer — no duplicated command lists.

    init(planStore: AgentPlanStore) {
        self.planStore = planStore
    }

    // MARK: - Execution Loop

    /// Starts executing the plan. Processes approved steps sequentially.
    /// Call this after setting steps or after approving steps.
    func executeNext() {
        guard let plan = planStore.activePlan,
              !plan.status.isTerminal,
              plan.status != .paused
        else { return }

        // Find next executable step
        guard let step = planStore.nextExecutableStep() else {
            // No approved steps — check if all are done
            let allTerminal = plan.steps.allSatisfy { $0.status.isTerminal }
            if allTerminal && !plan.steps.isEmpty {
                completePlan()
            }
            return
        }

        // Auto-approve safe read-only commands if permissions allow
        autoApprovePendingSafeSteps()

        guard let executableStep = planStore.nextExecutableStep() else { return }
        executeStep(executableStep)
    }

    /// Called when a command block finishes in the terminal.
    func handleCommandFinished(blockID: UUID, exitCode: Int, output: String?) {
        guard let plan = planStore.activePlan,
              let runningIdx = plan.steps.firstIndex(where: { $0.status == .running })
        else { return }

        let step = plan.steps[runningIdx]
        let durationMs = currentStepStartTime.map { Int(Date().timeIntervalSince($0) * 1000) }

        if exitCode == 0 {
            planStore.markStepSucceeded(id: step.id, output: output, durationMs: durationMs)
            logger.info("Step succeeded: \(step.title.prefix(60))")
        } else {
            planStore.markStepFailed(id: step.id, output: output)
            logger.warning("Step failed (exit \(exitCode)): \(step.title.prefix(60))")
        }

        currentStepStartTime = nil
        onStateChanged?()

        // Continue to next step after a brief pause
        executionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            self?.executeNext()
        }
    }

    func stop() {
        executionTask?.cancel()
        executionTask = nil
        planStore.stopPlan()
        onStateChanged?()
    }

    // MARK: - Private

    private func executeStep(_ step: AgentPlanStep) {
        guard let command = step.command, !command.isEmpty else {
            // No command — mark as succeeded (informational step)
            planStore.markStepSucceeded(id: step.id, output: nil, durationMs: nil)
            onStateChanged?()
            // Continue immediately
            executionTask = Task { @MainActor [weak self] in
                self?.executeNext()
            }
            return
        }

        planStore.markStepRunning(id: step.id)
        currentStepStartTime = Date()
        onStateChanged?()

        guard let blockID = dispatchCommand?(command) else {
            planStore.markStepFailed(id: step.id, output: "Failed to dispatch command to terminal")
            onStateChanged?()
            return
        }

        logger.info("Executing step: \(command.prefix(80))")
    }

    private func autoApprovePendingSafeSteps() {
        guard let plan = planStore.activePlan else { return }
        let permissions = AgentPermissionsStore.shared

        // Only auto-approve if the permission profile allows agent-decides or always-allow
        guard permissions.shouldAutoAllow(.runCommands) else { return }

        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
        let gitBranch = TerminalControlBridge.shared.delegate?.activeTabGitBranch

        for step in plan.steps where step.status == .pending {
            if let command = step.command {
                let assessment = RiskScorer.assess(command: command, pwd: pwd, gitBranch: gitBranch)
                let decision = permissions.decide(for: assessment)
                if case .autoApprove = decision {
                    planStore.approveStep(id: step.id)
                }
            } else {
                // Informational steps are always safe
                planStore.approveStep(id: step.id)
            }
        }
    }

    private func completePlan() {
        guard let plan = planStore.activePlan else { return }

        // Create post-plan checkpoint
        if let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd {
            Task {
                await CheckpointManager.shared.checkpointAfterPlan(
                    workDir: pwd,
                    goal: plan.displayGoal
                )
            }
        }

        // Save handoff to memory
        if let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd {
            let projectKey = AgentMemoryStore.key(for: pwd)
            let filesChanged = FileChangeStore.shared.recentPaths(limit: 20)
            AgentMemoryStore.shared.saveHandoff(
                projectKey: projectKey,
                goal: plan.displayGoal,
                stepsCompleted: plan.completedCount,
                totalSteps: plan.steps.count,
                filesChanged: filesChanged,
                outcome: plan.status.label
            )
        }

        onStateChanged?()
    }
}
