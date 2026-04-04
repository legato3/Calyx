// ComposeOverlayController.swift
// Calyx
//
// Manages the compose overlay lifecycle: tracks which surface is targeted,
// handles show/hide state, dispatches text to the terminal, and coordinates
// Warp-style assistant interactions.

import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "ComposeOverlayController"
)

private let shellPromptSuffixes: [String] = [
    "$ ", "% ", "❯ ", "➜ ", "> ", "λ ", "# "
]

@MainActor
final class ComposeOverlayController {
    private static let maxAgentIterations = 8

    let assistantState = ComposeAssistantState()
    var onStateChanged: (() -> Void)?

    /// The surface ID that will receive composed text.
    /// Set when the overlay opens; cleared when it closes.
    private(set) var targetSurfaceID: UUID?

    /// When `true`, the composed text is sent to every pane in the active tab's split tree
    /// instead of only the targeted surface.
    var broadcastEnabled: Bool = false
    private var agentTasks: [UUID: Task<Void, Never>] = [:]

    /// Retained for the duration of an agent run so safe commands can be auto-dispatched.
    private weak var agentTargetController: GhosttySurfaceController?
    private var agentSendEnterKey: ((GhosttySurfaceController) -> Void)?

    // Shell commands that are safe to run without user approval in agent mode.
    // Must be read-only or purely observational — no writes, no deletes, no network side-effects.
    private static let autoRunPrefixes: Set<String> = [
        "ls", "ll", "cat", "pwd", "echo", "which", "type",
        "head", "tail", "wc", "diff", "file",
        "git log", "git status", "git branch", "git diff",
        "git show", "git stash list", "git remote",
        "find", "rg", "grep", "awk", "sed", "sort", "uniq", "cut",
        "env", "printenv", "date", "uname", "whoami", "df", "du", "ps",
        "swift --version", "swiftc --version",
        "node --version", "npm --version", "npx --version",
        "cargo --version", "rustc --version",
        "python --version", "python3 --version",
        "go version", "ruby --version",
        "xcodebuild -version",
    ]

    // MARK: - Overlay Lifecycle

    func toggle(
        windowSession: WindowSession,
        focusedControllerID: UUID?
    ) {
        if windowSession.showComposeOverlay {
            dismiss(windowSession: windowSession, onDismiss: nil)
        } else {
            guard let activeTab = windowSession.activeGroup?.activeTab,
                  case .terminal = activeTab.content else { return }
            targetSurfaceID = focusedControllerID
            windowSession.showComposeOverlay = true
        }
    }

    func retargetIfNeeded(windowSession: WindowSession, focusedControllerID: UUID?) {
        guard windowSession.showComposeOverlay else { return }
        targetSurfaceID = focusedControllerID
    }

    func dismiss(windowSession: WindowSession, onDismiss: (() -> Void)?) {
        guard windowSession.showComposeOverlay else { return }
        windowSession.showComposeOverlay = false
        targetSurfaceID = nil
        onDismiss?()
    }

    // MARK: - Text Dispatch

    func send(
        _ text: String,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        let raw = text
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        switch assistantState.mode {
        case .shell:
            return dispatchShellCommand(
                raw,
                entryID: nil,
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            ) != nil
        case .ollamaCommand:
            return generateSuggestion(
                from: trimmed,
                activeTab: activeTab
            )
        case .ollamaAgent:
            return startAgent(
                goal: trimmed,
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            )
        case .claudeAgent:
            // Enrich prompt with any attached blocks
            let enriched = enrichWithAttachedBlocks(trimmed, activeTab: activeTab)
            activeTab?.clearAttachedBlocks()
            return launchClaudeAgentWorkflow(goal: enriched)
        }
    }

    func applyAssistantEntry(
        id: UUID,
        run: Bool,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        guard let entry = assistantState.entry(id: id),
              let command = entry.runnableCommand
        else { return false }

        if run {
            return dispatchShellCommand(
                command,
                entryID: id,
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            ) != nil
        }

        return assistantState.loadDraft(from: id)
    }

    func approveAgent(
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        guard let activeTab,
              let session = activeTab.ollamaAgentSession,
              session.canApprove,
              let command = session.pendingCommand
        else { return false }

        guard let commandBlockID = dispatchShellCommand(
            command,
            entryID: nil,
            source: .assistant,
            activeTab: activeTab,
            focusedController: focusedController,
            sendEnterKey: sendEnterKey
        ) else {
            return false
        }

        activeTab.markOllamaAgentRunning(blockID: commandBlockID)
        onStateChanged?()
        return true
    }

    func stopAgent(activeTab: Tab?) {
        guard let activeTab else { return }
        cancelAgentTask(for: activeTab.id)
        activeTab.stopOllamaAgent()
        onStateChanged?()
    }

    func handleCommandFinished(
        for activeTab: Tab?,
        commandBlockID: UUID
    ) {
        guard let activeTab,
              let session = activeTab.ollamaAgentSession,
              session.status == .runningCommand
        else { return }

        if let lastCommandBlockID = session.lastCommandBlockID,
           lastCommandBlockID != commandBlockID {
            return
        }

        guard let block = activeTab.commandBlock(id: commandBlockID) else { return }
        activeTab.recordOllamaAgentObservation(observationText(for: block))
        onStateChanged?()

        planNextAgentStep(for: activeTab)
    }

    func explainEntry(
        id: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) {
        guard let sourceEntry = assistantState.entry(id: id) else { return }
        guard let output = resolveContextSnippet(for: sourceEntry, activeTab: activeTab, focusedController: focusedController) else {
            let explainID = assistantState.beginEntry(kind: .explanation, prompt: sourceEntry.prompt)
            assistantState.failEntry(id: explainID, message: "No recent terminal output was available to explain.")
            return
        }

        let explainID = assistantState.beginEntry(
            kind: .explanation,
            prompt: sourceEntry.runnableCommand ?? sourceEntry.prompt,
            contextSnippet: output
        )
        let pwd = activeTab?.pwd
        let command = sourceEntry.runnableCommand

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await OllamaCommandService.streamExplainCommandOutput(
                    command: command,
                    output: output,
                    pwd: pwd
                ) { [weak self] partial in
                    self?.assistantState.updatePendingEntry(
                        id: explainID,
                        response: partial,
                        contextSnippet: output
                    )
                }
                self.assistantState.finishEntry(id: explainID, response: response, contextSnippet: output)
            } catch {
                self.assistantState.failEntry(id: explainID, message: error.localizedDescription, contextSnippet: output)
            }
        }
    }

    func explainCommandBlock(
        id: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) {
        guard let activeTab,
              let block = activeTab.commandBlock(id: id)
        else { return }
        let output = resolveBlockContextSnippet(block: block, activeTab: activeTab, focusedController: focusedController)
        guard let output else {
            let explainID = assistantState.beginEntry(kind: .explanation, prompt: block.titleText)
            assistantState.failEntry(id: explainID, message: "No recent terminal output was available to explain.")
            return
        }

        let explainID = assistantState.beginEntry(
            kind: .explanation,
            prompt: block.titleText,
            contextSnippet: output
        )
        let pwd = activeTab.pwd

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await OllamaCommandService.streamExplainCommandOutput(
                    command: block.command,
                    output: output,
                    pwd: pwd
                ) { [weak self] partial in
                    self?.assistantState.updatePendingEntry(
                        id: explainID,
                        response: partial,
                        contextSnippet: output
                    )
                }
                self.assistantState.finishEntry(id: explainID, response: response, contextSnippet: output)
            } catch {
                self.assistantState.failEntry(id: explainID, message: error.localizedDescription, contextSnippet: output)
            }
        }
    }

    func fixEntry(
        id: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) {
        guard let sourceEntry = assistantState.entry(id: id) else { return }
        guard let output = resolveContextSnippet(for: sourceEntry, activeTab: activeTab, focusedController: focusedController) else {
            let fixID = assistantState.beginEntry(kind: .fixSuggestion, prompt: sourceEntry.prompt)
            assistantState.failEntry(id: fixID, message: "No recent terminal output was available to fix.")
            return
        }

        let fixID = assistantState.beginEntry(
            kind: .fixSuggestion,
            prompt: sourceEntry.runnableCommand ?? sourceEntry.prompt,
            contextSnippet: output
        )
        let pwd = activeTab?.pwd
        let command = sourceEntry.runnableCommand

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await OllamaCommandService.streamSuggestFix(
                    command: command,
                    output: output,
                    pwd: pwd
                ) { [weak self] partial in
                    self?.assistantState.updatePendingEntry(
                        id: fixID,
                        response: partial,
                        command: partial,
                        contextSnippet: output
                    )
                }
                self.assistantState.finishEntry(id: fixID, response: response, command: response, contextSnippet: output)
            } catch {
                self.assistantState.failEntry(id: fixID, message: error.localizedDescription, contextSnippet: output)
            }
        }
    }

    func fixCommandBlock(
        id: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) {
        guard let activeTab,
              let block = activeTab.commandBlock(id: id)
        else { return }
        let output = resolveBlockContextSnippet(block: block, activeTab: activeTab, focusedController: focusedController)
        guard let output else {
            let fixID = assistantState.beginEntry(kind: .fixSuggestion, prompt: block.titleText)
            assistantState.failEntry(id: fixID, message: "No recent terminal output was available to fix.")
            return
        }

        let fixID = assistantState.beginEntry(
            kind: .fixSuggestion,
            prompt: block.titleText,
            contextSnippet: output
        )
        let pwd = activeTab.pwd

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await OllamaCommandService.streamSuggestFix(
                    command: block.command,
                    output: output,
                    pwd: pwd
                ) { [weak self] partial in
                    self?.assistantState.updatePendingEntry(
                        id: fixID,
                        response: partial,
                        command: partial,
                        contextSnippet: output
                    )
                }
                self.assistantState.finishEntry(id: fixID, response: response, command: response, contextSnippet: output)
            } catch {
                self.assistantState.failEntry(id: fixID, message: error.localizedDescription, contextSnippet: output)
            }
        }
    }

    // MARK: - Internals

    private func generateSuggestion(from prompt: String, activeTab: Tab?) -> Bool {
        let entryID = assistantState.beginEntry(kind: .commandSuggestion, prompt: prompt)
        let pwd = activeTab?.pwd

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await OllamaCommandService.streamCommand(for: prompt, pwd: pwd) { [weak self] partial in
                    self?.assistantState.updatePendingEntry(
                        id: entryID,
                        response: partial,
                        command: partial
                    )
                }
                self.assistantState.finishEntry(id: entryID, response: response, command: response)
            } catch {
                self.assistantState.failEntry(id: entryID, message: error.localizedDescription)
            }
        }
        return true
    }

    private func startAgent(
        goal: String,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        guard let activeTab else { return false }
        cancelAgentTask(for: activeTab.id)
        // Store for auto-dispatch of safe commands.
        agentTargetController = focusedController
        agentSendEnterKey = sendEnterKey
        activeTab.startOllamaAgent(goal: goal)
        assistantState.setDraftText("")
        onStateChanged?()
        planNextAgentStep(for: activeTab)
        return true
    }

    private func planNextAgentStep(for activeTab: Tab) {
        guard let session = activeTab.ollamaAgentSession,
              !session.status.isTerminal
        else { return }

        if session.iteration >= Self.maxAgentIterations {
            activeTab.completeOllamaAgent(
                summary: "Reached the current step limit. Review the latest output and continue manually if needed."
            )
            onStateChanged?()
            return
        }

        let sessionID = session.id
        let tabID = activeTab.id
        let goal = session.goal
        let pwd = activeTab.pwd
        let recentCommandContext = agentRecentCommandContext(for: activeTab)
        let priorAgentContext = agentPriorContext(for: session)

        cancelAgentTask(for: tabID)
        activeTab.updateOllamaAgentPlanPreview("Planning the next terminal step…")
        onStateChanged?()

        agentTasks[tabID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.agentTasks.removeValue(forKey: tabID)
                self.onStateChanged?()
            }

            do {
                let decision = try await OllamaCommandService.streamAgentDecision(
                    goal: goal,
                    pwd: pwd,
                    recentCommandContext: recentCommandContext,
                    priorAgentContext: priorAgentContext
                ) { [weak self] partial in
                    guard let self,
                          activeTab.ollamaAgentSession?.id == sessionID
                    else { return }
                    activeTab.updateOllamaAgentPlanPreview(partial)
                    self.onStateChanged?()
                }

                guard activeTab.ollamaAgentSession?.id == sessionID else { return }
                switch decision.action {
                case .run:
                    guard let command = decision.command else {
                        activeTab.failOllamaAgent("Ollama returned a run action without a command.")
                        return
                    }
                    // Auto-run if the command is safe and we still have a controller reference.
                    if self.isSafeAutoRunCommand(command),
                       let controller = self.agentTargetController,
                       let sendEnterKey = self.agentSendEnterKey {
                        activeTab.setOllamaAgentAwaitingApproval(command: command, message: "↪ Auto-running: \(decision.message)")
                        let blockID = self.dispatchShellCommand(
                            command,
                            entryID: nil,
                            source: .assistant,
                            activeTab: activeTab,
                            focusedController: controller,
                            sendEnterKey: sendEnterKey
                        )
                        activeTab.markOllamaAgentRunning(blockID: blockID)
                    } else {
                        activeTab.setOllamaAgentAwaitingApproval(command: command, message: decision.message)
                    }
                case .done:
                    activeTab.completeOllamaAgent(summary: decision.message)
                }
            } catch is CancellationError {
                return
            } catch {
                guard activeTab.ollamaAgentSession?.id == sessionID else { return }
                activeTab.failOllamaAgent(error.localizedDescription)
            }
        }
    }

    @discardableResult
    private func dispatchShellCommand(
        _ text: String,
        entryID: UUID?,
        source: TerminalCommandSource? = nil,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> UUID? {
        guard let controller = resolveTargetController(activeTab: activeTab, focusedController: focusedController) else {
            return nil
        }

        let commandText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandBlockID = activeTab?.beginCommandBlock(
            command: commandText,
            source: source ?? (entryID == nil ? .shell : .assistant),
            surfaceID: controller.id
        )
        let effectiveEntryID: UUID
        if let entryID {
            effectiveEntryID = entryID
            assistantState.markRan(id: entryID)
        } else {
            effectiveEntryID = assistantState.addEntry(
                kind: .shellDispatch,
                prompt: commandText,
                command: commandText,
                status: .ran
            )
        }

        if let tab = activeTab, tab.isAIAgentTab {
            AgentTextRouter.submit(text, to: controller, inputStyle: tab.preferredAgentInputStyle, sendEnterKey: sendEnterKey)
        } else {
            controller.sendText(text)
            sendEnterKey(controller)
        }

        if broadcastEnabled, let tab = activeTab {
            for leafID in tab.splitTree.allLeafIDs() {
                guard let otherController = tab.registry.controller(for: leafID),
                      otherController.id != controller.id else { continue }
                otherController.sendText(text)
                sendEnterKey(otherController)
            }
        }

        assistantState.setDraftText("")
        scheduleContextRefresh(for: effectiveEntryID, activeTab: activeTab, focusedController: focusedController)
        if let commandBlockID {
            scheduleCommandBlockRefresh(
                blockID: commandBlockID,
                surfaceID: controller.id,
                activeTab: activeTab,
                focusedController: focusedController
            )
        }
        logger.debug("Sent compose text (\(text.count) chars) to surface \(String(describing: self.targetSurfaceID))\(self.broadcastEnabled ? " [broadcast]" : "")")
        return commandBlockID
    }

    private func scheduleContextRefresh(
        for entryID: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            guard let entry = self.assistantState.entry(id: entryID) else { return }
            if let snippet = self.resolveContextSnippet(for: entry, activeTab: activeTab, focusedController: focusedController) {
                self.assistantState.attachContext(snippet, to: entryID)
            }
        }
    }

    private func resolveContextSnippet(
        for entry: ComposeAssistantEntry,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) -> String? {
        if let shellError = activeTab?.lastShellError?.snippet,
           !shellError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shellError
        }

        if let contextSnippet = entry.contextSnippet,
           !contextSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contextSnippet
        }

        return readViewportSnippet(activeTab: activeTab, focusedController: focusedController)
    }

    private func resolveBlockContextSnippet(
        block: TerminalCommandBlock,
        activeTab: Tab,
        focusedController: GhosttySurfaceController?
    ) -> String? {
        if let errorSnippet = block.errorSnippet,
           !errorSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return errorSnippet
        }

        if let outputSnippet = block.outputSnippet,
           !outputSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputSnippet
        }

        if let shellError = activeTab.lastShellError?.snippet,
           !shellError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shellError
        }

        return readViewportSnippet(
            activeTab: activeTab,
            preferredSurfaceID: block.surfaceID,
            focusedController: focusedController
        )
    }

    private func readViewportSnippet(
        activeTab: Tab?,
        preferredSurfaceID: UUID? = nil,
        focusedController: GhosttySurfaceController?
    ) -> String? {
        let controller: GhosttySurfaceController?
        if let preferredSurfaceID,
           let activeTab,
           let preferredController = activeTab.registry.controller(for: preferredSurfaceID) {
            controller = preferredController
        } else {
            controller = resolveTargetController(activeTab: activeTab, focusedController: focusedController)
        }

        guard let controller,
              let surface = controller.surface,
              let text = GhosttyFFI.surfaceReadViewportText(surface)
        else { return nil }

        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let snippet = lines.suffix(24).joined(separator: "\n")
        return snippet.isEmpty ? nil : snippet
    }

    private func scheduleCommandBlockRefresh(
        blockID: UUID,
        surfaceID: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let activeTab,
                      let block = activeTab.commandBlock(id: blockID),
                      block.status == .running
                else { return }

                let snippet = self.readViewportSnippet(
                    activeTab: activeTab,
                    preferredSurfaceID: surfaceID,
                    focusedController: focusedController
                )
                guard let snippet else { continue }
                if self.isPromptReady(snippet) {
                    let exitCode = activeTab.lastShellError == nil ? 0 : 1
                    let errorSnippet = activeTab.lastShellError?.snippet
                    _ = activeTab.finishCommandBlock(
                        id: blockID,
                        surfaceID: surfaceID,
                        fallbackCommand: block.command,
                        exitCode: exitCode,
                        durationNanoseconds: nil,
                        outputSnippet: snippet,
                        errorSnippet: errorSnippet
                    )
                    // Auto-suggest a fix when a user shell command fails with output.
                    if exitCode != 0,
                       block.source == .shell,
                       errorSnippet != nil || !snippet.isEmpty {
                        self.fixCommandBlock(
                            id: blockID,
                            activeTab: activeTab,
                            focusedController: focusedController
                        )
                    }
                    return
                }
            }
        }
    }

    private func isPromptReady(_ text: String) -> Bool {
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return false }
        return shellPromptSuffixes.contains { lastLine.hasSuffix($0) || lastLine.contains($0) }
    }

    private func resolveTargetController(
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) -> GhosttySurfaceController? {
        if let targetID = targetSurfaceID,
           let tab = activeTab,
           let controller = tab.registry.controller(for: targetID) {
            return controller
        }

        if let focusedController {
            return focusedController
        }

        guard let tab = activeTab else { return nil }
        if let focusedLeaf = tab.splitTree.focusedLeafID,
           let controller = tab.registry.controller(for: focusedLeaf) {
            return controller
        }
        return tab.splitTree.allLeafIDs().compactMap { tab.registry.controller(for: $0) }.first
    }

    private func cancelAgentTask(for tabID: UUID) {
        agentTasks.removeValue(forKey: tabID)?.cancel()
    }

    /// Returns `true` if the command is safe to auto-run without user approval.
    /// Only pure read/inspect commands qualify — anything that writes, deletes, or
    /// has network side-effects must still go through the approval flow.
    /// Also respects AgentPermissionsStore autonomy levels.
    private func isSafeAutoRunCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }

        let permissions = AgentPermissionsStore.shared

        // Check permission profile — if runCommands is alwaysAllow, skip safe-list check
        if permissions.level(for: .runCommands) == .alwaysAllow { return true }
        // If runCommands is never or alwaysAsk, always require approval
        if permissions.isBlocked(.runCommands) { return false }
        if permissions.level(for: .runCommands) == .alwaysAsk { return false }

        // agentDecides or default: use the safe-command list
        // Never auto-run if it contains destructive patterns.
        let destructive = ["rm ", "rmdir", "sudo", "kill ", "pkill", "chmod", "chown",
                           "git commit", "git push", "git pull", "git merge", "git rebase",
                           "git reset", "git checkout ", "git switch", "git stash pop",
                           "npm install", "npm run", "cargo build", "cargo run",
                           "xcodebuild build", "make ", "brew install", "brew upgrade"]
        if destructive.contains(where: { trimmed.contains($0) }) { return false }
        // Block redirects and pipes to mutating commands.
        if trimmed.contains(" > ") || trimmed.contains(" >> ") { return false }

        // Check git operations permission
        if trimmed.hasPrefix("git ") && permissions.level(for: .gitOperations) == .alwaysAsk { return false }

        // Check network permission
        let networkPrefixes = ["curl", "wget", "npm", "yarn", "pip", "pip3", "brew"]
        if networkPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            if permissions.level(for: .networkAccess) != .alwaysAllow { return false }
        }

        let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if Self.autoRunPrefixes.contains(firstToken) { return true }
        let firstTwo = trimmed.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        if Self.autoRunPrefixes.contains(firstTwo) { return true }
        return false
    }

    private func agentRecentCommandContext(for activeTab: Tab) -> String {
        activeTab.commandBlocks
            .prefix(6)
            .reversed()
            .map { block in
                let snippet = block.primarySnippet?.replacingOccurrences(of: "\n", with: " | ") ?? "(no output)"
                let exitText = block.exitCode.map(String.init) ?? "?"
                return "[\(block.status.label)] exit=\(exitText) command=\(block.titleText)\n\(snippet)"
            }
            .joined(separator: "\n\n")
    }

    private func agentPriorContext(for session: OllamaAgentSession) -> String {
        session.steps
            .prefix(10)
            .reversed()
            .map { step in
                if let command = step.command, !command.isEmpty {
                    return "\(step.kind.title): \(step.text)\nCommand: \(command)"
                }
                return "\(step.kind.title): \(step.text)"
            }
            .joined(separator: "\n\n")
    }

    private func observationText(for block: TerminalCommandBlock) -> String {
        let command = block.titleText
        let exitText = block.exitCode.map(String.init) ?? "?"
        let snippet = block.primarySnippet ?? "No output captured."
        return """
        Command finished with exit \(exitText).
        Command: \(command)
        Output:
        \(snippet)
        """
    }
}

// MARK: - Claude Agent Workflow (extension)

extension ComposeOverlayController {
    /// Launches a Solo Claude Code agent workflow with the given goal as the initial task.
    func launchClaudeAgentWorkflow(goal: String) -> Bool {
        guard !goal.isEmpty else { return false }
        let workflow = AgentWorkflow.templates.first(where: { $0.name == "Solo" })
            ?? AgentWorkflow.templates[0]
        var userInfo: [String: Any] = [
            "roleNames": workflow.roles.map(\.name),
            "autoStart": true,
            "sessionName": "",
            "initialTask": goal,
        ]
        AgentRuntimeConfiguration.default.notificationUserInfo.forEach { userInfo[$0.key] = $0.value }
        NotificationCenter.default.post(
            name: .calyxIPCLaunchWorkflow,
            object: nil,
            userInfo: userInfo
        )
        assistantState.draftText = ""
        return true
    }

    /// Enriches a prompt with context from any blocks attached to the active tab.
    func enrichWithAttachedBlocks(_ prompt: String, activeTab: Tab?) -> String {
        guard let tab = activeTab, !tab.attachedBlockIDs.isEmpty else { return prompt }
        let blocks = tab.attachedBlocks
        guard !blocks.isEmpty else { return prompt }
        let context = blocks.map { block -> String in
            let status = block.status == .failed ? "failed (exit \(block.exitCode ?? -1))" : "succeeded"
            let snippet = block.primarySnippet ?? "(no output)"
            return "Command: \(block.titleText) [\(status)]\nOutput:\n\(snippet)"
        }.joined(separator: "\n\n---\n\n")
        return "\(prompt)\n\n<terminal_context>\n\(context)\n</terminal_context>"
    }
}
