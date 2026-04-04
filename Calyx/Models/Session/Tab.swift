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

@MainActor @Observable
class Tab: Identifiable {
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
    /// When `true`, Claude Code confirmation prompts are automatically accepted.
    var autoAcceptEnabled: Bool = false
    /// Session log of auto-accepted events for this tab.
    var autoAcceptLog: [AutoAcceptEvent] = []
    /// Most recent shell error detected in this tab. Cleared after routing or dismissal.
    var lastShellError: ShellErrorEvent? = nil
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

    func clearUnreadNotifications() {
        unreadNotifications = 0
        lastNotificationTime = nil
    }
}
