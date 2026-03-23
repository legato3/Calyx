import AppKit
import SwiftUI
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "CalyxWindowController"
)

@MainActor
class CalyxWindowController: NSWindowController, NSWindowDelegate {
    private(set) var windowSession: WindowSession
    private var splitContainerView: SplitContainerView?
    private var hostingView: NSHostingView<AnyView>?
    private let commandRegistry = CommandRegistry()
    private var closingTabIDs: Set<UUID> = []
    private let focusManager = FocusManager()
    private let windowActions = WindowActions()
    private var isRestoring = false
    private var browserControllers: [UUID: BrowserTabController] = [:]
    private let gitController: GitController
    private let reviewController: ReviewController
    private var clipboardConfirmationController: ClipboardConfirmationController?
    private var composeOverlayTargetSurfaceID: UUID?
    private let windowViewState = WindowViewState()
    let mcpServer: CalyxMCPServer

    // O(1) surface-to-tab reverse lookup. Rebuilt lazily after any structural change.
    private var surfaceToTab: [UUID: (tab: Tab, group: TabGroup)] = [:]
    private var surfaceToTabDirty = true

    // MARK: - Computed Properties

    private var activeTab: Tab? {
        windowSession.activeGroup?.activeTab
    }

    private var activeRegistry: SurfaceRegistry? {
        activeTab?.registry
    }

    private var activeBrowserController: BrowserTabController? {
        guard let tab = activeTab, case .browser = tab.content else { return nil }
        return browserController(for: tab.id)
    }

    var activeBrowserControllerForExternal: BrowserTabController? {
        activeBrowserController
    }

    private var activeDiffState: DiffLoadState? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return reviewController.diffStates[tab.id]
    }

    private var activeDiffSource: DiffSource? {
        guard let tab = activeTab, case .diff(let source) = tab.content else { return nil }
        return source
    }

    private var activeDiffReviewStore: DiffReviewStore? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return reviewController.reviewStores[tab.id]
    }

    private var totalReviewCommentCount: Int { reviewController.totalReviewCommentCount }
    private var reviewFileCount: Int { reviewController.reviewFileCount }

    private func browserController(for tabID: UUID) -> BrowserTabController? {
        if let existing = browserControllers[tabID] { return existing }
        guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
              case .browser(let url) = tab.content else { return nil }
        let controller = BrowserTabController(url: url)
        wireBrowserCallbacks(controller: controller, tab: tab)
        browserControllers[tabID] = controller
        return controller
    }

    func browserController(forExternal tabID: UUID) -> BrowserTabController? {
        browserController(for: tabID)
    }

    private func wireBrowserCallbacks(controller: BrowserTabController, tab: Tab) {
        controller.browserView.onTitleChanged = { [weak tab] title in
            tab?.title = title
        }
        controller.browserView.onURLChanged = { [weak self, weak tab] url in
            guard let tab else { return }
            tab.content = .browser(url: url)
            self?.requestSave()
        }
    }

    // MARK: - Initialization

    convenience init(windowSession: WindowSession) {
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let width = (screenSize.width * 0.65).rounded()
        let height = (screenSize.height * 0.65).rounded()
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window, windowSession: windowSession)
    }

    init(window: NSWindow, windowSession: WindowSession, restoring: Bool = false, mcpServer: CalyxMCPServer = .shared) {
        self.windowSession = windowSession
        self.isRestoring = restoring
        self.mcpServer = mcpServer
        self.gitController = GitController(windowSession: windowSession)
        self.reviewController = ReviewController(windowSession: windowSession)
        super.init(window: window)
        gitController.onOpenDiff = { [weak self] source in self?.openDiffTab(source: source) }
        reviewController.onDiffStateChanged = { [weak self] in self?.refreshHostingView() }
        reviewController.onReviewChanged = { [weak self] in
            self?.windowViewState.reviewCommentGeneration += 1
            self?.updateViewState()
        }
        reviewController.sendToAgent = { [weak self] payload in
            self?.sendReviewToAgent(payload) ?? .failed
        }
        window.delegate = self
        window.center()
        setupShortcutManager()
        setupCommandRegistry()
        setupUI()
        if !restoring { setupTerminalSurface() }
        registerNotificationObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupShortcutManager() {
        guard let calyxWindow = window as? CalyxWindow else { return }
        let manager = ShortcutManager()

        // Ctrl+Shift+] → next group (keyCode 30 = ])
        manager.register(modifiers: [.control, .shift], keyCode: 30) { [weak self] in
            self?.switchToNextGroup()
        }
        // Ctrl+Shift+[ → previous group (keyCode 33 = [)
        manager.register(modifiers: [.control, .shift], keyCode: 33) { [weak self] in
            self?.switchToPreviousGroup()
        }
        // Ctrl+Shift+N → new group (keyCode 45 = N)
        manager.register(modifiers: [.control, .shift], keyCode: 45) { [weak self] in
            self?.createNewGroup()
        }
        // Ctrl+Shift+W → close group (keyCode 13 = W)
        manager.register(modifiers: [.control, .shift], keyCode: 13) { [weak self] in
            self?.closeActiveGroup()
        }
        // Cmd+Shift+E → compose overlay (keyCode 14 = E)
        manager.register(modifiers: [.command, .shift], keyCode: 14) { [weak self] in
            self?.toggleComposeOverlay()
        }

        calyxWindow.shortcutManager = manager
    }

    private func setupCommandRegistry() {
        commandRegistry.register(Command(id: "tab.new", title: "New Tab", shortcut: "Cmd+T", category: "Tabs") { [weak self] in
            self?.createNewTab()
        })
        commandRegistry.register(Command(id: "tab.close", title: "Close Tab", shortcut: "Cmd+W", category: "Tabs") { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.closeTab(id: tab.id)
        })
        commandRegistry.register(Command(id: "tab.next", title: "Next Tab", shortcut: "Cmd+Shift+]", category: "Tabs") { [weak self] in
            self?.selectNextTab(nil)
        })
        commandRegistry.register(Command(id: "tab.previous", title: "Previous Tab", shortcut: "Cmd+Shift+[", category: "Tabs") { [weak self] in
            self?.selectPreviousTab(nil)
        })
        commandRegistry.register(Command(id: "group.new", title: "New Group", shortcut: "Ctrl+Shift+N", category: "Groups") { [weak self] in
            self?.createNewGroup()
        })
        commandRegistry.register(Command(id: "group.close", title: "Close Group", shortcut: "Ctrl+Shift+W", category: "Groups") { [weak self] in
            self?.closeActiveGroup()
        })
        commandRegistry.register(Command(id: "group.next", title: "Next Group", shortcut: "Ctrl+Shift+]", category: "Groups") { [weak self] in
            self?.switchToNextGroup()
        })
        commandRegistry.register(Command(id: "group.previous", title: "Previous Group", shortcut: "Ctrl+Shift+[", category: "Groups") { [weak self] in
            self?.switchToPreviousGroup()
        })
        commandRegistry.register(Command(id: "view.sidebar", title: "Toggle Sidebar", shortcut: "Cmd+Opt+S", category: "View") { [weak self] in
            self?.toggleSidebar()
        })
        commandRegistry.register(Command(id: "view.fullscreen", title: "Toggle Full Screen", shortcut: "Ctrl+Cmd+F", category: "View") { [weak self] in
            self?.window?.toggleFullScreen(nil)
        })
        commandRegistry.register(Command(id: "window.new", title: "New Window", shortcut: "Cmd+N", category: "Window") {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindow()
            }
        })
        commandRegistry.register(Command(id: "edit.find", title: "Find in Terminal", shortcut: "Cmd+F", category: "Edit") { [weak self] in
            guard let controller = self?.focusedController else { return }
            controller.performAction("start_search")
        })
        commandRegistry.register(Command(
            id: "edit.compose",
            title: "Compose Input",
            shortcut: "Cmd+Shift+E",
            category: "Edit"
        ) { [weak self] in
            self?.toggleComposeOverlay()
        })
        commandRegistry.register(Command(id: "browser.open", title: "Open Browser Tab", category: "Browser") { [weak self] in
            self?.promptAndOpenBrowserTab()
        })
        commandRegistry.register(Command(id: "browser.back", title: "Browser Back", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goBack()
        })
        commandRegistry.register(Command(id: "browser.forward", title: "Browser Forward", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goForward()
        })
        commandRegistry.register(Command(id: "browser.reload", title: "Browser Reload", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.reload()
        })
        commandRegistry.register(Command(id: "git.showChanges", title: "Show Git Changes", category: "Git") { [weak self] in
            self?.windowSession.sidebarMode = .changes
            self?.windowSession.showSidebar = true
            self?.gitController.refreshGitStatus()
        })
        commandRegistry.register(Command(id: "git.refresh", title: "Refresh Git Changes", category: "Git") { [weak self] in
            self?.gitController.refreshGitStatus()
        })
        commandRegistry.register(Command(id: "ipc.enable", title: "Enable AI Agent IPC", category: "IPC", isAvailable: { [weak self] in
            !(self?.mcpServer.isRunning ?? false)
        }) { [weak self] in
            self?.enableIPC()
        })
        commandRegistry.register(Command(id: "ipc.disable", title: "Disable AI Agent IPC", category: "IPC", isAvailable: { [weak self] in
            self?.mcpServer.isRunning ?? false
        }) { [weak self] in
            self?.disableIPC()
        })
        commandRegistry.register(Command(id: "cli.install", title: "Install CLI to PATH", category: "System") {
            let appPath = Bundle.main.bundlePath
            let cliSource = "\(appPath)/Contents/Resources/bin/calyx"
            let cliDest = "/usr/local/bin/calyx"

            // Check if source exists
            guard FileManager.default.fileExists(atPath: cliSource) else {
                let alert = NSAlert()
                alert.messageText = "CLI Not Found"
                alert.informativeText = "CLI binary not found in app bundle. Please rebuild the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            // Use AppleScript to create symlink with admin privileges
            let script = "do shell script \"ln -sf '\(cliSource)' '\(cliDest)'\" with administrator privileges"
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Installation Failed"
                    alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "CLI Installed"
                    alert.informativeText = "The 'calyx' command is now available. Run 'calyx browser --help' to get started."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        })
        commandRegistry.register(Command(id: "tab.jumpToUnread", title: "Jump to Unread Tab", shortcut: "Cmd+Shift+U", category: "Tabs", isAvailable: { [weak self] in
            guard let self else { return false }
            return self.windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }) { [weak self] in
            self?.jumpToMostRecentUnreadTab()
        })
        commandRegistry.register(Command(
            id: "review.submitAll",
            title: "Submit All Review Comments",
            category: "Git",
            isAvailable: { [weak self] in (self?.reviewFileCount ?? 0) >= 2 }
        ) { [weak self] in
            self?.reviewController.submitAllDiffReviews()
        })

        // Claude Code slash commands
        let claudeCommands: [(id: String, title: String, cmd: String)] = [
            ("claude.commit",  "Claude: Commit",          "/commit"),
            ("claude.review",  "Claude: Review Changes",  "/review"),
            ("claude.plan",    "Claude: Create Plan",      "/plan"),
            ("claude.fix",     "Claude: Fix Issues",       "/fix"),
            ("claude.test",    "Claude: Run Tests",        "/test"),
            ("claude.explain", "Claude: Explain This",    "/explain"),
        ]
        for c in claudeCommands {
            commandRegistry.register(Command(
                id: c.id,
                title: c.title,
                category: "Claude",
                isAvailable: { [weak self] in
                    guard let tab = self?.activeTab else { return false }
                    if case .terminal = tab.content { return true }
                    return false
                },
                handler: { [weak self] in
                    self?.focusedController?.sendText(c.cmd + "\n")
                }
            ))
        }
    }

    private func setupUI() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        // Create the split container (shared across tabs — we swap its tree)
        let container = SplitContainerView(registry: SurfaceRegistry())
        container.onRatioChange = { [weak self] leafID, delta, direction in
            self?.handleDividerDrag(leafID: leafID, delta: delta, direction: direction)
        }
        self.splitContainerView = container

        wireWindowActions()
        let mainContent = buildMainContentView()
        let hosting = NSHostingView(rootView: AnyView(mainContent.environment(windowActions)))
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)
        self.hostingView = hosting

        // Title bar glass is now handled by SwiftUI overlay in MainContentView
    }

    private func setupTerminalSurface() {
        guard let tab = activeTab else {
            logger.error("No active tab during setup")
            return
        }

        guard let app = GhosttyAppController.shared.app,
              let window = self.window else {
            logger.error("Failed to set up terminal surface: app or window not available")
            return
        }

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: tab.pwd) else {
            logger.error("Failed to create initial surface")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)
        invalidateSurfaceToTab()

        // Create a SplitContainerView bound to this tab's registry
        rebuildSplitContainer()
        updateLayout()

        if let surfaceView = tab.registry.view(for: surfaceID) {
            window.makeFirstResponder(surfaceView)
        }
    }

    // MARK: - Content View Building

    private func wireWindowActions() {
        windowActions.onTabSelected = { [weak self] tabID in self?.switchToTab(id: tabID) }
        windowActions.onGroupSelected = { [weak self] groupID in self?.switchToGroup(id: groupID) }
        windowActions.onNewTab = { [weak self] in self?.createNewTab() }
        windowActions.onNewGroup = { [weak self] in self?.createNewGroup() }
        windowActions.onCloseTab = { [weak self] tabID in self?.closeTab(id: tabID) }
        windowActions.onGroupRenamed = { [weak self] in self?.requestSave() }
        windowActions.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        windowActions.onDismissCommandPalette = { [weak self] in self?.dismissCommandPalette() }
        windowActions.onWorkingFileSelected = { [weak self] entry in self?.gitController.handleWorkingFileSelected(entry) }
        windowActions.onCommitFileSelected = { [weak self] entry in self?.gitController.handleCommitFileSelected(entry) }
        windowActions.onRefreshGitStatus = { [weak self] in self?.gitController.refreshGitStatus() }
        windowActions.onLoadMoreCommits = { [weak self] in self?.gitController.loadMoreCommits() }
        windowActions.onExpandCommit = { [weak self] hash in self?.gitController.expandCommit(hash: hash) }
        windowActions.onSidebarWidthChanged = { [weak self] width in self?.windowSession.sidebarWidth = SidebarLayout.clampWidth(width) }
        windowActions.onCollapseToggled = { [weak self] in self?.requestSave() }
        windowActions.onCloseAllTabsInGroup = { [weak self] groupID in self?.closeAllTabsInGroup(id: groupID) }
        windowActions.onMoveTab = { [weak self] groupID, fromIndex, toIndex in
            guard let self,
                  let group = self.windowSession.groups.first(where: { $0.id == groupID })
            else { return }
            group.moveTab(fromIndex: fromIndex, toIndex: toIndex)
            self.requestSave()
        }
        windowActions.onSidebarDragCommitted = { [weak self] in self?.requestSave() }
        windowActions.onSubmitReview = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.reviewController.submitDiffReview(tabID: tab.id)
        }
        windowActions.onDiscardReview = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.reviewController.reviewStores[tab.id]?.clearAll()
        }
        windowActions.onSubmitAllReviews = { [weak self] in self?.reviewController.submitAllDiffReviews() }
        windowActions.onDiscardAllReviews = { [weak self] in self?.reviewController.discardAllDiffReviews() }
        windowActions.onComposeOverlaySend = { [weak self] text in self?.sendComposeText(text) ?? false }
        windowActions.onDismissComposeOverlay = { [weak self] in self?.dismissComposeOverlay() }
    }

    private func buildMainContentView() -> MainContentView {
        MainContentView(
            windowSession: windowSession,
            commandRegistry: commandRegistry,
            splitContainerView: splitContainerView ?? SplitContainerView(registry: SurfaceRegistry()),
            viewState: windowViewState,
            sidebarMode: Binding(
                get: { [weak self] in self?.windowSession.sidebarMode ?? .tabs },
                set: { [weak self] in
                    self?.windowSession.sidebarMode = $0
                    if $0 == .changes {
                        self?.gitController.refreshGitStatus()
                    }
                }
            )
        )
    }

    private func refreshHostingView() {
        updateViewState()
    }

    private func updateViewState() {
        windowViewState.activeBrowserController = activeBrowserController
        windowViewState.activeDiffState = activeDiffState
        windowViewState.activeDiffSource = activeDiffSource
        windowViewState.activeDiffReviewStore = activeDiffReviewStore
        windowViewState.totalReviewCommentCount = totalReviewCommentCount
        windowViewState.reviewFileCount = reviewFileCount
    }

    // MARK: - Split Container Management

    private func rebuildSplitContainer() {
        guard let tab = activeTab else { return }
        if let container = splitContainerView {
            container.updateRegistry(tab.registry)
        } else {
            let container = SplitContainerView(registry: tab.registry)
            container.onRatioChange = { [weak self] leafID, delta, direction in
                self?.handleDividerDrag(leafID: leafID, delta: delta, direction: direction)
            }
            self.splitContainerView = container
        }
    }

    private func updateTerminalLayout() {
        guard let tab = activeTab, let container = splitContainerView else { return }
        container.updateLayout(tree: tab.splitTree)
    }

    private func updateLayout() {
        updateTerminalLayout()
    }

    // MARK: - Tab Activation Helpers

    private func activateCurrentTab() {
        guard let tab = activeTab else { return }
        refreshHostingView()
        switch tab.content {
        case .terminal:
            rebuildSplitContainer()
            updateTerminalLayout()
            // setOcclusion(false) must run AFTER view hierarchy is stable; calling it before
            // rebuildSplitContainer would let the removeFromSuperview pass effectively re-occlude
            // the surface (Metal context reset) before ghostty could act on the unocclude signal.
            tab.registry.resumeAll()
            focusManager.focusImmediately(window: window, tab: activeTab)  // best-effort synchronous focus
            focusManager.restoreFocus(window: window, tab: activeTab, splitContainerView: splitContainerView)  // async safety net (handles post-layout focus loss)
        case .browser:
            DispatchQueue.main.async { [weak self] in
                if let bv = self?.browserController(for: tab.id)?.browserView {
                    self?.window?.makeFirstResponder(bv)
                }
            }
        case .diff:
            break  // Diff tabs don't need special activation
        }
        retargetComposeOverlayIfNeeded()
    }

    private func deactivateCurrentTab() {
        dismissComposeOverlay()
        guard let tab = activeTab else { return }
        if case .terminal = tab.content {
            focusedController?.setFocus(false)
            tab.registry.pauseAll()
        }
    }

    // MARK: - Tab Operations

    func createNewTab(inheritedConfig: Any? = nil, pwd: String? = nil) {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let group = windowSession.activeGroup else { return }

        let tab = Tab()

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
        invalidateSurfaceToTab()

        // Pause current tab
        activeTab?.registry.pauseAll()

        group.addTab(tab)
        group.activeTabID = tab.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        focusManager.restoreFocus(window: window, tab: activeTab, splitContainerView: splitContainerView)
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    func createBrowserTab(url: URL) {
        guard let group = windowSession.activeGroup else { return }
        let tab = Tab(title: url.host() ?? url.absoluteString, content: .browser(url: url))

        deactivateCurrentTab()

        group.addTab(tab)
        group.activeTabID = tab.id

        let controller = BrowserTabController(url: url)
        wireBrowserCallbacks(controller: controller, tab: tab)
        browserControllers[tab.id] = controller

        refreshHostingView()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(controller.browserView)
        }
        requestSave()
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

        // Normalize: add https:// if no scheme
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

    private func closeTab(id tabID: UUID) {
        // Prevent double execution
        guard !closingTabIDs.contains(tabID) else { return }

        guard let group = windowSession.groups.first(where: { g in
            g.tabs.contains(where: { $0.id == tabID })
        }) else { return }
        guard let tab = group.tabs.first(where: { $0.id == tabID }) else { return }

        // Check for unsent review comments
        if let store = reviewController.reviewStores[tabID], store.hasUnsubmittedComments {
            let alert = NSAlert()
            alert.messageText = "Unsent Review Comments"
            alert.informativeText = "This diff tab has \(store.comments.count) unsent review comment(s). Closing will discard them."
            alert.addButton(withTitle: "Discard & Close")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                return
            }
        }

        closingTabIDs.insert(tabID)

        cleanupTabResources(id: tabID)

        // Destroy all surfaces in the tab
        for surfaceID in tab.registry.allIDs {
            tab.registry.destroySurface(surfaceID)
        }
        invalidateSurfaceToTab()

        let result = windowSession.removeTab(id: tabID, fromGroup: group.id)

        switch result {
        case .switchedTab, .switchedGroup:
            activateCurrentTab()
        case .windowShouldClose:
            window?.close()
        }

        refreshHostingView()
        requestSave()
        closingTabIDs.remove(tabID)
    }

    func switchToTab(id tabID: UUID) {
        guard let targetGroup = windowSession.groups.first(where: { group in
            group.tabs.contains(where: { $0.id == tabID })
        }) else {
            logger.warning("Attempted to switch to non-existent tab: \(tabID)")
            return
        }
        let sameGroup = windowSession.activeGroupID == targetGroup.id
        let sameTab = sameGroup && targetGroup.activeTabID == tabID
        guard !sameTab else { return }

        deactivateCurrentTab()
        windowSession.activeGroupID = targetGroup.id
        targetGroup.activeTabID = tabID
        activateCurrentTab()
    }

    func switchToGroup(id groupID: UUID) {
        guard windowSession.groups.contains(where: { $0.id == groupID }) else {
            logger.warning("Attempted to switch to non-existent group: \(groupID)")
            return
        }
        guard windowSession.activeGroupID != groupID else { return }

        dismissComposeOverlay()
        deactivateCurrentTab()
        windowSession.activeGroupID = groupID
        activateCurrentTab()
    }

    // MARK: - Group Operations

    func createNewGroup() {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window else { return }

        let tab = Tab()

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create surface for new group")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)
        invalidateSurfaceToTab()

        // Pause current tab
        activeTab?.registry.pauseAll()

        let newColor = TabGroupColor.nextColor(excluding: windowSession.groups.map { $0.color })
        let group = TabGroup(
            name: "Group \(windowSession.groups.count + 1)",
            color: newColor,
            tabs: [tab],
            activeTabID: tab.id
        )

        windowSession.addGroup(group)
        windowSession.activeGroupID = group.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        focusManager.restoreFocus(window: window, tab: activeTab, splitContainerView: splitContainerView)
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    private func closeActiveGroup() {
        guard let group = windowSession.activeGroup else { return }

        // Mark all tabs as closing to prevent notification handler from double-deleting
        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            cleanupTabResources(id: tabID)
            closingTabIDs.insert(tabID)
        }

        // Destroy all surfaces in all tabs of this group
        for tab in group.tabs {
            for surfaceID in tab.registry.allIDs {
                tab.registry.destroySurface(surfaceID)
            }
        }
        invalidateSurfaceToTab()

        let result = windowSession.removeGroup(id: group.id)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab(_, _), .switchedGroup(_, _):
            activateCurrentTab()
            refreshHostingView()
            requestSave()
        case .windowShouldClose:
            window?.close()
            requestSave()
        }
    }

    private func closeAllTabsInGroup(id groupID: UUID) {
        guard let group = windowSession.groups.first(where: { $0.id == groupID }) else { return }

        let wasActiveGroup = (groupID == windowSession.activeGroupID)

        if wasActiveGroup {
            deactivateCurrentTab()
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
        invalidateSurfaceToTab()

        let result = windowSession.removeGroup(id: groupID)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab(_, _), .switchedGroup(_, _):
            if wasActiveGroup {
                activateCurrentTab()
            }
            refreshHostingView()
            requestSave()
        case .windowShouldClose:
            window?.close()
            requestSave()
        }
    }

    private func switchToNextGroup() {
        deactivateCurrentTab()
        windowSession.nextGroup()
        activateCurrentTab()
    }

    private func switchToPreviousGroup() {
        deactivateCurrentTab()
        windowSession.previousGroup()
        activateCurrentTab()
    }

    @objc func toggleSidebar() {
        windowSession.showSidebar.toggle()
        requestSave()
    }

    @objc func toggleCommandPalette() {
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        } else {
            windowSession.showCommandPalette = true
        }
    }

    private func dismissCommandPalette() {
        guard windowSession.showCommandPalette else { return }
        windowSession.showCommandPalette = false
        guard let tab = activeTab else { return }
        switch tab.content {
        case .terminal:
            focusManager.restoreFocus(window: window, tab: activeTab, splitContainerView: splitContainerView)
        case .browser:
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        case .diff:
            break
        }
    }

    @objc func toggleComposeOverlay() {
        if windowSession.showComposeOverlay {
            dismissComposeOverlay()
        } else {
            guard let tab = activeTab, case .terminal = tab.content else { return }
            composeOverlayTargetSurfaceID = focusedController?.id
            windowSession.showComposeOverlay = true
        }
    }

    private func retargetComposeOverlayIfNeeded() {
        guard windowSession.showComposeOverlay else { return }
        composeOverlayTargetSurfaceID = focusedController?.id
    }

    private func dismissComposeOverlay() {
        guard windowSession.showComposeOverlay else { return }
        windowSession.showComposeOverlay = false
        composeOverlayTargetSurfaceID = nil
        if case .terminal = activeTab?.content {
            focusManager.restoreFocus(window: window, tab: activeTab, splitContainerView: splitContainerView)
        }
    }

    private func sendEnterKey(to controller: GhosttySurfaceController) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.keycode = 0x24 // macOS keycode for Return/Enter
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        keyEvent.action = GHOSTTY_ACTION_PRESS
        controller.sendKey(keyEvent)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        controller.sendKey(keyEvent)
    }

    private func sendComposeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let targetController: GhosttySurfaceController?
        if let targetID = composeOverlayTargetSurfaceID,
           let tab = activeTab,
           let controller = tab.registry.controller(for: targetID) {
            targetController = controller
        } else {
            targetController = focusedController
        }

        guard let controller = targetController else { return false }

        // Check if the target is an AI agent (same detection as sendReviewToAgent)
        let isAgent = activeTab.map { tab -> Bool in
            guard case .terminal = tab.content else { return false }
            let title = tab.title
            return title.localizedCaseInsensitiveContains("claude") ||
                   title.localizedCaseInsensitiveContains("codex")
        } ?? false

        controller.sendText(text)

        if isAgent {
            // AI agent: confirm paste then submit, with timing delays
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.sendEnterKey(to: controller)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.sendEnterKey(to: controller)
                }
            }
        } else {
            // Regular terminal: single Enter, immediate
            sendEnterKey(to: controller)
        }
        return true
    }

    // MARK: - Split Operations

    private func handleDividerDrag(leafID: UUID, delta: Double, direction: SplitDirection) {
        guard let tab = activeTab, let contentView = window?.contentView else { return }
        tab.splitTree = tab.splitTree.resize(
            node: leafID,
            by: delta,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        splitContainerView?.updateLayout(tree: tab.splitTree)
    }

    private func registerNotificationObservers() {
        let center = NotificationCenter.default

        center.addObserver(self, selector: #selector(handleNewSplitNotification(_:)),
                           name: .ghosttyNewSplit, object: nil)
        center.addObserver(self, selector: #selector(handleCloseSurfaceNotification(_:)),
                           name: .ghosttyCloseSurface, object: nil)
        center.addObserver(self, selector: #selector(handleGotoSplitNotification(_:)),
                           name: .ghosttyGotoSplit, object: nil)
        center.addObserver(self, selector: #selector(handleResizeSplitNotification(_:)),
                           name: .ghosttyResizeSplit, object: nil)
        center.addObserver(self, selector: #selector(handleEqualizeSplitsNotification(_:)),
                           name: .ghosttyEqualizeSplits, object: nil)
        center.addObserver(self, selector: #selector(handleSetTitleNotification(_:)),
                           name: .ghosttySetTitle, object: nil)
        center.addObserver(self, selector: #selector(handleSetPwdNotification(_:)),
                           name: .ghosttySetPwd, object: nil)
        center.addObserver(self, selector: #selector(handleDesktopNotification(_:)),
                           name: .ghosttyDesktopNotification, object: nil)
        center.addObserver(self, selector: #selector(handleGotoTabNotification(_:)),
                           name: .ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(handleConfirmClipboardNotification(_:)),
                           name: .ghosttyConfirmClipboard, object: nil)
        center.addObserver(self, selector: #selector(handleIPCEnableNotification(_:)),
                           name: .calyxIPCEnable, object: nil)
        center.addObserver(self, selector: #selector(handleIPCDisableNotification(_:)),
                           name: .calyxIPCDisable, object: nil)
        center.addObserver(self, selector: #selector(handleIPCLaunchWorkflowNotification(_:)),
                           name: .calyxIPCLaunchWorkflow, object: nil)
        center.addObserver(self, selector: #selector(handleIPCReviewRequestedNotification(_:)),
                           name: .calyxIPCReviewRequested, object: nil)
        center.addObserver(self, selector: #selector(handleCloseTabNotification(_:)),
                           name: .ghosttyCloseTab, object: nil)
        center.addObserver(self, selector: #selector(handleCloseWindowNotification(_:)),
                           name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(handleToggleFullscreenNotification(_:)),
                           name: .ghosttyToggleFullscreen, object: nil)
        center.addObserver(self, selector: #selector(handleRingBellNotification(_:)),
                           name: .ghosttyRingBell, object: nil)
        center.addObserver(self, selector: #selector(handleShowChildExitedNotification(_:)),
                           name: .ghosttyShowChildExited, object: nil)
        center.addObserver(self, selector: #selector(handleRendererHealthNotification(_:)),
                           name: .ghosttyRendererHealth, object: nil)
        center.addObserver(self, selector: #selector(handleColorChangeNotification(_:)),
                           name: .ghosttyColorChange, object: nil)
        center.addObserver(self, selector: #selector(handleInitialSizeNotification(_:)),
                           name: .ghosttyInitialSize, object: nil)
        center.addObserver(self, selector: #selector(handleSizeLimitNotification(_:)),
                           name: .ghosttySizeLimit, object: nil)
    }

    // MARK: - Notification Handlers

    @objc private func handleNewSplitNotification(_ notification: Notification) {
        guard let event = GhosttyNewSplitEvent.from(notification) else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: event.surfaceView) else { return }
        guard belongsToThisWindow(event.surfaceView) else { return }

        guard let app = GhosttyAppController.shared.app else { return }

        let splitDir: SplitDirection
        switch event.direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
            splitDir = .horizontal
        case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP:
            splitDir = .vertical
        default:
            splitDir = .horizontal
        }

        var config: ghostty_surface_config_s = event.inheritedConfig ?? GhosttyFFI.surfaceConfigNew()
        if let window = self.window {
            config.scale_factor = Double(window.backingScaleFactor)
        }

        guard let newSurfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create split surface")
            return
        }
        invalidateSurfaceToTab()

        let (newTree, _) = tab.splitTree.insert(at: surfaceID, direction: splitDir, newID: newSurfaceID)
        tab.splitTree = newTree

        splitContainerView?.updateLayout(tree: tab.splitTree)

        if let newView = tab.registry.view(for: newSurfaceID) {
            window?.makeFirstResponder(newView)
        }
    }

    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let event = GhosttyCloseSurfaceEvent.from(notification) else { return }

        // Find the tab that owns this surface (may be a background tab)
        guard let (owningTab, owningGroup) = findTab(for: event.surfaceView) else { return }
        guard let surfaceID = owningTab.registry.id(for: event.surfaceView) else { return }

        // Surface-level cleanup: update split tree and destroy surface
        let (newTree, focusTarget) = owningTab.splitTree.remove(surfaceID)
        owningTab.registry.destroySurface(surfaceID)
        owningTab.splitTree = newTree
        invalidateSurfaceToTab()

        // If closeTab is handling this tab, skip tab removal (closeTab will do it)
        if closingTabIDs.contains(owningTab.id) {
            return
        }

        // Below runs only for process-initiated closes (e.g. `exit` command)
        if owningTab.splitTree.isEmpty {
            let wasActiveTab = (owningTab.id == activeTab?.id)
            let result = windowSession.removeTab(id: owningTab.id, fromGroup: owningGroup.id)
            if wasActiveTab {
                switch result {
                case .switchedTab, .switchedGroup:
                    activateCurrentTab()
                case .windowShouldClose:
                    window?.close()
                }
            }
            requestSave()
            return
        }

        if owningTab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: owningTab.splitTree)
            if let focusID = focusTarget, let focusView = owningTab.registry.view(for: focusID) {
                window?.makeFirstResponder(focusView)
            }
            requestSave()
        }
    }

    @objc private func handleGotoSplitNotification(_ notification: Notification) {
        guard let event = GhosttyGotoSplitEvent.from(notification) else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: event.surfaceView) else { return }
        guard belongsToThisWindow(event.surfaceView) else { return }

        let focusDir: FocusDirection
        switch event.direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: focusDir = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: focusDir = .next
        case GHOSTTY_GOTO_SPLIT_LEFT: focusDir = .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: focusDir = .spatial(.right)
        case GHOSTTY_GOTO_SPLIT_UP: focusDir = .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: focusDir = .spatial(.down)
        default: focusDir = .next
        }

        guard let targetID = tab.splitTree.focusTarget(for: focusDir, from: surfaceID) else { return }
        tab.splitTree.focusedLeafID = targetID

        if let targetView = tab.registry.view(for: targetID) {
            window?.makeFirstResponder(targetView)
        }
    }

    @objc private func handleResizeSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let contentView = window?.contentView else { return }

        guard let resize = notification.userInfo?["resize"] as? ghostty_action_resize_split_s else { return }

        let direction: SplitDirection
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT, GHOSTTY_RESIZE_SPLIT_RIGHT:
            direction = .horizontal
        case GHOSTTY_RESIZE_SPLIT_UP, GHOSTTY_RESIZE_SPLIT_DOWN:
            direction = .vertical
        default:
            direction = .horizontal
        }

        let sign: Double
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_RIGHT, GHOSTTY_RESIZE_SPLIT_DOWN:
            sign = 1.0
        default:
            sign = -1.0
        }

        let amount = Double(resize.amount) * sign
        tab.splitTree = tab.splitTree.resize(
            node: surfaceID,
            by: amount,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        splitContainerView?.updateLayout(tree: tab.splitTree)
    }

    @objc private func handleEqualizeSplitsNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }

        guard let tab = activeTab else { return }
        tab.splitTree = tab.splitTree.equalize()
        splitContainerView?.updateLayout(tree: tab.splitTree)
    }

    @objc private func handleSetTitleNotification(_ notification: Notification) {
        guard let event = GhosttySetTitleEvent.from(notification) else { return }
        guard belongsToThisWindow(event.surfaceView) else { return }
        guard let tab = activeTab else { return }

        if let focusedID = tab.splitTree.focusedLeafID,
           let focusedView = tab.registry.view(for: focusedID),
           focusedView === event.surfaceView,
           tab.title != event.title {
            window?.title = event.title
            tab.title = event.title
        }
    }

    @objc private func handleSetPwdNotification(_ notification: Notification) {
        guard let event = GhosttySetPwdEvent.from(notification) else { return }
        guard belongsToThisWindow(event.surfaceView) else { return }
        guard let (owningTab, _) = findTab(for: event.surfaceView) else { return }
        guard owningTab.pwd != event.pwd else { return }
        owningTab.pwd = event.pwd
        requestSave()
    }

    @objc private func handleGotoTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        guard let rawValue = notification.userInfo?["tab"] as? Int32 else { return }

        switch rawValue {
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            selectNextTab(nil)
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            selectPreviousTab(nil)
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            let lastIndex = (windowSession.activeGroup?.tabs.count ?? 1) - 1
            selectTabByIndex(lastIndex)
        default:
            if rawValue >= 0 {
                selectTabByIndex(Int(rawValue))
            }
        }
    }

    @objc private func handleConfirmClipboardNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let userInfo = notification.userInfo else { return }
        guard let contents = userInfo["contents"] as? String else { return }
        guard let surface = userInfo["surface"] as? ghostty_surface_t else { return }
        guard let requestRaw = userInfo["request"] as? ghostty_clipboard_request_e else { return }
        guard let request = ClipboardRequest.from(requestRaw) else { return }
        let state = userInfo["state"] as? UnsafeMutableRawPointer

        let controller = ClipboardConfirmationController(
            surface: surface,
            contents: contents,
            request: request,
            state: state
        )
        self.clipboardConfirmationController = controller

        guard let parentWindow = window, let sheet = controller.window else {
            // Cannot present confirmation UI; cancel the paste to avoid hanging.
            // Pass empty string with confirmed=true to avoid re-triggering unsafe paste detection.
            "".withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: state, confirmed: true)
            }
            return
        }
        parentWindow.beginSheet(sheet) { [weak self] _ in
            self?.clipboardConfirmationController = nil
        }
    }

    @objc private func handleDesktopNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        let body = notification.userInfo?["body"] as? String ?? ""

        let isActiveAndVisible = owningTab.id == activeTab?.id && (window?.isKeyWindow ?? false)
        guard !isActiveAndVisible else { return }

        let isFirstUnread = owningTab.unreadNotifications == 0
        owningTab.unreadNotifications += 1
        owningTab.lastNotificationTime = Date()

        NotificationManager.shared.sendNotification(title: title, body: body, tabID: owningTab.id)

        if isFirstUnread {
            NotificationManager.shared.bounceDockIcon()
        }
    }

    @objc private func handleCloseTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (tab, group) = findTab(for: surfaceView) else { return }
        let mode = notification.userInfo?["mode"] as? ghostty_action_close_tab_mode_e
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            // Close all tabs in the group except the one containing this surface
            let otherIDs = group.tabs.filter { $0.id != tab.id }.map { $0.id }
            otherIDs.forEach { closeTab(id: $0) }
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            // Close all tabs to the right of this tab in the group
            if let index = group.tabs.firstIndex(where: { $0.id == tab.id }) {
                let rightIDs = group.tabs[group.tabs.index(after: index)...].map { $0.id }
                rightIDs.forEach { closeTab(id: $0) }
            }
        default:
            // GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS or unknown
            closeTab(id: tab.id)
        }
    }

    @objc private func handleCloseWindowNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard findTab(for: surfaceView) != nil else { return }
        }
        window?.close()
    }

    @objc private func handleToggleFullscreenNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        window?.toggleFullScreen(nil)
    }

    @objc private func handleRingBellNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        NSSound.beep()
    }

    @objc private func handleShowChildExitedNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (tab, _) = findTab(for: surfaceView) else { return }
        let exitCode = notification.userInfo?["exit_code"] as? UInt32 ?? 0
        logger.info("[ChildExited] tab \(tab.id) exit_code=\(exitCode) — surface will close via ghosttyCloseSurface")
    }

    @objc private func handleRendererHealthNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        logger.warning("[RendererHealth] health changed for surface \(String(describing: ObjectIdentifier(surfaceView)))")
    }

    @objc private func handleColorChangeNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        // Color changes sync the terminal background color to the window.
        // Full implementation pending theme integration.
        logger.debug("[ColorChange] received for surface \(String(describing: ObjectIdentifier(surfaceView)))")
    }

    @objc private func handleInitialSizeNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let width = notification.userInfo?["width"] as? UInt32,
              let height = notification.userInfo?["height"] as? UInt32 else { return }
        // width/height are in cells; pixel resize requires cell size from SurfaceView.
        logger.debug("[InitialSize] requested \(width)×\(height) cells")
    }

    @objc private func handleSizeLimitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        // Size limits are in cells; pixel conversion requires cell size from SurfaceView.
        logger.debug("[SizeLimit] received for surface \(String(describing: ObjectIdentifier(surfaceView)))")
    }

    func applyCurrentGhosttyConfig() {
        guard let config = GhosttyAppController.shared.configManager.config else { return }

        for group in windowSession.groups {
            for tab in group.tabs {
                tab.registry.applyConfig(config)
            }
        }
    }

    // MARK: - Menu Actions

    @objc func jumpToMostRecentUnreadTab() {
        var mostRecentTab: Tab?
        var mostRecentTime: Date?

        for group in windowSession.groups {
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(jumpToMostRecentUnreadTab) {
            return windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }
        return true
    }

    @objc func newTab(_ sender: Any?) {
        createNewTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tab = activeTab else { return }
        closeTab(id: tab.id)
    }

    @objc func newBrowserTab(_ sender: Any?) {
        promptAndOpenBrowserTab()
    }

    @objc func selectNextTab(_ sender: Any?) {
        deactivateCurrentTab()
        windowSession.nextTab()
        activateCurrentTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        deactivateCurrentTab()
        windowSession.previousTab()
        activateCurrentTab()
    }

    @objc func selectTab1(_ sender: Any?) { selectTabByIndex(0) }
    @objc func selectTab2(_ sender: Any?) { selectTabByIndex(1) }
    @objc func selectTab3(_ sender: Any?) { selectTabByIndex(2) }
    @objc func selectTab4(_ sender: Any?) { selectTabByIndex(3) }
    @objc func selectTab5(_ sender: Any?) { selectTabByIndex(4) }
    @objc func selectTab6(_ sender: Any?) { selectTabByIndex(5) }
    @objc func selectTab7(_ sender: Any?) { selectTabByIndex(6) }
    @objc func selectTab8(_ sender: Any?) { selectTabByIndex(7) }
    @objc func selectTab9(_ sender: Any?) { selectTabByIndex(8) }

    func selectTab(at index: Int) {
        selectTabByIndex(index)
    }

    private func selectTabByIndex(_ index: Int) {
        guard index >= 0 else { return }
        deactivateCurrentTab()
        windowSession.selectTab(at: index)
        activateCurrentTab()
    }

    // MARK: - Session Persistence

    func activateRestoredSession() {
        isRestoring = false
        // Pause all non-active terminal tabs
        for group in windowSession.groups {
            for tab in group.tabs {
                if tab.id != windowSession.activeGroup?.activeTabID {
                    if case .terminal = tab.content {
                        tab.registry.pauseAll()
                    }
                }
            }
        }
        activateCurrentTab()
    }

    func windowSnapshot() -> WindowSnapshot {
        let frame = window?.frame ?? .zero
        let groups = windowSession.groups.map { group in
            let tabs = group.tabs.compactMap { tab -> TabSnapshot? in
                // Skip diff tabs — they are not persisted
                if case .diff = tab.content { return nil }
                let browserURL: URL?
                switch tab.content {
                case .terminal:
                    browserURL = nil
                case .browser(let configuredURL):
                    browserURL = browserControllers[tab.id]?.browserState.url ?? configuredURL
                case .diff:
                    return nil  // Already handled above, but needed for exhaustive switch
                }
                return TabSnapshot(
                    id: tab.id,
                    title: tab.title,
                    pwd: tab.pwd,
                    splitTree: tab.splitTree,
                    browserURL: browserURL
                )
            }
            return TabGroupSnapshot(
                id: group.id,
                name: group.name,
                color: group.color.rawValue,
                tabs: tabs,
                activeTabID: group.activeTabID,
                isCollapsed: group.isCollapsed
            )
        }
        return WindowSnapshot(
            id: windowSession.id,
            frame: frame,
            groups: groups,
            activeGroupID: windowSession.activeGroupID,
            showSidebar: windowSession.showSidebar,
            sidebarWidth: windowSession.sidebarWidth
        )
    }

    private func requestSave() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.requestSave()
        }
    }

    // MARK: - Helpers

    private func cleanupTabResources(id tabID: UUID) {
        browserControllers.removeValue(forKey: tabID)
        reviewController.cleanupTab(id: tabID)
    }

    private func belongsToThisWindow(_ view: NSView) -> Bool {
        view.window === self.window
    }

    private func invalidateSurfaceToTab() {
        surfaceToTabDirty = true
    }

    private func findTab(for surfaceView: SurfaceView) -> (Tab, TabGroup)? {
        guard let surfaceID = surfaceView.surfaceController?.id else { return nil }
        if surfaceToTabDirty {
            surfaceToTab.removeAll(keepingCapacity: true)
            for group in windowSession.groups {
                for tab in group.tabs {
                    for id in tab.registry.allIDs {
                        surfaceToTab[id] = (tab, group)
                    }
                }
            }
            surfaceToTabDirty = false
        }
        return surfaceToTab[surfaceID]
    }

    private var focusedController: GhosttySurfaceController? {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID else { return nil }
        return tab.registry.controller(for: focusedID)
    }

    /// Exposes the focused surface controller for UI testing only.
    var focusedControllerForTesting: GhosttySurfaceController? {
        focusedController
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(true)
        if case .browser = activeTab?.content {
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        } else if case .diff = activeTab?.content {
            // No special focus needed for diff tabs
        } else {
            // Unocclude all active tab surfaces in case windowDidChangeOcclusionState fired
            // with occluded=true during window setup before the surfaces were fully presented.
            activeTab?.registry.resumeAll()
            focusedController?.setFocus(true)
            focusManager.restoreFocus(window: window, tab: activeTab, splitContainerView: splitContainerView)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(false)
        focusedController?.setFocus(false)
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.closingWouldTerminate(self),
           !SettingsWindowController.shared.confirmTermination() {
            return false
        }
        return true
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = self.window, let tab = activeTab else { return }
        let occluded = !window.occlusionState.contains(.visible)
        for id in tab.registry.allIDs {
            tab.registry.controller(for: id)?.setOcclusion(occluded)
        }
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window, let tab = activeTab else { return }
        let scale = window.backingScaleFactor
        for id in tab.registry.allIDs {
            tab.registry.controller(for: id)?.setContentScale(scale)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.isClosingLastManagedWindow(self) {
            // Persist current session before this final window is removed from AppDelegate.
            appDelegate.saveImmediately()
        }

        // Mark all tabs as closing to prevent notification handler interference
        for group in windowSession.groups {
            for tab in group.tabs {
                closingTabIDs.insert(tab.id)
            }
        }

        // Destroy all surfaces in all tabs
        for group in windowSession.groups {
            for tab in group.tabs {
                for id in tab.registry.allIDs {
                    tab.registry.destroySurface(id)
                }
            }
        }

        browserControllers.removeAll()
        reviewController.cancelAll()
        gitController.cancelAll()

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // SplitContainerView handles resize via autoresizingMask + resizeSubviews
    }

    // MARK: - Git Source Control

    private func openDiffTab(source: DiffSource) {
        // Dedup: check if same source already open
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                if case .diff(let existingSource) = tab.content, existingSource == source {
                    switchToTab(id: tab.id)
                    return
                }
            }
        }

        guard let group = windowSession.activeGroup else { return }

        let fileName: String
        switch source {
        case .unstaged(let path, _), .staged(let path, _), .commit(_, let path, _), .untracked(let path, _):
            fileName = (path as NSString).lastPathComponent
        }

        let tab = Tab(title: fileName, content: .diff(source: source))
        deactivateCurrentTab()
        group.addTab(tab)
        group.activeTabID = tab.id

        reviewController.loadDiff(tabID: tab.id, source: source)
        refreshHostingView()
    }

    // MARK: - IPC

    private func enableIPC() {
        do {
            let token = SecurityUtils.generateHexToken()

            // Start server first to get the port
            try mcpServer.start(token: token)
            let port = mcpServer.port

            // Write config to all available agent tools
            let result = IPCConfigManager.enableIPC(port: port, token: token)

            if !result.anySucceeded {
                mcpServer.stop()
                showIPCAlert(
                    title: "IPC Error",
                    message: "MCP server running on port \(port).\nNo agent configs found. Configure manually if needed."
                )
                return
            }

            UserDefaults.standard.set(true, forKey: "calyx.ipcAutoStart")
            IPCAgentState.shared.startPolling()
            showIPCAlert(
                title: "IPC Enabled",
                message: "MCP server running on port \(port).\n\(configStatusMessage(result))\nRestart agent instances to connect."
            )
        } catch {
            showIPCAlert(title: "IPC Error", message: error.localizedDescription)
        }
    }

    private func disableIPC() {
        UserDefaults.standard.set(false, forKey: "calyx.ipcAutoStart")
        mcpServer.stop()
        IPCAgentState.shared.stopPolling()
        IPCAgentState.shared.clearLog()
        let result = IPCConfigManager.disableIPC()
        showIPCAlert(
            title: "IPC Disabled",
            message: "MCP server stopped.\n\(configStatusMessage(result))"
        )
    }

    private func configStatusMessage(_ result: IPCConfigResult) -> String {
        func label(_ status: ConfigStatus, name: String) -> String {
            switch status {
            case .success:
                return "\(name): configured"
            case .skipped(let reason):
                return "\(name): \(reason) (skipped)"
            case .failed(let error):
                return "\(name): error - \(error.localizedDescription)"
            }
        }
        return [
            label(result.claudeCode, name: "Claude Code"),
            label(result.codex, name: "Codex")
        ].joined(separator: "\n")
    }

    // MARK: - IPC Notification Handlers

    @objc private func handleIPCEnableNotification(_ notification: Notification) {
        enableIPC()
    }

    @objc private func handleIPCDisableNotification(_ notification: Notification) {
        disableIPC()
    }

    @objc private func handleIPCReviewRequestedNotification(_ notification: Notification) {
        windowSession.sidebarMode = .changes
        windowSession.showSidebar = true
        gitController.refreshGitStatus()
    }

    @objc private func handleIPCLaunchWorkflowNotification(_ notification: Notification) {
        guard let roleNames = notification.userInfo?["roleNames"] as? [String], !roleNames.isEmpty else { return }
        let autoStart = (notification.userInfo?["autoStart"] as? Bool) ?? false
        let sessionName = (notification.userInfo?["sessionName"] as? String) ?? ""
        let initialTask = (notification.userInfo?["initialTask"] as? String) ?? ""
        let port = mcpServer.port

        // Show folder picker before creating any tabs
        let panel = NSOpenPanel()
        panel.title = "Choose Session Directory"
        panel.message = "All agent tabs will open in this folder."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        // Default to the current tab's working directory if available
        if let tabPwd = activeTab?.pwd {
            panel.directoryURL = URL(fileURLWithPath: tabPwd)
        }

        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        let pwd = chosenURL.path

        // Record workflow for "Rejoin Session"
        IPCAgentState.shared.lastWorkflow = roleNames

        // Name the active group if a session name was provided
        if !sessionName.isEmpty {
            windowSession.activeGroup?.name = sessionName
        }

        // Create all tabs and capture references before any async work
        var createdTabs: [Tab] = []
        for roleName in roleNames {
            createNewTab(pwd: pwd)
            if let newTab = windowSession.activeGroup?.tabs.last {
                newTab.title = roleName
                createdTabs.append(newTab)
            }
        }

        // Broadcast initial task to all agents once they should be registered
        if !initialTask.isEmpty && autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                Task { @MainActor in
                    await self.mcpServer.ensureAppPeerRegistered()
                    guard let appPeerID = self.mcpServer.appPeerID else { return }
                    _ = try? await self.mcpServer.store.broadcast(
                        from: appPeerID,
                        content: initialTask,
                        topic: "task"
                    )
                }
            }
        }

        guard autoStart, createdTabs.count == roleNames.count else { return }

        for (index, (tab, roleName)) in zip(createdTabs, roleNames).enumerated() {
            let baseDelay = Double(index) * 0.15  // slight stagger so shells init independently

            // Step 1: start claude once the shell is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay + 0.8) { [weak self] in
                guard let self,
                      let leafID = tab.splitTree.focusedLeafID,
                      let controller = tab.registry.controller(for: leafID) else { return }
                controller.sendText("claude")
                self.sendEnterKey(to: controller)

                // Step 2: send role context after claude has initialised
                let prompt = AgentWorkflow.rolePrompt(roleName: roleName, allRoles: roleNames, port: port)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self,
                          let leafID = tab.splitTree.focusedLeafID,
                          let controller = tab.registry.controller(for: leafID) else { return }
                    controller.sendText(prompt)
                    // Two enters: first confirms claude's paste dialog, second submits
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        self.sendEnterKey(to: controller)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.sendEnterKey(to: controller)
                        }
                    }
                }
            }
        }
    }

    private func sendReviewToAgent(_ payload: String) -> ReviewSendResult {
        // Find terminal tabs running Claude Code (title contains "claude" or "codex")
        let agentTabs = windowSession.groups.flatMap(\.tabs).filter {
            guard case .terminal = $0.content else { return false }
            let title = $0.title
            return title.localizedCaseInsensitiveContains("claude") ||
                   title.localizedCaseInsensitiveContains("codex")
        }

        guard !agentTabs.isEmpty else {
            showIPCAlert(title: "No AI Agent", message: "No terminal tabs running Claude Code or Codex found. Start an AI agent first.")
            return .failed
        }

        // Select target tab
        let targetTab: Tab
        if agentTabs.count == 1 {
            targetTab = agentTabs[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Select Claude Code Tab"
            alert.informativeText = "Choose which Claude Code instance to send the review to:"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            for (i, tab) in agentTabs.enumerated() {
                let groupName = windowSession.groups.first { $0.tabs.contains { $0.id == tab.id } }?.name ?? ""
                let label = "\(tab.title) — \(groupName) (#\(i + 1))"
                popup.addItem(withTitle: label)
            }
            alert.accessoryView = popup

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return .cancelled }

            let selectedIndex = popup.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < agentTabs.count else { return .failed }
            targetTab = agentTabs[selectedIndex]
        }

        // Send review text to terminal PTY via ghostty surface
        guard let focusedID = targetTab.splitTree.focusedLeafID,
              let controller = targetTab.registry.controller(for: focusedID) else {
            showIPCAlert(title: "Send Failed", message: "Could not access terminal surface.")
            return .failed
        }

        controller.sendText(payload)
        // Send Enter twice: first to confirm paste, second to submit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendEnterKey(to: controller)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.sendEnterKey(to: controller)
            }
        }

        // Switch to the target terminal tab
        switchToTab(id: targetTab.id)

        return .sent
    }

    private func showIPCAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}
