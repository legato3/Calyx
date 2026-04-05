// AgentActivityStrip.swift
// CTerm
//
// Horizontal strip of AgentActivityChip views showing every non-terminal
// session in the shared registry. Surfaces queued/delegated/multi-step
// work that doesn't live on the active tab's run panel.
//
// Mounted below the compose bar. Zero-height when no active sessions.

import SwiftUI

struct AgentActivityStrip: View {
    var onChipTap: (AgentSession) -> Void

    @State private var registry = AgentSessionRegistry.shared
    @State private var collapsed: Bool = UserDefaults.standard.bool(forKey: "cterm.agentActivityStripCollapsed")
    @State private var tick: Int = 0
    @State private var timer: Timer?

    var body: some View {
        let _ = tick  // re-read observable state on timer fire
        let sessions = registry.active
        Group {
            if sessions.isEmpty {
                EmptyView()
            } else if collapsed {
                collapsedPill(count: sessions.count)
            } else {
                expandedStrip(sessions: sessions)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: collapsed)
        .animation(.easeInOut(duration: 0.15), value: sessions.count)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    private func expandedStrip(sessions: [AgentSession]) -> some View {
        HStack(spacing: 6) {
            Text("Active")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions) { session in
                        AgentActivityChip(
                            session: session,
                            onTap: { onChipTap(session) },
                            onCancel: { cancel(session) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            Button {
                for session in sessions { cancel(session) }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel all active sessions")
            Button {
                setCollapsed(true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .background(.ultraThinMaterial)
    }

    private func cancel(_ session: AgentSession) {
        session.errorMessage = "Cancelled from activity strip."
        session.cancel()
    }

    private func collapsedPill(count: Int) -> some View {
        HStack {
            Spacer()
            Button {
                setCollapsed(false)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
                    Text("\(count) active")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
        }
    }

    private func setCollapsed(_ value: Bool) {
        collapsed = value
        UserDefaults.standard.set(value, forKey: "cterm.agentActivityStripCollapsed")
    }

    // MARK: - Timer (polls because registry dict mutations don't auto-publish)

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
