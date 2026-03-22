import AppKit
import QuartzCore

/// Manages focus restoration after tab switches, splits, and layout changes.
/// Owned by CalyxWindowController; call sites pass current window/tab state.
@MainActor
final class FocusManager {
    private var focusRequestID: UInt64 = 0
    private static let focusRestoreTimeout: Double = 0.5

    // MARK: - Public API

    /// Schedules an async focus-restore cycle. Call after every tab switch or split.
    func restoreFocus(window: NSWindow?, tab: Tab?, splitContainerView: SplitContainerView?) {
        focusRequestID &+= 1
        let requestID = focusRequestID
        let startTime = CACurrentMediaTime()

        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusRestore(
                requestID: requestID,
                startTime: startTime,
                window: window,
                tab: tab,
                splitContainerView: splitContainerView
            )
        }
    }

    /// Synchronously focuses the active split view. Returns true if focus was set.
    @discardableResult
    func focusImmediately(window: NSWindow?, tab: Tab?) -> Bool {
        guard let tab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else {
            return false
        }

        let becameFirstResponder = window?.makeFirstResponder(focusView) ?? false
        guard becameFirstResponder else { return false }

        tab.registry.controller(for: focusedID)?.setFocus(true)
        tab.registry.controller(for: focusedID)?.refresh()
        focusView.needsDisplay = true
        tab.clearUnreadNotifications()
        return true
    }

    // MARK: - Private

    private func attemptFocusRestore(
        requestID: UInt64,
        startTime: Double,
        window: NSWindow?,
        tab: Tab?,
        splitContainerView: SplitContainerView?
    ) {
        guard requestID == focusRequestID else { return }

        let elapsed = CACurrentMediaTime() - startTime

        // Non-key window → skip; windowDidBecomeKey will call restoreFocus()
        guard window?.isKeyWindow == true else { return }

        guard let tab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else { return }

        let inWindow = focusView.window === window
        let hasSuperview = focusView.superview != nil

        // View must be attached to THIS window's hierarchy
        guard inWindow, hasSuperview else {
            guard elapsed < Self.focusRestoreTimeout else {
                splitContainerView?.onDeferredLayoutComplete = { [weak self] in
                    guard let self, requestID == self.focusRequestID else { return }
                    self.attemptFocusRestore(
                        requestID: requestID,
                        startTime: CACurrentMediaTime(),
                        window: window,
                        tab: tab,
                        splitContainerView: splitContainerView
                    )
                }
                return
            }
            // Retry with 10ms backoff
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.attemptFocusRestore(
                    requestID: requestID,
                    startTime: startTime,
                    window: window,
                    tab: tab,
                    splitContainerView: splitContainerView
                )
            }
            return
        }

        let result = window?.makeFirstResponder(focusView) ?? false
        if result {
            tab.registry.controller(for: focusedID)?.setFocus(true)
            tab.registry.controller(for: focusedID)?.refresh()
            focusView.needsDisplay = true
            tab.clearUnreadNotifications()
        }
    }
}
