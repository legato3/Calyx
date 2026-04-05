// AgentRunPlanStepper.swift
// CTerm
//
// Compact vertical list of plan steps with status icons. Highlights the
// currently running step. Shows kind badge + will-ask indicator + inline
// Approve/Skip buttons for risky pending rows.

import SwiftUI

struct AgentRunPlanStepper: View {
    let steps: [AgentPlanStep]
    let maxVisible: Int
    /// Only visible when the plan is in awaiting-approval phase; gates the
    /// per-row buttons from showing during execution.
    let awaitingApproval: Bool
    var onApproveStep: ((UUID) -> Void)? = nil
    var onSkipStep: ((UUID) -> Void)? = nil

    init(
        steps: [AgentPlanStep],
        maxVisible: Int = 6,
        awaitingApproval: Bool = false,
        onApproveStep: ((UUID) -> Void)? = nil,
        onSkipStep: ((UUID) -> Void)? = nil
    ) {
        self.steps = steps
        self.maxVisible = maxVisible
        self.awaitingApproval = awaitingApproval
        self.onApproveStep = onApproveStep
        self.onSkipStep = onSkipStep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleSteps) { step in
                row(step)
            }
            if steps.count > maxVisible {
                Text("+\(steps.count - maxVisible) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
    }

    private var visibleSteps: [AgentPlanStep] {
        guard steps.count > maxVisible else { return steps }
        let runningIdx = steps.firstIndex(where: { $0.status == .running })
        let focalIdx = runningIdx ?? steps.firstIndex(where: { !$0.status.isTerminal }) ?? 0
        let lower = max(0, focalIdx - 1)
        let upper = min(steps.count, lower + maxVisible)
        return Array(steps[lower..<upper])
    }

    private func row(_ step: AgentPlanStep) -> some View {
        HStack(spacing: 6) {
            Image(systemName: step.status.icon)
                .font(.system(size: 11))
                .foregroundStyle(color(for: step.status))
                .frame(width: 14)
            kindBadge(step.kind)
            Text(step.title)
                .font(.system(size: 11))
                .foregroundStyle(step.status == .running ? .primary : .secondary)
                .fontWeight(step.status == .running ? .semibold : .regular)
                .lineLimit(1)
            if step.willAsk && !step.status.isTerminal {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("This step will ask for approval at dispatch")
            }
            Spacer(minLength: 4)
            if awaitingApproval && step.status == .pending {
                perStepButtons(step)
            }
        }
    }

    private func kindBadge(_ kind: StepKind) -> some View {
        HStack(spacing: 2) {
            Image(systemName: kind.icon)
                .font(.system(size: 8, weight: .medium))
            Text(kind.label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .foregroundStyle(tint(for: kind))
        .background(tint(for: kind).opacity(0.12), in: Capsule())
    }

    private func perStepButtons(_ step: AgentPlanStep) -> some View {
        HStack(spacing: 4) {
            Button {
                onApproveStep?(step.id)
            } label: {
                Text("Approve")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(step.willAsk ? .orange : .accentColor)

            Button {
                onSkipStep?(step.id)
            } label: {
                Text("Skip")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func color(for status: AgentPlanStep.StepStatus) -> Color {
        switch status {
        case .pending:   return .secondary.opacity(0.5)
        case .approved:  return .blue
        case .running:   return .accentColor
        case .succeeded: return .green
        case .failed:    return .red
        case .skipped:   return .secondary.opacity(0.4)
        }
    }

    private func tint(for kind: StepKind) -> Color {
        switch kind {
        case .shell:   return .blue
        case .browser: return .teal
        case .peer:    return .purple
        case .manual:  return .secondary
        }
    }
}
