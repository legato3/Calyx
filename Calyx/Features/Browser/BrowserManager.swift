// BrowserManager.swift
// Calyx
//
// Manages the lifecycle of BrowserTabController instances keyed by Tab ID.
// Extracted from CalyxWindowController to keep browser state management cohesive.

import Foundation

@MainActor
final class BrowserManager {

    /// Fired when a browser tab's URL changes and the session should be persisted.
    var onSaveRequested: (() -> Void)?

    private var controllers: [UUID: BrowserTabController] = [:]

    // MARK: - Lookup

    /// Returns the browser controller for the given tab, lazily creating it if needed.
    func controller(for tabID: UUID, tab: Tab) -> BrowserTabController? {
        if let existing = controllers[tabID] { return existing }
        guard case .browser(let url) = tab.content else { return nil }
        let controller = BrowserTabController(url: url)
        wireCallbacks(controller: controller, tab: tab)
        controllers[tabID] = controller
        return controller
    }

    /// Returns the current live URL for a browser tab (reflecting navigations since creation).
    /// Falls back to the configured URL if no controller exists yet.
    func currentURL(for tabID: UUID, fallback: URL) -> URL {
        controllers[tabID]?.browserState.url ?? fallback
    }

    // MARK: - Lifecycle

    /// Registers a pre-created controller for a tab (called when creating a new browser tab).
    func register(_ controller: BrowserTabController, for tab: Tab) {
        wireCallbacks(controller: controller, tab: tab)
        controllers[tab.id] = controller
    }

    /// Removes the controller for a closed tab.
    func cleanupTab(id: UUID) {
        controllers.removeValue(forKey: id)
    }

    /// Removes all controllers (called on window close).
    func removeAll() {
        controllers.removeAll()
    }

    // MARK: - Private

    private func wireCallbacks(controller: BrowserTabController, tab: Tab) {
        controller.browserView.onTitleChanged = { [weak tab] title in
            tab?.title = title
        }
        controller.browserView.onURLChanged = { [weak self, weak tab] url in
            guard let tab else { return }
            tab.content = .browser(url: url)
            self?.onSaveRequested?()
        }
    }
}
