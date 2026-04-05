import SwiftUI

struct AgentSessionSidebarView: View {
    @Bindable var assistant: ComposeAssistantState
    let agentSession: OllamaAgentSession?
    let pwd: String?

    @Environment(WindowActions.self) private var actions

    @State private var gitBranch: String?

    private var hasContent: Bool {
        agentSession != nil || !assistant.interactions.isEmpty
    }

    private var titleText: String {
        switch assistant.mode {
        case .claudeAgent:
            return "Agent"
        case .ollamaAgent:
            return "Local Agent"
        case .ollamaCommand:
            return "Ollama"
        case .shell:
            return "Agent"
        }
    }

    private var subtitleText: String {
        switch assistant.mode {
        case .claudeAgent:
            return "Claude Subscription-backed workflow for long-running agent tasks."
        case .ollamaAgent:
            return "Plan, approvals, and execution stay here."
        case .ollamaCommand:
            return "Remote command suggestions and command-check assistance."
        case .shell:
            return "Switch the input mode to Agent or Ollama to start."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.28)

            if hasContent {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let agentSession {
                            AgentSessionSidebarCard(
                                session: agentSession,
                                onApprove: { _ = actions.onApproveOllamaAgent?() },
                                onStop: { actions.onStopOllamaAgent?() }
                            )
                        }

                        ForEach(assistant.interactions) { entry in
                            AgentHistoryEntryCard(
                                entry: entry,
                                onEdit: { _ = actions.onApplyComposeAssistantEntry?(entry.id, false) },
                                onRun: { _ = actions.onApplyComposeAssistantEntry?(entry.id, true) },
                                onExplain: { actions.onExplainComposeAssistantEntry?(entry.id) },
                                onFix: { actions.onFixComposeAssistantEntry?(entry.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
            }
        }
        .padding(.top, 4)
        .task(id: pwd) {
            guard let pwd, !pwd.isEmpty else {
                gitBranch = nil
                return
            }
            gitBranch = await TerminalContextGatherer.runTool(
                "git",
                args: ["branch", "--show-current"],
                cwd: pwd,
                timeout: 2
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)

                Text(titleText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                Spacer()

                if !assistant.interactions.isEmpty {
                    Button("Clear") {
                        assistant.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
            }

            Text(subtitleText)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Label(assistant.mode.displayName, systemImage: modeIcon)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(modeTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(modeTint.opacity(0.12), in: Capsule())

                if let gitBranch, !gitBranch.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(gitBranch)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
                }

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.purple.opacity(0.05))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.purple.opacity(0.7))

            Text("No active agent session")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text("Use the input bar below to start Agent or ask Ollama for command help. This sidebar stays dedicated to plans, approvals, and assistant output.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeTint: Color {
        switch assistant.mode {
        case .claudeAgent, .ollamaAgent:
            return .purple
        case .ollamaCommand:
            return .accentColor
        case .shell:
            return .secondary
        }
    }

    private var modeIcon: String {
        switch assistant.mode {
        case .shell:
            return "terminal"
        case .ollamaCommand:
            return "wand.and.stars"
        case .ollamaAgent:
            return "cpu"
        case .claudeAgent:
            return "sparkles"
        }
    }
}

private struct AgentSessionSidebarCard: View {
    let session: OllamaAgentSession
    let onApprove: () -> Void
    let onStop: () -> Void

    private var statusTint: Color {
        switch session.status {
        case .planning:
            return .secondary
        case .awaitingApproval:
            return .orange
        case .runningCommand:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Current Session")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Spacer()

                if session.status == .planning || session.status == .runningCommand {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.8)
                }

                Text(session.status.label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(statusTint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Goal")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text(session.goal)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !session.steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.steps.prefix(8).enumerated()), id: \.element.id) { index, step in
                        AgentSessionStepRow(
                            step: step,
                            isLast: index == session.steps.prefix(8).count - 1
                        )
                    }
                }
            }

            if let pendingCommand = session.pendingCommand,
               !pendingCommand.isEmpty,
               session.canApprove {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Proposed Command", systemImage: "terminal")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)

                    Text(pendingCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 8) {
                        Button("Approve & Run", action: onApprove)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.orange)

                        Button("Stop", action: onStop)
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Spacer()
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
            } else if !session.status.isTerminal {
                HStack {
                    Spacer()
                    Button("Stop Agent", action: onStop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.purple.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct AgentSessionStepRow: View {
    let step: OllamaAgentStep
    let isLast: Bool

    private var iconName: String {
        switch step.kind {
        case .goal:
            return "target"
        case .plan:
            return "list.bullet"
        case .command:
            return "terminal"
        case .observation:
            return "eye"
        case .summary:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch step.kind {
        case .goal:
            return .purple
        case .plan:
            return .accentColor
        case .command:
            return .primary
        case .observation:
            return .secondary
        case .summary:
            return .green
        case .error:
            return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(tint.opacity(0.1), in: Circle())

                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.kind.title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.opacity(0.85))
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let command = step.command, !command.isEmpty {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !step.text.isEmpty, step.text != step.command {
                    Text(step.text)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct AgentHistoryEntryCard: View {
    let entry: ComposeAssistantEntry
    let onEdit: () -> Void
    let onRun: () -> Void
    let onExplain: () -> Void
    let onFix: () -> Void

    private var tint: Color {
        switch entry.status {
        case .failed:
            return .red
        case .ran, .inserted:
            return .green
        default:
            return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.kind.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.1), in: Capsule())

                if entry.status == .pending {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.8)
                }

                Spacer()

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.quaternary)
            }

            Text(entry.prompt)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            if !entry.primaryText.isEmpty, entry.primaryText != entry.prompt {
                Text(entry.primaryText)
                    .font(entry.usesMonospacedBody
                          ? .system(size: 12, design: .monospaced)
                          : .system(size: 11, design: .rounded))
                    .foregroundStyle(entry.status == .failed ? .red : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            if let contextSnippet = entry.contextSnippet,
               !contextSnippet.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)

                    Text(contextSnippet)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
            }

            if entry.canInsert || entry.canRun || entry.canExplain || entry.canFix {
                HStack(spacing: 6) {
                    if entry.canInsert {
                        Button("Edit", action: onEdit)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    if entry.canRun {
                        Button(entry.kind == .shellDispatch ? "Run Again" : "Run", action: onRun)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }

                    if entry.canExplain {
                        Button("Explain", action: onExplain)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    if entry.canFix {
                        Button("Fix", action: onFix)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
