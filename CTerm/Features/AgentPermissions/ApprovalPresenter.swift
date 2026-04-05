// ApprovalPresenter.swift
// CTerm
//
// Bridge between AgentSession approval events and the SwiftUI approval sheet.
// Watches every registered AgentSession; whenever one requests approval,
// it exposes the pending session + context so the UI sheet can render.
// On resolve, records the grant and pokes the session to resume.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ApprovalPresenter")

@Observable
@MainActor
final class ApprovalPresenter: AgentSessionObserver {

    static let shared = ApprovalPresenter()

    private(set) var pendingSession: AgentSession?
    private(set) var pendingContext: ApprovalContext?
    private(set) var pendingHardStop: HardStopReason?
    /// pwd at the moment of the approval request — needed for repo-scope grants.
    private(set) var pendingRepoPath: String?

    /// Queued approval requests that arrived while one was already being shown.
    private struct QueuedApproval {
        let session: AgentSession
        let context: ApprovalContext
        let repoPath: String?
    }
    private var approvalQueue: [QueuedApproval] = []

    private var watchedSessionIDs: Set<UUID> = []
    private var pollTimer: Timer?

    private init() {}

    // MARK: - Session watching

    /// Start watching the shared registry so every new session gets an observer.
    func startWatching() {
        // Watch any session already registered.
        for s in AgentSessionRegistry.shared.all {
            attachIfNeeded(s)
        }
        // Poll for new sessions. The registry is @Observable but can't publish
        // dictionary inserts through the observer protocol, so a short poll
        // keeps this presenter in sync.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepRegistry() }
        }
    }

    private func sweepRegistry() {
        for s in AgentSessionRegistry.shared.all {
            attachIfNeeded(s)
        }
    }

    private func attachIfNeeded(_ session: AgentSession) {
        if !watchedSessionIDs.contains(session.id) {
            watchedSessionIDs.insert(session.id)
            session.addObserver(self)
        }
    }

    /// Set before calling `session.requestApproval(...)` so the presenter knows
    /// which repo path to associate with repo-scoped grants.
    /// Only affects the currently-shown approval; queued approvals capture their
    /// own repo path at the time they are enqueued.
    func setRepoPath(_ path: String?) {
        if pendingSession != nil {
            pendingRepoPath = path
        } else {
            // Store for the next approval that arrives (existing behaviour).
            pendingRepoPath = path
        }
    }

    // MARK: - AgentSessionObserver

    func session(_ session: AgentSession, didRequestApproval context: ApprovalContext) {
        // If another approval is already being shown, queue this one instead of
        // overwriting — otherwise the first session's callback is silently lost.
        if pendingSession != nil {
            approvalQueue.append(QueuedApproval(session: session, context: context, repoPath: pendingRepoPath))
            logger.info("Approval queued (presenter busy): session=\(session.id.uuidString.prefix(8))")
            return
        }
        showApproval(session: session, context: context, repoPath: pendingRepoPath)
    }

    private func showApproval(session: AgentSession, context: ApprovalContext, repoPath: String?) {
        pendingSession = session
        pendingContext = context
        pendingHardStop = nil  // hard-stop flag is set via `present(hardStop:)`
        pendingRepoPath = repoPath
        logger.info("Approval requested: session=\(session.id.uuidString.prefix(8)) score=\(context.riskScore)")
    }

    // MARK: - Public API

    /// Called by the gate when a hard-stop needs confirmation. Stores the reason
    /// so the sheet can render the stronger red-warning layout.
    func presentHardStop(reason: HardStopReason) {
        pendingHardStop = reason
    }

    /// Resolve the currently-shown approval. Records any grant, flips the
    /// session's approval state, kicks the driver to resume, clears state.
    func resolve(answer: ApprovalAnswer, scope: ApprovalScope) {
        guard let session = pendingSession, let context = pendingContext else { return }

        // Hard-stop approvals are always treated as once-only — never grant
        // broader scope on a destructive action regardless of what the UI passes.
        let effectiveScope = pendingHardStop != nil ? ApprovalScope.once : scope

        if answer == .approved, pendingHardStop == nil, effectiveScope != .once {
            let key = keyFrom(context: context)
            let grantContext = GrantContext(sessionID: session.id, pwd: pendingRepoPath)
            AgentGrantStore.shared.record(
                key: key,
                scope: effectiveScope,
                context: grantContext,
                repoPath: pendingRepoPath
            )
        }

        let resume = session.onApprovalResolved

        session.resolveApproval(decision: answer, scope: effectiveScope)
        session.clearApproval()

        pendingSession = nil
        pendingContext = nil
        pendingHardStop = nil
        pendingRepoPath = nil

        resume?(answer)

        // Show the next queued approval, if any.
        if let next = approvalQueue.first {
            approvalQueue.removeFirst()
            // Skip approvals for sessions that have already terminated.
            if !next.session.phase.isTerminal {
                showApproval(session: next.session, context: next.context, repoPath: next.repoPath)
            } else if !approvalQueue.isEmpty {
                let following = approvalQueue.removeFirst()
                showApproval(session: following.session, context: following.context, repoPath: following.repoPath)
            }
        }
    }

    /// Cancel without a grant — also resumes the driver so it can move on.
    func dismiss() {
        resolve(answer: .deferred, scope: .once)
    }

    // MARK: - Helpers

    private func keyFrom(context: ApprovalContext) -> GrantKey {
        // Reconstruct a grant key from the descriptor. ActionDescriber always
        // formats shell commands as "Run: <command>"; strip that prefix.
        let what = context.action.what
        let command: String = {
            if what.hasPrefix("Run: ") { return String(what.dropFirst(5)) }
            if what.hasPrefix("Browser: ") { return String(what.dropFirst(9)) }
            return what
        }()
        let prefix = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? command
        // We don't know the category precisely here; derive it from the tier +
        // command prefix. This is fine for matching since RiskScorer is
        // deterministic on command text.
        let assessment = RiskScorer.assess(command: command, pwd: pendingRepoPath, gitBranch: nil)
        return GrantKey(category: assessment.category, riskTier: context.riskTier, commandPrefix: prefix)
    }
}
