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
    case localShell         // dispatch command to terminal
    case browserAction      // dispatch to BrowserToolHandler
    case browserResearch    // full browser research workflow with findings capture
    case peerDelegation     // send via IPC to a peer agent
    case informational      // no execution needed (explain, generate)
}

// MARK: - Coordinator

@MainActor
final class ExecutionCoordinator {

    private let session: AgentSession
    private let planStore: AgentPlanStore
    private var executionTask: Task<Void, Never>?
    private var currentStepStartTime: Date?
    private var replanAttempts: Int = 0
    private static let maxReplanAttempts = 3

    /// Callback when all steps are done (triggers summarization).
    var onAllStepsCompleted: (() -> Void)?

    /// Callback when a step observation is captured.
    var onObservation: ((_ stepIndex: Int, _ output: String) -> Void)?

    /// Callback when a step fails and replanning is needed.
    /// Returns replacement steps for the remaining plan, or nil to continue as-is.
    var onReplanNeeded: ((_ failedStep: AgentPlanStep, _ output: String) async -> [AgentPlanStep]?)?

    init(session: AgentSession, planStore: AgentPlanStore) {
        self.session = session
        self.planStore = planStore
    }

    // MARK: - Execution

    func start() {
        guard !session.phase.isTerminal else { return }
        session.transition(to: .running)

        // Ensure the session has a plan; if not (shouldn't happen for multiStep), bail.
        if session.plan == nil {
            let plan = planStore.createPlan(goal: session.userIntent, backend: .ollama)
            session.plan = plan
        } else if let plan = session.plan {
            planStore.adoptPlan(plan)
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
        session.transition(to: .completed)
    }

    /// Called when a command block finishes in the terminal.
    func handleCommandFinished(exitCode: Int, output: String?) {
        guard let stepIndex = currentRunningStepIndex() else { return }

        session.transition(to: .running)

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

        // Update step status (absorbed from the retired AgentPlanExecutor)
        guard let plan = session.plan, stepIndex < plan.steps.count else { return }
        let stepID = plan.steps[stepIndex].id
        let durationMs = currentStepStartTime.map { Int(Date().timeIntervalSince($0) * 1000) }
        currentStepStartTime = nil

        if exitCode == 0 {
            planStore.markStepSucceeded(id: stepID, output: String(observation.prefix(1000)), durationMs: durationMs)
        } else {
            planStore.markStepFailed(id: stepID, output: String(observation.prefix(1000)))
        }

        // If step failed, attempt replan before continuing
        if exitCode != 0 {
            executionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.attemptReplan(failedIndex: stepIndex, output: observation)
            }
        } else {
            // Reset replan counter on success
            replanAttempts = 0
            // Continue to next step after brief pause
            executionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                self?.executeNextStep()
            }
        }
    }

    // MARK: - Replan

    private func attemptReplan(failedIndex: Int, output: String) async {
        guard let plan = session.plan, failedIndex < plan.steps.count else {
            executeNextStep()
            return
        }
        let step = plan.steps[failedIndex]

        // Only replan if there are remaining non-terminal steps
        let remainingPending = plan.steps.filter { !$0.status.isTerminal }
        guard !remainingPending.isEmpty else {
            executeNextStep()
            return
        }

        // Guard against infinite replan loops
        guard replanAttempts < Self.maxReplanAttempts else {
            logger.warning("ExecutionCoordinator: replan limit (\(Self.maxReplanAttempts)) reached, stopping")
            session.fail(message: "Replanning limit reached after repeated step failures.")
            return
        }
        replanAttempts += 1

        if let replanCallback = onReplanNeeded {
            if let newSteps = await replanCallback(step, output) {
                logger.info("ExecutionCoordinator: replanned \(newSteps.count) replacement step(s) (attempt \(self.replanAttempts))")

                // Replace remaining pending/approved steps with new ones
                var updated = plan.steps.filter { $0.status.isTerminal }
                updated.append(contentsOf: newSteps)
                plan.steps = updated

                // Auto-approve safe steps in the new plan
                if session.approvalRequirement == .none {
                    for i in plan.steps.indices where plan.steps[i].status == .pending {
                        plan.steps[i].status = .approved
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

        guard let plan = session.plan else { return }

        // Auto-approve any safe pending steps (absorbed from AgentPlanExecutor).
        autoApprovePendingSafeSteps(plan: plan)

        // Find next approved step
        guard let nextIndex = plan.steps.firstIndex(where: { $0.status == .approved }) else {
            // Check if all done
            let allTerminal = plan.steps.allSatisfy { $0.status.isTerminal }
            if allTerminal && !plan.steps.isEmpty {
                onAllStepsCompleted?()
            }
            return
        }

        session.currentStepID = plan.steps[nextIndex].id
        let step = plan.steps[nextIndex]
        let strategy = chooseStrategy(for: step)

        logger.info("ExecutionCoordinator: executing step \(nextIndex + 1)/\(plan.steps.count) via \(strategy.rawValue)")

        switch strategy {
        case .localShell:
            executeLocalShell(step: step, index: nextIndex)

        case .browserAction:
            executeBrowserAction(step: step, index: nextIndex)

        case .browserResearch:
            executeBrowserResearch(startingAt: nextIndex)

        case .peerDelegation:
            executePeerDelegation(step: step, index: nextIndex)

        case .informational:
            // Mark as succeeded immediately — no execution needed
            plan.steps[nextIndex].status = .succeeded
            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
        }
    }

    /// Absorbed from the retired AgentPlanExecutor. Auto-approves pending steps
    /// that the risk scorer tags as safe (reads/observational commands).
    private func autoApprovePendingSafeSteps(plan: AgentPlan) {
        let permissions = AgentPermissionsStore.shared
        guard permissions.shouldAutoAllow(.runCommands) else { return }

        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
        let gitBranch = TerminalControlBridge.shared.delegate?.activeTabGitBranch

        for i in plan.steps.indices where plan.steps[i].status == .pending {
            if let command = plan.steps[i].command {
                let assessment = RiskScorer.assess(command: command, pwd: pwd, gitBranch: gitBranch)
                if case .autoApprove = permissions.decide(for: assessment) {
                    plan.steps[i].status = .approved
                }
            } else {
                // Informational steps are always safe
                plan.steps[i].status = .approved
            }
        }
    }

    // MARK: - Strategy Selection

    private func chooseStrategy(for step: AgentPlanStep) -> ExecutionStrategy {
        switch step.kind {
        case .manual:
            return .informational
        case .peer:
            return .peerDelegation
        case .browser:
            return session.classifiedIntent == .browserResearch
                ? .browserResearch
                : .browserAction
        case .shell:
            return .localShell
        }
    }

    // MARK: - Local Shell Execution

    private func executeLocalShell(step: AgentPlanStep, index: Int) {
        guard let plan = session.plan, let command = step.command else { return }

        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
        let gitBranch = TerminalControlBridge.shared.delegate?.activeTabGitBranch

        // Route through the unified approval gate (hard-stop + grants + trust mode).
        let gate = ApprovalGate.evaluate(
            action: .shellCommand(command),
            session: session,
            pwd: pwd,
            gitBranch: gitBranch
        )

        switch gate {
        case .blocked(let reason):
            plan.steps[index].status = .failed
            plan.steps[index].output = "Blocked: \(reason)"
            logger.warning("ExecutionCoordinator: blocked: \(command.prefix(60))")
            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
            return

        case .requireApproval(let ctx, _):
            // Surface approval sheet and park this step. `onApprovalResolved`
            // on the session fires once the user answers.
            presentApproval(context: ctx, hardStop: nil, pwd: pwd, step: step, index: index)
            return

        case .hardStop(let reason, let ctx, _):
            presentApproval(context: ctx, hardStop: reason, pwd: pwd, step: step, index: index)
            return

        case .autoApprove:
            break
        }

        plan.steps[index].status = .running
        currentStepStartTime = Date()
        session.transition(to: .running)

        // Dispatch to terminal via TerminalControlBridge
        let dispatched = TerminalControlBridge.shared.routeToNearestAgentPaneOrActive(text: command)
        if !dispatched {
            plan.steps[index].status = .failed
            plan.steps[index].output = "No terminal pane available"
            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
        } else {
            // Watchdog: if handleCommandFinished is never called (e.g. shell integration
            // is absent in an SSH session), unstick the loop after a timeout.
            scheduleStepWatchdog(index: index)
        }
    }

    // MARK: - Approval Parking

    /// Park the current step on an approval request. When the user resolves,
    /// `onApprovalResolved` fires and we either advance the step (approved)
    /// or mark it failed (denied/deferred).
    private func presentApproval(
        context: ApprovalContext,
        hardStop: HardStopReason?,
        pwd: String?,
        step: AgentPlanStep,
        index: Int
    ) {
        guard let plan = session.plan else { return }
        plan.steps[index].status = .pending

        ApprovalPresenter.shared.setRepoPath(pwd)
        if let hardStop { ApprovalPresenter.shared.presentHardStop(reason: hardStop) }

        // Wire resume. Executor picks up after the user answers.
        // Read session.plan inside the closure so we always operate on the
        // current plan — not a stale capture from before a potential replan.
        session.onApprovalResolved = { [weak self] answer in
            guard let self else { return }
            self.session.onApprovalResolved = nil
            guard let currentPlan = self.session.plan, index < currentPlan.steps.count else {
                self.executeNextStep()
                return
            }
            if answer == .approved {
                // Re-enter executeLocalShell; grant cache should now cover it.
                currentPlan.steps[index].status = .approved
                self.executeNextStep()
            } else {
                currentPlan.steps[index].status = .failed
                currentPlan.steps[index].output = "Denied by user"
                self.executeNextStep()
            }
        }
        session.requestApproval(context)
        logger.info("ExecutionCoordinator: awaiting approval for step \(index + 1)")
    }

    // MARK: - Browser Execution

    private func executeBrowserAction(step: AgentPlanStep, index: Int) {
        guard let plan = session.plan, let command = step.command else { return }
        plan.steps[index].status = .running

        // Audit: log browser step start
        SessionAuditLogger.log(
            type: .browserStepStarted,
            detail: "Browser action: \(step.title)"
        )

        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let tier = RiskTier.from(score: self.browserRiskScore(for: command))
            let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
            let gate = ApprovalGate.evaluate(
                action: .browserAction(command: command, tier: tier),
                session: self.session,
                pwd: pwd,
                gitBranch: nil
            )
            switch gate {
            case .blocked(let reason):
                plan.steps[index].status = .failed
                plan.steps[index].output = "Blocked: \(reason)"
                SessionAuditLogger.log(
                    type: .browserStepCompleted,
                    detail: "Browser action BLOCKED: \(reason)"
                )
                self.executeNextStep()
                return
            case .requireApproval(let ctx, _):
                self.presentApproval(context: ctx, hardStop: nil, pwd: pwd, step: step, index: index)
                return
            case .hardStop(let reason, let ctx, _):
                self.presentApproval(context: ctx, hardStop: reason, pwd: pwd, step: step, index: index)
                return
            case .autoApprove:
                break
            }

            let result = await self.dispatchBrowserCommand(command)

            if result.isError {
                plan.steps[index].status = .failed
                plan.steps[index].output = result.text
                SessionAuditLogger.log(
                    type: .browserStepCompleted,
                    detail: "Browser action FAILED: \(result.text.prefix(200))"
                )
                logger.warning("ExecutionCoordinator: browser action failed: \(result.text.prefix(100))")
            } else {
                plan.steps[index].status = .succeeded
                plan.steps[index].output = String(result.text.prefix(1000))
                self.session.addArtifact(AgentArtifact(kind: .commandOutput, value: "Browser: \(String(result.text.prefix(300)))"))
                SessionAuditLogger.log(
                    type: .browserStepCompleted,
                    detail: "Browser action OK: \(step.title) (\(result.text.count) chars)"
                )
            }

            self.executeNextStep()
        }
    }

    /// Risk score for browser commands. Read-only extractions are low risk;
    /// form fills and clicks are medium; eval is high.
    private func browserRiskScore(for command: String) -> Int {
        let lower = command.lowercased()
        if lower.contains("eval") { return 45 }
        if lower.contains("click") || lower.contains("fill") || lower.contains("type")
            || lower.contains("press") || lower.contains("check") || lower.contains("select") {
            return 25
        }
        // Read-only: snapshot, get_text, get_links, get_html, navigate, open
        return 10
    }

    // MARK: - Browser Research Workflow

    /// The active browser research workflow, if any.
    private(set) var browserResearchWorkflow: BrowserResearchWorkflow?

    /// Execute all remaining browser steps as a cohesive research workflow.
    /// Batches all browser-prefixed steps and runs them through BrowserResearchWorkflow.
    private func executeBrowserResearch(startingAt index: Int) {
        guard let plan = session.plan else { return }

        // Collect all remaining approved browser steps
        let browserSteps = plan.steps[index...].filter { step in
            guard step.status == .approved || step.status == .pending else { return false }
            guard let cmd = step.command?.lowercased() else { return true } // informational
            return cmd.hasPrefix("browse:") || cmd.hasPrefix("browser:") || cmd.hasPrefix("open http") || cmd.isEmpty
        }

        guard let handler = BrowserServer.shared.toolHandler else {
            plan.steps[index].status = .failed
            plan.steps[index].output = "Browser automation not available"
            executionTask = Task { @MainActor [weak self] in
                self?.executeNextStep()
            }
            return
        }

        let workflow = BrowserResearchWorkflow(toolHandler: handler)
        self.browserResearchWorkflow = workflow

        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // (workflow.execute publishes its BrowserResearchSession onto
            //  self.session.browserResearchSession — see BrowserResearchWorkflow)

            // Auto-approve all browser steps for the research workflow
            for i in plan.steps.indices {
                if plan.steps[i].status == .pending,
                   let cmd = plan.steps[i].command?.lowercased(),
                   cmd.hasPrefix("browse:") || cmd.hasPrefix("browser:") || cmd.hasPrefix("open http") {
                    plan.steps[i].status = .approved
                }
            }

            // Build a stable ID→planIndex map before the async call so we can
            // write results back to the correct slots even if the plan mutates.
            let browserStepIDs: [UUID] = Array(browserSteps).map { $0.id }

            let (findings, summary) = await workflow.execute(
                goal: self.session.displayIntent,
                steps: Array(browserSteps),
                agentSession: self.session
            )

            // Sync step statuses from the workflow back to the session.
            // entry.stepIndex is relative to the browserSteps array, so map
            // through the captured ID list rather than using a raw offset from
            // `index` (which would be wrong when non-browser steps precede the
            // first browser step in the slice).
            if let researchSession = workflow.activeSession {
                for entry in researchSession.logEntries {
                    guard entry.stepIndex < browserStepIDs.count else { continue }
                    let stepID = browserStepIDs[entry.stepIndex]
                    guard let planIdx = plan.steps.firstIndex(where: { $0.id == stepID }) else { continue }
                    switch entry.status {
                    case .succeeded:
                        plan.steps[planIdx].status = .succeeded
                        plan.steps[planIdx].output = entry.output
                    case .failed:
                        plan.steps[planIdx].status = .failed
                        plan.steps[planIdx].output = entry.output
                    case .skipped:
                        plan.steps[planIdx].status = .skipped
                    case .running:
                        break
                    }
                }
            }

            // Add findings summary as an artifact
            if !findings.isEmpty {
                self.session.addArtifact(AgentArtifact(
                    kind: .commandOutput,
                    value: "Research summary: \(summary.prefix(500))"
                ))
            }

            // Remember the research fact
            self.rememberFact(
                key: "browser_research_result",
                value: String(summary.prefix(300))
            )

            self.browserResearchWorkflow = nil
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
        guard let plan = session.plan, let command = step.command else { return }
        plan.steps[index].status = .running

        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Extract peer name and message from command
            let message = command.replacingOccurrences(of: "delegate:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to route to nearest agent pane
            let sent = TerminalControlBridge.shared.routeToNearestAgentPaneOrActive(text: message)

            if sent {
                plan.steps[index].status = .succeeded
                plan.steps[index].output = "Delegated to peer agent"
                self.session.addArtifact(AgentArtifact(kind: .peerMessage, value: message))
            } else {
                plan.steps[index].status = .failed
                plan.steps[index].output = "No peer agent available"
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
        session.plan?.steps.firstIndex(where: { $0.status == .running })
    }

    // MARK: - Step Watchdog

    /// Timeout (in seconds) after which a .running step is considered stuck.
    private static let stepWatchdogTimeout: UInt64 = 30

    /// Schedules a watchdog that will force-advance the step if handleCommandFinished
    /// is never called. This covers SSH sessions and shells without ghostty integration.
    private func scheduleStepWatchdog(index: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.stepWatchdogTimeout * 1_000_000_000)
            guard let self, let plan = self.session.plan else { return }
            guard index < plan.steps.count,
                  plan.steps[index].status == .running
            else { return }

            logger.warning("ExecutionCoordinator: step \(index + 1) watchdog fired — no command-finished callback received")
            plan.steps[index].status = .failed
            plan.steps[index].output = "Timed out waiting for command completion (shell integration may be unavailable)"
            self.executeNextStep()
        }
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
