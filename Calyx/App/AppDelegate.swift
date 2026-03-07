import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "AppDelegate"
)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appSession = AppSession()
    private var windowControllers: [CalyxWindowController] = []

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = GhosttyAppController.shared
        guard controller.readiness == .ready else {
            logger.critical("GhosttyAppController initialization failed")
            let alert = NSAlert()
            alert.messageText = "Failed to Initialize"
            alert.informativeText = "Terminal engine initialization failed. The application will now exit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        if let app = controller.app {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(app, scheme)
        }

        setupMainMenu()
        registerNotificationObservers()
        createNewWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = GhosttyAppController.shared.app else {
            return .terminateNow
        }

        if ghostty_app_needs_confirm_quit(app) {
            let alert = NSAlert()
            alert.messageText = "Quit Calyx?"
            alert.informativeText = "A process is still running. Do you want to quit?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowControllers.removeAll()
    }

    func applicationDidChangeOcclusionState(_ notification: Notification) {
        if let app = GhosttyAppController.shared.app {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(app, scheme)
        }
    }

    // MARK: - Notification Observers

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleNewTab(_:)), name: .ghosttyNewTab, object: nil)
        center.addObserver(self, selector: #selector(handleNewWindow(_:)), name: .ghosttyNewWindow, object: nil)
    }

    @objc private func handleNewTab(_ notification: Notification) {
        // Find the window controller that owns the source surface
        guard let surfaceView = notification.object as? SurfaceView,
              let window = surfaceView.window,
              let wc = windowControllers.first(where: { $0.window === window }) else {
            // No source — create tab in the key window's controller
            if let keyWC = windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
                keyWC.createNewTab(inheritedConfig: notification.userInfo?["inherited_config"])
            }
            return
        }
        wc.createNewTab(inheritedConfig: notification.userInfo?["inherited_config"])
    }

    @objc private func handleNewWindow(_ notification: Notification) {
        createNewWindow()
    }

    // MARK: - Window Management

    @objc func createNewWindow() {
        let initialTab = Tab()
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)

        let wc = CalyxWindowController(windowSession: windowSession)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    func removeWindowController(_ controller: CalyxWindowController) {
        appSession.removeWindow(id: controller.windowSession.id)
        windowControllers.removeAll { $0 === controller }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Calyx", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Calyx", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Calyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(withTitle: "New Window", action: #selector(createNewWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(CalyxWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(CalyxWindowController.closeTab(_:)), keyEquivalent: "w")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(CalyxWindowController.toggleSidebar),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebarItem)

        let fullScreenItem = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Tab navigation via menu
        let nextTabItem = NSMenuItem(title: "Select Next Tab", action: #selector(CalyxWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Select Previous Tab", action: #selector(CalyxWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevTabItem)

        windowMenu.addItem(.separator())

        // Cmd+1-9 tab selection
        for i in 1...9 {
            let selector = Selector("selectTab\(i):")
            let item = NSMenuItem(title: "Select Tab \(i)", action: selector, keyEquivalent: "\(i)")
            windowMenu.addItem(item)
        }

        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func openPreferences(_ sender: Any?) {
        SettingsWindowController.shared.showSettings()
    }
}
