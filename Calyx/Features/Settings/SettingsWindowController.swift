import AppKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "SettingsWindowController"
)

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    // MARK: - Glass / Theme controls
    private let opacityLabel = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider(value: 0.7, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var lastLoadedOpacity = 0.7
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorWell = NSColorWell()
    private let hexField = NSTextField()
    private var lastLoadedPreset: String = "original"
    private var lastLoadedCustomHex: String = ThemeColorPreset.defaultCustomHex

    // MARK: - Terminal settings controls
    private let scrollbackField = NSTextField()
    private let scrollbackStepper = NSStepper()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let copyOnSelectCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let mouseHideCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let focusFollowsMouseCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let cursorStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // MARK: - Terminal overrides persistence
    private var terminalOverrides: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: AppStorageKeys.ghosttyTerminalOverrides),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: AppStorageKeys.ghosttyTerminalOverrides)
            }
            GhosttyConfigManager.writeUserSettings(newValue)
        }
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupContent() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Use a plain NSView as the document view so NSScrollView can compute scroll extent
        // correctly. The stack view is constrained inside it — the bottom constraint between
        // stack and document is what gives the document its height.
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: clipView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            root.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])

        // --- Theme Color Section ---
        let themeTitle = NSTextField(labelWithString: "Theme Color")
        themeTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(themeTitle)

        let themeSubtitle = NSTextField(labelWithString: "Choose a preset or pick a custom color.")
        themeSubtitle.textColor = .secondaryLabelColor
        themeSubtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(themeSubtitle)

        // Preset popup
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        for preset in presets {
            presetPopup.addItem(withTitle: preset.displayName)
        }
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.target = self
        presetPopup.action = #selector(presetDidChange(_:))
        root.addArrangedSubview(row(label: "Preset", control: presetPopup))

        // Color well
        colorWell.color = ThemeColorPreset.original.color
        colorWell.target = self
        colorWell.action = #selector(colorWellDidChange(_:))
        root.addArrangedSubview(row(label: "Color", control: colorWell))

        // Hex field
        hexField.stringValue = ThemeColorPreset.defaultCustomHex
        hexField.placeholderString = "#RRGGBB"
        hexField.target = self
        hexField.action = #selector(hexFieldDidCommit(_:))
        hexField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        root.addArrangedSubview(row(label: "Hex", control: hexField))

        // Separator between Theme Color and Glass
        let themeDivider = NSBox()
        themeDivider.boxType = .separator
        themeDivider.translatesAutoresizingMaskIntoConstraints = false
        themeDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(themeDivider)

        // --- Glass Section ---
        let title = NSTextField(labelWithString: "Glass")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Controls the transparency of the glass effect.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(subtitle)

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityDidChange(_:))
        opacityLabel.alignment = .right
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        updateOpacityLabel()

        let opacityRow = NSStackView()
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 12
        opacityRow.alignment = .centerY
        let opacityText = NSTextField(labelWithString: "Glass opacity")
        opacityText.font = .systemFont(ofSize: 13, weight: .medium)
        opacityText.setContentHuggingPriority(.required, for: .horizontal)
        opacityRow.addArrangedSubview(opacityText)
        opacityRow.addArrangedSubview(opacitySlider)
        opacityRow.addArrangedSubview(opacityLabel)
        root.addArrangedSubview(opacityRow)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(divider)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        saveButton.target = self
        saveButton.action = #selector(savePreset(_:))
        saveButton.bezelStyle = .rounded
        actions.addArrangedSubview(saveButton)

        let openButton = NSButton(title: "Open Config File", target: self, action: #selector(openConfigFile(_:)))
        openButton.bezelStyle = .rounded
        actions.addArrangedSubview(openButton)

        actions.addArrangedSubview(NSView())
        root.addArrangedSubview(actions)

        // --- Terminal Settings Section ---
        let termDivider = NSBox()
        termDivider.boxType = .separator
        termDivider.translatesAutoresizingMaskIntoConstraints = false
        termDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(termDivider)

        let termTitle = NSTextField(labelWithString: "Terminal Settings")
        termTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(termTitle)

        let termSubtitle = NSTextField(wrappingLabelWithString: "Override ghostty config settings from the UI. Changes apply immediately and are saved to ~/.config/calyx/calyx-user-settings.conf.")
        termSubtitle.textColor = .secondaryLabelColor
        termSubtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(termSubtitle)

        // Scrollback limit
        scrollbackStepper.minValue = 100
        scrollbackStepper.maxValue = 1_000_000
        scrollbackStepper.increment = 1000
        scrollbackStepper.valueWraps = false
        scrollbackStepper.isContinuous = false
        scrollbackStepper.target = self
        scrollbackStepper.action = #selector(scrollbackStepperDidChange(_:))
        scrollbackField.placeholderString = "10000"
        scrollbackField.target = self
        scrollbackField.action = #selector(scrollbackFieldDidCommit(_:))
        scrollbackField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let linesLabel = NSTextField(labelWithString: "lines")
        linesLabel.textColor = .secondaryLabelColor
        let scrollbackRow = NSStackView(views: [scrollbackField, scrollbackStepper, linesLabel])
        scrollbackRow.orientation = .horizontal
        scrollbackRow.spacing = 4
        root.addArrangedSubview(row(label: "Scrollback limit", control: scrollbackRow))

        // Font size
        fontSizeStepper.minValue = 6
        fontSizeStepper.maxValue = 72
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.isContinuous = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepperDidChange(_:))
        fontSizeField.placeholderString = "13"
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeFieldDidCommit(_:))
        fontSizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let ptLabel = NSTextField(labelWithString: "pt")
        ptLabel.textColor = .secondaryLabelColor
        let fontSizeRow = NSStackView(views: [fontSizeField, fontSizeStepper, ptLabel])
        fontSizeRow.orientation = .horizontal
        fontSizeRow.spacing = 4
        root.addArrangedSubview(row(label: "Font size", control: fontSizeRow))

        // Cursor style
        cursorStylePopup.addItems(withTitles: ["Block", "Bar", "Underline"])
        cursorStylePopup.target = self
        cursorStylePopup.action = #selector(cursorStyleDidChange(_:))
        root.addArrangedSubview(row(label: "Cursor style", control: cursorStylePopup))

        // Copy on select
        copyOnSelectCheckbox.target = self
        copyOnSelectCheckbox.action = #selector(copyOnSelectDidChange(_:))
        root.addArrangedSubview(row(label: "Copy on select", control: copyOnSelectCheckbox))

        // Mouse hide while typing
        mouseHideCheckbox.target = self
        mouseHideCheckbox.action = #selector(mouseHideDidChange(_:))
        root.addArrangedSubview(row(label: "Mouse hide while typing", control: mouseHideCheckbox))

        // Focus follows mouse
        focusFollowsMouseCheckbox.target = self
        focusFollowsMouseCheckbox.action = #selector(focusFollowsMouseDidChange(_:))
        root.addArrangedSubview(row(label: "Focus follows mouse", control: focusFollowsMouseCheckbox))

        let resetButton = NSButton(title: "Reset to Ghostty Defaults", target: self, action: #selector(resetTerminalSettings(_:)))
        resetButton.bezelStyle = .rounded
        root.addArrangedSubview(resetButton)
        // --- Scrolling Section ---
        let scrollingDivider = NSBox()
        scrollingDivider.boxType = .separator
        scrollingDivider.translatesAutoresizingMaskIntoConstraints = false
        scrollingDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(scrollingDivider)

        let scrollingTitle = NSTextField(labelWithString: "Scrolling")
        scrollingTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(scrollingTitle)

        let smoothScrollSwitch = NSSwitch()
        smoothScrollSwitch.state = (UserDefaults.standard.object(forKey: "smoothScrollEnabled") as? Bool ?? true) ? .on : .off
        smoothScrollSwitch.target = self
        smoothScrollSwitch.action = #selector(smoothScrollDidChange(_:))
        root.addArrangedSubview(row(label: "Smooth Scrolling", control: smoothScrollSwitch))

        // Divider before config info section
        let configDivider = NSBox()
        configDivider.boxType = .separator
        configDivider.translatesAutoresizingMaskIntoConstraints = false
        configDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(configDivider)

        // Config info section
        let configTitle = NSTextField(labelWithString: "Ghostty Config Compatibility")
        configTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(configTitle)

        let configSubtitle = NSTextField(wrappingLabelWithString: "Calyx reads ~/.config/ghostty/config. Most settings are hot-reloaded when you save the file.")
        configSubtitle.textColor = .secondaryLabelColor
        configSubtitle.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(configSubtitle)

        let managedLabel = NSTextField(wrappingLabelWithString: "The following keys are managed by Calyx for the Glass UI effect and will be overridden:")
        managedLabel.textColor = .secondaryLabelColor
        managedLabel.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(managedLabel)

        let managedKeysText = GhosttyConfigManager.managedKeys.map { "  • \($0)" }.joined(separator: "\n")
        let managedKeysList = NSTextField(wrappingLabelWithString: managedKeysText)
        managedKeysList.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        managedKeysList.textColor = .tertiaryLabelColor
        root.addArrangedSubview(managedKeysList)

        loadPresetIntoUI()
        loadTerminalSettingsIntoUI()
    }

    /// Checks for unsaved changes before app termination.
    /// Returns `true` to proceed, `false` to cancel termination.
    func confirmTermination() -> Bool {
        guard window?.isVisible == true, hasUnsavedChanges() else { return true }

        let alert = NSAlert()
        alert.messageText = "Save settings before quitting?"
        alert.informativeText = "Your settings have unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            savePresetFromUI()
            snapshotCurrentAsLoaded()
            return true
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": lastLoadedOpacity])
            UserDefaults.standard.set(lastLoadedPreset, forKey: "themeColorPreset")
            UserDefaults.standard.set(lastLoadedCustomHex, forKey: "themeColorCustomHex")
            loadPresetIntoUI()
            GhosttyAppController.shared.reloadConfig()
            return true
        default:
            // Do not revert UserDefaults here (unlike windowShouldClose Cancel).
            // The user wants to keep editing their in-progress changes.
            return false
        }
    }

    func showSettings() {
        loadPresetIntoUI()
        loadTerminalSettingsIntoUI()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Terminal settings load/save

    private func loadTerminalSettingsIntoUI() {
        let overrides = terminalOverrides
        let config = GhosttyAppController.shared.configManager

        // Scrollback limit
        if let str = overrides["scrollback-limit"], let val = Int(str) {
            scrollbackStepper.integerValue = val
            scrollbackField.stringValue = "\(val)"
        } else {
            let val = config.getInt("scrollback-limit", default: 10000)
            scrollbackStepper.integerValue = val
            scrollbackField.stringValue = "\(val)"
        }

        // Font size
        if let str = overrides["font-size"], let val = Double(str) {
            fontSizeStepper.doubleValue = val
            fontSizeField.stringValue = String(format: "%.0f", val)
        } else {
            let val = config.getDouble("font-size", default: 13)
            fontSizeStepper.doubleValue = val
            fontSizeField.stringValue = String(format: "%.0f", val)
        }

        // Cursor style
        let cursorStyles = ["block", "bar", "underline"]
        if let str = overrides["cursor-style"], let idx = cursorStyles.firstIndex(of: str) {
            cursorStylePopup.selectItem(at: idx)
        } else {
            let style = config.getString("cursor-style") ?? "block"
            cursorStylePopup.selectItem(at: cursorStyles.firstIndex(of: style) ?? 0)
        }

        // Copy on select
        if let str = overrides["copy-on-select"] {
            copyOnSelectCheckbox.state = (str == "clipboard" || str == "true") ? .on : .off
        } else {
            let val = config.getString("copy-on-select") ?? "clipboard"
            copyOnSelectCheckbox.state = (val == "clipboard" || val == "true") ? .on : .off
        }

        // Mouse hide while typing
        if let str = overrides["mouse-hide-while-typing"] {
            mouseHideCheckbox.state = str == "true" ? .on : .off
        } else {
            mouseHideCheckbox.state = config.getBool("mouse-hide-while-typing") ? .on : .off
        }

        // Focus follows mouse
        if let str = overrides["focus-follows-mouse"] {
            focusFollowsMouseCheckbox.state = str == "true" ? .on : .off
        } else {
            focusFollowsMouseCheckbox.state = config.getBool("focus-follows-mouse") ? .on : .off
        }
    }

    private func applyTerminalOverride(_ key: String, value: String) {
        var overrides = terminalOverrides
        overrides[key] = value
        terminalOverrides = overrides
        GhosttyAppController.shared.reloadConfig()
    }

    // MARK: - Terminal settings handlers

    @objc private func scrollbackStepperDidChange(_ sender: Any?) {
        let val = scrollbackStepper.integerValue
        scrollbackField.stringValue = "\(val)"
        applyTerminalOverride("scrollback-limit", value: "\(val)")
    }

    @objc private func scrollbackFieldDidCommit(_ sender: Any?) {
        guard let val = Int(scrollbackField.stringValue), val >= 100 else {
            scrollbackField.stringValue = "\(scrollbackStepper.integerValue)"
            return
        }
        let clamped = min(val, 1_000_000)
        scrollbackStepper.integerValue = clamped
        scrollbackField.stringValue = "\(clamped)"
        applyTerminalOverride("scrollback-limit", value: "\(clamped)")
    }

    @objc private func fontSizeStepperDidChange(_ sender: Any?) {
        let val = fontSizeStepper.integerValue
        fontSizeField.stringValue = "\(val)"
        applyTerminalOverride("font-size", value: "\(val)")
    }

    @objc private func fontSizeFieldDidCommit(_ sender: Any?) {
        guard let val = Double(fontSizeField.stringValue), val >= 6 else {
            fontSizeField.stringValue = "\(fontSizeStepper.integerValue)"
            return
        }
        let clamped = min(val, 72)
        fontSizeStepper.doubleValue = clamped
        fontSizeField.stringValue = String(format: "%.0f", clamped)
        applyTerminalOverride("font-size", value: String(format: "%.0f", clamped))
    }

    @objc private func cursorStyleDidChange(_ sender: Any?) {
        let styles = ["block", "bar", "underline"]
        let style = styles[cursorStylePopup.indexOfSelectedItem]
        applyTerminalOverride("cursor-style", value: style)
    }

    @objc private func copyOnSelectDidChange(_ sender: Any?) {
        applyTerminalOverride("copy-on-select", value: copyOnSelectCheckbox.state == .on ? "clipboard" : "false")
    }

    @objc private func mouseHideDidChange(_ sender: Any?) {
        applyTerminalOverride("mouse-hide-while-typing", value: mouseHideCheckbox.state == .on ? "true" : "false")
    }

    @objc private func focusFollowsMouseDidChange(_ sender: Any?) {
        applyTerminalOverride("focus-follows-mouse", value: focusFollowsMouseCheckbox.state == .on ? "true" : "false")
    }

    @objc private func resetTerminalSettings(_ sender: Any?) {
        terminalOverrides = [:]
        GhosttyAppController.shared.reloadConfig()
        loadTerminalSettingsIntoUI()
    }

    @objc private func openConfigFile(_ sender: Any?) {
        var opener = SystemConfigFileOpener()
        let result = ConfigFileOpener.openConfigFile(using: &opener)

        switch result {
        case .opened, .createdAndOpened:
            break // Success
        case .error(let error):
            showConfigFileError(error, opener: opener)
        }
    }

    private func showConfigFileError(_ error: ConfigFileOpenError, opener: SystemConfigFileOpener) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open config file"

        let rawPath = opener.configOpenPath()
        let hasPath = !rawPath.isEmpty

        switch error {
        case .emptyPath:
            alert.informativeText = "Could not determine the config file path."
        case .isDirectory:
            alert.informativeText = "The config path points to a directory, not a file."
        case .isSymlink:
            alert.informativeText = "The config path is a symbolic link. For security, Calyx will not follow symlinks."
        case .createFailed(let message):
            alert.informativeText = "Failed to create config file: \(message)"
        case .openFailed:
            alert.informativeText = "The file exists but could not be opened."
        }

        if hasPath {
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "Copy Path")
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "OK")
        }

        let response = alert.runModal()

        guard hasPath else { return }
        let fileURL = URL(fileURLWithPath: rawPath)

        switch response {
        case .alertFirstButtonReturn:
            opener.revealInFinder(url: fileURL)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rawPath, forType: .string)
        default:
            break
        }
    }

    @objc private func opacityDidChange(_ sender: Any?) {
        updateOpacityLabel()
        let opacity = max(0.0, min(1.0, opacitySlider.doubleValue))
        UserDefaults.standard.set(opacity, forKey: "terminalGlassOpacity")
        NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": opacity])
        applyOpacityToRunningSurfaces()
        fieldDidChange(sender)
    }

    @objc private func smoothScrollDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "smoothScrollEnabled")
        if !enabled {
            NotificationCenter.default.post(name: .smoothScrollSettingChanged, object: nil)
        }
    }

    @objc private func presetDidChange(_ sender: Any?) {
        let index = presetPopup.indexOfSelectedItem
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        if index < presets.count {
            let preset = presets[index]
            UserDefaults.standard.set(preset.rawValue, forKey: "themeColorPreset")
            colorWell.color = preset.color
            hexField.stringValue = HexColor.toHex(preset.color)
            hexField.textColor = .labelColor
        }
        // If "Custom" selected (last item), just set preset to custom
        else {
            UserDefaults.standard.set("custom", forKey: "themeColorPreset")
        }
        fieldDidChange(sender)
        GhosttyAppController.shared.reloadConfig()
    }

    @objc private func colorWellDidChange(_ sender: Any?) {
        let color = colorWell.color
        let hex = HexColor.toHex(color)
        hexField.stringValue = hex
        hexField.textColor = .labelColor
        UserDefaults.standard.set(hex, forKey: "themeColorCustomHex")
        UserDefaults.standard.set("custom", forKey: "themeColorPreset")
        // Update popup to show "Custom"
        presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
        fieldDidChange(sender)
        GhosttyAppController.shared.reloadConfig()
    }

    @objc private func hexFieldDidCommit(_ sender: Any?) {
        let text = hexField.stringValue
        if let color = HexColor.parse(text) {
            let normalized = HexColor.toHex(color)
            hexField.stringValue = normalized
            hexField.textColor = .labelColor
            colorWell.color = color
            UserDefaults.standard.set(normalized, forKey: "themeColorCustomHex")
            UserDefaults.standard.set("custom", forKey: "themeColorPreset")
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
            GhosttyAppController.shared.reloadConfig()
        } else {
            // Invalid hex - show red text, do NOT write to UserDefaults
            hexField.textColor = .systemRed
        }
        fieldDidChange(sender)
    }

    @objc private func savePreset(_ sender: Any?) {
        savePresetFromUI()
        snapshotCurrentAsLoaded()
    }

    @objc func reloadConfig() {
        // Ghostty reloads config automatically via file watcher
        // This is a manual trigger if needed
        logger.info("Config reload requested")
    }

    @objc private func fieldDidChange(_ sender: Any?) {
        refreshSaveButtonState()
    }

    private func row(label: String, control: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        let text = NSTextField(labelWithString: label)
        text.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(control)
        return stack
    }

    private func updateOpacityLabel() {
        opacityLabel.stringValue = String(format: "%.2f", opacitySlider.doubleValue)
    }

    private func loadPresetIntoUI() {
        let opacity = UserDefaults.standard.object(forKey: "terminalGlassOpacity") as? Double ?? 0.7
        opacitySlider.doubleValue = max(0.0, min(1.0, opacity))
        updateOpacityLabel()

        // Load theme color state
        let preset = UserDefaults.standard.string(forKey: "themeColorPreset") ?? "original"
        let customHex = UserDefaults.standard.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        if let idx = presets.firstIndex(where: { $0.rawValue == preset }) {
            presetPopup.selectItem(at: idx)
            colorWell.color = presets[idx].color
            hexField.stringValue = HexColor.toHex(presets[idx].color)
        } else {
            // Custom
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
            colorWell.color = HexColor.parse(customHex) ?? ThemeColorPreset.original.color
            hexField.stringValue = customHex
        }
        hexField.textColor = .labelColor

        snapshotCurrentAsLoaded()
        refreshSaveButtonState()
    }

    private func savePresetFromUI() {
        // Theme color changes are written to UserDefaults immediately for live preview.
        // Only glass opacity needs explicit persistence here.
        let opacity = max(0.0, min(1.0, opacitySlider.doubleValue))
        UserDefaults.standard.set(opacity, forKey: "terminalGlassOpacity")
        NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": opacity])
        applyOpacityToRunningSurfaces()
    }

    private func applyOpacityToRunningSurfaces() {
        // reloadConfig(soft: false) handles both disk reload and window propagation
        // via ConfigReloadCoordinator with 200ms debounce.
        GhosttyAppController.shared.reloadConfig()
    }

    private func snapshotCurrentAsLoaded() {
        lastLoadedOpacity = opacitySlider.doubleValue
        lastLoadedPreset = UserDefaults.standard.string(forKey: "themeColorPreset") ?? "original"
        lastLoadedCustomHex = UserDefaults.standard.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex
        refreshSaveButtonState()
    }

    private func hasUnsavedChanges() -> Bool {
        let currentOpacity = opacitySlider.doubleValue
        let opacityChanged = abs(currentOpacity - lastLoadedOpacity) > 0.0001
        let currentPreset = UserDefaults.standard.string(forKey: "themeColorPreset") ?? "original"
        let currentCustomHex = UserDefaults.standard.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex
        let themeChanged = currentPreset != lastLoadedPreset || currentCustomHex != lastLoadedCustomHex
        return opacityChanged || themeChanged
    }

    private func refreshSaveButtonState() {
        saveButton.isEnabled = hasUnsavedChanges()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges() else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Your Glass settings have unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            savePreset(nil)
            return !hasUnsavedChanges()
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": lastLoadedOpacity])
            UserDefaults.standard.set(lastLoadedPreset, forKey: "themeColorPreset")
            UserDefaults.standard.set(lastLoadedCustomHex, forKey: "themeColorCustomHex")
            loadPresetIntoUI()
            GhosttyAppController.shared.reloadConfig()
            return true
        default:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": lastLoadedOpacity])
            UserDefaults.standard.set(lastLoadedPreset, forKey: "themeColorPreset")
            UserDefaults.standard.set(lastLoadedCustomHex, forKey: "themeColorCustomHex")
            loadPresetIntoUI()
            GhosttyAppController.shared.reloadConfig()
            return false
        }
    }
}
