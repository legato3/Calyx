// AgentRunPlanStepper.swift
// CTerm
//
// Compact vertical list of plan steps with status icons. Highlights the
// currently running step. Used inside AgentRunPanelView.

import SwiftUI

struct AgentRunPlanStepper: View {
    let steps: [AgentPlanStep]
    let maxVisible: Int

    init(steps: [AgentPlanStep], maxVisible: Int = 6) {
        self.steps = steps
        self.maxVisible = maxVisible
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
        // Prefer to show a window centered on the running/next step.
        guard steps.count > maxVisible else { return steps }
        let runningIdx = steps.firstIndex(where: { $0.status == .running })
        let focalIdx = runningIdx ?? steps.firstIndex(where: { !$0.status.isTerminal }) ?? 0
        let lower = max(0, focalIdx - 1)
        let upper = min(steps.count, lower + maxVisible)
        return Array(steps[lower..<upper])
    }

    private func row(_ step: AgentPlanStep) -> some View {
        HStack(spacing: 8) {
            Image(systemName: step.status.icon)
                .font(.system(size: 11))
                .foregroundStyle(color(for: step.status))
                .frame(width: 14)
            Text(step.title)
                .font(.system(size: 11))
                .foregroundStyle(step.status == .running ? .primary : .secondary)
                .fontWeight(step.status == .running ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
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
}
