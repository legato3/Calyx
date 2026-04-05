// TaskCardViews.swift
// CTerm
//
// Reusable card and row views for the task sidebar.
// TaskCard: full expanded view with step timeline, approval controls, progress.
// TaskCompactRow: minimal row for background tasks.
// TaskQueueRow: row for queued tasks with priority badge.
// TaskHistoryRow: row for completed/failed tasks with retry option.

import SwiftUI

// MARK: - TaskCard (Active Task)

struct TaskCard: View {
    let task: ManagedTask
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onApprove: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onBackground: () -> Void
    let onApproveStep: (UUID) -> Void
    let onSkipStep: (UUID) -> Void

    @State private var phasePulse = false

    private var phaseTint: Color {
        switch task.phase.tintName {
        case "purple":    return .purple
        case "orange":    return .orange
        case "green":     return .green
        case "red":       return .red
        case "blue":      return .blue
        case "teal":      return .teal
        case "indigo":    return .indigo
        case "yellow":    return .yellow
        default:          return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                phaseIndicator
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayPrompt)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(isExpanded ? nil : 2)
                    HStack(spacing: 6) {
                        Text(task.phase.rawValue)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(phaseTint)
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(task.elapsedFormatted)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                        if task.attemptCount > 0 {
                            Text("· attempt \(task.attemptCount + 1)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Progress bar
            if !task.planSteps.isEmpty {
                progressBar
            }

            // Streaming preview
            if let preview = task.streamingPreview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            }

            // Expanded: step timeline
            if isExpanded && !task.planSteps.isEmpty {
                stepTimeline
            }

            // Approval banner
            if task.phase == .awaitingApproval {
                approvalBanner
            }

            // Error message
            if let error = task.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // Summary + next actions
            if let summary = task.summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !task.nextActions.isEmpty {
                        Text("Suggested next:")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                        ForEach(task.nextActions, id: \.self) { action in
                            Text("→ \(action)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.purple)
                        }
                    }
                }
            }

            // Controls
            controlBar
        }
        .padding(12)
        .background(phaseTint.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(phaseTint.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Phase Indicator

    private var phaseIndicator: some View {
        ZStack {
            Circle()
                .fill(phaseTint.opacity(0.15))
                .frame(width: 28, height: 28)
            if task.phase.isActive {
                Circle()
                    .fill(phaseTint.opacity(0.08))
                    .frame(width: 28, height: 28)
                    .scaleEffect(phasePulse ? 1.4 : 1.0)
                    .opacity(phasePulse ? 0 : 0.5)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                            phasePulse = true
                        }
                    }
                    .onDisappear { phasePulse = false }
            }
            Image(systemName: task.phase.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(phaseTint)
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(phaseTint)
                        .frame(width: geo.size.width * task.progress, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: task.progress)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(task.succeededStepCount)/\(task.planSteps.count) steps")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
                if task.failedStepCount > 0 {
                    Text("\(task.failedStepCount) failed")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Step Timeline

    private var stepTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(task.planSteps.enumerated()), id: \.element.id) { index, step in
                TaskStepRow(
                    step: step,
                    isLast: index == task.planSteps.count - 1,
                    showApproval: task.phase == .awaitingApproval && step.status == .pending,
                    onApprove: { onApproveStep(step.id) },
                    onSkip: { onSkipStep(step.id) }
                )
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Approval Banner

    private var approvalBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Plan ready — review and approve")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                Spacer()
            }

            HStack(spacing: 8) {
                Button("Approve All", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            if task.phase.canPause {
                Button(action: onPause) {
                    Label("Pause", systemImage: "pause")
                        .font(.system(size: 10, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if task.phase == .paused {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play")
                        .font(.system(size: 10, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }

            if task.phase.canCancel {
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 10, design: .rounded))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if task.canRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }

            Spacer()

            if task.phase.isActive {
                Button(action: onBackground) {
                    Image(systemName: "arrow.down.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Move to background")
            }
        }
    }
}

// MARK: - TaskStepRow

struct TaskStepRow: View {
    let step: AgentPlanStep
    let isLast: Bool
    let showApproval: Bool
    let onApprove: () -> Void
    let onSkip: () -> Void

    private var stepTint: Color {
        switch step.status {
        case .pending:   return .secondary
        case .approved:  return .blue
        case .running:   return .purple
        case .succeeded: return .green
        case .failed:    return .red
        case .skipped:   return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timeline connector
            VStack(spacing: 0) {
                Image(systemName: step.status.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(stepTint)
                    .frame(width: 18, height: 18)
                    .background(stepTint.opacity(0.1), in: Circle())

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(step.status.isTerminal && step.status != .succeeded ? .secondary : .primary)

                if let command = step.command, !command.isEmpty {
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let output = step.output, !output.isEmpty {
                    Text(output.prefix(200))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }

                if let ms = step.durationMs {
                    Text("\(ms)ms")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.quaternary)
                }

                if showApproval {
                    HStack(spacing: 6) {
                        Button("Approve", action: onApprove)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(.orange)
                        Button("Skip", action: onSkip)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// MARK: - TaskCompactRow (Background)

struct TaskCompactRow: View {
    let task: ManagedTask
    let onCancel: () -> Void
    let onForeground: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.phase.icon)
                .font(.system(size: 10))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayPrompt)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(task.phase.rawValue)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                    if !task.planSteps.isEmpty {
                        Text("· \(task.succeededStepCount)/\(task.planSteps.count)")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Button(action: onForeground) {
                Image(systemName: "arrow.up.left.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Bring to foreground")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - TaskQueueRow

struct TaskQueueRow: View {
    let task: ManagedTask
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.priority.icon)
                .font(.system(size: 10))
                .foregroundStyle(task.priority >= .high ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayPrompt)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(task.priority.label)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(task.model.displayName)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - TaskHistoryRow

struct TaskHistoryRow: View {
    let task: ManagedTask
    let onRetry: () -> Void

    private var statusTint: Color {
        switch task.phase {
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .gray
        default:         return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: task.phase.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(statusTint)

                Text(task.displayPrompt)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(2)

                Spacer()

                Text(task.elapsedFormatted)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.quaternary)
            }

            if let summary = task.summary {
                Text(summary)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 4) {
                if !task.planSteps.isEmpty {
                    Text("\(task.succeededStepCount)/\(task.planSteps.count) steps")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if task.canRetry {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
