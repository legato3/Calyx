import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "SplitController"
)

/// Handles all split-pane operations: creation, navigation, resize, equalization,
/// and divider drags. Owned by CalyxWindowController.
@MainActor
final class SplitController {
    private weak var window: NSWindow?

    var getActiveTab: (() -> Tab?)?
    var getSplitContainerView: (() -> SplitContainerView?)?
    /// Called whenever a new surface UUID is added to the registry (invalidates the surface→tab cache).
    var onSurfaceCreated: (() -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    // MARK: - Window Membership

    func belongsToThisWindow(_ view: NSView) -> Bool {
        view.window === window
    }

    // MARK: - Split Handlers

    func handleNewSplit(event: GhosttyNewSplitEvent) {
        guard let tab = getActiveTab?() else { return }
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
        if let window {
            config.scale_factor = Double(window.backingScaleFactor)
        }

        guard let newSurfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create split surface")
            return
        }
        onSurfaceCreated?()

        let (newTree, _) = tab.splitTree.insert(at: surfaceID, direction: splitDir, newID: newSurfaceID)
        tab.splitTree = newTree

        getSplitContainerView?()?.updateLayout(tree: tab.splitTree)

        if let newView = tab.registry.view(for: newSurfaceID) {
            window?.makeFirstResponder(newView)
        }
    }

    func handleGotoSplit(event: GhosttyGotoSplitEvent) {
        guard let tab = getActiveTab?() else { return }
        guard let surfaceID = tab.registry.id(for: event.surfaceView) else { return }
        guard belongsToThisWindow(event.surfaceView) else { return }

        let focusDir: FocusDirection
        switch event.direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: focusDir = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT:     focusDir = .next
        case GHOSTTY_GOTO_SPLIT_LEFT:     focusDir = .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT:    focusDir = .spatial(.right)
        case GHOSTTY_GOTO_SPLIT_UP:       focusDir = .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN:     focusDir = .spatial(.down)
        default:                          focusDir = .next
        }

        guard let targetID = tab.splitTree.focusTarget(for: focusDir, from: surfaceID) else { return }
        tab.splitTree.focusedLeafID = targetID

        if let targetView = tab.registry.view(for: targetID) {
            window?.makeFirstResponder(targetView)
        }
    }

    func handleResizeSplit(event: GhosttyResizeSplitEvent) {
        guard let tab = getActiveTab?() else { return }
        guard let _ = tab.registry.id(for: event.surfaceView) else { return }
        guard belongsToThisWindow(event.surfaceView) else { return }
        guard let contentView = window?.contentView else { return }

        let resize = event.resize

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

        guard let surfaceID = tab.registry.id(for: event.surfaceView) else { return }
        let amount = Double(resize.amount) * sign
        tab.splitTree = tab.splitTree.resize(
            node: surfaceID,
            by: amount,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        getSplitContainerView?()?.updateLayout(tree: tab.splitTree)
    }

    func handleEqualizeSplits(surfaceView: SurfaceView?) {
        if let sv = surfaceView {
            guard belongsToThisWindow(sv) else { return }
        }
        guard let tab = getActiveTab?() else { return }
        tab.splitTree = tab.splitTree.equalize()
        getSplitContainerView?()?.updateLayout(tree: tab.splitTree)
    }

    func handleDividerDrag(leafID: UUID, delta: Double, direction: SplitDirection) {
        guard let tab = getActiveTab?(), let contentView = window?.contentView else { return }
        tab.splitTree = tab.splitTree.resize(
            node: leafID,
            by: delta,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        getSplitContainerView?()?.updateLayout(tree: tab.splitTree)
    }

    // MARK: - Surface Removal

    /// Removes a surface from its tab's split tree, destroys the surface, and returns the
    /// suggested focus target UUID (if any). The caller is responsible for tab teardown
    /// when `tab.splitTree.isEmpty` after this call.
    @discardableResult
    func removeSurface(_ surfaceView: SurfaceView, fromTab tab: Tab) -> UUID? {
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return nil }
        let (newTree, focusTarget) = tab.splitTree.remove(surfaceID)
        tab.registry.destroySurface(surfaceID)
        tab.splitTree = newTree
        return focusTarget
    }
}
