// AgentRunPanelStrip.swift
// CTerm
//
// Collapsed form: a single subtle chip showing phase icon + label.
// Matches Warp's "✓ Tool Name" style in the tab bar.

import SwiftUI

struct AgentRunPanelStrip: View {
    let session: AgentSession
    var onExpand: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExpand) {
                HStack(spacing: 5) {
                    phaseIcon
                    Text(chipLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(phaseColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(phaseColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if !session.phase.isTerminal {
                Button(action: onStop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var phaseIcon: some View {
        if session.phase.isActive {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        } else if session.phase == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
        } else if session.phase == .failed {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.red)
        } else if session.phase == .awaitingApproval {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var chipLabel: String {
        let intent = session.intent.prefix(60)
        switch session.phase {
        case .completed:        return "✓ \(intent)"
        case .failed:           return "✗ \(intent)"
        case .cancelled:        return "\(intent)"
        case .awaitingApproval: return "Approve: \(intent)"
        default:                return String(intent)
        }
    }

    private var phaseColor: Color {
        switch session.phase {
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
