# Phase 7: Fragility Map

## 1. CalyxWindowController Notification Handlers

### Why fragile
All ghostty events arrive as untyped `NotificationCenter` posts. Each handler does `as?` casts on `notification.object` and `notification.userInfo`. If ghostty changes the shape of its callback data, these fail silently.

### What breaks it
Any ghostty submodule update that changes callback signatures, notification names, or userInfo keys.

### Symptoms
Silent feature breakage -- splits stop working, titles stop updating, surfaces don't close properly. No crash, just wrong behavior. Extremely hard to debug because the failure is a nil `as?` cast with no logging.

### Stabilize
Create typed notification wrappers that validate payloads at the posting site (in `GhosttyApp.swift` callbacks). Example:

```swift
struct GhosttyNewSplitEvent {
    let surfaceView: SurfaceView
    let direction: ghostty_action_split_direction_e
    let inheritedConfig: ghostty_surface_config_s?

    static func from(_ notification: Notification) -> Self? {
        guard let sv = notification.object as? SurfaceView,
              let dir = notification.userInfo?["direction"] as? ghostty_action_split_direction_e
        else {
            assertionFailure("Invalid ghosttyNewSplit notification payload")
            return nil
        }
        return Self(surfaceView: sv, direction: dir,
                    inheritedConfig: notification.userInfo?["inherited_config"] as? ghostty_surface_config_s)
    }
}
```

## 2. ✅ Session Persistence Spin-Loops (fixed)

### What was fragile
`applicationWillTerminate` used a spin-loop with a 1-second deadline to save. `restoreSession` used a 2-second spin-loop. Both blocked the main thread and could silently fail.

### Fix
Marked `savePath`, `backupPath`, `recoveryMarkerPath` as `nonisolated(unsafe)` (write-once in init). Made `restore()`, `migrateFromLegacyPath()`, `loadFromPath()`, and all recovery counter methods `nonisolated`. Added `saveImmediatelySync()` for the shutdown path. All spin-loops in `AppDelegate` replaced with direct synchronous calls.

## 3. Focus Management Retry Loop

### Why fragile
`restoreFocus()` -> `attemptFocusRestore()` retries with 10ms backoff up to 500ms, then falls back to a deferred callback on `SplitContainerView.onDeferredLayoutComplete`. If the view layout is already complete when the callback is registered, it will never fire.

### What breaks it
- SwiftUI layout timing changes (new macOS version)
- Adding views that delay layout
- Focus being stolen by another component (command palette, compose overlay)
- Multiple rapid tab switches (focus request ID invalidation)

### Symptoms
Terminal pane visible but not accepting keyboard input. User must click to re-focus.

### ✅ Partial fix
Added `onFocusFailed`/`onFocusRestored` callbacks to `FocusManager`. When `makeFirstResponder` fails, an amber border appears on `SplitContainerView` (via `CALayer.borderColor`). Cleared automatically when the user clicks or focus is successfully restored. Failure is now logged at `warning` level.

### Remaining
- Add a `windowDidUpdate` or `viewDidLayout` observer as a final fallback
- Use `NSView.viewDidMoveToWindow` callback instead of polling

## 4. GhosttyAppController Singleton + C Callbacks

### Why fragile
C callbacks receive `Unmanaged.passUnretained(self).toOpaque()` as userdata. They dispatch to the main thread via `DispatchQueue.main.async` and recover the controller via `Unmanaged.fromOpaque`. If the singleton is somehow deallocated, this is a use-after-free.

### What breaks it
Any change to app lifecycle that could cause the singleton to be released before callbacks stop. In practice, this is unlikely because `static let shared` prevents deallocation, but the pattern is inherently unsafe.

### Symptoms
Hard crash (EXC_BAD_ACCESS) in C callback handler.

### Stabilize
- Document that `GhosttyAppController` must never be deallocated during app lifetime
- The current `Unmanaged.passUnretained` is correct for a true singleton
- Consider adding an assertion in `deinit` to catch accidental deallocation

## 5. Browser Automation Security Model

### Why fragile
`BrowserServer` writes `~/.config/calyx/browser.json` with port and token. The token is generated via `SecRandomCopyBytes` but the return value is not checked. File permissions are 0o600 (owner-only), which is correct but any process running as the same user can read it.

### What breaks it
- `SecRandomCopyBytes` failure produces all-zero token (predictable)
- A malicious local process reads the token and controls browser tabs
- State file not cleaned up if app crashes (stale token in file)

### Symptoms
Browser tabs navigating to unexpected URLs, data exfiltration via `browser_eval` command.

### Stabilize
- **Fix**: Check `SecRandomCopyBytes` return value (matches what MCP server already does)
- The 0o600 permissions are appropriate for local-user security
- Consider per-session token rotation on app restart (already happens -- token regenerated on `start()`)
- Add PID verification in CLI client before using state file

## 6. TOML Parser for Codex Config

### Why fragile
`CodexConfigManager` uses hand-coded line-by-line TOML parsing with regex. No actual TOML parser library.

### What breaks it
- TOML features like inline tables, multi-line strings, or comments within the calyx section
- User manually editing the file with different formatting
- Codex changing their config format

### Symptoms
IPC configuration silently not applied or corrupted. User's other Codex config may be damaged.

### Stabilize
- Consider using a proper TOML parser library
- Or keep the regex approach but add comprehensive tests for edge cases (already has 520 lines of tests, which helps)
- Add config validation after write (read back and verify calyx section exists)
