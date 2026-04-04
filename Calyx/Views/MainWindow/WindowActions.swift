// WindowActions.swift
// Calyx
//
// Observable action container injected into the view hierarchy via SwiftUI environment.
// Replaces the 22+ callback closures previously passed directly to MainContentView.

import Foundation
import SwiftUI

/// Holds all user-initiated action callbacks for the main window view hierarchy.
/// Owned by CalyxWindowController, injected once via `.environment(windowActions)`.
/// SwiftUI views read it with `@Environment(WindowActions.self)`.
@Observable
@MainActor
final class WindowActions {
    var onTabSelected: ((UUID) -> Void)?
    var onGroupSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onDismissCommandPalette: (() -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?
    var onRollbackToCheckpoint: ((GitCommit) -> Void)?
    var onSidebarWidthChanged: ((CGFloat) -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?
    var onSidebarDragCommitted: (() -> Void)?
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?
    var onComposeOverlaySend: ((String) -> Bool)?
    var onDismissComposeOverlay: (() -> Void)?
    var onToggleComposeOverlay: (() -> Void)?
    var onToggleComposeBroadcast: (() -> Void)?
    var onApplyComposeAssistantEntry: ((UUID, Bool) -> Bool)?
    var onExplainComposeAssistantEntry: ((UUID) -> Void)?
    var onFixComposeAssistantEntry: ((UUID) -> Void)?
    var onExplainCommandBlock: ((UUID) -> Void)?
    var onFixCommandBlock: ((UUID) -> Void)?
    var onApproveOllamaAgent: (() -> Bool)?
    var onStopOllamaAgent: (() -> Void)?
    var onOpenDiff: ((DiffSource) -> Void)?
    var onOpenAggregateDiff: ((String) -> Void)?
    /// Route the shell error captured in the given tab to the nearest Claude pane.
    var onRouteShellError: ((UUID) -> Void)?
    /// Dismiss (clear) the shell error badge on a tab without routing.
    var onDismissShellError: ((UUID) -> Void)?
    var onTabRenamed: (() -> Void)?
    /// Jump to the pane whose surface UUID string matches (from terminal search results).
    var onJumpToSearchPane: ((String) -> Void)?
    /// Reflects `ComposeOverlayController.broadcastEnabled` for the SwiftUI overlay.
    var composeBroadcastEnabled: Bool = false
    var composeAssistantState: ComposeAssistantState?
    // Active AI
    /// Accept an Active AI suggestion chip — sends the prompt to the agent.
    var onAcceptActiveAISuggestion: ((ActiveAISuggestion) -> Void)?
    /// Dismiss all Active AI suggestions.
    var onDismissActiveAISuggestions: (() -> Void)?
    /// Accept the suggested code diff.
    var onAcceptSuggestedDiff: ((SuggestedDiff) -> Void)?
    /// Dismiss the suggested code diff.
    var onDismissSuggestedDiff: (() -> Void)?
    /// Accept the next-command ghost-text suggestion.
    var onAcceptNextCommand: (() -> String?)?
    /// Attach a command block to the current agent prompt.
    var onAttachBlock: ((UUID) -> Void)?
    /// Detach a previously attached block.
    var onDetachBlock: ((UUID) -> Void)?
    // Active AI state (read by views)
    var activeAISuggestions: [ActiveAISuggestion] = []
    var nextCommandSuggestion: String? = nil
    var suggestedDiffStatus: SuggestedDiffStatus = .idle
    var attachedBlockIDs: Set<UUID> = []
}
