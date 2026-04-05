// AgentSession.swift
// CTerm
//
// Canonical agent session. Every entry point (compose bar, MCP queue_task,
// MCP delegate_task, full multi-step pipeline, trigger engine) produces one
// of these. Observers subscribe for phase transitions, approval requests,
// artifacts, and the final result.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentSession")

@Observable
@MainActor
final class AgentSession: Identifiable {

    // MARK: - Identity (immutable)

    let id: UUID
    let intent: String              // user-facing goal (context envelope stripped)
    let rawPrompt: String           // enriched prompt sent to LLM
    let tabID: UUID?
    let kind: AgentSessionKind
    let backend: AgentBackend
    let startedAt: Date
    /// Optional provenance: name of the trigger rule that caused this session
    /// to spawn. Nil for user-driven sessions. Displayed in the run panel
    /// header and activity-strip chips so the user can always answer
    /// "what caused this to start?".
    let triggeredBy: String?

    // MARK: - State (mutable, observable)

    private(set) var phase: AgentPhase {
        didSet {
            guard oldValue != phase else { return }
            updatedAt = Date()
            logger.info("AgentSession[\(self.id.uuidString.prefix(8))]: \(oldValue.rawValue) → \(self.phase.rawValue)")
            notifyTransition(from: oldValue, to: phase)
        }
    }

    /// Present for multiStep sessions; nil for inline/queued/delegated that don't expose a plan.
    var plan: AgentPlan?

    /// Intent classification produced during the thinking phase (multiStep kind).
    var classifiedIntent: IntentCategory?

    /// Legacy coarse approval requirement. Temporary bridge until per-step
    /// ApprovalContext replaces all call sites.
    var approvalRequirement: ApprovalRequirement = .planLevel

    /// Index within plan.steps that is currently running.
    var currentStepID: UUID?

    /// Non-nil while execution is blocked on user decision.
    private(set) var approval: ApprovalContext?

    private(set) var artifacts: [AgentArtifact] = []

    private(set) var result: AgentResult?

    var errorMessage: String?

    /// Free-form summary set during summarization. Mirrors into `result.summary`
    /// when the session completes via `complete(with:)`.
    var summary: String?

    /// Suggested follow-up prompts set during summarization.
    var nextActions: [String] = []

    // MARK: - Inline-kind state
    // Populated for `.inline` sessions driven by the compose bar loop.

    /// Command awaiting user approval (shown in the compose bar chip).
    var pendingCommand: String?

    /// Plan preview or message shown next to the pending command.
    var pendingMessage: String?

    /// Id of the current terminal command block, if any.
    var lastCommandBlockID: UUID?

    /// Iteration counter for the inline planning loop (max 8).
    var inlineIteration: Int = 0

    /// Inline-kind step history (goal / plan / command / observation / summary).
    var inlineSteps: [InlineAgentStep] = []

    private(set) var updatedAt: Date

    /// Optional resume callback set by a session driver (executor, inline loop,
    /// etc.) before calling `requestApproval`. Invoked by the presenter once the
    /// user answers, so the driver can continue where it left off.
    var onApprovalResolved: (() -> Void)?

    /// UI state: has the user collapsed the inline run panel for this session?
    /// Session-lifetime only, not persisted.
    var isRunPanelCollapsed: Bool = false

    /// Live browser research state (set by ExecutionCoordinator during
    /// browserResearch workflows). Bound by the run panel to render the
    /// progress strip + finding cards in real time. Cleared when the
    /// workflow finishes.
    var browserResearchSession: BrowserResearchSession?

    /// Findings the user has explicitly kept via the per-card Save button.
    /// Transient: populated during the session, discarded at session end.
    var keptFindingIDs: Set<UUID> = []

    // MARK: - Observers

    private var observers: [WeakObserver] = []

    private struct WeakObserver {
        weak var value: (any AgentSessionObserver)?
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        intent: String,
        rawPrompt: String,
        tabID: UUID?,
        kind: AgentSessionKind,
        backend: AgentBackend,
        triggeredBy: String? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.intent = intent
        self.rawPrompt = rawPrompt
        self.triggeredBy = triggeredBy
        self.tabID = tabID
        self.kind = kind
        self.backend = backend
        self.startedAt = startedAt
        self.phase = .idle
        self.updatedAt = startedAt
    }

    // MARK: - Observer registration

    func addObserver(_ observer: any AgentSessionObserver) {
        observers.removeAll { $0.value == nil }
        observers.append(WeakObserver(value: observer))
    }

    func removeObserver(_ observer: any AgentSessionObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    // MARK: - Transitions

    func transition(to newPhase: AgentPhase) {
        phase = newPhase
    }

    func fail(message: String) {
        errorMessage = message
        phase = .failed
    }

    func cancel() {
        phase = .cancelled
    }

    // MARK: - Approval

    func requestApproval(_ context: ApprovalContext) {
        approval = context
        phase = .awaitingApproval
        notifyApprovalRequested(context)
    }

    func resolveApproval(decision: ApprovalAnswer, scope: ApprovalScope) {
        guard var ctx = approval else { return }
        ctx.decision = decision
        ctx.grantedScope = scope
        approval = ctx
        if decision == .denied {
            phase = .cancelled
        }
    }

    func clearApproval() {
        approval = nil
    }

    // MARK: - Artifacts

    func addArtifact(_ artifact: AgentArtifact) {
        artifacts.append(artifact)
        updatedAt = Date()
        notifyArtifactProduced(artifact)
    }

    // MARK: - Completion

    func complete(with result: AgentResult) {
        self.result = result
        phase = .summarizing
        phase = .completed
        notifyCompleted(result)
    }

    // MARK: - Observer dispatch

    private func notifyTransition(from oldPhase: AgentPhase, to newPhase: AgentPhase) {
        observers.removeAll { $0.value == nil }
        for entry in observers {
            entry.value?.session(self, didTransitionTo: newPhase)
        }
    }

    private func notifyApprovalRequested(_ context: ApprovalContext) {
        observers.removeAll { $0.value == nil }
        for entry in observers {
            entry.value?.session(self, didRequestApproval: context)
        }
    }

    private func notifyArtifactProduced(_ artifact: AgentArtifact) {
        observers.removeAll { $0.value == nil }
        for entry in observers {
            entry.value?.session(self, didProduce: artifact)
        }
    }

    private func notifyCompleted(_ result: AgentResult) {
        observers.removeAll { $0.value == nil }
        for entry in observers {
            entry.value?.session(self, didComplete: result)
        }
    }

    // MARK: - Derived

    var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    /// 0-1 progress, derived from plan steps (or 0 for sessions without a plan).
    var progress: Double {
        guard let steps = plan?.steps, !steps.isEmpty else { return 0 }
        let done = steps.filter { $0.status.isTerminal }.count
        return Double(done) / Double(steps.count)
    }

    // MARK: - Inline compatibility shims (for compose-bar UI bindings)

    /// OllamaAgentSession.status projection derived from phase + pending state.
    var status: OllamaAgentStatus {
        switch phase {
        case .idle, .thinking:    return .planning
        case .awaitingApproval:   return .awaitingApproval
        case .running, .summarizing: return .runningCommand
        case .completed:          return .completed
        case .failed:             return .failed
        case .cancelled:          return .stopped
        }
    }

    /// Legacy API: OllamaAgentSession.goal.
    var goal: String { intent }

    /// Legacy API: OllamaAgentSession.displayGoal.
    var displayGoal: String { intent }

    /// Legacy API: OllamaAgentSession.iteration.
    var iteration: Int {
        get { inlineIteration }
        set { inlineIteration = newValue }
    }

    /// Legacy API: OllamaAgentSession.steps.
    var steps: [InlineAgentStep] {
        get { inlineSteps }
        set { inlineSteps = newValue }
    }

    /// Legacy API: OllamaAgentSession.canApprove.
    var canApprove: Bool {
        status == .awaitingApproval && pendingCommand?.isEmpty == false
    }

    /// Legacy API: OllamaAgentSession.latestPlanText.
    var latestPlanText: String? {
        if let pendingMessage, !pendingMessage.isEmpty {
            return pendingMessage
        }
        return inlineSteps.last(where: { $0.kind == .plan || $0.kind == .summary || $0.kind == .error })?.text
    }

    // MARK: - Compatibility (temporary — used while AgentSessionState callers migrate)

    /// Passthrough to `plan?.steps` so code written against the old
    /// AgentSessionState.planSteps continues to work. Mutations apply to the
    /// underlying AgentPlan (reference type).
    var planSteps: [AgentPlanStep] {
        get { plan?.steps ?? [] }
        set { plan?.steps = newValue }
    }

    /// Alias kept for migration from AgentSessionState.userIntent.
    var userIntent: String { rawPrompt }

    /// Alias kept for migration from AgentSessionState.displayIntent.
    var displayIntent: String { intent }

    /// Index within plan.steps that is currently running (nil if none).
    /// Kept for migration from AgentSessionState.currentStepIndex.
    var currentStepIndex: Int? {
        get { plan?.steps.firstIndex(where: { $0.status == .running }) }
        set { /* no-op — derived state. Callers that used to assign should stop. */ _ = newValue }
    }

    // MARK: - Derived

    var progressLabel: String {
        if let plan, !plan.steps.isEmpty {
            let done = plan.steps.filter { $0.status.isTerminal }.count
            if let running = plan.steps.first(where: { $0.status == .running }) {
                return "Step \(done + 1)/\(plan.steps.count): \(running.title.prefix(40))"
            }
            return "\(done)/\(plan.steps.count) steps"
        }
        return phase.userLabel
    }
}
