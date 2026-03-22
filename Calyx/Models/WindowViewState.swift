// WindowViewState.swift
// Calyx
//
// Observable model for the active tab's view-layer state that lives in
// CalyxWindowController but must be visible to MainContentView.
//
// Owned by CalyxWindowController, passed once to MainContentView at setup.
// The controller calls updateViewState() whenever the active tab changes or
// diff/browser/review state mutates, making all downstream SwiftUI updates
// automatic without rebuilding the view tree.

import Foundation

@Observable @MainActor
final class WindowViewState {
    /// The browser controller for the currently active browser tab, or nil.
    var activeBrowserController: BrowserTabController?

    /// The load state of the currently active diff tab, or nil.
    var activeDiffState: DiffLoadState?

    /// The diff source for the currently active diff tab, or nil.
    var activeDiffSource: DiffSource?

    /// The review comment store for the currently active diff tab, or nil.
    var activeDiffReviewStore: DiffReviewStore?

    /// Total number of unsubmitted review comments across all open diff tabs.
    var totalReviewCommentCount: Int = 0

    /// Number of diff tabs that have unsubmitted review comments.
    var reviewFileCount: Int = 0

    /// Incremented whenever review comments change, causing DiffGlassContentView
    /// to call redisplayWithComments() via its updateNSView path.
    var reviewCommentGeneration: Int = 0
}
