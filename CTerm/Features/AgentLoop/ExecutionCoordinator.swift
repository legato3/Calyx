// ExecutionCoordinator.swift
// CTerm
//
// Orchestrates step execution across local shell, browser automation, and IPC
// peer delegation. Respects AgentPermissionsStore before dispatching.
// Writes important facts into AgentMemoryStore during execution.
// Bridges to the existing AgentPlanExecutor for terminal command dispatch.
// Wires browser actions through BrowserServer.shared.toolHandler.
// Checks cost budget via ClaudeUsageMonitor before each step.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ExecutionCoordinator")

// MARK: - Execution Strategy

enum ExecutionStrategy: String, Sendable {
    case localShell       // dispatch command to terminal
    case browserAction    // dispatch to BrowserToolHandler
    case peerDelegation   // send via IPC to a peer agent
    case informational    // no execution needed (explain, generate)
}

// MARK: - Coordinator

@MainActor
final class ExecutionCoordinator {

    private let session: AgentSessionState
    private let planStore: AgentPlanStore
    private let executor: AgentPlanExecutor
    private var executionTask: Task<Void, Never>?

    /// Callback when all steps are done (triggers summarization).
    var onAllStepsCompleted: (() -> Void)?

    /// Callback when a step observation is captured.
    var onObservation: ((_ stepIndex: Int, _ output: String) -> Void)?

    /// Callback when a step fails and replanning is needed.
    /// Returns replacement steps for the remaining plan, or nil to continue as-is.
    var onReplanNeeded: ((_ failedStep: AgentPlanStep, _ output: String) async -> [AgentPlanStep]?)?

    init(session: AgentSessionState, planStore: AgentPlanStore, executor: AgentPlanExecutor) {
        self.session = session
        self.planStore = planStore
        self.executor = executor
    }

    // MARK: - Execution

    func start() {
        guard !session.phase.isTerminal else { return }
        session.transitionTo(.executing)

        // Sync session steps into the plan store
        _ = planStore.createPlan(goal: session.userIntent, backend: .ollama)
        for step in session.planSteps {
            planStore.addStep(step)
        }
        if session.approvalRequirement == .none {
            planStore.approveAllPending()
        }
        planStore.setPlanReady()

        executeNextStep()
    }

    func stop() {
        executionTask?.cancel()
        executionTask = nil
        planStore.stopPlan()
        session.transitionTo(.completed)
    }

    /// Called when a command block finishes in the terminal.
    func handleCommandFinished(exitCode: Int, output: String?) {
        guard let stepIndex = session.currentStepIndex ?? currentRunningStepIndex() else { return }

        session.transitionTo(.observing)

        // Record observation
        let observation = output ?? "(no output)"
        onObservation?(stepIndex, observation)

        // Track artifact
        session.addArtifact(AgentArtifact(
            kind: .commandOutput,
            value: String(observation.prefix(500))
        ))

        // Write important observations to memory
        if exitCode != 0 {
            rememberFact(
                key: "last_error",
                value: "Step \(stepIndex + 1) failed (exit \(exitCode)): \(String(observation.prefix(200)))"
            )
        }

        // Update step status
        if exitCode == 0 {
            if stepIndex < session.planSteps.count {
                session.planSteps[stepIndex].status = .succeeded
                session.planSteps[stepIndex].output = String(observation.prefix(1000))
            }
        } else {
            if stepIndex < session.planSteps.count {
                session.planSteps[stepIndex].status = .failed
                session.planSteps[stepIndex].output = String(observation.prefix(1000))
            }
        }

        // Forward to plan executor for its own bookkeeping
        if let blockID = session.planSteps[safe: stepIndex]?.id {
            executor.handleCommandFinished(blockID: blockID, exitCode: exitCode, output: output)
        }

        // If step failed, attempt replan before continuing
        if exitCode != 0 {
            executionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.attemptReplan(failedIndex: stepIndex, output: observation)
            }
        } else {
            // Continue to next step after brief pause
            executionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                self?.executeNextStep()
            }
        }
    }

    // MARK: - Replan

    private func attemptReplan(failedIndex: Int, output: String) async {
        guard let step = session.planSteps[safe: failedIndex] else {
            executeNextStep()
            return
        }

        // Only replan if there are remaining non-terminal steps
        let remainingPending = session.planSteps.filter { !$0.status.isTerminal }
        guard !remainingPending.isEmpty else {
            executeNextStep()
            return
        }

        if let replanCallback = onReplanNeeded {
            if let newSteps = await replanCallback(step, output) {
                logger.info("ExecutionCoordinator: replanned \(newSteps.count) replacement step(s)")

                // Replace remaining pending/approved steps with new ones
                var updated = session.planSteps.filter { $0.status.isTerminal }
                updated.append(contentsOf: newSteps)
                session.planSteps = updated

                // Sync to plan store
                for newStep in newSteps {
                    planStore.addStep(newStep)
                }

                // Auto-approve safe steps in the new plan
                if session.approvalRequirement == .none {
                    for i in session.planSteps.indices where session.planSteps[i].status == .pending {
                        session.planSteps[i].status = .approved
                    }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        executeNextStep()
    }

    // MARK: - Step Execution

    private func executeNextStep() {
        // Check cost budget before proceeding
        if isBudgetExceeded() {
            session.fail(message: "Daily cost budget exceeded. Pausing execution.")
            logger.warning("ExecutionCoordinator: budget exceeded, stopping")
            return
        }

        // Find next approved step
        guard let nextIndex = session.planSteps.firstIndex(where: { $0.status == .approved }) else {
            // Check if all done
            let allTerminal = session.planSteps.allSatisfy { $0.status.isTerminal }
            if allTerminal && !session.planSteps.isEmpty {
                onAllStepsCompleted?()
            }
            return
        }

        session.currentStepIndex = nextIndex
        let step = session.planSteps[nextIndex]
        let strategy = chooseStrategy(for: step)

        logger.info("ExecutionCoordinator: executing step \(nextIndex + 1)/\(self.session.planSteps.count) via \(strategy.rawValue)")

        switch strategy {
        case .localShell:
            executeLocalShell(step: step, index: nextIndex)

        case .browserAction:
            executeBrowserAction(step: step, index: nextIndex)

        case .peerDelegation:
            executePeerDelegation(step: step, index: nextIndex)

        case .informational:
            // Mark as succeeded immediately — no execution needed
            session.planSteps[nextIndex].status = .succeeded
            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
        }
    }

    // MARK: - Strategy Selection

    private func chooseStrategy(for step: AgentPlanStep) -> ExecutionStrategy {
        guard let command = step.command, !command.isEmpty else {
            return .informational
        }

        let lower = command.lowercased()

        // Peer delegation
        if lower.hasPrefix("@") || lower.contains("send_message") || lower.contains("delegate:") {
            return .peerDelegation
        }

        // Browser actions
        if lower.hasPrefix("browse:") || lower.hasPrefix("browser:") {
            return .browserAction
        }
        // URL opening
        if lower.hasPrefix("open http") || lower.hasPrefix("open https") {
            return .browserAction
        }

        return .localShell
    }

    // MARK: - Local Shell Execution

    private func executeLocalShell(step: AgentPlanStep, index: Int) {
        guard let command = step.command else { return }

        let permissions = AgentPermissionsStore.shared
        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
        let gitBranch = TerminalControlBridge.shared.delegate?.activeTabGitBranch

        // Risk-score the command in context
        let assessment = RiskScorer.assess(
            command: command,
            pwd: pwd,
            gitBranch: gitBranch
        )

        let decision = permissions.decide(for: assessment)

        switch decision {
        case .blocked(let reason):
            session.planSteps[index].status = .failed
            session.planSteps[index].output = "Blocked: \(reason)"
            logger.warning("ExecutionCoordinator: blocked (\(assessment.tier.rawValue)): \(command.prefix(60))")

            // Propose a safer alternative
            if let alternative = DenialHandler.proposeSaferAlternative(command: command, assessment: assessment) {
                if let saferCommand = alternative.saferCommand {
                    session.planSteps[index].output = "Blocked: \(reason)\nSuggested alternative: \(saferCommand)\n\(alternative.explanation)"
                }
            }

            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
            return

        case .requireApproval:
            // Step should already be in .approved state from the approval flow.
            // If it somehow got here without approval, mark it pending.
            if step.status != .approved {
                session.planSteps[index].status = .pending
                logger.info("ExecutionCoordinator: step requires approval (risk \(assessment.score)): \(command.prefix(60))")
                return
            }

        case .autoApprove:
            // Record in approval memory for this session
            ApprovalMemory.shared.remember(
                command: command,
                tier: assessment.tier,
                scope: .session,
                projectKey: pwd.map { AgentMemoryStore.key(for: $0) }
            )
        }

        session.planSteps[index].status = .running
        session.transitionTo(.executing)

        // Dispatch to terminal via TerminalControlBridge
        let dispatched = TerminalControlBridge.shared.routeToNearestAgentPaneOrActive(text: command)
        if !dispatched {
            session.planSteps[index].status = .failed
            session.planSteps[index].output = "No terminal pane available"
            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
        }
    }

    // MARK: - Browser Execution

    private func executeBrowserAction(step: AgentPlanStep, index: Int) {
        guard let command = step.command else { return }
        session.planSteps[index].status = .running

        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let result = await self.dispatchBrowserCommand(command)

            if result.isError {
                self.session.planSteps[index].status = .failed
                self.session.planSteps[index].output = result.text
                logger.warning("ExecutionCoordinator: browser action failed: \(result.text.prefix(100))")
            } else {
                self.session.planSteps[index].status = .succeeded
                self.session.planSteps[index].output = String(result.text.prefix(1000))
                self.session.addArtifact(AgentArtifact(kind: .commandOutput, value: "Browser: \(String(result.text.prefix(300)))"))
            }

            self.executeNextStep()
        }
    }

    /// Parse and dispatch a browser command string.
    /// Formats: "browse:<url>", "browser:<tool> <args>", "open http(s)://..."
    private func dispatchBrowserCommand(_ command: String) async -> BrowserToolResult {
        guard let handler = BrowserServer.shared.toolHandler else {
            return BrowserToolResult(text: "Browser automation not available (BrowserServer not started)", isError: true)
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // "browse:<url>" or "open http..."
        if trimmed.lowercased().hasPrefix("browse:") {
            let url = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            return await handler.handleTool(name: "browser_open", arguments: ["url": url])
        }
        if trimmed.lowercased().hasPrefix("open http") {
            let url = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return await handler.handleTool(name: "browser_open", arguments: ["url": url])
        }

        // "browser:<tool_name> [json_args]"
        if trimmed.lowercased().hasPrefix("browser:") {
            let rest = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = rest.split(separator: " ", maxSplits: 1)
            let toolName = "browser_\(parts[0])"
            var args: [String: Any]? = nil
            if parts.count > 1 {
                let jsonStr = String(parts[1])
                if let data = jsonStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    args = parsed
                }
            }
            return await handler.handleTool(name: toolName, arguments: args)
        }

        return BrowserToolResult(text: "Unrecognized browser command format", isError: true)
    }

    // MARK: - Peer Delegation

    private func executePeerDelegation(step: AgentPlanStep, index: Int) {
        guard let command = step.command else { return }
        session.planSteps[index].status = .running

        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Extract peer name and message from command
            let message = command.replacingOccurrences(of: "delegate:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to route to nearest agent pane
            let sent = TerminalControlBridge.shared.routeToNearestAgentPaneOrActive(text: message)

            if sent {
                self.session.planSteps[index].status = .succeeded
                self.session.planSteps[index].output = "Delegated to peer agent"
                self.session.addArtifact(AgentArtifact(kind: .peerMessage, value: message))
            } else {
                self.session.planSteps[index].status = .failed
                self.session.planSteps[index].output = "No peer agent available"
            }

            self.executeNextStep()
        }
    }

    // MARK: - Cost Budget Check

    private func isBudgetExceeded() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppStorageKeys.dailyCostBudgetEnabled) else { return false }
        let budget = defaults.double(forKey: AppStorageKeys.dailyCostBudget)
        guard budget > 0 else { return false }
        let todayCost = ClaudeUsageMonitor.shared.today.costUSD
        return todayCost >= budget
    }

    // MARK: - Helpers

    private func categorizeCommand(_ command: String) -> AgentActionCategory {
        RiskScorer.categorize(command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func rememberFact(key: String, value: String) {
        guard let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd else { return }
        let projectKey = AgentMemoryStore.key(for: pwd)
        AgentMemoryStore.shared.remember(projectKey: projectKey, key: key, value: value, ttlDays: 1)
    }

    private func currentRunningStepIndex() -> Int? {
        session.planSteps.firstIndex(where: { $0.status == .running })
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
