// AgentPromptContextBuilder.swift
// CTerm
//
// Builds the richer Warp-style context envelope used when launching
// or continuing agent sessions from the command bar.

import Foundation

@MainActor
enum AgentPromptContextBuilder {
    private static let maxCommandSnippetLength = 1_200

    static func buildPrompt(goal: String, activeTab: Tab?) -> String {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return "" }

        let sections = contextSections(for: activeTab)
        guard !sections.isEmpty else { return trimmedGoal }

        return """
        \(trimmedGoal)

        <cterm_agent_context>
        \(sections.joined(separator: "\n\n"))
        </cterm_agent_context>
        """
    }

    private static func contextSections(for activeTab: Tab?) -> [String] {
        guard let activeTab else { return [] }

        var sections: [String] = []

        if let pwd = activeTab.pwd?.trimmingCharacters(in: .whitespacesAndNewlines),
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

        if let attachedBlocks = attachedBlocksSection(for: activeTab) {
            sections.append(attachedBlocks)
        } else if let recentCommands = recentCommandSection(for: activeTab) {
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

    private static func attachedBlocksSection(for tab: Tab) -> String? {
        let blocks = tab.attachedBlocks
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
