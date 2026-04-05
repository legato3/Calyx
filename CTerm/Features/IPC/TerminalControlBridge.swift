// TerminalControlBridge.swift
// CTerm
//
// Singleton bridge between CTermMCPServer (network layer) and the window controller
// (app layer). MCP tool handlers call TerminalControlBridge.shared; the active
// CTermWindowController registers itself as the delegate.

import Foundation
import GhosttyKit

// MARK: - Response types

/// Pane descriptor for get_workspace_state.
struct PaneInfo: Encodable {
    let id: String
    let isFocused: Bool
}

/// Tab descriptor for get_workspace_state.
struct TabInfo: Encodable {
    let id: String
    let title: String
    let pwd: String?
    let isActive: Bool
    let panes: [PaneInfo]
}

/// Group descriptor for get_workspace_state.
struct GroupInfo: Encodable {
    let id: String
    let name: String
    let tabs: [TabInfo]
}

/// Full workspace state returned by get_workspace_state.
struct WorkspaceStateResult: Encodable {
    let activeTabID: String?
    let groups: [GroupInfo]
}

// MARK: - Protocol

/// Methods the MCP server can invoke on the active window.
/// All methods run on the main actor, matching the window controller's isolation.
@MainActor
protocol TerminalControl: AnyObject {
    /// The window session this controller manages (used for workspace state).
    var terminalWindowSession: WindowSession { get }

    /// Working directory of the active tab, used as a default for new tabs.
    var activeTabPwd: String? { get }

    /// Current git branch of the active tab's working directory, if available.
    /// Used by RiskScorer for protected-branch detection.
    var activeTabGitBranch: String? { get }

    /// Create a new terminal tab.
    /// - Parameters:
    ///   - pwd: Initial working directory. Nil uses the active tab's pwd.
    ///   - title: Optional title to set on the new tab.
    ///   - command: Optional shell command to inject once the shell is ready.
    func createTab(pwd: String?, title: String?, command: String?)

    /// Split the currently focused pane.
    /// - Parameter direction: "horizontal" (top/bottom) or "vertical" (left/right).
    func createSplit(direction: String)

    /// Inject text into a specific pane.
    /// - Parameters:
    ///   - tabID: UUID of the target tab. Nil targets the active tab.
    ///   - paneID: UUID of the target pane. Nil targets the focused pane in the tab.
    ///   - text: Text to inject.
    ///   - pressEnter: Whether to send a Return key after the text.
    /// - Returns: true if a pane was found and text was sent.
    @discardableResult
    func runInPane(tabID: UUID?, paneID: UUID?, text: String, pressEnter: Bool) -> Bool

    /// Move keyboard focus to a pane by UUID.
    /// - Returns: true if the pane was found.
    @discardableResult
    func focusPane(paneID: UUID) -> Bool

    /// Rename a tab.
    /// - Returns: true if the tab was found.
    @discardableResult
    func setTabTitle(tabID: UUID, title: String) -> Bool

    /// Push a macOS desktop notification.
    func showNotification(title: String, body: String)

    /// Return a formatted git status string for the active tab's working directory.
    /// Returns an error description string on failure.
    func getGitStatus() async -> String

    /// Build and return the current workspace state.
    func getWorkspaceState() -> WorkspaceStateResult

    /// Return the currently selected text in a pane.
    /// - Parameters:
    ///   - tabID: UUID of the target tab. Nil uses the active tab.
    ///   - paneID: UUID of the target pane. Nil uses the focused pane.
    /// - Returns: Selected text string, or nil if nothing is selected or pane not found.
    func getPaneOutput(tabID: UUID?, paneID: UUID?) -> String?

    /// Inject text into the first tab whose title contains the given string (case-insensitive).
    /// Useful for targeting a specific agent's pane by peer name.
    /// - Returns: true if a matching tab was found and text was sent.
    @discardableResult
    func runInPaneMatching(titleContains: String, text: String, pressEnter: Bool) -> Bool
}

// MARK: - Bridge

/// Singleton that connects CTermMCPServer tool handlers to the active window controller.
///
/// The active `CTermWindowController` sets itself as `delegate` on creation and
/// clears it on dealloc. MCP tool handlers call the delegate on the main actor.
@MainActor
final class TerminalControlBridge {
    static let shared = TerminalControlBridge()

    weak var delegate: (any TerminalControl)?

    private init() {}

    /// Convenience: inject `text` (with Enter) into the best available AI agent pane,
    /// falling back to the active terminal tab, then any active tab.
    @discardableResult
    func routeToNearestAgentPaneOrActive(text: String) -> Bool {
        guard let delegate else { return false }
        let session = delegate.terminalWindowSession
        let allTabs = session.groups.flatMap(\.tabs)

        let target = allTabs.first { $0.autoAcceptEnabled }
            ?? allTabs.first(where: \.isAIAgentTab)
            ?? {
                guard let active = session.activeGroup?.activeTab,
                      case .terminal = active.content else { return nil }
                return active
            }()
            ?? allTabs.first { tab in
                if case .terminal = tab.content { return true }
                return false
            }
            ?? session.activeGroup?.activeTab

        if let target {
            return delegate.runInPane(tabID: target.id, paneID: nil, text: text, pressEnter: true)
        }
        return false
    }

    @discardableResult
    func routeToNearestClaudePaneOrActive(text: String) -> Bool {
        routeToNearestAgentPaneOrActive(text: text)
    }
}
