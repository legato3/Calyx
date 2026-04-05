// TaskExecutionCoordinator.swift
// CTerm
//
// Bridges ManagedTask lifecycle with the AgentLoopCoordinator pipeline.
// Manages foreground/background task switching, retry scheduling,
// and progress synchronization between the task model and agent session.
//
// One coordinator per window — owns the active task queue and drives execution.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "TaskExecCoord")

@Observable
@MainActor
final class TaskExecutionCoordinator {

    /// All managed tasks (active + history). Most recent first for history.
    private(set) var tasks: [ManagedTask] = []

    /// The currently executing task (at most one foreground task at a time).
    private(set) var activeTask: ManagedTask?

    /// Background tasks that are running without terminal focus.
    private(set) var backgroundTasks: [ManagedTask] = []

    /// True when the coordinator is processing the queue.
    var isProcessing: Bool = false

    /// Max concurrent background tasks.
    var maxBackgroundTasks: Int = 2

    private let agentCoordinator: AgentLoopCoordinator
    private let planStore: AgentPlanStore
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?

    init(agentCoordinator: AgentLoopCoordinator, planStore: AgentPlanStore) {
        self.agentCoordinator = agentCoordinator
        self.planStore = planStore
    }

    // MARK: - Queue Management

    /// Create and enqueue a new task from a user prompt.
    @discardableResult
    func enqueue(
        prompt: String,
        priority: TaskPriority = .normal,
        executionMode: TaskExecutionMode = .foreground,
        model: TaskModel = .auto
    ) -> ManagedTask {
        let task = ManagedTask(
            prompt: prompt,
            priority: priority,
            executionMode: executionMode,
            model: model
        )
        // Insert by priority: urgent/high go before normal/low
        if let insertIdx = tasks.firstIndex(where: {
            $0.phase == .queued && $0.priority < priority
        }) {
            tasks.insert(task, at: insertIdx)
        } else {
            // Append after last queued task (before completed/failed history)
            let lastQueuedIdx = tasks.lastIndex(where: { $0.phase == .queued }) ?? -1
            tasks.insert(task, at: lastQueuedIdx + 1)
        }

        logger.info("TaskExecCoord: enqueued \"\(task.displayPrompt.prefix(60))\" (priority: \(priority.label))")

        if isProcessing { advanceQueue() }
        return task
    }

    /// Start processing the queue.
    func startProcessing() {
        isProcessing = true
        advanceQueue()
    }

    /// Stop processing (doesn't cancel running tasks).
    func stopProcessing() {
        isProcessing = false
    }

    // MARK: - Task Control

    func pauseTask(_ task: ManagedTask) {
        guard task.phase.canPause else { return }
        task.transitionTo(.paused)
        if task.id == activeTask?.id {
            // Pause the agent session
            agentCoordinator.activeSession?.transitionTo(.completed)
        }
    }

    func resumeTask(_ task: ManagedTask) {
        guard task.phase == .paused else { return }
        task.transitionTo(.executing)
        if task.id == activeTask?.id {
            executeTask(task)
        }
    }

    func cancelTask(_ task: ManagedTask) {
        guard task.phase.canCancel else { return }
        retryTasks[task.id]?.cancel()
        retryTasks.removeValue(forKey: task.id)

        if task.id == activeTask?.id {
            agentCoordinator.stopSession()
            activeTask = nil
        }
        backgroundTasks.removeAll { $0.id == task.id }
        task.cancel()
        advanceQueue()
    }

    func retryTask(_ task: ManagedTask) {
        guard task.prepareForRetry() else { return }
        logger.info("TaskExecCoord: retrying task \(task.id.uuidString.prefix(8)) (attempt \(task.attemptCount))")

        let delay = task.retryDelay
        if delay > 0 {
            retryTasks[task.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.advanceQueue()
            }
        } else {
            advanceQueue()
        }
    }

    /// Move a task between foreground and background.
    func setExecutionMode(_ mode: TaskExecutionMode, for task: ManagedTask) {
        task.executionMode = mode
        if mode == .background && task.id == activeTask?.id {
            // Demote to background
            activeTask = nil
            backgroundTasks.append(task)
            advanceQueue() // pick up next foreground task
        } else if mode == .foreground {
            backgroundTasks.removeAll { $0.id == task.id }
            if activeTask == nil {
                activeTask = task
            }
        }
    }

    // MARK: - Approval

    func approveTask(_ task: ManagedTask) {
        guard task.phase == .awaitingApproval else { return }
        task.transitionTo(.executing)

        // Approve all pending steps
        for i in task.planSteps.indices where task.planSteps[i].status == .pending {
            task.planSteps[i].status = .approved
        }

        // Forward to agent coordinator
        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
        Task { @MainActor [weak self] in
            await self?.agentCoordinator.approveAndExecute(pwd: pwd)
        }
    }

    func approveStep(_ task: ManagedTask, stepID: UUID) {
        guard let idx = task.planSteps.firstIndex(where: { $0.id == stepID }) else { return }
        task.planSteps[idx].status = .approved
        agentCoordinator.approveStep(id: stepID)
    }

    func skipStep(_ task: ManagedTask, stepID: UUID) {
        guard let idx = task.planSteps.firstIndex(where: { $0.id == stepID }) else { return }
        task.planSteps[idx].status = .skipped
        agentCoordinator.skipStep(id: stepID)
    }

    // MARK: - Command Finished (from terminal)

    func handleCommandFinished(exitCode: Int, output: String?) {
        guard let task = activeTask, task.phase == .executing || task.phase == .observing else { return }

        // Record partial result
        let stepIdx = task.planSteps.firstIndex(where: { $0.status == .running })
            ?? task.planSteps.count - 1
        task.addPartialResult(TaskPartialResult(
            stepIndex: stepIdx,
            output: String((output ?? "").prefix(500)),
            exitCode: exitCode,
            artifactKind: .commandOutput
        ))

        // Forward to agent coordinator
        agentCoordinator.handleCommandFinished(exitCode: exitCode, output: output)

        // Sync state back
        syncTaskFromSession(task)
    }

    // MARK: - Queue Advancement

    private func advanceQueue() {
        guard isProcessing else { return }

        // Start foreground task if none active
        if activeTask == nil {
            if let next = nextQueuedTask(mode: .foreground) {
                executeTask(next)
            }
        }

        // Fill background slots
        while backgroundTasks.count < maxBackgroundTasks {
            guard let next = nextQueuedTask(mode: .background) else { break }
            executeBackgroundTask(next)
        }
    }

    private func nextQueuedTask(mode: TaskExecutionMode) -> ManagedTask? {
        tasks.first { $0.phase == .queued && $0.executionMode == mode }
    }

    // MARK: - Execution

    private func executeTask(_ task: ManagedTask) {
        activeTask = task
        task.transitionTo(.planning)

        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Start the agent pipeline
            await self.agentCoordinator.startSession(
                intent: task.prompt,
                tabID: nil,
                pwd: pwd
            )

            // Sync agent session state back to task
            self.startSessionSync(for: task)
        }
    }

    private func executeBackgroundTask(_ task: ManagedTask) {
        backgroundTasks.append(task)
        task.transitionTo(.planning)
        // Background tasks use the existing TaskQueueStore injection path
        TaskQueueStore.shared.enqueue(task.prompt, model: task.model)
    }

    // MARK: - Session Sync

    /// Continuously sync agent session state into the managed task.
    private func startSessionSync(for task: ManagedTask) {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.syncTaskFromSession(task)

                // Check for terminal state
                if task.phase.isTerminal {
                    self.onTaskCompleted(task)
                    return
                }

                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    private func syncTaskFromSession(_ task: ManagedTask) {
        guard let session = agentCoordinator.activeSession else { return }
        task.agentSession = session

        // Sync plan steps
        task.planSteps = session.planSteps
        task.streamingPreview = agentCoordinator.streamingPreview

        // Map agent phase → task phase
        switch session.phase {
        case .classifying, .planning:
            if task.phase != .planning { task.transitionTo(.planning) }
        case .awaitingApproval:
            task.transitionTo(.awaitingApproval)
        case .executing:
            if task.phase == .awaitingApproval || task.phase == .planning {
                task.transitionTo(.executing)
            }
        case .observing:
            task.transitionTo(.observing)
        case .summarizing:
            task.transitionTo(.summarizing)
        case .completed:
            task.summary = session.summary
            task.nextActions = session.nextActions
            task.transitionTo(.completed)
        case .failed:
            task.fail(message: session.errorMessage ?? "Agent session failed")
        case .idle:
            break
        }
    }

    private func onTaskCompleted(_ task: ManagedTask) {
        syncTask?.cancel()
        syncTask = nil

        if task.id == activeTask?.id {
            activeTask = nil
        }
        backgroundTasks.removeAll { $0.id == task.id }

        // Auto-retry on failure if policy allows
        if task.phase == .failed && task.canRetry {
            logger.info("TaskExecCoord: auto-retrying failed task \(task.id.uuidString.prefix(8))")
            retryTask(task)
            return
        }

        // Persist handoff for cross-session continuity
        if task.phase == .completed {
            persistTaskHandoff(task)
        }

        advanceQueue()
    }

    // MARK: - Persistence

    private func persistTaskHandoff(_ task: ManagedTask) {
        guard let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd else { return }
        let projectKey = AgentMemoryStore.key(for: pwd)
        AgentMemoryStore.shared.saveHandoff(
            projectKey: projectKey,
            goal: task.displayPrompt,
            stepsCompleted: task.succeededStepCount,
            totalSteps: task.planSteps.count,
            filesChanged: task.partialResults
                .compactMap { $0.artifactKind == .fileChanged ? $0.output : nil },
            outcome: task.phase.rawValue
        )
    }

    // MARK: - Queries

    var queuedTasks: [ManagedTask] { tasks.filter { $0.phase == .queued } }
    var activeTasks: [ManagedTask] {
        tasks.filter { $0.phase.isActive || $0.phase == .awaitingApproval || $0.phase == .paused }
    }
    var completedTasks: [ManagedTask] { tasks.filter { $0.phase.isTerminal } }
    var pendingApprovalCount: Int { tasks.filter { $0.phase == .awaitingApproval }.count }

    func task(byID id: UUID) -> ManagedTask? {
        tasks.first { $0.id == id }
    }

    // MARK: - Bulk Operations

    func clearCompleted() {
        tasks.removeAll { $0.phase.isTerminal }
    }

    func cancelAll() {
        for task in tasks where task.phase.canCancel {
            cancelTask(task)
        }
    }
}
