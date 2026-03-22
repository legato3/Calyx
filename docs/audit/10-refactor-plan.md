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
