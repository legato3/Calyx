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
                        onDismiss: onDismiss
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
