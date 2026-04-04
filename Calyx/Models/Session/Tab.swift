// Tab.swift
// Calyx
//
// Represents a single terminal tab with its split layout.

import Foundation

enum TabContent: Sendable {
    case terminal
    case browser(url: URL)
    case diff(source: DiffSource)
}

enum TerminalCommandSource: String, Sendable {
    case shell
    case assistant
    case automation

    var label: String {
        switch self {
        case .shell: return "Shell"
        case .assistant: return "Assistant"
        case .automation: return "Automation"
        }
    }
}

enum TerminalCommandStatus: String, Sendable {
    case running
    case succeeded
    case failed

    var label: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        }
    }
}

struct TerminalCommandBlock: Identifiable, Sendable {
    let id: UUID
    let source: TerminalCommandSource
    let surfaceID: UUID?
    let command: String?
    let startedAt: Date
    var finishedAt: Date?
    var status: TerminalCommandStatus
    var outputSnippet: String?
    var errorSnippet: String?
    var exitCode: Int?
    var durationNanoseconds: UInt64?

    var titleText: String {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Manual command"
    }

    var primarySnippet: String? {
        if let errorSnippet, !errorSnippet.isEmpty {
            return errorSnippet
        }
        if let outputSnippet, !outputSnippet.isEmpty {
            return outputSnippet
        }
        return nil
    }

    var canExplain: Bool {
        primarySnippet != nil
    }

    var canFix: Bool {
        status == .failed && primarySnippet != nil
    }

    var durationText: String? {
        guard let durationNanoseconds else { return nil }
        let seconds = Double(durationNanoseconds) / 1_000_000_000
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}

@MainActor @Observable
class Tab: Identifiable {
    private static let maxCommandBlocks = 20

    let id: UUID
    var title: String
    var titleOverride: String?
    var pwd: String?
    var splitTree: SplitTree
    var content: TabContent
    var unreadNotifications: Int = 0
    var lastNotificationTime: Date?
    var processExited: Bool = false
    var lastExitCode: UInt32? = nil
    /// When `true`, compose overlay broadcasts text to all panes in this tab's split tree.
    var broadcastInputEnabled: Bool = false
    /// Explicit runtime marker for tabs launched as AI agents.
    var agentRuntime: AgentRuntimePreset? = nil
    /// Controls how Calyx should submit prompts into this agent tab.
    var agentInputStyle: AgentInputStyle? = nil
    /// When `true`, Claude Code confirmation prompts are automatically accepted.
    var autoAcceptEnabled: Bool = false
    /// Session log of auto-accepted events for this tab.
    var autoAcceptLog: [AutoAcceptEvent] = []
    /// Most recent shell error detected in this tab. Cleared after routing or dismissal.
    var lastShellError: ShellErrorEvent? = nil
    /// Recent command blocks used by the Warp-style command bar.
    var commandBlocks: [TerminalCommandBlock] = []
    /// Per-tab Ollama agent session attached to the Warp-style command bar.
    var ollamaAgentSession: OllamaAgentSession? = nil
    let registry: SurfaceRegistry

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        titleOverride: String? = nil,
        pwd: String? = nil,
        splitTree: SplitTree = SplitTree(),
        content: TabContent = .terminal,
        registry: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.id = id
        self.title = title
        self.titleOverride = titleOverride
        self.pwd = pwd
        self.splitTree = splitTree
        self.content = content
        self.registry = registry
    }

    var isAIAgentTab: Bool {
        guard case .terminal = content else { return false }
        return agentRuntime != nil || autoAcceptEnabled || AgentRuntimeConfiguration.isLikelyAgentTitle(title)
    }

    var preferredAgentInputStyle: AgentInputStyle {
        if let agentInputStyle {
            return agentInputStyle
        }
        return AgentRuntimeConfiguration.isLikelyAgentTitle(title) ? .confirmPasteThenSubmit : .submitOnce
    }

    func clearUnreadNotifications() {
        unreadNotifications = 0
        lastNotificationTime = nil
    }

    @discardableResult
    func beginCommandBlock(
        command: String?,
        source: TerminalCommandSource,
        surfaceID: UUID?
    ) -> UUID {
        let id = UUID()
        commandBlocks.insert(
            TerminalCommandBlock(
                id: id,
                source: source,
                surfaceID: surfaceID,
                command: command,
                startedAt: Date(),
                finishedAt: nil,
                status: .running,
                outputSnippet: nil,
                errorSnippet: nil,
                exitCode: nil,
                durationNanoseconds: nil
            ),
            at: 0
        )
        if commandBlocks.count > Self.maxCommandBlocks {
            commandBlocks = Array(commandBlocks.prefix(Self.maxCommandBlocks))
        }
        return id
    }

    func commandBlock(id: UUID) -> TerminalCommandBlock? {
        commandBlocks.first(where: { $0.id == id })
    }

    var latestCommandBlock: TerminalCommandBlock? {
        commandBlocks.first
    }

    @discardableResult
    func finishCommandBlock(
        id: UUID? = nil,
        surfaceID: UUID?,
        fallbackCommand: String? = nil,
        exitCode: Int?,
        durationNanoseconds: UInt64?,
        outputSnippet: String?,
        errorSnippet: String?
    ) -> UUID {
        if let id,
           let existingID = updateCommandBlock(id: id, exitCode: exitCode, durationNanoseconds: durationNanoseconds, outputSnippet: outputSnippet, errorSnippet: errorSnippet) {
            return existingID
        }

        if let surfaceID,
           let existing = commandBlocks.first(where: { $0.status == .running && $0.surfaceID == surfaceID }),
           let existingID = updateCommandBlock(id: existing.id, exitCode: exitCode, durationNanoseconds: durationNanoseconds, outputSnippet: outputSnippet, errorSnippet: errorSnippet) {
            return existingID
        }

        if let running = commandBlocks.first(where: { $0.status == .running }),
           let existingID = updateCommandBlock(id: running.id, exitCode: exitCode, durationNanoseconds: durationNanoseconds, outputSnippet: outputSnippet, errorSnippet: errorSnippet) {
            return existingID
        }

        let synthesizedID = beginCommandBlock(command: fallbackCommand, source: .shell, surfaceID: surfaceID)
        _ = updateCommandBlock(
            id: synthesizedID,
            exitCode: exitCode,
            durationNanoseconds: durationNanoseconds,
            outputSnippet: outputSnippet,
            errorSnippet: errorSnippet
        )
        return synthesizedID
    }

    private func updateCommandBlock(
        id: UUID,
        exitCode: Int?,
        durationNanoseconds: UInt64?,
        outputSnippet: String?,
        errorSnippet: String?
    ) -> UUID? {
        guard let index = commandBlocks.firstIndex(where: { $0.id == id }) else { return nil }
        var updatedBlocks = commandBlocks
        var block = updatedBlocks[index]
        block.exitCode = exitCode
        block.durationNanoseconds = durationNanoseconds ?? block.durationNanoseconds
        block.outputSnippet = trimmedSnippet(outputSnippet) ?? block.outputSnippet
        block.errorSnippet = trimmedSnippet(errorSnippet)
        block.finishedAt = Date()
        block.status = (exitCode ?? 0) == 0 ? .succeeded : .failed
        updatedBlocks[index] = block
        commandBlocks = updatedBlocks
        return id
    }

    private func trimmedSnippet(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
