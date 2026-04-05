// AgentLoopView.swift
// CTerm
//
// Sidebar view for the agent loop pipeline. Shows the current session's
// phase, plan steps with approve/skip buttons, live progress, artifacts,
// summary, and next-action chips. Binds directly to AgentLoopCoordinator.

import SwiftUI

struct AgentLoopView: View {
    let coordinator: AgentLoopCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let session = coordinator.activeSession {
                    activeSessionSection(session)
                } else {
                    idleSection
                }

                if !coordinator.sessionHistory.isEmpty {
                    historySection
                }
            }
            .padding(12)
        }
    }

    // MARK: - Idle

    private var idleSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No active agent session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Use the compose bar to start a task")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Active Session

    @ViewBuilder
    private func activeSessionSection(_ session: AgentSessionState) -> some View {
        // Phase badge + intent
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                phaseBadge(session.phase)
                if let intent = session.classifiedIntent {
                    Text(intent.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if session.phase.isActive {
                    Button(action: { coordinator.stopSession() }) {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }

            Text(session.displayIntent)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
        }

        // Progress bar
        if !session.planSteps.isEmpty {
            ProgressView(value: session.progress)
                .tint(session.planSteps.contains(where: { $0.status == .failed }) ? .orange : .blue)
        }

        // Plan steps
        if !session.planSteps.isEmpty {
            planStepsSection(session)
        }

        // Approval buttons
        if session.phase == .awaitingApproval {
            approvalButtons(session)
        }

        // Summary
        if let summary = session.summary {
            summarySection(summary)
        }

        // Next actions
        if !session.nextActions.isEmpty {
            nextActionsSection(session.nextActions)
        }

        // Artifacts
        if !session.artifacts.isEmpty {
            artifactsSection(session.artifacts)
        }
    }

    // MARK: - Plan Steps

    private func planStepsSection(_ session: AgentSessionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(session.planSteps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 6) {
                    Image(systemName: step.status.icon)
                        .font(.caption)
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.caption)
                            .lineLimit(2)
                        if let cmd = step.command {
                            Text(cmd)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let output = step.output, step.status == .failed {
                            Text(output.prefix(100))
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    // Per-step approve/skip for perStep approval
                    if session.approvalRequirement == .perStep && step.status == .pending {
                        HStack(spacing: 4) {
                            Button(action: { coordinator.approveStep(id: step.id) }) {
                                Image(systemName: "checkmark.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.green)

                            Button(action: { coordinator.skipStep(id: step.id) }) {
                                Image(systemName: "forward.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                        }
                    }

                    if let ms = step.durationMs {
                        Text("\(ms)ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Approval Buttons

    private func approvalButtons(_ session: AgentSessionState) -> some View {
        HStack(spacing: 8) {
            Button("Approve All") {
                Task {
                    let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
                    await coordinator.approveAndExecute(pwd: pwd)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Stop") {
                coordinator.stopSession()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Summary

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Next Actions

    private func nextActionsSection(_ actions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggested Next")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(actions, id: \.self) { action in
                    Button(action) {
                        // Clicking a suggestion starts a new session
                        Task {
                            let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
                            await coordinator.startSession(intent: action, pwd: pwd)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Artifacts

    private func artifactsSection(_ artifacts: [AgentArtifact]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Artifacts (\(artifacts.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            let fileArtifacts = artifacts.filter { $0.kind == .fileChanged }
            if !fileArtifacts.isEmpty {
                ForEach(fileArtifacts) { artifact in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(artifact.value)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(coordinator.sessionHistory.prefix(5)) { session in
                HStack(spacing: 6) {
                    Image(systemName: session.phase == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(session.phase == .completed ? .green : .red)
                    Text(session.displayIntent)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTime(session.startedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Helpers

    private func phaseBadge(_ phase: AgentPhase) -> some View {
        HStack(spacing: 3) {
            if phase.isActive {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(phase.label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(phaseColor(phase).opacity(0.15), in: Capsule())
        .foregroundStyle(phaseColor(phase))
    }

    private func phaseColor(_ phase: AgentPhase) -> Color {
        switch phase {
        case .idle:             return .secondary
        case .classifying:      return .purple
        case .planning:         return .blue
        case .awaitingApproval: return .orange
        case .executing:        return .blue
        case .observing:        return .teal
        case .summarizing:      return .indigo
        case .completed:        return .green
        case .failed:           return .red
        }
    }

    private func stepColor(_ status: AgentPlanStep.StepStatus) -> Color {
        switch status {
        case .pending:   return .secondary
        case .approved:  return .blue
        case .running:   return .orange
        case .succeeded: return .green
        case .failed:    return .red
        case .skipped:   return .secondary
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

// MARK: - FlowLayout (simple horizontal wrap)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), offsets)
    }
}
