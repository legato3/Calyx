// AgentPromptContextBuilder.swift
// CTerm
//
// Builds the richer Warp-style context envelope used when launching
// or continuing agent sessions from the command bar.

import Foundation

@MainActor
enum AgentPromptContextBuilder {
    private static let maxCommandSnippetLength = 1_200
    /// Budget for the live terminal viewport block (~800 tokens @ ~4 chars/token).
    private static let maxViewportLength = 3_200

    static func buildPrompt(goal: String, activeTab: Tab?, scope: GoalScope? = nil) -> String {
        // Resolve any `@block:<shortID>` tokens the user typed directly and
        // strip them from the visible prompt. Attached blocks are the union
        // of explicitly-attached IDs and token-matched IDs.
        let tokenShortIDs = BlockMentionToken.extractShortIDs(from: goal)
        let strippedGoal = tokenShortIDs.isEmpty
            ? goal.trimmingCharacters(in: .whitespacesAndNewlines)
            : BlockMentionToken.stripTokens(from: goal)
        let trimmedGoal = strippedGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return "" }
        let resolvedScope = scope ?? IntentRouter.inferScope(trimmedGoal)

        let tokenBlockIDs: Set<UUID> = {
            guard let activeTab, !tokenShortIDs.isEmpty else { return [] }
            let matches = tokenShortIDs.compactMap { short -> UUID? in
                activeTab.commandBlocks.first(where: {
                    $0.id.uuidString.lowercased().hasPrefix(short)
                })?.id
            }
            return Set(matches)
        }()

        let sections = contextSections(for: activeTab, scope: resolvedScope, extraBlockIDs: tokenBlockIDs)
        guard !sections.isEmpty else { return trimmedGoal }

        return """
        \(trimmedGoal)

        <cterm_agent_context>
        \(sections.joined(separator: "\n\n"))
        </cterm_agent_context>
        """
    }

    private static func contextSections(
        for activeTab: Tab?,
        scope: GoalScope,
        extraBlockIDs: Set<UUID> = []
    ) -> [String] {
        guard let activeTab else { return [] }

        var sections: [String] = []

        if scope.includesProjectContext,
           let pwd = activeTab.pwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pwd.isEmpty {
            sections.append(ProjectContextProvider.formattedBlock(for: pwd))

            // Cross-session continuity: inject last handoff summary if available
            if let handoff = lastHandoffSection(pwd: pwd) {
                sections.append(handoff)
            }
        }

        // CTerm environment: pane identity and capabilities
        if let envSection = ctermEnvironmentSection(for: activeTab) {
            sections.append(envSection)
        }

        if let shellError = shellErrorSection(for: activeTab) {
            sections.append(shellError)
        }

        // Live terminal viewport — what the user can actually see right now.
        // This is the single biggest lever for "smart" agent behavior: the
        // model gets to read the same error/output the user is looking at.
        if let viewport = terminalViewportSection(for: activeTab) {
            sections.append(viewport)
        }

        let unionIDs = activeTab.attachedBlockIDs.union(extraBlockIDs)
        if let attachedBlocks = attachedBlocksSection(for: activeTab, blockIDs: unionIDs) {
            sections.append(attachedBlocks)
        } else if scope.includesWorkspaceContext,
                  let recentCommands = recentCommandSection(for: activeTab) {
            sections.append(recentCommands)
        }

        return sections
    }

    private static func ctermEnvironmentSection(for tab: Tab) -> String? {
        let server = CTermMCPServer.shared
        let browser = BrowserServer.shared
        let ipcState = IPCAgentState.shared

        var lines: [String] = ["<cterm_environment>"]
        lines.append("tab_id: \(tab.id.uuidString)")
        lines.append("tab_title: \(tab.title)")

        if let focusedID = tab.splitTree.focusedLeafID {
            lines.append("pane_id: \(focusedID.uuidString)")
        }

        let paneCount = tab.splitTree.allLeafIDs().count
        if paneCount > 1 {
            lines.append("split_panes: \(paneCount) (use get_workspace_state to see layout)")
        }

        if ipcState.activePeerCount > 0 {
            lines.append("active_peers: \(ipcState.activePeerCount) (MCP IPC available for coordination)")
        }

        var caps: [String] = []
        if server.isRunning { caps.append("mcp_ipc:port=\(server.port)") }
        if browser.isRunning { caps.append("browser_automation:port=\(browser.port)") }
        if !caps.isEmpty {
            lines.append("capabilities: \(caps.joined(separator: ", "))")
        }

        lines.append("</cterm_environment>")
        return lines.joined(separator: "\n")
    }

    private static func lastHandoffSection(pwd: String) -> String? {
        let projectKey = AgentMemoryStore.key(for: pwd)
        guard let handoff = AgentMemoryStore.shared.lastHandoff(projectKey: projectKey) else {
            return nil
        }
        // Only include if the handoff is recent (< 24 hours)
        guard Date().timeIntervalSince(handoff.updatedAt) < 86400 else { return nil }

        return """
        <previous_session_handoff>
        \(handoff.value)
        </previous_session_handoff>
        """
    }

    private static func terminalViewportSection(for tab: Tab) -> String? {
        guard let raw = TerminalControlBridge.shared.delegate?.readViewportText(
            tabID: tab.id,
            paneID: nil
        ) else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Keep the tail (most recent lines) — that's what the user is looking at.
        let body: String
        if trimmed.count > maxViewportLength {
            let tail = String(trimmed.suffix(maxViewportLength))
            body = "[...truncated earlier output]\n" + tail
        } else {
            body = trimmed
        }

        return """
        <current_terminal_viewport>
        \(body)
        </current_terminal_viewport>
        """
    }

    private static func shellErrorSection(for tab: Tab) -> String? {
        guard let shellError = tab.lastShellError else { return nil }
        let snippet = shellError.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return nil }

        var lines = ["<latest_shell_error>"]
        lines.append("Tab: \(shellError.tabTitle)")
        lines.append("Output:")
        lines.append(snippet)
        lines.append("</latest_shell_error>")
        return lines.joined(separator: "\n")
    }

    private static func attachedBlocksSection(for tab: Tab, blockIDs: Set<UUID>) -> String? {
        let blocks = tab.commandBlocks.filter { blockIDs.contains($0.id) }
        guard !blocks.isEmpty else { return nil }

        let body = blocks
            .map(commandBlockSummary(_:))
            .joined(separator: "\n\n---\n\n")

        return """
        <attached_terminal_blocks>
        \(body)
        </attached_terminal_blocks>
        """
    }

    private static func recentCommandSection(for tab: Tab) -> String? {
        let recent = Array(tab.commandBlocks.prefix(3))
        guard !recent.isEmpty else { return nil }

        let body = recent
            .map(commandBlockSummary(_:))
            .joined(separator: "\n\n")

        return """
        <recent_terminal_activity>
        \(body)
        </recent_terminal_activity>
        """
    }

    private static func commandBlockSummary(_ block: TerminalCommandBlock) -> String {
        var lines: [String] = [
            "Command: \(block.titleText)",
            "Status: \(block.status.label)",
        ]

        if let exitCode = block.exitCode {
            lines.append("Exit Code: \(exitCode)")
        }

        if let durationText = block.durationText {
            lines.append("Duration: \(durationText)")
        }

        if let snippet = limitedSnippet(block.primarySnippet) {
            lines.append("Output:")
            lines.append(snippet)
        }

        return lines.joined(separator: "\n")
    }

    private static func limitedSnippet(_ snippet: String?) -> String? {
        guard let snippet else { return nil }
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCommandSnippetLength else { return trimmed }
        return String(trimmed.prefix(maxCommandSnippetLength)) + "\n[...truncated]"
    }
}
