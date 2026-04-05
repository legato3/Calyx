// AgentActivityChip.swift
// CTerm
//
// Single chip inside AgentActivityStrip. Represents one in-flight
// AgentSession from the shared registry.

import SwiftUI

struct AgentActivityChip: View {
    let session: AgentSession
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                phaseDot
                kindBadge
                Text(session.intent)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                contextBadge
                if let rule = session.triggeredBy {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7))
                        Text(rule)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.yellow.opacity(0.12), in: Capsule())
                    .help("Triggered by rule: \(rule)")
                }
                Text(elapsedString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 280, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Components

    private var phaseDot: some View {
        Group {
            if session.phase.isActive {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 10, height: 10)
    }

    private var kindBadge: some View {
        Text(kindLabel)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var contextBadge: some View {
        switch session.kind {
        case .delegated:
            if case .peer(let name) = session.backend {
                Text(name)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Styling

    private var kindLabel: String {
        switch session.kind {
        case .inline:     return "inline"
        case .multiStep:  return "plan"
        case .queued:     return "queued"
        case .delegated:  return "peer"
        }
    }

    private var tint: Color {
        switch session.kind {
        case .inline:     return .green
        case .multiStep:  return .blue
        case .queued:     return .orange
        case .delegated:  return .purple
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

    private var elapsedString: String {
        let seconds = Int(session.elapsedSeconds)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}
