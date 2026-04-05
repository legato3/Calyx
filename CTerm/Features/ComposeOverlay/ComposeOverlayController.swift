// ComposeOverlayController.swift
// CTerm
//
// Manages the compose overlay lifecycle: tracks which surface is targeted,
// handles show/hide state, dispatches text to the terminal, and coordinates
// Warp-style assistant interactions.

import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.cterm",
    category: "ComposeOverlayController"
)

private let shellPromptSuffixes: [String] = [
    "$ ", "% ", "❯ ", "➜ ", "> ", "λ ", "# ",
    // Trimmed variants for when viewport text doesn't capture the trailing space
    // (e.g. cursor is at the prompt position in SSH sessions).
    "$", "%", "❯", "➜", "#",
]

enum InlineAgentCompletionHeuristics {
    private static let interpretationKeywords: [String] = [
        "troubleshoot", "diagnose", "debug", "check for issues", "issue", "issues",
        "problem", "problems", "wrong", "health", "slow", "slowness",
        "performance", "failing", "failure", "why is", "why does", "what's wrong",
        "what is wrong", "investigate",
    ]

    @MainActor
    static func shouldShortCircuitFirstSuccess(
        intent: String,
        session: AgentSession,
        block: TerminalCommandBlock
    ) -> Bool {
        guard block.exitCode == 0 else { return false }
        guard let snippet = block.primarySnippet,
              !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        let commandCount = session.inlineSteps.filter { $0.kind == .command }.count
        guard commandCount == 1 else { return false }

        let scope = IntentRouter.inferScope(intent)
        let category = IntentRouter.classify(intent, scope: scope).category
        switch category {
        case .fixError, .runWorkflow, .delegateToPeer, .browserResearch:
            return false
        case .explain, .generateCommand, .executeCommand, .inspectRepo:
            break
        }

        if requiresInterpretation(intent: intent, scope: scope) {
            return false
        }

        let words = intent.split(whereSeparator: { $0.isWhitespace }).count
        return words <= 8
    }

    static func requiresInterpretation(intent: String, scope: GoalScope) -> Bool {
        let lower = intent.lowercased()
        if interpretationKeywords.contains(where: { lower.contains($0) }) {
            return true
        }

        if scope == .system {
            let systemTerms = [
                "my mac", "this mac", "my machine", "this machine", "cpu", "memory",
                "ram", "disk", "storage", "battery", "wifi", "network", "bluetooth",
            ]
            if systemTerms.contains(where: { lower.contains($0) }) &&
                (lower.contains("check") || lower.contains("inspect") || lower.contains("investigate")) {
                return true
            }
        }

        return false
    }
}

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
    // Now delegated to RiskScorer — this list is kept only as a fast-path hint.
    // The actual decision is made by RiskScorer.isAutoApprovable().
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
        assistantState.isForcedAgentMode = false
        onDismiss?()
    }

    /// Opens the compose overlay in forced-agent mode (triggered by the `#`
    /// NL-prefix in a terminal surface). Locks `mode` to the user's last-used
    /// agent backend and raises the `isForcedAgentMode` flag so the UI can
    /// render the "# triggered" indicator. The flag auto-clears on send or
    /// dismiss.
    func openForcedAgentMode(
        windowSession: WindowSession,
        focusedControllerID: UUID?,
        prefilledText: String? = nil
    ) {
        guard let activeTab = windowSession.activeGroup?.activeTab,
              case .terminal = activeTab.content else { return }

        targetSurfaceID = focusedControllerID

        let agentMode = assistantState.lastAgentMode.startsAgentSession
            ? assistantState.lastAgentMode
            : .claudeAgent
        assistantState.mode = agentMode
        assistantState.isModeLocked = true
        assistantState.isForcedAgentMode = true
        if let prefilledText {
            assistantState.draftText = prefilledText
        }

        windowSession.showComposeOverlay = true
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

        // Forced-agent-mode (# prefix) is a one-shot lock: once the user
        // sends, release it so later messages can be routed normally.
        assistantState.isForcedAgentMode = false

        // Slash-command dispatch: if the draft begins with `/` and resolves to
        // a known built-in command, always route to the agent regardless of
        // the current compose mode.
        if SlashParser.isSlashPrefix(trimmed),
           let invocation = SlashParser.parse(trimmed) {
            activeTab?.clearAttachedBlocks()
            return dispatchSlash(
                invocation,
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            )
        }

        // Smart routing: when the user hasn't locked a mode, detect their
        // intent from the draft text and route accordingly. Shell commands
        // still dispatch to shell; natural-language goals dispatch to the
        // user's last-used agent backend.
        let effective = assistantState.effectiveMode(for: trimmed)
        let routedFromShellDetection = (!assistantState.isModeLocked
            && assistantState.mode == .shell
            && effective.isAgentMode)

        switch effective {
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
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            )
        case .ollamaAgent:
            activeTab?.clearAttachedBlocks()
            if routedFromShellDetection { markAutoRouteHintSeen() }
            return startAgent(
                goal: trimmed,
                backend: .ollama,
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            )
        case .claudeAgent:
            activeTab?.clearAttachedBlocks()
            if routedFromShellDetection { markAutoRouteHintSeen() }
            return startAgent(
                goal: trimmed,
                backend: .claudeSubscription,
                activeTab: activeTab,
                focusedController: focusedController,
                sendEnterKey: sendEnterKey
            )
        }
    }

    private func markAutoRouteHintSeen() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: AppStorageKeys.hasSeenAgentAutoRouteHint) {
            assistantState.showAutoRouteHint = true
            defaults.set(true, forKey: AppStorageKeys.hasSeenAgentAutoRouteHint)
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
        agentTargetController = nil
        agentSendEnterKey = nil
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

        // Accept the finished block if it matches the tracked block ID, OR if no
        // specific block was tracked (lastCommandBlockID is nil). Also accept if the
        // tracked block ID is no longer present in the tab (already cleaned up), so
        // we don't get permanently stuck in .runningCommand.
        if let lastCommandBlockID = session.lastCommandBlockID,
           lastCommandBlockID != commandBlockID {
            // Only skip if the tracked block still exists and is still running.
            // If it's gone or finished, fall through so the loop can continue.
            if let trackedBlock = activeTab.commandBlock(id: lastCommandBlockID),
               trackedBlock.status == .running {
                return
            }
        }

        guard let block = activeTab.commandBlock(id: commandBlockID) else {
            // Block not found — still advance the loop so status doesn't get stuck.
            planNextAgentStep(for: activeTab)
            return
        }
        activeTab.recordOllamaAgentObservation(observationText(for: block))
        onStateChanged?()

        // Trivial-goal short-circuit: if this is the session's very first
        // command and it succeeded with output, skip the second Claude round-trip
        // (which is expensive for a simple "what is X" goal) and complete
        // directly using the command output as the summary.
        if let session = activeTab.ollamaAgentSession,
           shouldShortCircuitAfterFirstSuccess(session: session, block: block) {
            let summary = summaryText(forFirstSuccess: block)
            activeTab.completeOllamaAgent(summary: summary)
            agentTargetController = nil
            agentSendEnterKey = nil
            onStateChanged?()
            return
        }

        planNextAgentStep(for: activeTab)
    }

    /// True when the session has executed exactly one command that exited 0
    /// with non-empty output AND the user's goal is short enough that one
    /// command is almost certainly the entire answer. Used to avoid spending
    /// a second Claude CLI round-trip just to hear "done".
    private func shouldShortCircuitAfterFirstSuccess(
        session: AgentSession,
        block: TerminalCommandBlock
    ) -> Bool {
        InlineAgentCompletionHeuristics.shouldShortCircuitFirstSuccess(
            intent: session.intent,
            session: session,
            block: block
        )
    }

    private func summaryText(forFirstSuccess block: TerminalCommandBlock) -> String {
        let snippet = (block.primarySnippet ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = block.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty {
            return "Ran `\(command)` — see output above."
        }
        // Keep the summary compact; the full output is already visible in the
        // terminal block above the run panel.
        let lines = snippet.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count == 1 {
            return String(lines[0]).trimmingCharacters(in: .whitespaces)
        }
        return "Ran `\(command)`. Output:\n\(snippet)"
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

    private func generateSuggestion(
        from prompt: String,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        let entryID = assistantState.beginEntry(kind: .commandSuggestion, prompt: prompt)
        let pwd = activeTab?.pwd
        let terminalObservation = latestTerminalObservation(
            activeTab: activeTab,
            focusedController: focusedController
        )
        onStateChanged?()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await OllamaCommandService.streamCommand(
                    for: prompt,
                    pwd: pwd,
                    terminalObservation: terminalObservation
                ) { [weak self] partial in
                    self?.assistantState.updatePendingEntry(
                        id: entryID,
                        response: partial,
                        command: partial
                    )
                    self?.onStateChanged?()
                }
                self.assistantState.finishEntry(id: entryID, response: response, command: response)
                if self.assistantState.mode == .ollamaCommand {
                    self.applySuggestionBehavior(
                        entryID: entryID,
                        activeTab: activeTab,
                        focusedController: focusedController,
                        sendEnterKey: sendEnterKey
                    )
                }
                self.onStateChanged?()
            } catch {
                self.assistantState.failEntry(id: entryID, message: error.localizedDescription)
                self.onStateChanged?()
            }
        }
        return true
    }

    private func applySuggestionBehavior(
        entryID: UUID,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) {
        guard let entry = assistantState.entry(id: entryID),
              let command = entry.runnableCommand,
              shouldAutoLoadSuggestion(command)
        else { return }

        switch OllamaSuggestionBehavior.current() {
        case .suggestOnly:
            return
        case .autofill:
            _ = assistantState.loadDraft(from: entryID)
        case .autorunSafe:
            if isSafeAutoRunCommand(command, for: activeTab) {
                _ = dispatchShellCommand(
                    command,
                    entryID: entryID,
                    source: .assistant,
                    activeTab: activeTab,
                    focusedController: focusedController,
                    sendEnterKey: sendEnterKey
                )
                assistantState.clearLoadedSuggestionContext()
            } else {
                _ = assistantState.loadDraft(from: entryID)
            }
        }
    }

    private func shouldAutoLoadSuggestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.hasPrefix("NOTE:")
        else { return false }

        let lower = trimmed.lowercased()
        let structuredPrefixes = ["action:", "command:", "message:", "step:", "browse:"]
        guard !structuredPrefixes.contains(where: { lower.hasPrefix($0) }) else { return false }
        guard ConfidenceScorer.startsWithKnownCommand(trimmed) else { return false }
        guard !ConfidenceScorer.looksLikeNaturalLanguage(trimmed) else { return false }
        guard !ConfidenceScorer.isGenericSuggestion(trimmed) else { return false }
        return true
    }

    private func latestTerminalObservation(
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?
    ) -> String? {
        guard let activeTab else { return nil }
        var sections: [String] = []

        if let block = activeTab.latestCommandBlock {
            var lines: [String] = []
            lines.append("Latest command: \(block.titleText)")
            lines.append("Latest exit code: \(block.exitCode.map(String.init) ?? "?")")
            if let errorSnippet = block.errorSnippet,
               !errorSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Latest stderr snippet:\n\(errorSnippet)")
            }
            if let outputSnippet = block.outputSnippet,
               !outputSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Latest stdout snippet:\n\(outputSnippet)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if let shellError = activeTab.lastShellError?.snippet,
           !shellError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Latest shell error:\n\(shellError)")
        }

        let attachedBlocks = activeTab.attachedBlocks.prefix(3)
        if !attachedBlocks.isEmpty {
            let attached = attachedBlocks.map { block in
                var lines: [String] = []
                lines.append("Command: \(block.titleText)")
                lines.append("Exit: \(block.exitCode.map(String.init) ?? "?")")
                if let snippet = block.primarySnippet,
                   !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Snippet:\n\(snippet)")
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
            sections.append("Attached command blocks:\n\(attached)")
        }

        if let viewport = readViewportSnippet(activeTab: activeTab, focusedController: focusedController),
           !viewport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Current viewport snippet:\n\(viewport)")
        }

        let combined = sections.joined(separator: "\n\n")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : combined
    }

    private func startAgent(
        goal: String,
        backend: AgentPlanningBackend,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void,
        triggeredBy: String? = nil
    ) -> Bool {
        guard let activeTab else { return false }
        cancelAgentTask(for: activeTab.id)
        // Store for auto-dispatch of safe commands.
        agentTargetController = focusedController
        agentSendEnterKey = sendEnterKey
        let rawPrompt = AgentPromptContextBuilder.buildPrompt(goal: goal, activeTab: activeTab)
        activeTab.startOllamaAgent(goal: goal, rawPrompt: rawPrompt, backend: backend, triggeredBy: triggeredBy)
        assistantState.setDraftText("")
        onStateChanged?()
        planNextAgentStep(for: activeTab)
        return true
    }

    // MARK: - Slash Commands

    /// Dispatches a slash command invocation to the agent backend, bypassing
    /// the compose-mode selector. Always starts an agent session.
    func dispatchSlash(
        _ invocation: SlashCommandInvocation,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        let rendered = invocation.renderedPrompt
        // Pick the user's preferred agent backend from last-agent-mode; fall
        // back to Claude if it isn't an agent-capable mode.
        let mode = assistantState.lastAgentMode.startsAgentSession
            ? assistantState.lastAgentMode
            : .claudeAgent
        let backend: AgentPlanningBackend = (mode == .ollamaAgent) ? .ollama : .claudeSubscription
        return startAgent(
            goal: rendered,
            backend: backend,
            activeTab: activeTab,
            focusedController: focusedController,
            sendEnterKey: sendEnterKey,
            triggeredBy: "slash:/\(invocation.command.name)"
        )
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
        let scope = IntentRouter.inferScope(goal)
        let backend = session.backend.planningBackend ?? .ollama
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
                    backend: backend,
                    scope: scope,
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
                        self.agentTargetController = nil
                        self.agentSendEnterKey = nil
                        return
                    }
                    // Loop-guard: if the LLM is proposing a command that was just observed
                    // successfully, short-circuit to done rather than re-running it.
                    if self.isRepeatOfJustSucceeded(command: command, in: activeTab.ollamaAgentSession) {
                        activeTab.completeOllamaAgent(
                            summary: "Already ran `\(command.trimmingCharacters(in: .whitespacesAndNewlines))` — see output above."
                        )
                        self.agentTargetController = nil
                        self.agentSendEnterKey = nil
                        return
                    }
                    // Auto-run if the command is safe and we still have a controller reference.
                    if self.isSafeAutoRunCommand(command, for: activeTab),
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
                    self.agentTargetController = nil
                    self.agentSendEnterKey = nil
                case .browse:
                    // Browser actions are surfaced as observations for now;
                    // full browser-in-loop execution is wired through AgentPlanExecutor.
                    let browseMsg = decision.browseAction.map { "Browse: \($0.url)" } ?? decision.message
                    activeTab.recordOllamaAgentObservation(browseMsg)
                    self.planNextAgentStep(for: activeTab)
                }
            } catch is CancellationError {
                return
            } catch {
                guard activeTab.ollamaAgentSession?.id == sessionID else { return }
                activeTab.failOllamaAgent(error.localizedDescription)
                self.agentTargetController = nil
                self.agentSendEnterKey = nil
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
                    let finishedID = activeTab.finishCommandBlock(
                        id: blockID,
                        surfaceID: surfaceID,
                        fallbackCommand: block.command,
                        exitCode: exitCode,
                        durationNanoseconds: nil,
                        outputSnippet: snippet,
                        errorSnippet: errorSnippet
                    )
                    // Notify the agent loop so it doesn't stay stuck in .runningCommand
                    // when ghostty shell integration didn't fire (e.g. remote SSH sessions).
                    self.handleCommandFinished(
                        for: activeTab,
                        commandBlockID: finishedID
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

            // Polling exhausted without detecting a prompt — unstick the agent loop.
            // This handles cases where shell integration is absent (SSH, non-standard
            // shells) and the prompt pattern isn't recognized.
            guard let activeTab,
                  let block = activeTab.commandBlock(id: blockID),
                  block.status == .running
            else { return }

            let snippet = self.readViewportSnippet(
                activeTab: activeTab,
                preferredSurfaceID: surfaceID,
                focusedController: focusedController
            )
            let finishedID = activeTab.finishCommandBlock(
                id: blockID,
                surfaceID: surfaceID,
                fallbackCommand: block.command,
                exitCode: nil,
                durationNanoseconds: nil,
                outputSnippet: snippet,
                errorSnippet: nil
            )
            logger.warning("Command block \(blockID) timed out waiting for prompt — advancing agent loop")
            self.handleCommandFinished(
                for: activeTab,
                commandBlockID: finishedID
            )
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
    /// Routes through ApprovalGate so hard-stops and existing grants are respected.
    private func isSafeAutoRunCommand(_ command: String, for activeTab: Tab?) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let pwd = activeTab?.pwd ?? TerminalControlBridge.shared.delegate?.activeTabPwd
        let gitBranch = TerminalControlBridge.shared.delegate?.activeTabGitBranch
        let session = activeTab?.ollamaAgentSession

        let gate = ApprovalGate.evaluate(
            action: .shellCommand(command),
            session: session,
            pwd: pwd,
            gitBranch: gitBranch
        )
        switch gate {
        case .autoApprove: return true
        default:           return false
        }
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

    private func agentPriorContext(for session: AgentSession) -> String {
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

    /// Returns true when the LLM's proposed command matches the most recent
    /// command/observation pair in the session and that observation reported
    /// a successful exit. Used to break trivial replanning loops where the
    /// model keeps re-proposing a command it just ran.
    private func isRepeatOfJustSucceeded(command: String, in session: AgentSession?) -> Bool {
        guard let session else { return false }
        let proposed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return false }

        // Walk steps in reverse: expect the last observation to correspond to
        // the most-recently executed command. If that command matches, and the
        // observation header reports exit 0, treat it as a repeat.
        var lastObservation: InlineAgentStep?
        var lastCommand: InlineAgentStep?
        for step in session.inlineSteps.reversed() {
            if lastObservation == nil, step.kind == .observation {
                lastObservation = step
                continue
            }
            if lastObservation != nil, step.kind == .command {
                lastCommand = step
                break
            }
        }
        guard let observation = lastObservation,
              let ranCommand = lastCommand?.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ranCommand.isEmpty
        else { return false }

        guard proposed == ranCommand else { return false }
        // Observation text starts with "Command finished with exit N.".
        return observation.text.contains("exit 0.")
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
    func launchClaudeAgentWorkflow(goal: String, activeTab: Tab? = nil) -> Bool {
        guard !goal.isEmpty else { return false }
        let workflow = AgentWorkflow.templates.first(where: { $0.name == "Solo" })
            ?? AgentWorkflow.templates[0]
        var userInfo: [String: Any] = [
            "roleNames": workflow.roles.map(\.name),
            "autoStart": true,
            "sessionName": "",
            "initialTask": goal,
        ]
        if let workingDirectory = activeTab?.pwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            userInfo["workingDirectory"] = workingDirectory
            userInfo["skipDirectoryPrompt"] = true
        }
        AgentRuntimeConfiguration.default.notificationUserInfo.forEach { userInfo[$0.key] = $0.value }
        NotificationCenter.default.post(
            name: .ctermIPCLaunchWorkflow,
            object: nil,
            userInfo: userInfo
        )
        assistantState.draftText = ""
        return true
    }
}
