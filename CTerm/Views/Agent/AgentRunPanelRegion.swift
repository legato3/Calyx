// AgentRunPanelRegion.swift
// CTerm
//
// Container placed between the terminal area and the compose bar. Reads the
// active tab's inline AgentSession (via Tab.ollamaAgentSession) and any
// other non-terminal session tied to the tab (via AgentSessionRegistry).
// Renders card / strip / nothing based on state.

import SwiftUI

struct AgentRunPanelRegion: View {
    let activeTab: Tab?
    var onApprove: () -> Void
    var onStop: () -> Void
    var onDeny: () -> Void
    var onDismiss: () -> Void

    /// Driven by a 1-second timer so the elapsed-time label updates and the
    /// registry-scanned fallback stays in sync even when a non-inline session
    /// mutates outside of Tab's observable tree.
    @State private var tick: Int = 0
    @State private var timer: Timer?

    var body: some View {
        Group {
            if let session = displayedSession {
                if session.isRunPanelCollapsed {
                    AgentRunPanelStrip(
                        session: session,
                        onExpand: { session.isRunPanelCollapsed = false },
                        onStop: onStop
                    )
                } else {
                    AgentRunPanelView(
                        session: session,
                        onCollapse: { session.isRunPanelCollapsed = true },
                        onStop: onStop,
                        onApprove: onApprove,
                        onDeny: onDeny,
                        onDismiss: onDismiss,
                        onApproveSafe: { approveSafe(in: session) },
                        onApproveStep: { approveStep(id: $0, in: session) },
                        onSkipStep: { skipStep(id: $0, in: session) }
                    )
                }
            } else {
                EmptyView()
            }
        }
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    // MARK: - Selection

    /// Prefers the tab's inline session; falls back to the most recent
    /// non-terminal session in the registry for this tab.
    private var displayedSession: AgentSession? {
        _ = tick  // re-read on timer fire
        guard let tab = activeTab else { return nil }
        if let inline = tab.ollamaAgentSession, !inline.phase.isTerminal {
            return inline
        }
        return AgentSessionRegistry.shared.activeSession(forTab: tab.id)
    }

    // MARK: - Per-step approval

    private func approveStep(id: UUID, in session: AgentSession) {
        guard let plan = session.plan, let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        if plan.steps[idx].status == .pending {
            plan.steps[idx].status = .approved
        }
        maybeStartExecuting(plan: plan)
    }

    private func skipStep(id: UUID, in session: AgentSession) {
        guard let plan = session.plan, let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        if plan.steps[idx].status == .pending || plan.steps[idx].status == .approved {
            plan.steps[idx].status = .skipped
        }
        maybeStartExecuting(plan: plan)
    }

    private func approveSafe(in session: AgentSession) {
        guard let plan = session.plan else { return }
        for i in plan.steps.indices
            where plan.steps[i].status == .pending && !plan.steps[i].willAsk {
            plan.steps[i].status = .approved
        }
        maybeStartExecuting(plan: plan)
    }

    /// If every step has been resolved (approved/skipped/terminal) and the plan
    /// is still in ready state, flip it to executing so ExecutionCoordinator picks up.
    private func maybeStartExecuting(plan: AgentPlan) {
        let anyPending = plan.steps.contains { $0.status == .pending }
        if !anyPending && plan.status == .ready {
            plan.status = .executing
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in tick &+= 1 }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
