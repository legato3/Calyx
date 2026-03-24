# Phase 2: Architecture Reality Check

## Architectural Pattern

**Hybrid AppKit/SwiftUI with NotificationCenter-based event bus.**

- AppKit for window management (`NSWindowController`, `NSWindow`, `NSView`)
- SwiftUI for UI composition (sidebar, tab bar, command palette, overlays)
- Bridged via `NSHostingView`
- C FFI callbacks -> NotificationCenter -> controller handlers

## Where Separation is Respected

- **GhosttyFFI** is clean -- no business logic, just C function wrappers (417 lines, pure `enum` namespace)
- **SplitTree** is a proper immutable value type with pure functions (422 lines, well-tested with 561 lines of tests)
- **SessionPersistenceActor** properly uses Swift actor isolation with atomic writes and crash-loop detection
- **Models** are clean data containers with minimal logic (`AppSession` is 23 lines, `Tab` is 45 lines)
- **Feature modules** (Git, Browser, IPC) are reasonably self-contained in their own directories

## Where Separation is Broken

### 1. ✅ CalyxWindowController god class — PARTIALLY RESOLVED

8 extraction steps complete (see `docs/audit/10-refactor-plan.md`). Extracted: GitController, ReviewController, FocusManager, BrowserManager, ComposeOverlayController + WindowActions environment + typed notification events. File reduced from 1,965 lines. Remaining: split operations, IPC enable/disable, review dispatch, tab/group lifecycle.

### 2. ✅ MainContentView callback closures — RESOLVED

Replaced the 22-closure pattern with a `WindowActions` `@Observable` environment object injected via `.environment()`. Views read actions they need directly without closures being threaded through the hierarchy. The original closures were:

```swift
var onTabSelected: ((UUID) -> Void)?
var onGroupSelected: ((UUID) -> Void)?
var onNewTab: (() -> Void)?
var onNewGroup: (() -> Void)?
var onCloseTab: ((UUID) -> Void)?
var onGroupRenamed: (() -> Void)?
var onToggleSidebar: (() -> Void)?
var onDismissCommandPalette: (() -> Void)?
var onWorkingFileSelected: ((GitFileEntry) -> Void)?
var onCommitFileSelected: ((CommitFileEntry) -> Void)?
var onRefreshGitStatus: (() -> Void)?
var onLoadMoreCommits: (() -> Void)?
var onExpandCommit: ((String) -> Void)?
var onSidebarWidthChanged: ((CGFloat) -> Void)?
var onCollapseToggled: (() -> Void)?
var onCloseAllTabsInGroup: ((UUID) -> Void)?
var onMoveTab: ((UUID, Int, Int) -> Void)?
var onSidebarDragCommitted: (() -> Void)?
var onSubmitReview: (() -> Void)?
var onDiscardReview: (() -> Void)?
var onSubmitAllReviews: (() -> Void)?
var onDiscardAllReviews: (() -> Void)?
var onComposeOverlaySend: ((String) -> Bool)?
var onDismissComposeOverlay: (() -> Void)?
```

### 3. NotificationCenter is untyped

All inter-component communication goes through `userInfo` dictionaries with string keys and `as?` casts. No compile-time safety:

```swift
// Posting (in C callback bridge):
NotificationCenter.default.post(name: .ghosttyNewSplit, object: surfaceView, userInfo: [
    "direction": direction,
    "inherited_config": config
])

// Receiving (in CalyxWindowController):
let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e
let config = notification.userInfo?["inherited_config"] as? ghostty_surface_config_s
```

If the posting side changes the key name or value type, the receiving side silently gets nil.

## Top 5 Structural Risks

### 1. ⚠️ CalyxWindowController (~1,350 lines) — SUBSTANTIALLY MITIGATED

12 extraction / completion steps completed (Steps 1-12 of `10-refactor-plan.md`). Extracted: GitController, ReviewController, FocusManager, BrowserManager, ComposeOverlayController, WindowActions, SplitController, IPCWindowController, TabLifecycleController. `SplitController.removeSurface(_:fromTab:)` added in Step 12 extracts the surface-level work from `handleCloseSurfaceNotification`; tab teardown remains in CWC. Both previously-stubbed notification handlers (`handleColorChangeNotification`, `handleShowChildExitedNotification`) are now fully implemented.

### 2. ✅ 28 NotificationCenter names with untyped payloads — FIXED

All 28 notification handlers now use typed event wrappers (`GhosttyNotificationEvents.swift`). Every `userInfo` payload access goes through a typed `from(_:)` factory. Payload mismatches now cause a `nil` return at the factory boundary rather than silently using wrong data.

### 3. ⚠️ 10 singletons with no dependency injection — PARTIALLY MITIGATED

`CalyxMCPServer._testSetToken()` `#if DEBUG` backdoor removed; tests now use `CalyxMCPServer(testToken:)`. `CalyxWindowController` accepts injected `mcpServer`. Remaining: `GhosttyAppController.shared`, `ClaudeUsageMonitor.shared`, and 7 other singletons still require the full app for testing.

### 4. ✅ Callback-closure architecture for view-to-controller communication — FIXED

Replaced with `WindowActions` `@Observable` environment object injected via `.environment()`. Views read only the actions they need directly. The original 22+ closures are gone.

### 5. nonisolated(unsafe) usage (25 instances)

Used to bridge C callbacks and shared state. While each use is documented and justified, these are concurrency escape hatches that bypass Swift's safety guarantees:

| File | Count | Purpose |
|------|-------|---------|
| `GhosttyApp.swift` | 7 | C callback captures, app pointer |
| `GhosttySurface.swift` | 1 | Surface pointer |
| `GhosttyConfig.swift` | 1 | Config pointer |
| `GlobalEventTap.swift` | 2 | Singleton, ghostty app cache |
| `SurfaceView.swift` | 1 | Secure input flag |
| `ClaudeUsageMonitor.swift` | 5 | Read-only paths and formatters |
| `TabReorderState.swift` | 1 | PreferenceKey default |
| `TabBarContentView.swift` | 1 | Event monitor |
| `SurfaceScrollView.swift` | 1 | Notification object capture |
| `QuickTerminalController.swift` | 1 | Hidden dock reference |
| `SecureInput.swift` | 1 | Observer storage |
| `GhosttyThemeProvider.swift` | 1 | Observer reference |
| `Dock.swift` | 4 | Private framework pointers |
