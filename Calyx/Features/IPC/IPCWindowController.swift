import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "IPCWindowController"
)

/// Handles IPC enable/disable lifecycle and IPC-triggered window actions
/// (workflow launch, review dispatch). Owned by CalyxWindowController.
@MainActor
final class IPCWindowController {
    private let mcpServer: CalyxMCPServer
    private weak var windowSession: WindowSession?

    /// Called to open a new terminal tab with the given working directory.
    var onCreateNewTab: ((String?) -> Void)?
    /// Called to switch focus to a specific tab by ID.
    var onSwitchToTab: ((UUID) -> Void)?
    /// Called to send a Return/Enter key to a terminal surface controller.
    var onSendEnterKey: ((GhosttySurfaceController) -> Void)?
    /// Returns the active tab's current working directory (for workflow directory defaulting).
    var getActiveTabPwd: (() -> String?)?
    /// Called when IPC review is requested — should open the git sidebar.
    var onShowGitSidebar: (() -> Void)?

    /// Pending role prompts keyed by tab title (role name). Populated during workflow launch;
    /// consumed when the matching peer calls register_peer.
    private var pendingRolePrompts: [String: (tab: Tab, prompt: String)] = [:]
    /// Notification observer token for peerRegistered events. Using NSObjectProtocol boxed
    /// in a class wrapper so the block-based observer is removed when no longer needed.
    private var peerRegisteredObserver: NSObjectProtocol?

    init(mcpServer: CalyxMCPServer, windowSession: WindowSession) {
        self.mcpServer = mcpServer
        self.windowSession = windowSession
    }


    // MARK: - IPC Toggle

    func enableIPC() {
        do {
            let token = SecurityUtils.generateHexToken()
            try mcpServer.start(token: token)
            let port = mcpServer.port
            let result = IPCConfigManager.enableIPC(port: port, token: token)

            if !result.anySucceeded {
                mcpServer.stop()
                showAlert(
                    title: "IPC Error",
                    message: "MCP server running on port \(port).\nNo agent configs found. Configure manually if needed."
                )
                return
            }

            UserDefaults.standard.set(true, forKey: "calyx.ipcAutoStart")
            IPCAgentState.shared.startPolling()
            showAlert(
                title: "IPC Enabled",
                message: "MCP server running on port \(port).\n\(configStatusMessage(result))\nRestart agent instances to connect."
            )
        } catch {
            showAlert(title: "IPC Error", message: error.localizedDescription)
        }
    }

    func disableIPC() {
        UserDefaults.standard.set(false, forKey: "calyx.ipcAutoStart")
        mcpServer.stop()
        IPCAgentState.shared.stopPolling()
        IPCAgentState.shared.clearLog()
        let result = IPCConfigManager.disableIPC()
        showAlert(
            title: "IPC Disabled",
            message: "MCP server stopped.\n\(configStatusMessage(result))"
        )
    }

    // MARK: - Review Requested

    func handleReviewRequested() {
        guard let session = windowSession else { return }
        session.sidebarMode = .changes
        session.showSidebar = true
        onShowGitSidebar?()
    }

    // MARK: - Workflow Launch

    func handleLaunchWorkflow(event: CalyxIPCLaunchWorkflowEvent) {
        let roleNames = event.roleNames
        let autoStart = event.autoStart
        let sessionName = event.sessionName
        let initialTask = event.initialTask
        let port = mcpServer.port

        let panel = NSOpenPanel()
        panel.title = "Choose Session Directory"
        panel.message = "All agent tabs will open in this folder."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if let tabPwd = getActiveTabPwd?() {
            panel.directoryURL = URL(fileURLWithPath: tabPwd)
        }

        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        let pwd = chosenURL.path

        IPCAgentState.shared.lastWorkflow = roleNames

        if !sessionName.isEmpty {
            windowSession?.activeGroup?.name = sessionName
        }

        var createdTabs: [Tab] = []
        for roleName in roleNames {
            onCreateNewTab?(pwd)
            if let newTab = windowSession?.activeGroup?.tabs.last {
                newTab.title = roleName
                createdTabs.append(newTab)
            }
        }

        if !initialTask.isEmpty && autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                Task { @MainActor in
                    await self.mcpServer.ensureAppPeerRegistered()
                    guard let appPeerID = self.mcpServer.appPeerID else { return }
                    _ = try? await self.mcpServer.store.broadcast(
                        from: appPeerID,
                        content: initialTask,
                        topic: "task"
                    )
                }
            }
        }

        guard autoStart, createdTabs.count == roleNames.count else { return }

        // Build a role-name → (tab, prompt) map so we can inject prompts when
        // the matching peer calls register_peer rather than after a hardcoded delay.
        for (tab, roleName) in zip(createdTabs, roleNames) {
            let prompt = AgentWorkflow.rolePrompt(roleName: roleName, allRoles: roleNames, port: port)
            pendingRolePrompts[roleName.lowercased()] = (tab: tab, prompt: prompt)
        }

        // Subscribe to peerRegistered once (idempotent — remove any previous observer first).
        if let existing = peerRegisteredObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        peerRegisteredObserver = NotificationCenter.default.addObserver(
            forName: .peerRegistered,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable values from the Notification before crossing into the Task.
            let peerName = note.userInfo?["name"] as? String
            Task { @MainActor [weak self] in
                self?.handlePeerRegisteredNamed(peerName)
            }
        }

        // Launch Claude in each tab after a short shell-ready delay (keeps the staggered
        // launch, removes the per-agent hardcoded 3.5 s prompt delay).
        for (index, tab) in createdTabs.enumerated() {
            let baseDelay = Double(index) * 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay + 0.8) { [weak self] in
                guard let self,
                      let leafID = tab.splitTree.focusedLeafID,
                      let controller = tab.registry.controller(for: leafID) else { return }
                controller.sendText("claude")
                self.onSendEnterKey?(controller)
            }
        }
    }

    // MARK: - Peer Registration Event Handler

    /// Called when any agent calls register_peer. Looks up the matching pending role prompt
    /// by peer name (which must equal the tab title / role name) and injects it.
    private func handlePeerRegisteredNamed(_ peerName: String?) {
        guard let peerName else { return }
        let key = peerName.lowercased()

        guard let entry = pendingRolePrompts.removeValue(forKey: key) else {
            // Either not a workflow agent, or already handled.
            return
        }

        let tab = entry.tab
        let prompt = entry.prompt

        // Find the surface controller and inject the prompt.
        guard let leafID = tab.splitTree.focusedLeafID,
              let controller = tab.registry.controller(for: leafID) else {
            // Tab surface not ready yet — fall back to a short delay.
            logger.warning("IPCWindowController: peerRegistered for '\(peerName)' but tab surface not ready; using 2s fallback")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let leafID = tab.splitTree.focusedLeafID,
                      let controller = tab.registry.controller(for: leafID) else { return }
                controller.sendText(prompt)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.onSendEnterKey?(controller)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.onSendEnterKey?(controller)
                    }
                }
            }
            return
        }

        logger.info("IPCWindowController: injecting role prompt for peer '\(peerName)'")
        controller.sendText(prompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.onSendEnterKey?(controller)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.onSendEnterKey?(controller)
            }
        }

        // If all pending prompts have been consumed, remove the observer.
        if pendingRolePrompts.isEmpty {
            if let observer = peerRegisteredObserver {
                NotificationCenter.default.removeObserver(observer)
                peerRegisteredObserver = nil
            }
        }
    }

    // MARK: - Review → Agent Dispatch

    func sendToAgent(_ payload: String) -> ReviewSendResult {
        guard let session = windowSession else { return .failed }

        let agentTabs = session.groups.flatMap(\.tabs).filter {
            guard case .terminal = $0.content else { return false }
            let title = $0.title
            return title.localizedCaseInsensitiveContains("claude") ||
                   title.localizedCaseInsensitiveContains("codex")
        }

        guard !agentTabs.isEmpty else {
            showAlert(
                title: "No AI Agent",
                message: "No terminal tabs running Claude Code or Codex found. Start an AI agent first."
            )
            return .failed
        }

        let targetTab: Tab
        if agentTabs.count == 1 {
            targetTab = agentTabs[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Select Claude Code Tab"
            alert.informativeText = "Choose which Claude Code instance to send the review to:"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            for (i, tab) in agentTabs.enumerated() {
                let groupName = session.groups.first { $0.tabs.contains { $0.id == tab.id } }?.name ?? ""
                let label = "\(tab.title) — \(groupName) (#\(i + 1))"
                popup.addItem(withTitle: label)
            }
            alert.accessoryView = popup

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return .cancelled }

            let selectedIndex = popup.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < agentTabs.count else { return .failed }
            targetTab = agentTabs[selectedIndex]
        }

        guard let focusedID = targetTab.splitTree.focusedLeafID,
              let controller = targetTab.registry.controller(for: focusedID) else {
            showAlert(title: "Send Failed", message: "Could not access terminal surface.")
            return .failed
        }

        controller.sendText(payload)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.onSendEnterKey?(controller)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.onSendEnterKey?(controller)
            }
        }

        onSwitchToTab?(targetTab.id)
        return .sent
    }

    // MARK: - Helpers

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func configStatusMessage(_ result: IPCConfigResult) -> String {
        func label(_ status: ConfigStatus, name: String) -> String {
            switch status {
            case .success:
                return "\(name): configured"
            case .skipped(let reason):
                return "\(name): \(reason) (skipped)"
            case .failed(let error):
                return "\(name): error - \(error.localizedDescription)"
            }
        }
        return [
            label(result.claudeCode, name: "Claude Code"),
            label(result.codex, name: "Codex")
        ].joined(separator: "\n")
    }
}
