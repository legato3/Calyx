// TaskQueueStore.swift
// CTerm
//
// Phase 10: Sequential Task Queue — queue prompts for a Codex/Claude pane to
// process one at a time.  When a task finishes (target peer goes idle) the
// next pending task is auto-injected, with a brief context snippet from the
// peer's most recent IPC message prepended.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "TaskQueue")

// MARK: - TaskStatus

enum TaskStatus: String, Sendable, Codable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

// MARK: - TaskModel

/// The Claude model to use when processing a task.
enum TaskModel: String, Sendable, Codable, CaseIterable, Identifiable {
    case auto
    case haiku
    case sonnet
    case opus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }

    /// The model ID passed to `--model` flag. `nil` means no flag (inherit session model).
    var modelID: String? {
        switch self {
        case .auto: return nil  // resolved at inject time via keyword inference
        case .haiku: return "claude-haiku-4-5-20251001"
        case .sonnet: return "claude-sonnet-4-6"
        case .opus: return "claude-opus-4-6"
        }
    }

    /// Infer a concrete model from task description keywords.
    static func infer(from prompt: String) -> TaskModel {
        let lower = prompt.lowercased()
        let opusKeywords = ["architect", "design", "plan", "analyze", "analyse", "review", "audit", "strategy"]
        let haikuKeywords = ["explain", "summarize", "summarise", "what is", "describe", "list", "show me", "how does"]
        if opusKeywords.contains(where: { lower.contains($0) }) { return .opus }
        if haikuKeywords.contains(where: { lower.contains($0) }) { return .haiku }
        return .sonnet  // default for refactor, implement, fix, write, etc.
    }
}

// MARK: - QueuedTask

struct QueuedTask: Identifiable, Sendable, Codable {
    let id: UUID
    var prompt: String
    /// Override the queue's default target peer for this individual task.
    var targetPeerName: String?
    /// Model to use for this task. `.auto` infers from prompt keywords at inject time.
    var model: TaskModel
    var status: TaskStatus
    /// Brief snippet captured on completion (from peer's last IPC message).
    var resultSnippet: String?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    init(prompt: String, targetPeerName: String? = nil, model: TaskModel = .auto) {
        self.id = UUID()
        self.prompt = prompt
        self.targetPeerName = targetPeerName
        self.model = model
        self.status = .pending
        self.createdAt = .now
    }
}

// MARK: - TaskQueueStore

@MainActor @Observable
final class TaskQueueStore {

    static let shared: TaskQueueStore = {
        let s = TaskQueueStore()
        s.setupEngine()
        return s
    }()

    // MARK: State

    var tasks: [QueuedTask] = []
    /// When true the engine automatically pops and injects tasks.
    var isProcessing: Bool = false
    /// Default peer name to target (e.g. "codex-worker").  Falls back to
    /// `runInPaneMatching` with any active peer if empty.
    var defaultTargetPeerName: String = ""
    /// Default model for newly-added tasks.
    var defaultModel: TaskModel = .auto
    /// Minimum seconds a task must run before it can be auto-completed.
    var minRunSeconds: TimeInterval = 20

    // MARK: - Convenience

    var pendingCount: Int { tasks.filter { $0.status == .pending }.count }
    var runningTask: QueuedTask? { tasks.first(where: { $0.status == .running }) }
    var hasWork: Bool { !tasks.filter({ $0.status == .pending || $0.status == .running }).isEmpty }

    // MARK: - Mutations (UI + MCP)

    func enqueue(_ prompt: String, targetPeerName: String? = nil, model: TaskModel? = nil, at position: Int? = nil) {
        let task = QueuedTask(prompt: prompt, targetPeerName: targetPeerName, model: model ?? defaultModel)
        if let pos = position, pos < tasks.count {
            tasks.insert(task, at: pos)
        } else {
            tasks.append(task)
        }
        logger.info("Queued task \(task.id): \"\(task.prompt.prefix(60))\"")
        if isProcessing { engine.kickIfNeeded() }
    }

    func setModel(_ model: TaskModel, for id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              tasks[idx].status == .pending else { return }
        tasks[idx].model = model
    }

    func cancel(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[idx].status == .running { engine.abortRunning() }
        tasks[idx].status = .cancelled
    }

    func clearPending() {
        tasks = tasks.filter { $0.status != .pending }
    }

    /// Enable processing and kick the engine to start the next pending task.
    func advanceToNext() {
        isProcessing = true
        engine.kickIfNeeded()
    }

    func clearAll() {
        engine.abortRunning()
        tasks.removeAll()
    }

    func moveTask(fromOffsets: IndexSet, toOffset: Int) {
        tasks.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func remove(at offsets: IndexSet) {
        for idx in offsets.sorted(by: >) {
            if tasks[idx].status == .running { engine.abortRunning() }
        }
        tasks.remove(atOffsets: offsets)
    }

    // Called by MCP tool `complete_task`
    func completeCurrent(result: String? = nil) {
        engine.completeRunning(result: result)
    }

    // MARK: - Bridge to ManagedTask system

    /// Convert a QueuedTask to a ManagedTask for the new execution coordinator.
    func asManagedTask(_ task: QueuedTask) -> ManagedTask {
        ManagedTask(
            prompt: task.prompt,
            priority: .normal,
            executionMode: .foreground,
            model: task.model,
            targetPeerName: task.targetPeerName
        )
    }

    /// Migrate all pending tasks to a TaskExecutionCoordinator.
    func migratePendingTo(_ coordinator: TaskExecutionCoordinator) {
        for task in tasks where task.status == .pending {
            coordinator.enqueue(
                prompt: task.prompt,
                executionMode: .foreground,
                model: task.model
            )
        }
    }

    // MARK: - Engine reference

    // Stored outside @Observable tracking to avoid init-accessor restrictions.
    // Always non-nil after shared is created.
    private(set) var engine: TaskQueueEngine!

    fileprivate func setupEngine() {
        engine = TaskQueueEngine(store: self)
    }
}

// MARK: - TaskQueueEngine

/// Drives automatic task dispatch: monitors peer state, injects prompts, detects completion.
@MainActor
final class TaskQueueEngine {

    private weak var store: TaskQueueStore?
    private var monitorTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private static let pollNs: UInt64 = 5_000_000_000   // 5 s

    init(store: TaskQueueStore?) {
        self.store = store
    }

    func kickIfNeeded() {
        guard let store, store.isProcessing else { return }
        guard store.runningTask == nil else { return }   // already running
        guard let idx = store.tasks.firstIndex(where: { $0.status == .pending }) else { return }
        startTask(at: idx)
    }

    func abortRunning() {
        if let idx = store?.tasks.firstIndex(where: { $0.status == .running }) {
            store?.tasks[idx].status = .cancelled
        }
        runStartedAt = nil
    }

    func completeRunning(result: String?) {
        guard let store,
              let idx = store.tasks.firstIndex(where: { $0.status == .running }) else { return }
        let completedPrompt = store.tasks[idx].prompt
        store.tasks[idx].status = .completed
        store.tasks[idx].completedAt = .now
        store.tasks[idx].resultSnippet = result
        SessionAuditLogger.log(type: .taskCompleted, detail: String(completedPrompt.prefix(120)))
        runStartedAt = nil
        logger.info("Task \(store.tasks[idx].id) completed")
        // Start next after brief pause
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.kickIfNeeded()
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: Self.pollNs)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Tick

    private func tick() {
        guard let store else { return }
        guard store.isProcessing else { return }

        // If nothing running, kick
        if store.runningTask == nil {
            kickIfNeeded()
            return
        }

        // Check if running task's target peer has gone idle
        guard let running = store.runningTask,
              let start = runStartedAt,
              Date().timeIntervalSince(start) >= store.minRunSeconds
        else { return }

        let targetName = running.targetPeerName ?? store.defaultTargetPeerName
        let peers = IPCAgentState.shared.peers
        if let peer = peers.first(where: { matchesPeer($0, name: targetName) }) {
            let status = AgentStatus.infer(from: peer)
            if status == .idle || status == .disconnected {
                // Capture context from last message this peer sent
                let snippet = lastMessageSnippet(fromPeer: peer)
                completeRunning(result: snippet)
            }
        } else if targetName.isEmpty {
            // No specific target — check any peer went idle
            let anyIdle = peers.filter { matchesAnyActivePeer($0) && AgentStatus.infer(from: $0) == .idle }
            if !anyIdle.isEmpty {
                let snippet = anyIdle.first.flatMap { lastMessageSnippet(fromPeer: $0) }
                completeRunning(result: snippet)
            }
        }
    }

    // MARK: - Task Injection

    private func startTask(at index: Int) {
        guard let store else { return }
        let task = store.tasks[index]
        let targetName = task.targetPeerName ?? store.defaultTargetPeerName

        // Build prompt — prepend context from previous completed task if available
        var prompt = task.prompt
        if let prev = store.tasks.prefix(index).last(where: { $0.status == .completed }),
           let snippet = prev.resultSnippet, !snippet.isEmpty {
            prompt = "[Context from previous task]\n\(snippet)\n\n\(task.prompt)"
        }

        // Resolve model and prepend --model flag if a specific model is selected
        let resolvedModel: TaskModel
        if task.model == .auto {
            resolvedModel = TaskModel.infer(from: task.prompt)
        } else {
            resolvedModel = task.model
        }
        if let modelID = resolvedModel.modelID {
            prompt = "--model \(modelID)\n\(prompt)"
        }

        let injected: Bool
        if targetName.isEmpty {
            injected = TerminalControlBridge.shared.routeToNearestAgentPaneOrActive(text: prompt)
        } else {
            injected = (TerminalControlBridge.shared.delegate?.runInPaneMatching(
                titleContains: targetName, text: prompt, pressEnter: true) ?? false)
        }

        if injected {
            store.tasks[index].status = .running
            store.tasks[index].startedAt = .now
            runStartedAt = .now
            logger.info("Injected task \(task.id) into pane matching '\(targetName)'")
        } else {
            store.tasks[index].status = .failed
            logger.warning("Failed to inject task \(task.id) — no matching pane for '\(targetName)'")
        }
    }

    // MARK: - Helpers

    private func matchesPeer(_ peer: Peer, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return peer.name.lowercased().contains(name.lowercased())
    }

    private func matchesAnyActivePeer(_ peer: Peer) -> Bool {
        peer.name != "cterm-app"
    }

    private func lastMessageSnippet(fromPeer peer: Peer) -> String? {
        let log = IPCAgentState.shared.activityLog
        guard let msg = log.last(where: { $0.from == peer.id }) else { return nil }
        let content = msg.content
        return content.count > 300 ? String(content.suffix(300)) : content
    }
}
