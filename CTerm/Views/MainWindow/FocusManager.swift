import AppKit
import OSLog
import QuartzCore

/// Manages focus restoration after tab switches, splits, and layout changes.
/// Owned by CTermWindowController; call sites pass current window/tab state.
private let logger = Logger(subsystem: "com.cterm", category: "FocusManager")

@MainActor
final class FocusManager {
    private var focusRequestID: UInt64 = 0

    /// Called when `makeFirstResponder` fails after layout is complete.
    /// Owner should use this to show a visual "click to focus" indicator.
    var onFocusFailed: (() -> Void)?

    /// Called when `makeFirstResponder` succeeds.
    /// Owner should use this to clear any focus-lost indicator.
    var onFocusRestored: (() -> Void)?

    /// When set, called instead of focusing the terminal surface.
    /// Used in Warp-mode to keep focus in the compose bar.
    var focusComposeOverlay: (() -> Void)?

    /// When set and returns true, the compose redirect is skipped and focus
    /// falls through to the terminal surface (used when a TUI owns the pane).
    var isComposeFocusSuppressed: (() -> Bool)?

    // MARK: - Public API

    /// Schedules an async focus-restore cycle. Call after every tab switch or split.
    func restoreFocus(window: NSWindow?, tab: Tab?, splitContainerView: SplitContainerView?) {
        // In Warp mode, keep keyboard focus in the compose bar, but preserve
        // the active terminal surface's focused appearance while the window is key.
        // Skip the redirect when a TUI owns the focused pane — it needs the keys.
        let suppressed = isComposeFocusSuppressed?() ?? false
        if let focusComposeOverlay, !suppressed {
            focusComposeOverlay()
            applyVisualFocus(window: window, tab: tab)
            return
        }

        focusRequestID &+= 1
        let requestID = focusRequestID

        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusRestore(
                requestID: requestID,
                window: window,
                tab: tab,
                splitContainerView: splitContainerView
            )
        }
    }

    /// Synchronously focuses the active split view. Returns true if focus was set.
    @discardableResult
    func focusImmediately(window: NSWindow?, tab: Tab?) -> Bool {
        // In Warp mode, keep keyboard focus in the compose bar, but preserve
        // the active terminal surface's focused appearance while the window is key.
        // Skip the redirect when a TUI owns the focused pane — it needs the keys.
        let suppressed = isComposeFocusSuppressed?() ?? false
        if let focusComposeOverlay, !suppressed {
            focusComposeOverlay()
            return applyVisualFocus(window: window, tab: tab)
        }

        guard let tab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else {
            return false
        }

        let becameFirstResponder = window?.makeFirstResponder(focusView) ?? false
        guard becameFirstResponder else { return false }

        applyFocusedSurfaceState(tab: tab, focusedID: focusedID, focusView: focusView)
        return true
    }

    // MARK: - Private

    @discardableResult
    private func applyVisualFocus(window: NSWindow?, tab: Tab?) -> Bool {
        guard window?.isKeyWindow == true,
              let tab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else {
            return false
        }

        applyFocusedSurfaceState(tab: tab, focusedID: focusedID, focusView: focusView)
        return true
    }

    private func applyFocusedSurfaceState(tab: Tab, focusedID: UUID, focusView: SurfaceView) {
        tab.registry.controller(for: focusedID)?.setFocus(true)
        tab.registry.controller(for: focusedID)?.refresh()
        focusView.needsDisplay = true
        onFocusRestored?()
        tab.clearUnreadNotifications()
    }

    private func attemptFocusRestore(
        requestID: UInt64,
        window: NSWindow?,
        tab: Tab?,
        splitContainerView: SplitContainerView?
    ) {
        guard requestID == focusRequestID else { return }

        // Non-key window → skip; windowDidBecomeKey will call restoreFocus()
        guard window?.isKeyWindow == true else { return }

        guard let tab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else { return }

        let inWindow = focusView.window === window
        let hasSuperview = focusView.superview != nil

        // View must be attached to THIS window's hierarchy. If not, wait for the
        // next layout pass rather than busy-polling with a timing-dependent loop.
        guard inWindow, hasSuperview else {
            splitContainerView?.onDeferredLayoutComplete = { [weak self] in
                guard let self, requestID == self.focusRequestID else { return }
                self.attemptFocusRestore(
                    requestID: requestID,
                    window: window,
                    tab: tab,
                    splitContainerView: splitContainerView
                )
            }
            return
        }

        let result = window?.makeFirstResponder(focusView) ?? false
        if result {
            applyFocusedSurfaceState(tab: tab, focusedID: focusedID, focusView: focusView)
        } else {
            logger.warning("makeFirstResponder failed for surface \(focusedID) — triggering focus-lost indicator")
            onFocusFailed?()
        }
    }
}
