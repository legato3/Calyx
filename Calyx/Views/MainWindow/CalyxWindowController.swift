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
    private let focusManager = FocusManager()
    private let windowActions = WindowActions()
    private var isRestoring = false
    private let browserManager = BrowserManager()
    private let gitController: GitController
    private let reviewController: ReviewController
    private var clipboardConfirmationController: ClipboardConfirmationController?
    private let composeController = ComposeOverlayController()
    private let windowViewState = WindowViewState()
    let mcpServer: CalyxMCPServer
    private let splitController: SplitController
    private let tabController: TabLifecycleController
    private let ipcController: IPCWindowController

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
        guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }) else { return nil }
        return browserManager.controller(for: tabID, tab: tab)
    }

    func browserController(forExternal tabID: UUID) -> BrowserTabController? {
        browserController(for: tabID)
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
        let rc = ReviewController(windowSession: windowSession)
        self.reviewController = rc
        self.splitController = SplitController(window: window)
        self.tabController = TabLifecycleController(
            windowSession: windowSession,
            reviewController: rc,
            browserManager: self.browserManager,
            focusManager: self.focusManager
        )
        self.ipcController = IPCWindowController(mcpServer: mcpServer, windowSession: windowSession)
        super.init(window: window)

        // SplitController callbacks
        splitController.getActiveTab = { [weak self] in self?.activeTab }
        splitController.getSplitContainerView = { [weak self] in self?.splitContainerView }
        splitController.onSurfaceCreated = { [weak self] in self?.invalidateSurfaceToTab() }

        // TabLifecycleController callbacks
        tabController.onActivateCurrentTab = { [weak self] in self?.activateCurrentTab() }
        tabController.onDeactivateCurrentTab = { [weak self] in self?.deactivateCurrentTab() }
        tabController.onRefreshHostingView = { [weak self] in self?.refreshHostingView() }
        tabController.onRebuildSplitContainerAndLayout = { [weak self] in
            self?.rebuildSplitContainer()
            self?.updateLayout()
        }
        tabController.onInvalidateSurfaceToTab = { [weak self] in self?.invalidateSurfaceToTab() }
        tabController.onRequestSave = { [weak self] in self?.requestSave() }
        tabController.onCloseWindow = { [weak self] in self?.window?.close() }
        tabController.onRetargetComposeOverlay = { [weak self] in self?.retargetComposeOverlayIfNeeded() }
        tabController.onDismissComposeOverlay = { [weak self] in self?.dismissComposeOverlay() }
        tabController.getWindow = { [weak self] in self?.window }
        tabController.getSplitContainerView = { [weak self] in self?.splitContainerView }

        // IPCWindowController callbacks
        ipcController.onCreateNewTab = { [weak self] pwd in self?.createNewTab(pwd: pwd) }
        ipcController.onSwitchToTab = { [weak self] id in self?.switchToTab(id: id) }
        ipcController.onSendEnterKey = { [weak self] controller in self?.sendEnterKey(to: controller) }
        ipcController.getActiveTabPwd = { [weak self] in self?.activeTab?.pwd }
        ipcController.onShowGitSidebar = { [weak self] in self?.gitController.refreshGitStatus() }

        gitController.onOpenDiff = { [weak self] source in self?.openDiffTab(source: source) }
        reviewController.onDiffStateChanged = { [weak self] in self?.refreshHostingView() }
        reviewController.onReviewChanged = { [weak self] in
            self?.windowViewState.reviewCommentGeneration += 1
            self?.updateViewState()
        }
        reviewController.sendToAgent = { [weak self] payload in
            self?.ipcController.sendToAgent(payload) ?? .failed
        }
        window.delegate = self
        window.center()
        setupShortcutManager()
        setupCommandRegistry()
        setupUI()
        if !restoring { setupTerminalSurface() }
        registerNotificationObservers()
        focusManager.onFocusFailed = { [weak self] in
            self?.splitContainerView?.focusLostIndicator = true
        }
        focusManager.onFocusRestored = { [weak self] in
            self?.splitContainerView?.focusLostIndicator = false
        }
        browserManager.onSaveRequested = { [weak self] in
            self?.requestSave()
        }
        TerminalControlBridge.shared.delegate = self
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
        commandRegistry.register(Command(id: "checkpoint.now", title: "Checkpoint Now", category: "Git") { [weak self] in
            guard let self else { return }
            Task {
                let pwd = await self.activeTabPwd
                await CheckpointManager.shared.checkpoint(workDir: pwd ?? FileManager.default.currentDirectoryPath)
            }
        })
        commandRegistry.register(Command(
            id: "checkpoint.toggle",
            title: "Enable Auto-Checkpoint",
            category: "Git",
            isAvailable: { !CheckpointManager.shared.isEnabled }
        ) {
            CheckpointManager.shared.isEnabled = true
        })
        commandRegistry.register(Command(
            id: "checkpoint.toggleOff",
            title: "Disable Auto-Checkpoint",
            category: "Git",
            isAvailable: { CheckpointManager.shared.isEnabled }
        ) {
            CheckpointManager.shared.isEnabled = false
        })
        commandRegistry.register(Command(id: "ipc.enable", title: "Enable AI Agent IPC", category: "IPC", isAvailable: { [weak self] in
            !(self?.mcpServer.isRunning ?? false)
        }) { [weak self] in
            self?.ipcController.enableIPC()
        })
        commandRegistry.register(Command(id: "ipc.disable", title: "Disable AI Agent IPC", category: "IPC", isAvailable: { [weak self] in
            self?.mcpServer.isRunning ?? false
        }) { [weak self] in
            self?.ipcController.disableIPC()
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

        commandRegistry.register(Command(
            id: "shell.restart",
            title: "Restart Shell",
            category: "Terminal",
            isAvailable: { [weak self] in self?.activeTab?.processExited == true },
            handler: { [weak self] in
                guard let self,
                      let tab = activeTab else { return }
                let pwd = tab.pwd
                tabController.closeTab(id: tab.id)
                tabController.createNewTab(pwd: pwd)
            }
        ))

        // Broadcast input toggle
        commandRegistry.register(Command(
            id: "split.broadcastInput",
            title: "Toggle Broadcast Input to All Panes",
            category: "Splits",
            isAvailable: { [weak self] in
                guard let tab = self?.activeTab else { return false }
                return tab.splitTree.allLeafIDs().count > 1
            },
            handler: { [weak self] in
                guard let self, let tab = activeTab else { return }
                tab.broadcastInputEnabled.toggle()
                // Keep compose broadcast in sync with pane broadcast state
                composeController.broadcastEnabled = tab.broadcastInputEnabled
                windowActions.composeBroadcastEnabled = tab.broadcastInputEnabled
            }
        ))

        // Workspace commands
        commandRegistry.register(Command(
            id: "workspace.save",
            title: "Save Workspace As…",
            category: "Workspaces",
            handler: { [weak self] in self?.promptSaveWorkspace() }
        ))

        for name in WorkspaceManager.list() {
            commandRegistry.register(Command(
                id: "workspace.load.\(name)",
                title: "Load Workspace: \(name)",
                category: "Workspaces",
                handler: { [weak self] in self?.loadWorkspace(name: name) }
            ))
            commandRegistry.register(Command(
                id: "workspace.delete.\(name)",
                title: "Delete Workspace: \(name)",
                category: "Workspaces",
                handler: { [weak self] in try? WorkspaceManager.delete(name: name) }
            ))
        }

        refreshPromptCommands()
    }

    // MARK: - Prompt Library

    private func refreshPromptCommands() {
        // Remove any previously-registered prompt commands before re-registering.
        commandRegistry.unregisterAll(withPrefix: "prompt.")

        commandRegistry.register(Command(
            id: "prompt.save_as",
            title: "Save Prompt As…",
            category: "Prompts",
            handler: { [weak self] in self?.promptSavePrompt() }
        ))

        for entry in PromptLibraryManager.all() {
            let id = entry.id
            let content = entry.content
            commandRegistry.register(Command(
                id: "prompt.inject.\(id)",
                title: "Prompt: \(entry.title)",
                category: "Prompts",
                isAvailable: { [weak self] in self?.focusedController != nil },
                handler: { [weak self] in
                    self?.focusedController?.sendText(content)
                }
            ))
            commandRegistry.register(Command(
                id: "prompt.delete.\(id)",
                title: "Delete Prompt: \(entry.title)",
                category: "Prompts",
                handler: { [weak self] in
                    PromptLibraryManager.delete(id: id)
                    self?.refreshPromptCommands()
                }
            ))
        }
    }

    private func promptSavePrompt() {
        // Build a stacked accessory view: name field on top, content text view below.
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        nameField.placeholderString = "Prompt name…"

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let contentView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        contentView.isEditable = true
        contentView.isRichText = false
        contentView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        contentView.string = NSPasteboard.general.string(forType: .string) ?? ""
        scrollView.documentView = contentView

        let stack = NSStackView(views: [nameField, scrollView])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 130)

        let alert = NSAlert()
        alert.messageText = "Save Prompt"
        alert.informativeText = "Enter a name and the prompt content to save:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let content = contentView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !content.isEmpty else { return }

        let entry = PromptEntry(id: UUID(), title: name, content: content, createdAt: Date())
        PromptLibraryManager.save(entry)
        refreshPromptCommands()
    }

    private func promptSaveWorkspace() {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Enter a name for this workspace:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        input.placeholderString = "My Workspace"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        guard let snapshot = windowSnapshot() else { return }
        do {
            try WorkspaceManager.save(snapshot, name: name)
        } catch {
            let err = NSAlert(error: error)
            err.runModal()
        }
    }

    private func loadWorkspace(name: String) {
        guard let snapshot = WorkspaceManager.load(name: name) else {
            let a = NSAlert()
            a.messageText = "Workspace Not Found"
            a.informativeText = "The workspace '\(name)' could not be loaded."
            a.runModal()
            return
        }
        (NSApp.delegate as? AppDelegate)?.openWorkspace(snapshot)
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
        windowActions.onRollbackToCheckpoint = { [weak self] commit in self?.confirmAndRollbackToCheckpoint(commit) }
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
        windowActions.onToggleComposeBroadcast = { [weak self] in
            guard let self else { return }
            composeController.broadcastEnabled.toggle()
            windowActions.composeBroadcastEnabled = composeController.broadcastEnabled
        }
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
        container.broadcastInputIndicator = tab.broadcastInputEnabled
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
        tabController.createNewTab(inheritedConfig: inheritedConfig, pwd: pwd)
    }

    func createBrowserTab(url: URL) {
        tabController.createBrowserTab(url: url)
    }

    func promptAndOpenBrowserTab() {
        tabController.promptAndOpenBrowserTab()
    }

    private func closeTab(id tabID: UUID) {
        tabController.closeTab(id: tabID)
    }

    func switchToTab(id tabID: UUID) {
        tabController.switchToTab(id: tabID)
    }

    func switchToGroup(id groupID: UUID) {
        tabController.switchToGroup(id: groupID)
    }

    // MARK: - Group Operations

    func createNewGroup() {
        tabController.createNewGroup()
    }

    private func closeActiveGroup() {
        tabController.closeActiveGroup()
    }

    private func closeAllTabsInGroup(id groupID: UUID) {
        tabController.closeAllTabsInGroup(id: groupID)
    }

    private func switchToNextGroup() {
        tabController.switchToNextGroup()
    }

    private func switchToPreviousGroup() {
        tabController.switchToPreviousGroup()
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
        composeController.toggle(windowSession: windowSession, focusedControllerID: focusedController?.id)
    }

    private func retargetComposeOverlayIfNeeded() {
        composeController.retargetIfNeeded(windowSession: windowSession, focusedControllerID: focusedController?.id)
    }

    private func dismissComposeOverlay() {
        composeController.dismiss(windowSession: windowSession) { [weak self] in
            guard let self, case .terminal = self.activeTab?.content else { return }
            self.focusManager.restoreFocus(window: self.window, tab: self.activeTab, splitContainerView: self.splitContainerView)
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
        composeController.send(
            text,
            activeTab: activeTab,
            focusedController: focusedController,
            sendEnterKey: { [weak self] controller in self?.sendEnterKey(to: controller) }
        )
    }

    // MARK: - Split Operations

    private func handleDividerDrag(leafID: UUID, delta: Double, direction: SplitDirection) {
        splitController.handleDividerDrag(leafID: leafID, delta: delta, direction: direction)
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
        splitController.handleNewSplit(event: event)
    }

    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let event = GhosttyCloseSurfaceEvent.from(notification) else { return }

        // Find the tab that owns this surface (may be a background tab)
        guard let (owningTab, owningGroup) = findTab(for: event.surfaceView) else { return }

        // Surface-level cleanup delegated to SplitController
        let focusTarget = splitController.removeSurface(event.surfaceView, fromTab: owningTab)
        invalidateSurfaceToTab()

        // If closeTab is handling this tab, skip tab removal (closeTab will do it)
        if tabController.closingTabIDs.contains(owningTab.id) {
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
        splitController.handleGotoSplit(event: event)
    }

    @objc private func handleResizeSplitNotification(_ notification: Notification) {
        guard let event = GhosttyResizeSplitEvent.from(notification) else { return }
        splitController.handleResizeSplit(event: event)
    }

    @objc private func handleEqualizeSplitsNotification(_ notification: Notification) {
        splitController.handleEqualizeSplits(surfaceView: notification.object as? SurfaceView)
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
        guard let event = GhosttyGotoTabEvent.from(notification) else { return }
        if let sv = event.surfaceView { guard findTab(for: sv) != nil else { return } }

        switch event.tab {
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
        guard let event = GhosttyConfirmClipboardEvent.from(notification) else { return }
        let surfaceView = event.surfaceView
        guard belongsToThisWindow(surfaceView) else { return }
        guard let request = ClipboardRequest.from(event.request) else { return }
        let contents = event.contents
        let surface = event.surface
        let state = event.state

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
        guard let event = GhosttyDesktopNotificationEvent.from(notification) else { return }
        guard let (owningTab, _) = findTab(for: event.surfaceView) else { return }
        let title = event.title
        let body = event.body

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
        guard let event = GhosttyCloseTabEvent.from(notification) else { return }
        guard let (tab, group) = findTab(for: event.surfaceView) else { return }
        switch event.mode {
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
        guard let event = GhosttyShowChildExitedEvent.from(notification),
              let (tab, _) = findTab(for: event.surfaceView) else { return }
        tab.processExited = true
        tab.lastExitCode = event.exitCode
        if event.exitCode != 0 {
            let seconds = event.runtimeMs / 1000
            NotificationManager.shared.sendNotification(
                title: "Process exited",
                body: "Exit code \(event.exitCode) after \(seconds)s",
                tabID: tab.id
            )
        }
    }

    @objc private func handleRendererHealthNotification(_ notification: Notification) {
        guard let event = GhosttyRendererHealthEvent.from(notification) else { return }
        guard findTab(for: event.surfaceView) != nil else { return }
        logger.warning("[RendererHealth] health=\(event.health.rawValue) for surface \(String(describing: ObjectIdentifier(event.surfaceView)))")
    }

    @objc private func handleColorChangeNotification(_ notification: Notification) {
        guard let event = GhosttyColorChangeEvent.from(notification),
              belongsToThisWindow(event.surfaceView),
              event.change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return }
        let c = event.change
        window?.backgroundColor = NSColor(
            calibratedRed: CGFloat(c.r) / 255,
            green: CGFloat(c.g) / 255,
            blue: CGFloat(c.b) / 255,
            alpha: 1.0
        )
    }

    @objc private func handleInitialSizeNotification(_ notification: Notification) {
        guard let event = GhosttyInitialSizeEvent.from(notification) else { return }
        let surfaceView = event.surfaceView
        guard belongsToThisWindow(surfaceView) else { return }
        guard let window else { return }
        let width = event.width
        let height = event.height

        let cellSize = surfaceView.cachedCellSize
        guard cellSize.width > 0, cellSize.height > 0 else {
            logger.debug("[InitialSize] cell size not yet known, ignoring \(width)×\(height)")
            return
        }

        // Measure chrome and compute target content size
        let contentSize = window.contentView?.bounds.size ?? .zero
        let surfaceSize = surfaceView.bounds.size
        let hChrome = max(contentSize.width - surfaceSize.width, 0)
        let vChrome = max(contentSize.height - surfaceSize.height, 0)

        let target = NSSize(
            width: CGFloat(width) * cellSize.width + hChrome,
            height: CGFloat(height) * cellSize.height + vChrome
        )
        window.setContentSize(target)
        logger.debug("[InitialSize] resized to \(width)×\(height) cells → content \(target.width)×\(target.height)px")
    }

    @objc private func handleSizeLimitNotification(_ notification: Notification) {
        guard let event = GhosttySizeLimitEvent.from(notification) else { return }
        let surfaceView = event.surfaceView
        guard belongsToThisWindow(surfaceView) else { return }
        guard let window else { return }

        let cellSize = surfaceView.cachedCellSize
        guard cellSize.width > 0, cellSize.height > 0 else {
            logger.debug("[SizeLimit] cell size not yet known, ignoring")
            return
        }

        let minW = event.minWidth
        let minH = event.minHeight
        let maxW = event.maxWidth
        let maxH = event.maxHeight

        // Measure chrome: content view area minus the surface area
        let contentSize = window.contentView?.bounds.size ?? .zero
        let surfaceSize = surfaceView.bounds.size
        let hChrome = max(contentSize.width - surfaceSize.width, 0)
        let vChrome = max(contentSize.height - surfaceSize.height, 0)

        if minW > 0 || minH > 0 {
            window.contentMinSize = NSSize(
                width: CGFloat(minW) * cellSize.width + hChrome,
                height: CGFloat(minH) * cellSize.height + vChrome
            )
        }
        if maxW > 0 || maxH > 0 {
            window.contentMaxSize = NSSize(
                width: maxW > 0 ? CGFloat(maxW) * cellSize.width + hChrome : CGFloat.greatestFiniteMagnitude,
                height: maxH > 0 ? CGFloat(maxH) * cellSize.height + vChrome : CGFloat.greatestFiniteMagnitude
            )
        }
        logger.debug("[SizeLimit] applied min=\(minW)×\(minH) max=\(maxW)×\(maxH) cells (chrome \(hChrome)×\(vChrome)px)")
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
        tabController.jumpToMostRecentUnreadTab()
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
        tabController.selectTabByIndex(index)
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
                    browserURL = browserManager.currentURL(for: tab.id, fallback: configuredURL)
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
        tabController.cleanupTabResources(id: tabID)
    }

    private func belongsToThisWindow(_ view: NSView) -> Bool {
        splitController.belongsToThisWindow(view)
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
        tabController.markAllTabsAsClosing(in: windowSession)

        // Destroy all surfaces in all tabs
        for group in windowSession.groups {
            for tab in group.tabs {
                for id in tab.registry.allIDs {
                    tab.registry.destroySurface(id)
                }
            }
        }

        browserManager.removeAll()
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

    // MARK: - IPC Notification Handlers

    @objc private func handleIPCEnableNotification(_ notification: Notification) {
        ipcController.enableIPC()
    }

    @objc private func handleIPCDisableNotification(_ notification: Notification) {
        ipcController.disableIPC()
    }

    @objc private func handleIPCReviewRequestedNotification(_ notification: Notification) {
        ipcController.handleReviewRequested()
    }

    @objc private func handleIPCLaunchWorkflowNotification(_ notification: Notification) {
        guard let event = CalyxIPCLaunchWorkflowEvent.from(notification) else { return }
        ipcController.handleLaunchWorkflow(event: event)
    }

}

// MARK: - TerminalControl (MCP bridge)

extension CalyxWindowController: TerminalControl {

    var terminalWindowSession: WindowSession { windowSession }

    var activeTabPwd: String? { activeTab?.pwd }

    // MARK: create_tab

    func createTab(pwd: String?, title: String?, command: String?) {
        tabController.createNewTab(pwd: pwd ?? activeTab?.pwd)
        if let title, let newTab = windowSession.activeGroup?.activeTab {
            newTab.title = title
        }
        guard let command, !command.isEmpty else { return }
        // Inject command after a brief delay for the shell to be ready.
        let delay = DispatchTime.now() + 0.8
        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
            guard let self else { return }
            guard let tab = self.windowSession.activeGroup?.activeTab,
                  let focusedID = tab.splitTree.focusedLeafID,
                  let controller = tab.registry.controller(for: focusedID) else { return }
            controller.sendText(command)
            if !command.hasSuffix("\n") {
                self.sendEnterKey(to: controller)
            }
        }
    }

    // MARK: create_split

    func createSplit(direction: String) {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let surfaceView = tab.registry.view(for: focusedID) else { return }

        let splitDirection: ghostty_action_split_direction_e
        switch direction.lowercased() {
        case "horizontal":
            splitDirection = GHOSTTY_SPLIT_DIRECTION_DOWN
        default:
            splitDirection = GHOSTTY_SPLIT_DIRECTION_RIGHT
        }

        NotificationCenter.default.post(
            name: .ghosttyNewSplit,
            object: surfaceView,
            userInfo: ["direction": splitDirection]
        )
    }

    // MARK: run_in_pane

    @discardableResult
    func runInPane(tabID: UUID?, paneID: UUID?, text: String, pressEnter: Bool) -> Bool {
        let targetTab: Tab?
        if let tabID {
            targetTab = windowSession.groups.flatMap(\.tabs).first { $0.id == tabID }
        } else {
            targetTab = activeTab
        }
        guard let tab = targetTab else { return false }

        let leafID: UUID?
        if let paneID {
            leafID = tab.splitTree.allLeafIDs().contains(paneID) ? paneID : nil
        } else {
            leafID = tab.splitTree.focusedLeafID
        }
        guard let resolvedID = leafID,
              let controller = tab.registry.controller(for: resolvedID) else { return false }

        controller.sendText(text)
        if pressEnter {
            sendEnterKey(to: controller)
        }
        return true
    }

    // MARK: focus_pane

    @discardableResult
    func focusPane(paneID: UUID) -> Bool {
        for group in windowSession.groups {
            for tab in group.tabs {
                guard tab.splitTree.allLeafIDs().contains(paneID) else { continue }
                tab.splitTree.focusedLeafID = paneID
                if let view = tab.registry.view(for: paneID) {
                    window?.makeFirstResponder(view)
                }
                // Also switch to this tab if it isn't active
                if group.activeTabID != tab.id {
                    tabController.switchToTab(id: tab.id)
                }
                return true
            }
        }
        return false
    }

    // MARK: set_tab_title

    @discardableResult
    func setTabTitle(tabID: UUID, title: String) -> Bool {
        for group in windowSession.groups {
            if let tab = group.tabs.first(where: { $0.id == tabID }) {
                tab.title = title
                return true
            }
        }
        return false
    }

    // MARK: show_notification

    func showNotification(title: String, body: String) {
        let tabID = activeTab?.id ?? UUID()
        NotificationManager.shared.sendNotification(title: title, body: body, tabID: tabID)
    }

    // MARK: get_git_status

    func getGitStatus() async -> String {
        guard let pwd = activeTab?.pwd else {
            return "No active terminal tab with a working directory."
        }
        do {
            let repoRoot = try await GitService.repoRoot(workDir: pwd)
            let entries = try await GitService.gitStatus(workDir: repoRoot)
            if entries.isEmpty {
                return "No changes (clean working tree at \(repoRoot))"
            }
            let staged = entries.filter { $0.isStaged }.map { "S \($0.status.rawValue) \($0.path)" }
            let unstaged = entries.filter { !$0.isStaged }.map { "  \($0.status.rawValue) \($0.path)" }
            let lines = staged + unstaged
            return "Repo: \(repoRoot)\n" + lines.joined(separator: "\n")
        } catch {
            return "Not a git repository or git error: \(error.localizedDescription)"
        }
    }

    // MARK: - Checkpoint rollback

    private func confirmAndRollbackToCheckpoint(_ commit: GitCommit) {
        guard let pwd = activeTab?.pwd else { return }
        let alert = NSAlert()
        alert.messageText = "Roll back to checkpoint?"
        alert.informativeText = "This will run git reset --hard \(commit.shortHash) and discard all changes made since:\n\n"\(commit.message)"\n\nThis cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Roll Back")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await CheckpointManager.shared.rollback(to: commit.id, workDir: pwd)
                    self.gitController.refreshGitStatus()
                } catch {
                    let errAlert = NSAlert(error: error)
                    if let w = self.window { errAlert.beginSheetModal(for: w) }
                }
            }
        }
    }

    // MARK: get_workspace_state

    func getWorkspaceState() -> WorkspaceStateResult {
        let activeTabID = windowSession.activeGroup?.activeTabID?.uuidString
        let groups: [GroupInfo] = windowSession.groups.map { group in
            let tabs: [TabInfo] = group.tabs.map { tab in
                let panes: [PaneInfo] = tab.splitTree.allLeafIDs().map { paneID in
                    PaneInfo(id: paneID.uuidString, isFocused: tab.splitTree.focusedLeafID == paneID)
                }
                return TabInfo(
                    id: tab.id.uuidString,
                    title: tab.title,
                    pwd: tab.pwd,
                    isActive: group.activeTabID == tab.id,
                    panes: panes
                )
            }
            return GroupInfo(id: group.id.uuidString, name: group.name, tabs: tabs)
        }
        return WorkspaceStateResult(activeTabID: activeTabID, groups: groups)
    }

    // MARK: run_in_pane_matching

    @discardableResult
    func runInPaneMatching(titleContains: String, text: String, pressEnter: Bool) -> Bool {
        let needle = titleContains.lowercased()
        for group in windowSession.groups {
            for tab in group.tabs {
                guard tab.title.lowercased().contains(needle) else { continue }
                guard let focusedID = tab.splitTree.focusedLeafID ?? tab.splitTree.allLeafIDs().first,
                      let controller = tab.registry.controller(for: focusedID) else { continue }
                controller.sendText(text)
                if pressEnter { sendEnterKey(to: controller) }
                return true
            }
        }
        return false
    }

    // MARK: get_pane_output

    func getPaneOutput(tabID: UUID?, paneID: UUID?) -> String? {
        let targetTab: Tab?
        if let tabID {
            targetTab = windowSession.groups.flatMap(\.tabs).first { $0.id == tabID }
        } else {
            targetTab = activeTab
        }
        guard let tab = targetTab else { return nil }

        let leafID: UUID?
        if let paneID {
            leafID = tab.splitTree.allLeafIDs().contains(paneID) ? paneID : nil
        } else {
            leafID = tab.splitTree.focusedLeafID
        }
        guard let resolvedID = leafID,
              let controller = tab.registry.controller(for: resolvedID),
              let surface = controller.surface else { return nil }

        var text = ghostty_text_s()
        guard GhosttyFFI.surfaceReadSelection(surface, text: &text) else { return nil }
        defer {
            var mutableText = text
            GhosttyFFI.surfaceFreeText(surface, text: &mutableText)
        }
        let len = Int(text.text_len)
        guard len > 0 else { return "" }
        return String(cString: text.text)
    }
}
