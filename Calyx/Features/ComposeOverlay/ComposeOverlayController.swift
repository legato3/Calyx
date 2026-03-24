// ComposeOverlayController.swift
// Calyx
//
// Manages the compose overlay lifecycle: tracks which surface is targeted,
// handles show/hide state, and dispatches text to the terminal.

import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "ComposeOverlayController"
)

@MainActor
final class ComposeOverlayController {

    /// The surface ID that will receive composed text.
    /// Set when the overlay opens; cleared when it closes.
    private(set) var targetSurfaceID: UUID?

    /// When `true`, the composed text is sent to every pane in the active tab's split tree
    /// instead of only the targeted surface.
    var broadcastEnabled: Bool = false

    // MARK: - Overlay Lifecycle

    /// Toggles the overlay. Opens it targeting `focusedControllerID`,
    /// or closes it if already open.
    func toggle(
        windowSession: WindowSession,
        focusedControllerID: UUID?
    ) {
        if windowSession.showComposeOverlay {
            dismiss(windowSession: windowSession, onDismiss: nil)
        } else {
            guard let activeTab = windowSession.activeGroup?.activeTab,
                  case .terminal = activeTab.content else { return }
            targetSurfaceID = focusedControllerID
            windowSession.showComposeOverlay = true
        }
    }

    /// Re-points the overlay at the currently focused surface (called on tab switch).
    func retargetIfNeeded(windowSession: WindowSession, focusedControllerID: UUID?) {
        guard windowSession.showComposeOverlay else { return }
        targetSurfaceID = focusedControllerID
    }

    /// Closes the overlay and calls `onDismiss` so the caller can restore focus.
    func dismiss(windowSession: WindowSession, onDismiss: (() -> Void)?) {
        guard windowSession.showComposeOverlay else { return }
        windowSession.showComposeOverlay = false
        targetSurfaceID = nil
        onDismiss?()
    }

    // MARK: - Text Dispatch

    /// Sends `text` to the targeted (or currently focused) surface and submits with Enter.
    /// Returns `true` if text was dispatched.
    func send(
        _ text: String,
        activeTab: Tab?,
        focusedController: GhosttySurfaceController?,
        sendEnterKey: @escaping (GhosttySurfaceController) -> Void
    ) -> Bool {
        guard !text.isEmpty else { return false }

        let targetController: GhosttySurfaceController?
        if let targetID = targetSurfaceID,
           let tab = activeTab,
           let controller = tab.registry.controller(for: targetID) {
            targetController = controller
        } else {
            targetController = focusedController
        }

        guard let controller = targetController else { return false }

        let isAgent = activeTab.map { tab -> Bool in
            guard case .terminal = tab.content else { return false }
            let title = tab.title
            return title.localizedCaseInsensitiveContains("claude") ||
                   title.localizedCaseInsensitiveContains("codex")
        } ?? false

        controller.sendText(text)

        if isAgent {
            // AI agent: confirm paste then submit with timing delays
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                sendEnterKey(controller)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    sendEnterKey(controller)
                }
            }
        } else {
            sendEnterKey(controller)
        }

        // Broadcast to all other panes if enabled
        if broadcastEnabled, let tab = activeTab {
            for leafID in tab.splitTree.allLeafIDs() {
                guard let otherController = tab.registry.controller(for: leafID),
                      otherController.id != controller.id else { continue }
                otherController.sendText(text)
                sendEnterKey(otherController)
            }
        }

        logger.debug("Sent compose text (\(text.count) chars) to surface \(String(describing: self.targetSurfaceID))\(self.broadcastEnabled ? " [broadcast]" : "")")
        return true
    }
}
