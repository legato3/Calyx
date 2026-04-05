// AgentRunPanelView.swift
// CTerm
//
// Warp-style chat view for an inline agent session.
// User goal appears as a message bubble; tool calls show as ✓/⟳ chips;
// the agent summary renders as plain text below. Minimal chrome.

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
    var onSaveFinding: ((BrowserFinding) -> Void)? = nil
    var onSaveAllFindings: (() -> Void)? = nil
    var onNextAction: ((NextAction) -> Void)? = nil
    var onContinue: (() -> Void)? = nil
    var handoffGoalPreview: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chatContent
            if session.phase == .awaitingApproval, let command = session.pendingCommand {
                approvalBar(command: command)
            } else if session.phase.isTerminal {
                terminalBar
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Chat content

    private var chatContent: some View {
        // Use a fixed height to avoid AttributeGraph cycles from maxHeight in
        // an unconstrained VStack. Height adapts to content state.
        let chips = toolChipItems
        let hasFindings = session.browserResearchSession?.findings.isEmpty == false
        let hasActions = session.phase.isTerminal && !nextActions.isEmpty
        let estimatedHeight: CGFloat = {
            var h: CGFloat = 60 // user bubble + padding
            h += CGFloat(min(chips.count, 6)) * 28
            if session.summary != nil || session.phase.isActive || session.errorMessage != nil { h += 36 }
            if hasFindings { h += 80 }
            if hasActions { h += 32 }
            return min(h + 24, 300)
        }()

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                userBubble

                if !chips.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(chips) { chip in
                            ToolCallChip(
                                item: chip,
                                onApprove: chip.needsApproval ? { onApproveStep?(chip.id) } : nil,
                                onSkip: chip.needsApproval ? { onSkipStep?(chip.id) } : nil
                            )
                        }
                    }
                }

                if let summary = session.summary, !summary.isEmpty {
                    agentResponse(summary)
                } else if session.phase.isActive {
                    thinkingIndicator
                } else if let err = session.errorMessage {
                    agentResponse("⚠ \(err)")
                }

                if hasFindings, let research = session.browserResearchSession {
                    findingsBlock(research)
                }

                if hasActions {
                    nextActionsRow
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(height: estimatedHeight)
    }

    // MARK: - User bubble

    private var userBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 40)
            Text(session.intent)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Tool chips

    private var toolChipItems: [ToolChipItem] {
        // Prefer plan steps for multi-step sessions
        if let steps = session.plan?.steps, !steps.isEmpty {
            return steps.map { step in
                ToolChipItem(
                    id: step.id,
                    label: step.command ?? step.title,
                    status: ToolChipItem.Status(stepStatus: step.status),
                    kind: step.kind,
                    needsApproval: step.status == .pending && session.phase == .awaitingApproval
                )
            }
        }
        // Fall back to inline command steps
        return session.inlineSteps
            .filter { $0.kind == .command }
            .map { step in
                ToolChipItem(
                    id: step.id,
                    label: step.command ?? step.text,
                    status: .done,
                    kind: .shell,
                    needsApproval: false
                )
            }
    }

    // MARK: - Agent response

    private func agentResponse(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Thinking indicator

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(session.progressLabel.isEmpty ? session.phase.userLabel : session.progressLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Browser findings

    private func findingsBlock(_ research: BrowserResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(research.findings) { finding in
                BrowserFindingCard(
                    url: finding.url,
                    title: finding.title,
                    preview: finding.preview,
                    fullContent: finding.content,
                    isKept: session.keptFindingIDs.contains(finding.id),
                    onSave: { onSaveFinding?(finding) }
                )
            }
            if research.isComplete,
               !research.findings.isEmpty,
               !research.findings.allSatisfy({ session.keptFindingIDs.contains($0.id) }) {
                Button {
                    onSaveAllFindings?()
                } label: {
                    Label("Save all to memory", systemImage: "tray.and.arrow.down.fill")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.teal)
            }
        }
    }

    // MARK: - Next actions

    private var nextActionsRow: some View {
        HStack(spacing: 6) {
            if let handoff = handoffGoalPreview {
                Button {
                    onContinue?()
                } label: {
                    Label("Continue: \(handoff.prefix(40))", systemImage: "arrow.uturn.forward")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            ForEach(nextActions.prefix(3)) { action in
                Button {
                    onNextAction?(action)
                } label: {
                    Text(action.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(action.prompt)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Approval bar

    private func approvalBar(command: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Deny") { onDeny() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            if hasSafeSteps, let onApproveSafe {
                Button("Approve Safe") { onApproveSafe() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            Button("Approve") { onApprove() }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
    }

    // MARK: - Terminal bar

    private var terminalBar: some View {
        HStack(spacing: 8) {
            Image(systemName: exitIcon)
                .font(.system(size: 10))
                .foregroundStyle(exitTint)
            Text(exitHeadline)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(exitTint)
            Spacer(minLength: 8)
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(exitTint.opacity(0.05))
    }

    // MARK: - Helpers

    private var hasSafeSteps: Bool {
        guard let steps = session.plan?.steps else { return false }
        let pending = steps.filter { $0.status == .pending }
        return pending.contains { !$0.willAsk } && pending.contains { $0.willAsk }
    }

    private var nextActions: [NextAction] { session.result?.nextActions ?? [] }

    private var exitHeadline: String {
        guard let result = session.result else {
            return session.phase == .failed ? "Failed" : "Done"
        }
        let s = result.durationMs / 1000
        let dur = s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
        let files = result.filesChanged.isEmpty ? "" : " · \(result.filesChanged.count) file\(result.filesChanged.count == 1 ? "" : "s") changed"
        switch result.exitStatus {
        case .succeeded: return "Done · \(dur)\(files)"
        case .failed:    return "Failed · \(dur)\(files)"
        case .partial:   return "Partial · \(dur)\(files)"
        case .cancelled: return "Cancelled · \(dur)"
        }
    }

    private var exitIcon: String {
        guard let result = session.result else { return "checkmark.circle.fill" }
        switch result.exitStatus {
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .partial:   return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private var exitTint: Color {
        guard let result = session.result else { return .green }
        switch result.exitStatus {
        case .succeeded: return .green
        case .failed:    return .red
        case .partial:   return .orange
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Tool chip model

private struct ToolChipItem: Identifiable {
    let id: UUID
    let label: String
    let status: Status
    let kind: StepKind
    let needsApproval: Bool

    enum Status {
        case pending, running, done, failed, skipped

        init(stepStatus: AgentPlanStep.StepStatus) {
            switch stepStatus {
            case .pending:   self = .pending
            case .approved:  self = .pending
            case .running:   self = .running
            case .succeeded: self = .done
            case .failed:    self = .failed
            case .skipped:   self = .skipped
            }
        }
    }
}

// MARK: - Tool call chip view

private struct ToolCallChip: View {
    let item: ToolChipItem
    var onApprove: (() -> Void)?
    var onSkip: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(item.label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.needsApproval {
                approvalButtons
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "forward.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var approvalButtons: some View {
        HStack(spacing: 4) {
            Button("Skip") { onSkip?() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Button("Run") { onApprove?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(item.kind == .shell ? .accentColor : .teal)
        }
    }

    private var labelColor: Color {
        switch item.status {
        case .failed:  return .red
        case .skipped: return .secondary
        default:       return .primary
        }
    }

    private var backgroundFill: some ShapeStyle {
        switch item.status {
        case .done:    return AnyShapeStyle(Color.green.opacity(0.07))
        case .running: return AnyShapeStyle(Color.accentColor.opacity(0.08))
        case .failed:  return AnyShapeStyle(Color.red.opacity(0.07))
        default:       return AnyShapeStyle(Color.primary.opacity(0.05))
        }
    }
}
