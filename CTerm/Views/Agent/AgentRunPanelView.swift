// AgentRunPanelView.swift
// CTerm
//
// The card form of the agent run panel. Shows goal, phase, plan stepper,
// current command, last observation, and primary buttons. Tap the header
// to collapse back to the strip.

import SwiftUI

struct AgentRunPanelView: View {
    let session: AgentSession
    var onCollapse: () -> Void
    var onStop: () -> Void
    var onApprove: () -> Void
    var onDeny: () -> Void
    var onDismiss: () -> Void
    var onApproveSafe: (() -> Void)? = nil
    var onApproveStep: ((UUID) -> Void)? = nil
    var onSkipStep: ((UUID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statusLine
            if let plan = session.plan, !plan.steps.isEmpty {
                Divider()
                AgentRunPlanStepper(
                    steps: plan.steps,
                    awaitingApproval: session.phase == .awaitingApproval,
                    onApproveStep: onApproveStep,
                    onSkipStep: onSkipStep
                )
            }
            if session.phase == .awaitingApproval, let command = session.pendingCommand {
                Divider()
                approvalBlock(command: command)
            } else if session.phase.isActive {
                Divider()
                runningBlock
            } else if session.phase.isTerminal {
                Divider()
                summaryBlock
            }
            buttonsRow
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForKind)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(session.intent)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCollapse)
    }

    private var iconForKind: String {
        switch session.kind {
        case .inline:     return "terminal"
        case .multiStep:  return "list.bullet.rectangle"
        case .queued:     return "tray.and.arrow.down"
        case .delegated:  return "arrow.triangle.branch"
        }
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 6) {
            phaseBadge
            Text("•")
                .foregroundStyle(.tertiary)
            Text(session.progressLabel)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(elapsedString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var phaseBadge: some View {
        HStack(spacing: 4) {
            if session.phase.isActive {
                ProgressView().controlSize(.mini)
            }
            Text(session.phase.userLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(phaseColor)
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
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: - Running block

    private var runningBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let running = session.plan?.steps.first(where: { $0.status == .running }),
               let command = running.command {
                HStack(spacing: 6) {
                    Text("$")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let lastObs = lastObservation {
                Text(lastObs)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    /// True when the plan has at least one safe pending step + at least one risky one,
    /// so the "Approve Safe" shortcut is meaningful.
    private var hasSafeSteps: Bool {
        guard let steps = session.plan?.steps else { return false }
        let pending = steps.filter { $0.status == .pending }
        let safe = pending.filter { !$0.willAsk }
        let risky = pending.filter { $0.willAsk }
        return !safe.isEmpty && !risky.isEmpty
    }

    private var lastObservation: String? {
        let artifactText = session.artifacts
            .last(where: { $0.kind == .commandOutput })?
            .value
        if let artifactText, !artifactText.isEmpty { return artifactText }
        return session.inlineSteps.first(where: { $0.kind == .observation })?.text
    }

    // MARK: - Approval block

    private func approvalBlock(command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Awaiting approval")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Summary block

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = session.summary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let err = session.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Buttons

    private var buttonsRow: some View {
        HStack(spacing: 8) {
            Spacer()
            switch session.phase {
            case .awaitingApproval:
                Button("Deny") { onDeny() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                if hasSafeSteps, let onApproveSafe {
                    Button("Approve Safe") { onApproveSafe() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                Button("Approve All") { onApprove() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.orange)
            case .completed, .failed, .cancelled:
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            case .idle, .thinking, .running, .summarizing:
                Button {
                    onStop()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop").font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
            }
        }
    }
}
