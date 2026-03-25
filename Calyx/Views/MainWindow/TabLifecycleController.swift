import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "TabLifecycleController"
)

/// Manages tab and group creation, switching, and teardown.
/// Owns the `closingTabIDs` guard set and `cleanupTabResources` logic.
/// Owned by CalyxWindowController; calls back for all view-side effects.
@MainActor
final class TabLifecycleController {
    private weak var windowSession: WindowSession?
    private let reviewController: ReviewController
    private let browserManager: BrowserManager
    private let focusManager: FocusManager

    /// Guards against double-execution during tab teardown.
    private(set) var closingTabIDs: Set<UUID> = []

    // MARK: - View-side callbacks (set by CalyxWindowController after init)

    var onTabCreated: ((Tab) -> Void)?
    var onActivateCurrentTab: (() -> Void)?
    var onDeactivateCurrentTab: (() -> Void)?
    var onRefreshHostingView: (() -> Void)?
    /// Called when a newly-created tab needs its split container built and laid out.
    /// Corresponds to `rebuildSplitContainer() + updateLayout()` in CWC.
    var onRebuildSplitContainerAndLayout: (() -> Void)?
    var onInvalidateSurfaceToTab: (() -> Void)?
    var onRequestSave: (() -> Void)?
    var onCloseWindow: (() -> Void)?
    var onRetargetComposeOverlay: (() -> Void)?
    var onDismissComposeOverlay: (() -> Void)?
    var getWindow: (() -> NSWindow?)?
    var getSplitContainerView: (() -> SplitContainerView?)?

    init(
        windowSession: WindowSession,
        reviewController: ReviewController,
        browserManager: BrowserManager,
        focusManager: FocusManager
    ) {
        self.windowSession = windowSession
        self.reviewController = reviewController
        self.browserManager = browserManager
        self.focusManager = focusManager
    }

    /// Marks every tab in the given session as closing. Called during window teardown
    /// to prevent ghosttyCloseSurface handlers from double-removing already-closing tabs.
    func markAllTabsAsClosing(in session: WindowSession) {
        for group in session.groups {
            for tab in group.tabs {
                closingTabIDs.insert(tab.id)
            }
        }
    }

    // MARK: - Resource Cleanup

    func cleanupTabResources(id tabID: UUID) {
        browserManager.cleanupTab(id: tabID)
        reviewController.cleanupTab(id: tabID)
    }

    // MARK: - Tab Creation

    func createNewTab(inheritedConfig: Any? = nil, pwd: String? = nil) {
        guard let session = windowSession,
              let app = GhosttyAppController.shared.app,
              let window = getWindow?(),
              let group = session.activeGroup else { return }

        let tab = Tab(pwd: pwd ?? NSHomeDirectory())

        var config: ghostty_surface_config_s
        if let inherited = inheritedConfig as? ghostty_surface_config_s {
            config = inherited
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: pwd) else {
            logger.error("Failed to create surface for new tab")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)
        onInvalidateSurfaceToTab?()

        session.activeGroup?.activeTab?.registry.pauseAll()

        group.addTab(tab)
        group.activeTabID = tab.id
        onTabCreated?(tab)

        onRebuildSplitContainerAndLayout?()
        onRefreshHostingView?()

        focusManager.restoreFocus(
            window: window,
            tab: session.activeGroup?.activeTab,
            splitContainerView: getSplitContainerView?()
        )
        onRetargetComposeOverlay?()
        onRequestSave?()
    }

    func createBrowserTab(url: URL) {
        guard let session = windowSession,
              let group = session.activeGroup else { return }

        let tab = Tab(title: url.host() ?? url.absoluteString, content: .browser(url: url))

        onDeactivateCurrentTab?()

        group.addTab(tab)
        group.activeTabID = tab.id

        let controller = BrowserTabController(url: url)
        browserManager.register(controller, for: tab)

        onRefreshHostingView?()
        DispatchQueue.main.async { [weak self] in
            self?.getWindow?()?.makeFirstResponder(controller.browserView)
        }
        onRequestSave?()
    }

    func promptAndOpenBrowserTab() {
        let alert = NSAlert()
        alert.messageText = "Open Browser Tab"
        alert.informativeText = "Enter a URL:"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        var input = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        if !input.contains("://") {
            input = "https://" + input
        }

        guard let url = URL(string: input),
              let scheme = url.scheme,
              BrowserSecurity.isAllowedTopLevelScheme(scheme) else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Invalid URL"
            errorAlert.informativeText = "Only http and https URLs are allowed."
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
            return
        }

        createBrowserTab(url: url)
    }

    // MARK: - Tab Closing

    func closeTab(id tabID: UUID) {
        guard let session = windowSession else { return }
        guard !closingTabIDs.contains(tabID) else { return }

        guard let group = session.groups.first(where: { g in
            g.tabs.contains(where: { $0.id == tabID })
        }) else { return }
        guard let tab = group.tabs.first(where: { $0.id == tabID }) else { return }

        if let store = reviewController.reviewStores[tabID], store.hasUnsubmittedComments {
            let alert = NSAlert()
            alert.messageText = "Unsent Review Comments"
            alert.informativeText = "This diff tab has \(store.comments.count) unsent review comment(s). Closing will discard them."
            alert.addButton(withTitle: "Discard & Close")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }

        closingTabIDs.insert(tabID)
        cleanupTabResources(id: tabID)

        for surfaceID in tab.registry.allIDs {
            tab.registry.destroySurface(surfaceID)
        }
        onInvalidateSurfaceToTab?()

        let result = session.removeTab(id: tabID, fromGroup: group.id)

        switch result {
        case .switchedTab, .switchedGroup:
            onActivateCurrentTab?()
        case .windowShouldClose:
            onCloseWindow?()
        }

        onRefreshHostingView?()
        onRequestSave?()
        closingTabIDs.remove(tabID)
    }

    // MARK: - Tab Navigation

    func switchToTab(id tabID: UUID) {
        guard let session = windowSession else { return }
        guard let targetGroup = session.groups.first(where: { group in
            group.tabs.contains(where: { $0.id == tabID })
        }) else {
            logger.warning("Attempted to switch to non-existent tab: \(tabID)")
            return
        }
        let sameGroup = session.activeGroupID == targetGroup.id
        let sameTab = sameGroup && targetGroup.activeTabID == tabID
        guard !sameTab else { return }

        onDeactivateCurrentTab?()
        session.activeGroupID = targetGroup.id
        targetGroup.activeTabID = tabID
        onActivateCurrentTab?()
    }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, let session = windowSession else { return }
        onDeactivateCurrentTab?()
        session.selectTab(at: index)
        onActivateCurrentTab?()
    }

    func jumpToMostRecentUnreadTab() {
        guard let session = windowSession else { return }
        var mostRecentTab: Tab?
        var mostRecentTime: Date?

        for group in session.groups {
            for tab in group.tabs {
                guard tab.unreadNotifications > 0,
                      let time = tab.lastNotificationTime else { continue }
                if mostRecentTime == nil || time > mostRecentTime! {
                    mostRecentTab = tab
                    mostRecentTime = time
                }
            }
        }

        guard let target = mostRecentTab else {
            NSSound.beep()
            return
        }

        switchToTab(id: target.id)
    }

    // MARK: - Group Operations

    func switchToGroup(id groupID: UUID) {
        guard let session = windowSession else { return }
        guard session.groups.contains(where: { $0.id == groupID }) else {
            logger.warning("Attempted to switch to non-existent group: \(groupID)")
            return
        }
        guard session.activeGroupID != groupID else { return }

        onDismissComposeOverlay?()
        onDeactivateCurrentTab?()
        session.activeGroupID = groupID
        onActivateCurrentTab?()
    }

    func createNewGroup() {
        guard let session = windowSession,
              let app = GhosttyAppController.shared.app,
              let window = getWindow?() else { return }

        let tab = Tab()

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create surface for new group")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)
        onInvalidateSurfaceToTab?()

        session.activeGroup?.activeTab?.registry.pauseAll()

        let newColor = TabGroupColor.nextColor(excluding: session.groups.map { $0.color })
        let group = TabGroup(
            name: "Group \(session.groups.count + 1)",
            color: newColor,
            tabs: [tab],
            activeTabID: tab.id
        )

        session.addGroup(group)
        session.activeGroupID = group.id

        onRebuildSplitContainerAndLayout?()
        onRefreshHostingView?()

        focusManager.restoreFocus(
            window: window,
            tab: session.activeGroup?.activeTab,
            splitContainerView: getSplitContainerView?()
        )
        onRetargetComposeOverlay?()
        onRequestSave?()
    }

    func closeActiveGroup() {
        guard let session = windowSession,
              let group = session.activeGroup else { return }

        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            cleanupTabResources(id: tabID)
            closingTabIDs.insert(tabID)
        }

        for tab in group.tabs {
            for surfaceID in tab.registry.allIDs {
                tab.registry.destroySurface(surfaceID)
            }
        }
        onInvalidateSurfaceToTab?()

        let result = session.removeGroup(id: group.id)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab, .switchedGroup:
            onActivateCurrentTab?()
            onRefreshHostingView?()
            onRequestSave?()
        case .windowShouldClose:
            onCloseWindow?()
            onRequestSave?()
        }
    }

    func closeAllTabsInGroup(id groupID: UUID) {
        guard let session = windowSession,
              let group = session.groups.first(where: { $0.id == groupID }) else { return }

        let wasActiveGroup = (groupID == session.activeGroupID)

        if wasActiveGroup {
            onDeactivateCurrentTab?()
        }

        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            cleanupTabResources(id: tabID)
            closingTabIDs.insert(tabID)
        }

        for tab in group.tabs {
            for surfaceID in tab.registry.allIDs {
                tab.registry.destroySurface(surfaceID)
            }
        }
        onInvalidateSurfaceToTab?()

        let result = session.removeGroup(id: groupID)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab, .switchedGroup:
            if wasActiveGroup {
                onActivateCurrentTab?()
            }
            onRefreshHostingView?()
            onRequestSave?()
        case .windowShouldClose:
            onCloseWindow?()
            onRequestSave?()
        }
    }

    func switchToNextGroup() {
        onDeactivateCurrentTab?()
        windowSession?.nextGroup()
        onActivateCurrentTab?()
    }

    func switchToPreviousGroup() {
        onDeactivateCurrentTab?()
        windowSession?.previousGroup()
        onActivateCurrentTab?()
    }
}
