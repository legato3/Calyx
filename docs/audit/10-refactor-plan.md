# Phase 10: Controlled Refactor Plan

Goals: Improve consistency, reduce bugs, prepare for future features.
Constraints: No full rewrite. Incremental changes only. Each step is independently mergeable.

## Step 1: ✅ Extract TabCleanupHelper (done — commit `1ec1c9d`)

### What
Create a method `cleanupTabResources(id:)` on `CalyxWindowController`:

```swift
private func cleanupTabResources(id tabID: UUID) {
    browserControllers.removeValue(forKey: tabID)
    diffTasks[tabID]?.cancel()
    diffTasks.removeValue(forKey: tabID)
    diffStates.removeValue(forKey: tabID)
    reviewStores.removeValue(forKey: tabID)
}
```

### Where to call
- `closeTab(id:)` -- line 623-629
- `closeActiveGroup()` -- lines 727-737
- `closeAllTabsInGroup(id:)` -- lines 777-784
- `windowWillClose(_:)` -- lines 1523-1528

### Risk
Low. Pure extraction, no behavior change. All 4 call sites have identical cleanup sequences.

### Verification
Run `CalyxTests` -- all existing tests should pass unchanged.

## Step 2: ✅ Extract GitController (done — commit `7a4a246`)

### What
Create `GitController` class with:

```swift
@MainActor
final class GitController {
    private weak var windowSession: WindowSession?
    private var refreshTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var expandTasks: [String: Task<Void, Never>] = [:]
    private var hasMoreCommits = true

    func refreshGitStatus()
    func loadMoreCommits()
    func expandCommit(hash:)
    func handleWorkingFileSelected(_:)
    func handleCommitFileSelected(_:)
    func findWorkDir() -> String?
}
```

### Methods to move from CalyxWindowController
- `refreshGitStatus()` (lines 1545-1588)
- `loadMoreCommits()` (lines 1590-1616)
- `expandCommit(hash:)` (lines 1618-1641)
- `handleWorkingFileSelected(_:)` (lines 1643-1657)
- `handleCommitFileSelected(_:)` (lines 1659-1665)
- `findWorkDir()` (lines 1728-1751)

### CalyxWindowController keeps
- `private let gitController = GitController()`
- Delegates sidebar callbacks to `gitController`
- Owns `openDiffTab(source:)` (because it manages tab lifecycle)

### Risk
Low-medium. Clean boundary -- git operations don't touch tab/split state directly. The only coupling is `findWorkDir()` needing access to tabs (pass as parameter or give GitController a reference to WindowSession).

## Step 3: ✅ Extract ReviewController (done — commit `7a4a246`)

### What
Create `ReviewController` class managing diff review lifecycle:

```swift
@MainActor
final class ReviewController {
    var reviewStores: [UUID: DiffReviewStore] = [:]
    var diffStates: [UUID: DiffLoadState] = [:]
    var diffTasks: [UUID: Task<Void, Never>] = [:]

    func loadDiff(tabID:, source:)
    func submitDiffReview(tabID:, windowSession:) -> ReviewSendResult
    func submitAllDiffReviews(windowSession:) -> ReviewSendResult
    func discardAllDiffReviews(windowSession:)
    func sendReviewToAgent(_:, windowSession:) -> ReviewSendResult
    func cleanupTab(id:)
    func cancelAll()

    var totalReviewCommentCount: Int
    var reviewFileCount: Int
}
```

### Methods to move from CalyxWindowController
- `submitDiffReview(tabID:)` (lines 1899-1918)
- `submitAllDiffReviews()` (lines 1920-1937)
- `discardAllDiffReviews()` (lines 1939-1954)
- `sendReviewToAgent(_:)` (lines 1819-1897)
- Related computed properties (`totalReviewCommentCount`, `reviewFileCount`)

### Risk
Medium. `sendReviewToAgent` accesses `windowSession.groups` and terminal controllers. Will need to pass these as parameters or give ReviewController a reference.

## Step 4: ✅ Extract FocusManager (done)

### What
Create `FocusManager` encapsulating focus restoration logic:

```swift
@MainActor
final class FocusManager {
    private var focusRequestID: UInt64 = 0
    private static let focusRestoreTimeout: Double = 0.5

    func restoreFocus(window:, tab:, splitContainerView:)
    func focusImmediately(window:, tab:) -> Bool

    private func attemptFocusRestore(requestID:, startTime:, window:, tab:, splitContainerView:)
}
```

### Methods to move
- `restoreFocus()` (lines 934-942)
- `attemptFocusRestore(requestID:startTime:)` (lines 946-984)
- `focusActiveTabImmediately()` (lines 452-468)
- `focusRequestID` property (line 19)

### Risk
Medium. Focus logic interacts with window, tab registry, and split container. Parameters will be verbose but the logic is self-contained.

## Step 5: ✅ Type the top 5 notifications (done)

### What
Replace untyped `Notification.Name` + `userInfo` with typed wrappers:

```swift
struct GhosttyNewSplitEvent {
    let surfaceView: SurfaceView
    let direction: ghostty_action_split_direction_e
    let inheritedConfig: ghostty_surface_config_s?

    static func from(_ notification: Notification) -> Self? { ... }
}
```

### Notifications to type (in priority order)
1. `.ghosttyCloseSurface` -- object: SurfaceView
2. `.ghosttyNewSplit` -- object: SurfaceView, userInfo: direction, inherited_config
3. `.ghosttySetTitle` -- object: SurfaceView, userInfo: title
4. `.ghosttySetPwd` -- object: SurfaceView, userInfo: pwd
5. `.ghosttyGotoSplit` -- object: SurfaceView, userInfo: direction

### Risk
Low. Each notification can be migrated independently. The typed wrapper adds validation at the call site without changing the notification mechanism.

## Step 6: ✅ Reduce MainContentView callbacks (done)

### What
Create `WindowActions` environment object:

```swift
@Observable @MainActor
final class WindowActions {
    var onTabSelected: ((UUID) -> Void)?
    var onGroupSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    // ... remaining callbacks
}
```

Pass via `.environment()` in `setupUI()`:

```swift
let actions = WindowActions()
actions.onTabSelected = { [weak self] id in self?.switchToTab(id: id) }
// ...
hosting.rootView = mainContent.environment(actions)
```

### Risk
Low. SwiftUI environment is the standard pattern for this. No behavior change, just plumbing.

## Step 7: ✅ Extract BrowserManager (done)

### What
Created `BrowserManager` in `Calyx/Features/Browser/BrowserManager.swift`:

```swift
@MainActor
final class BrowserManager {
    var onSaveRequested: (() -> Void)?
    func controller(for tabID: UUID, tab: Tab) -> BrowserTabController?
    func register(_ controller: BrowserTabController, for tab: Tab)
    func currentURL(for tabID: UUID, fallback: URL) -> URL
    func cleanupTab(id: UUID)
    func removeAll()
}
```

### What moved from CalyxWindowController
- `browserControllers: [UUID: BrowserTabController]` dict
- `wireBrowserCallbacks(controller:tab:)` — now private to `BrowserManager`
- `browserController(for:)` now delegates to `browserManager.controller(for:tab:)`
- `cleanupTabResources` / `windowWillClose` / `windowSnapshot` updated to use `browserManager`

### Risk
Low. Clean boundary: browser lifecycle doesn't interact with split/tab model directly.

## Step 8: ✅ Extract ComposeOverlayController (done)

### What
Created `ComposeOverlayController` in `Calyx/Features/ComposeOverlay/ComposeOverlayController.swift`:

```swift
@MainActor
final class ComposeOverlayController {
    private(set) var targetSurfaceID: UUID?

    func toggle(windowSession:, focusedControllerID:)
    func retargetIfNeeded(windowSession:, focusedControllerID:)
    func dismiss(windowSession:, onDismiss:)
    func send(_:activeTab:focusedController:sendEnterKey:) -> Bool
}
```

### What moved from CalyxWindowController
- `composeOverlayTargetSurfaceID` → `composeController.targetSurfaceID`
- `toggleComposeOverlay()` → delegates to `composeController.toggle(...)`
- `retargetComposeOverlayIfNeeded()` → delegates to `composeController.retargetIfNeeded(...)`
- `dismissComposeOverlay()` → delegates to `composeController.dismiss(...)` with focus restore callback
- `sendComposeText(_:)` body → delegates to `composeController.send(...)`

### Risk
Low. Clean boundary: compose overlay state and text dispatch logic is self-contained. CalyxWindowController retains ownership of focus restoration (since that requires `focusManager` and window context).

## Step 9: ✅ Extract SplitController (done)

### What
Created `Calyx/Views/MainWindow/SplitController.swift`:

```swift
@MainActor
final class SplitController {
    private weak var window: NSWindow?
    var getActiveTab: (() -> Tab?)?
    var getSplitContainerView: (() -> SplitContainerView?)?
    var onSurfaceCreated: (() -> Void)?

    func belongsToThisWindow(_ view: NSView) -> Bool
    func handleNewSplit(event: GhosttyNewSplitEvent)
    func handleGotoSplit(event: GhosttyGotoSplitEvent)
    func handleResizeSplit(event: GhosttyResizeSplitEvent)
    func handleEqualizeSplits(surfaceView: SurfaceView?)
    func handleDividerDrag(leafID: UUID, delta: Double, direction: SplitDirection)
}
```

### What moved from CalyxWindowController
- Full bodies of `handleNewSplitNotification`, `handleGotoSplitNotification`, `handleResizeSplitNotification`, `handleEqualizeSplitsNotification`, `handleDividerDrag`
- `belongsToThisWindow` — CWC delegates to `splitController.belongsToThisWindow(_:)`
- Note: `handleCloseSurfaceNotification` remains in CWC — it mixes split-tree and tab-lifecycle concerns

### Risk
Low. All split operations are self-contained in the split tree; no tab model mutation.

## Step 10: ✅ Extract IPCWindowController (done)

### What
Created `Calyx/Features/IPC/IPCWindowController.swift`:

```swift
@MainActor
final class IPCWindowController {
    private let mcpServer: CalyxMCPServer
    private weak var windowSession: WindowSession?

    var onCreateNewTab: ((String?) -> Void)?
    var onSwitchToTab: ((UUID) -> Void)?
    var onSendEnterKey: ((GhosttySurfaceController) -> Void)?
    var getActiveTabPwd: (() -> String?)?
    var onShowGitSidebar: (() -> Void)?

    func enableIPC()
    func disableIPC()
    func handleReviewRequested()
    func handleLaunchWorkflow(event: CalyxIPCLaunchWorkflowEvent)
    func sendToAgent(_ payload: String) -> ReviewSendResult
}
```

### What moved from CalyxWindowController
- `enableIPC()`, `disableIPC()`, `showIPCAlert()`, `configStatusMessage()` — IPC toggle cluster
- `handleIPCLaunchWorkflowNotification` body → `handleLaunchWorkflow(event:)`
- `handleIPCReviewRequestedNotification` body → `handleReviewRequested()`
- `sendReviewToAgent(_:)` → `sendToAgent(_:)`
- `reviewController.sendToAgent` callback updated to call `ipcController.sendToAgent`

### Risk
Medium. Workflow launch creates tabs (via callback) and sends keystrokes (via callback). Timing-dependent async delays unchanged.

## Step 11: ✅ Extract TabLifecycleController (done)

### What
Created `Calyx/Views/MainWindow/TabLifecycleController.swift`:

```swift
@MainActor
final class TabLifecycleController {
    private weak var windowSession: WindowSession?
    private let reviewController: ReviewController
    private let browserManager: BrowserManager
    private let focusManager: FocusManager
    private(set) var closingTabIDs: Set<UUID> = []

    func createNewTab(inheritedConfig: Any? = nil, pwd: String? = nil)
    func createBrowserTab(url: URL)
    func promptAndOpenBrowserTab()
    func closeTab(id: UUID)
    func switchToTab(id: UUID)
    func switchToGroup(id: UUID)
    func createNewGroup()
    func closeActiveGroup()
    func closeAllTabsInGroup(id: UUID)
    func switchToNextGroup()
    func switchToPreviousGroup()
    func selectTabByIndex(_ index: Int)
    func jumpToMostRecentUnreadTab()
    func cleanupTabResources(id: UUID)
    func markAllTabsAsClosing(in session: WindowSession)
}
```

### What moved from CalyxWindowController
- All tab/group creation, switching, and teardown methods
- `closingTabIDs` guard set (was CWC property)
- `cleanupTabResources` (now delegates to browserManager + reviewController)
- `jumpToMostRecentUnreadTab`, `selectTabByIndex`
- `createNewGroup`, `closeActiveGroup`, `closeAllTabsInGroup`, `switchToNextGroup`, `switchToPreviousGroup`

### CWC after Step 11
- 1,314 lines (down from 1,877 before Step 9)
- All method stubs delegate to the appropriate controller
- `handleCloseSurfaceNotification` remains (mixes split + tab lifecycle); reads `tabController.closingTabIDs`

### Risk
Medium. Many callbacks required (10 view-side effects). All are [weak self] closures wired in CWC.init after super.init().

## Step 12: ✅ Complete Stubbed Handlers + Partial handleCloseSurface Extraction (done)

### handleColorChangeNotification (completed)
Updates `window.backgroundColor` tint when `change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND`. The window stays transparent (`isOpaque = false`); the background color serves as a compositor tint hint.

### handleShowChildExitedNotification (completed)
Sets `tab.processExited = true` and `tab.lastExitCode`. On non-zero exit code posts a desktop notification via `NotificationManager.shared`. Tab bar shows a circle icon (green=0, red=non-zero). "Restart Shell" command palette command enabled when `processExited == true`.

### handleCloseSurfaceNotification (partially extracted)
`SplitController.removeSurface(_:fromTab:)` now owns split-tree mutation and surface destruction. The CWC handler is reduced to 3 coordination calls. Tab teardown (empty-tree → close tab → window close) remains in CWC as it straddles session and window concerns.

## Remaining Work

No incomplete stub handlers remain. Structural items still deferred:

## What NOT to Touch Yet

| Component | Why |
|-----------|-----|
| `GhosttyApp.swift` C callbacks | Working correctly, high risk of subtle C interop bugs |
| `SurfaceView.swift` (881 lines) | Deep AppKit coupling to ghostty internals, every line matters |
| `SettingsWindowController` | Self-contained, working, no external pressure |
| Session persistence | Production-quality, don't optimize prematurely |
| SplitTree | Already well-designed, well-tested |
| MetalView | Hardware-level rendering, very fragile |
| GlobalEventTap | CGEvent tap callbacks run on system thread, tricky |

## Order of Execution

```
Step 1 (tab cleanup)         -- no dependencies, do first
    |
Step 2 (GitController)      -- independent of Step 3
Step 3 (ReviewController)    -- independent of Step 2
    |
Step 4 (FocusManager)       -- after Steps 2-3 reduce CalyxWindowController
    |
Step 5 (typed notifications) -- after controller extractions stabilize
    |
Step 6 (environment actions) -- after notification types are settled
```

Steps 2 and 3 can be done in parallel. Each step should be its own commit/PR.
