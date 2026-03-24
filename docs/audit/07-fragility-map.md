# Phase 7: Fragility Map

## 1. ✅ CalyxWindowController Notification Handlers (fixed)

### What was fragile
All ghostty events arrived as untyped `NotificationCenter` posts. Each handler did `as?` casts on `notification.object` and `notification.userInfo`. If ghostty changed the shape of its callback data, these failed silently.

### Fix
All 28 notification handlers now use typed event wrappers (`GhosttyNotificationEvents.swift`). Every handler that had userInfo payload access now goes through a typed struct with a `from(_:)` factory method.

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

## 3. ✅ Focus Management Retry Loop (fixed)

### What was fragile
`restoreFocus()` -> `attemptFocusRestore()` used 10ms polling with 500ms timeout. Timing-dependent; would break on macOS layout schedule changes.

### Fix
Polling loop replaced with `SplitContainerView.onDeferredLayoutComplete` callback. `FocusManager` waits for the next layout pass instead of polling. Added `onFocusFailed`/`onFocusRestored` callbacks — amber border indicator appears when focus fails and clears automatically. Failure logged at `warning` level.

### Remaining edge case
If the surface view is in the window hierarchy but has zero bounds (not yet laid out), `makeFirstResponder` may fail silently with no retry. Low probability but still possible on very first tab creation.

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

## 5. ✅ Browser Automation Security Model (fixed)

### What was fragile
`BrowserServer` token generation did not check the `SecRandomCopyBytes` return value. A failure would produce an all-zero predictable token, creating a theoretical auth bypass.

### Fix
`SecRandomCopyBytes` return value is now checked; failure triggers `fatalError`. Shared `SecurityUtils.generateHexToken()` utility used by both `BrowserServer` and `CalyxMCPServer`.

### Remaining
- Any malicious local process running as the same user can still read `~/.config/calyx/browser.json` (inherent to local IPC)
- State file not cleaned up if app crashes (stale token) — acceptable: token regenerated on next `start()`

## 6. ✅ TOML Parser for Codex Config (fully hardened)

### What was fragile
`CodexConfigManager` used hand-coded line-by-line TOML parsing with regex. No actual TOML parser library.

### What was done
- Added 3 original edge-case tests (inline comments, bracket values, multi-line string)
- Added triple-quote `"""` state tracking in `removeSections()` — lines inside a multi-line TOML string are now emitted verbatim and never parsed as section headers
- The previously-documented known limitation (bracket line inside `"""` string treated as section header) is now fixed; test updated to assert correct behavior

### Remaining
No known parser gaps. The hand-rolled parser covers all realistic Codex config shapes.
