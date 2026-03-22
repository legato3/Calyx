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
}
