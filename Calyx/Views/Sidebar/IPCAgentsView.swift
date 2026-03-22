// IPCAgentsView.swift
// Calyx
//
// Sidebar panel for the IPC MCP feature: server status, connected agents,
// broadcast composer, activity feed, and workflow launcher.

import SwiftUI

struct IPCAgentsView: View {
    private var agentState: IPCAgentState { IPCAgentState.shared }
    private let server = CalyxMCPServer.shared

    @State private var broadcastText = ""
    @State private var isSending = false
    @State private var selectedPeerFilter: UUID? = nil
    @State private var selectedTopicFilter: String? = nil
    @State private var showWorkflowSheet = false
    @State private var showManualConnectSheet = false
    @State private var selectedWorkflow: AgentWorkflow = AgentWorkflow.templates[1]

    // MARK: - Derived

    private var visiblePeers: [Peer] {
        agentState.peers.filter { $0.name != "calyx-app" }
    }

    private var peerNameMap: [UUID: String] {
        Dictionary(uniqueKeysWithValues: agentState.peers.map { ($0.id, $0.name) })
    }

    private var availableTopics: [String] {
        Array(Set(agentState.activityLog.compactMap(\.topic))).sorted()
    }

    private var filteredLog: [Message] {
        var msgs = agentState.activityLog
        if let pf = selectedPeerFilter {
            msgs = msgs.filter { $0.from == pf || $0.to == pf }
        }
        if let tf = selectedTopicFilter {
            msgs = msgs.filter { $0.topic == tf }
        }
        return Array(msgs.suffix(50).reversed())
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                serverStatusSection
                if agentState.isRunning {
                    peersSection
                    quickActionsSection
                    if !agentState.activityLog.isEmpty {
                        activitySection
                    }
                    workflowSection
                } else {
                    startHintSection
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onAppear {
            agentState.isAgentsTabActive = true
            agentState.markRead()
        }
        .onDisappear {
            agentState.isAgentsTabActive = false
        }
        .sheet(isPresented: $showManualConnectSheet) {
            ManualConnectSheet(port: agentState.port, token: server.token, onDone: { showManualConnectSheet = false })
        }
        .sheet(isPresented: $showWorkflowSheet) {
            LaunchWorkflowSheet(
                selectedWorkflow: $selectedWorkflow,
                onLaunch: { params in
                    showWorkflowSheet = false
                    NotificationCenter.default.post(
                        name: .calyxIPCLaunchWorkflow,
                        object: nil,
                        userInfo: [
                            "roleNames": params.workflow.roles.map(\.name),
                            "autoStart": params.autoStart,
                            "sessionName": params.sessionName,
                            "initialTask": params.initialTask,
                        ]
                    )
                },
                onCancel: { showWorkflowSheet = false }
            )
        }
    }

    // MARK: - Server Status

    private var serverStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("MCP Server", icon: "network")

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(agentState.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(agentState.isRunning ? "Port \(agentState.port)" : "Stopped")
                        .font(.system(size: 12, design: .rounded))
                    Spacer()
                    Button(agentState.isRunning ? "Stop" : "Enable") {
                        NotificationCenter.default.post(
                            name: agentState.isRunning ? .calyxIPCDisable : .calyxIPCEnable,
                            object: nil
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if agentState.isRunning {
                    HStack(spacing: 6) {
                        Text("http://127.0.0.1:\(agentState.port)/mcp")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: { showManualConnectSheet = true }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Show connection instructions")
                        Button(action: copyConnectionInfo) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy URL, token, and JSON config to clipboard")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    // MARK: - Peers

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Agents (\(visiblePeers.count))", icon: "person.2")
                Spacer()
                if selectedPeerFilter != nil {
                    Button("Clear filter") { selectedPeerFilter = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
            }

            if visiblePeers.isEmpty {
                Text("No agents connected yet.\nStart Claude Code in a terminal to connect.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            } else {
                VStack(spacing: 3) {
                    ForEach(visiblePeers, id: \.id) { peer in
                        PeerRowView(
                            peer: peer,
                            isSelected: peer.id == selectedPeerFilter,
                            onTap: {
                                selectedPeerFilter = selectedPeerFilter == peer.id ? nil : peer.id
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Broadcast", icon: "megaphone")

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Message all agents…", text: $broadcastText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                        .onSubmit { sendBroadcast(broadcastText) }

                    Button(action: { sendBroadcast(broadcastText) }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(broadcastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }

                HStack(spacing: 4) {
                    ForEach(QuickCommand.all, id: \.label) { cmd in
                        Button(cmd.label) { sendBroadcast(cmd.text, topic: cmd.topic) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .font(.system(size: 10, design: .rounded))
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Activity Feed

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Activity (\(agentState.activityLog.count))", icon: "bubble.left.and.bubble.right")
                Spacer()
                Button("Clear") { agentState.clearLog() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            // Topic filter chips
            if !availableTopics.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(availableTopics, id: \.self) { topic in
                            Button(topic) {
                                selectedTopicFilter = selectedTopicFilter == topic ? nil : topic
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(
                                    selectedTopicFilter == topic
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.white.opacity(0.08)
                                )
                            )
                        }
                    }
                }
            }

            if filteredLog.isEmpty {
                Text("No messages match the current filter.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 3) {
                    ForEach(filteredLog, id: \.id) { msg in
                        MessageRowView(message: msg, peerNames: peerNameMap)
                    }
                }
            }
        }
    }

    // MARK: - Workflow

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Start Session", icon: "play.circle")
            Button(action: { showWorkflowSheet = true }) {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text("Launch Agent Workflow…")
                    Spacer()
                }
                .font(.system(size: 12, design: .rounded))
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let roleNames = agentState.lastWorkflow, !visiblePeers.isEmpty {
                Button(action: { rejoinSession(roleNames: roleNames) }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Rejoin Session (\(roleNames.joined(separator: ", ")))")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .font(.system(size: 12, design: .rounded))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-send role context to connected peers from the last workflow")
            }
        }
    }

    // MARK: - Start Hint

    private var startHintSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Enable the MCP server to let\nClaude agents communicate.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func sendBroadcast(_ text: String, topic: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        broadcastText = ""
        isSending = true
        Task {
            await server.ensureAppPeerRegistered()
            guard let appPeerID = server.appPeerID else { isSending = false; return }
            try? await server.store.broadcast(from: appPeerID, content: trimmed, topic: topic)
            isSending = false
        }
    }

    private func rejoinSession(roleNames: [String]) {
        let port = agentState.port
        Task {
            await server.ensureAppPeerRegistered()
            guard let appPeerID = server.appPeerID else { return }
            let peers = await CalyxMCPServer.shared.store.listPeers()
            for peer in peers where peer.name != "calyx-app" {
                if roleNames.contains(where: { $0.lowercased() == peer.name.lowercased() }) {
                    let prompt = AgentWorkflow.rolePrompt(roleName: peer.name, allRoles: roleNames, port: port)
                    try? await CalyxMCPServer.shared.store.sendMessage(
                        from: appPeerID, to: peer.id, content: prompt, topic: "role-context", replyTo: nil
                    )
                }
            }
        }
    }

    private func copyConnectionInfo() {
        let url = "http://127.0.0.1:\(agentState.port)/mcp"
        let token = server.token
        let info = """
        MCP URL: \(url)
        Token:   \(token)

        JSON config snippet:
        {
          "mcpServers": {
            "calyx-ipc": {
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    // MARK: - Helper

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

// MARK: - Quick Commands

private struct QuickCommand {
    let label: String
    let text: String
    let topic: String?

    static let all: [QuickCommand] = [
        QuickCommand(label: "Status?", text: "Status update — what are you working on right now?", topic: "status"),
        QuickCommand(label: "Pause", text: "Pause your current work and wait for further instructions.", topic: "control"),
        QuickCommand(label: "Resume", text: "Resume your work.", topic: "control"),
    ]
}

// MARK: - PeerRowView

private struct PeerRowView: View {
    let peer: Peer
    let isSelected: Bool
    var onTap: () -> Void

    private var freshnessOpacity: Double {
        let age = Date().timeIntervalSince(peer.lastSeen)
        return max(0.35, 1 - age / 60)
    }

    private var ageLabel: String {
        let age = Date().timeIntervalSince(peer.lastSeen)
        if age < 5 { return "just now" }
        if age < 60 { return "\(Int(age))s ago" }
        return "\(Int(age / 60))m ago"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green.opacity(freshnessOpacity))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    if !peer.role.isEmpty {
                        Text(peer.role)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(ageLabel)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MessageRowView

private struct MessageRowView: View {
    let message: Message
    let peerNames: [UUID: String]

    private var fromName: String { peerNames[message.from] ?? "?" }
    private var toName: String { peerNames[message.to] ?? "?" }

    private var timeLabel: String {
        let age = Date().timeIntervalSince(message.timestamp)
        if age < 5 { return "now" }
        if age < 60 { return "\(Int(age))s" }
        return "\(Int(age / 60))m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(fromName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(toName)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                if let topic = message.topic {
                    Text(topic)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                }
                Spacer()
                Text(timeLabel)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
            Text(message.content.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
    }
}

// MARK: - LaunchWorkflowSheet

struct LaunchWorkflowSheet: View {
    @Binding var selectedWorkflow: AgentWorkflow
    var onLaunch: (WorkflowLaunchParams) -> Void
    var onCancel: () -> Void

    @State private var autoStart = false
    @State private var sessionName = ""
    @State private var initialTask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Launch Agent Workflow")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            // Template picker
            VStack(spacing: 8) {
                ForEach(AgentWorkflow.templates) { workflow in
                    WorkflowTemplateRow(
                        workflow: workflow,
                        isSelected: workflow.id == selectedWorkflow.id,
                        onSelect: { selectedWorkflow = workflow }
                    )
                }
            }

            // Config box
            VStack(alignment: .leading, spacing: 10) {
                Text("Opens \(selectedWorkflow.roles.count) terminal tab\(selectedWorkflow.roles.count == 1 ? "" : "s"):")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)

                ForEach(selectedWorkflow.roles) { role in
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(role.name)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Text("—")
                            .foregroundStyle(.tertiary)
                        Text(role.description)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Session name
                HStack {
                    Text("Session name")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    TextField("e.g. auth refactor", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .rounded))
                }

                // Initial task
                VStack(alignment: .leading, spacing: 4) {
                    Text("Initial task (broadcast to all agents after startup)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                    TextField("Describe the task…", text: $initialTask, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .rounded))
                        .lineLimit(3...5)
                }

                Divider()

                Toggle(isOn: $autoStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-start Claude with role instructions")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                        Text("Runs \u{2018}claude\u{2019} in each tab and sends each agent its role, teammates, and IPC server details.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Launch") {
                    onLaunch(WorkflowLaunchParams(
                        workflow: selectedWorkflow,
                        autoStart: autoStart,
                        sessionName: sessionName.trimmingCharacters(in: .whitespacesAndNewlines),
                        initialTask: initialTask.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - ManualConnectSheet

private struct ManualConnectSheet: View {
    let port: Int
    let token: String
    var onDone: () -> Void

    private var cliCommand: String {
        "claude mcp add --transport http calyx-ipc http://127.0.0.1:\(port)/mcp --header \"Authorization: Bearer \(token)\""
    }

    private var jsonSnippet: String {
        """
        {
          "mcpServers": {
            "calyx-ipc": {
              "url": "http://127.0.0.1:\(port)/mcp",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect an Agent Manually")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text("Run this in any terminal session where Claude Code is running:")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)

            CodeBlockView(code: cliCommand, copyLabel: "Copy Command")

            Divider()

            Text("Or add this to your \u{007E}/.claude.json:")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)

            CodeBlockView(code: jsonSnippet, copyLabel: "Copy JSON")

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct CodeBlockView: View {
    let code: String
    let copyLabel: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))

            Button(copyLabel) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11, design: .rounded))
        }
    }
}

private struct WorkflowTemplateRow: View {
    let workflow: AgentWorkflow
    let isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: workflow.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workflow.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(workflow.description)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                Text("\(workflow.roles.count) tab\(workflow.roles.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
