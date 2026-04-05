// AgentRunPanelStrip.swift
// CTerm
//
// Collapsed form of the agent run panel. Thin horizontal strip showing phase
// badge, progress bar, and an expand chevron. Tap to expand into the card.

import SwiftUI

struct AgentRunPanelStrip: View {
    let session: AgentSession
    var onExpand: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            phaseBadge
            progressLabel
            if !(session.plan?.steps.isEmpty ?? true) && session.phase.isActive {
                ProgressView(value: session.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                    .tint(.accentColor)
            }
            Spacer(minLength: 8)
            if !session.phase.isTerminal {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.red))
                }
                .buttonStyle(.plain)
            }
            Button(action: onExpand) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    private var phaseBadge: some View {
        HStack(spacing: 4) {
            if session.phase.isActive {
                ProgressView().controlSize(.mini)
            } else if session.phase == .completed {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
            } else if session.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red)
            } else if session.phase == .awaitingApproval {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text(session.phase.userLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color(for: session.phase))
        }
    }

    private var progressLabel: some View {
        Text(session.progressLabel.prefix(50))
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func color(for phase: AgentPhase) -> Color {
        switch phase {
        case .idle:             return .secondary
        case .thinking:         return .blue
        case .awaitingApproval: return .orange
        case .running:          return .teal
        case .summarizing:      return .indigo
        case .completed:        return .green
        case .failed:           return .red
        case .cancelled:        return .secondary
        }
    }
}
