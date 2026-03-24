# Phase 8: Quick Wins

10 high-impact, low-effort improvements. No large refactors.

**Status**: All done. #5 (handler stubs) superseded — all 9 handlers implemented or documented; `initialSize` and `sizeLimit` now fully functional. #7 done via lazy-rebuild `surfaceToTab` dictionary.

## 1. ✅ Extract tab cleanup method

**What**: Create `cleanupTabResources(id:)` on `CalyxWindowController` that consolidates the repeated pattern:

```swift
private func cleanupTabResources(id tabID: UUID) {
    browserControllers.removeValue(forKey: tabID)
    diffTasks[tabID]?.cancel()
    diffTasks.removeValue(forKey: tabID)
    diffStates.removeValue(forKey: tabID)
    reviewStores.removeValue(forKey: tabID)
}
```

Call from `closeTab`, `closeActiveGroup`, `closeAllTabsInGroup`, `windowWillClose`.

**Why**: Eliminates 4x duplicated logic, reduces bug surface for tab closing edge cases.

**Visible effect**: Fewer edge cases in tab closing; single point of change for future tab resource types.

## 2. ✅ Fix BrowserServer.generateToken()

**What**: Check `SecRandomCopyBytes` return value:

```swift
private static func generateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        fatalError("Failed to generate secure random token")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}
```

**Why**: Prevents all-zero predictable token on failure. The MCP server already does this check.

**Visible effect**: Eliminates theoretical auth bypass in browser automation.

## 3. ✅ Extract sendKeyEvent helper

**What**: Create a helper for the duplicated Enter-key event pattern:

```swift
private func sendEnterKey(to controller: GhosttySurfaceController) {
    var keyEvent = ghostty_input_key_s()
    keyEvent.keycode = 0x24
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
```

**Why**: DRY -- currently duplicated between `sendComposeText` and `sendReviewToAgent`.

**Visible effect**: Consistent compose/review behavior; single point of change for key event timing.

## 4. ✅ Extract generateHexToken() utility

**What**: Move token generation to a shared utility:

```swift
enum SecurityUtils {
    static func generateHexToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
```

**Why**: 3 call sites with identical logic (`AppDelegate`, `CalyxWindowController`, `BrowserServer`).

**Visible effect**: Reduced duplication, consistent security behavior.

## 5. ⚠️ Delete unused notification names (deferred — not dead code)

**What**: Grep for observers of each notification name. Delete any that have zero observers:

```bash
# Run for each name:
grep -r "ghosttyCloseTab" --include="*.swift" Calyx/
grep -r "ghosttyCloseWindow" --include="*.swift" Calyx/
# ... etc
```

**Why**: 28 notification names defined, but likely 10+ are unused. Reduces confusion for maintainer.

**Visible effect**: Cleaner API surface; easier to understand which notifications matter.

**Audit result**: 9 names (`ghosttyCloseTab`, `ghosttyCloseWindow`, `ghosttyToggleFullscreen`,
`ghosttyRingBell`, `ghosttyShowChildExited`, `ghosttyRendererHealth`, `ghosttyColorChange`,
`ghosttyInitialSize`, `ghosttySizeLimit`) have no observers — but they are posted from
`GhosttyAction.swift` in response to real libghostty callbacks. Deleting them without adding
observers would silently discard real user actions (Cmd+W from ghostty config, bell, etc.).
These are **unimplemented handlers**, not dead code. Fix: add observers in CalyxWindowController.

## 6. ✅ Move performDebugSelect() behind #if DEBUG

**What**: Wrap the 125-line `performDebugSelect()` method and its `debugLog()` helper in `AppDelegate.swift`:

```swift
#if DEBUG
private func performDebugSelect() { ... }
private func debugLog(_ msg: String) { ... }
#endif
```

Also wrap the corresponding key monitor check:

```swift
#if DEBUG
if isUITesting, mods == [.control, .shift],
   event.charactersIgnoringModifiers?.lowercased() == "d" {
    self?.performDebugSelect()
    return nil
}
#endif
```

**Why**: 125 lines of test-only code in production AppDelegate.

**Visible effect**: Cleaner production code; smaller binary.

## 7. ✅ Add reverse lookup to findTab (done)

**What**: Added `surfaceToTab: [UUID: (tab: Tab, group: TabGroup)]` dictionary with lazy rebuild via `surfaceToTabDirty` flag. `findTab(for:)` rebuilds only when the tree changes, then returns O(1).

**Why**: `findTab(for:)` is called on every notification handler and previously did O(n²) scanning.

**Visible effect**: Faster notification handling with many tabs; eliminates cumulative UI lag.

## 8. ✅ Remove dead binding

**What**: Delete line 1324 in `CalyxWindowController.swift`:

```swift
// Before:
@objc func closeTab(_ sender: Any?) {
    guard let tab = activeTab, let group = windowSession.activeGroup else { return }
    closeTab(id: tab.id)
    _ = group // silence warning  <-- DELETE THIS
}

// After:
@objc func closeTab(_ sender: Any?) {
    guard let tab = activeTab else { return }
    closeTab(id: tab.id)
}
```

**Why**: Dead code that exists only to silence a compiler warning about an unused binding.

**Visible effect**: Cleaner code.

## 9. ✅ Add logging to silent catch blocks

**What**: Replace silent error swallowing with logged warnings:

```swift
// CalyxWindowController.swift:1611 (loadMoreCommits)
} catch {
    logger.warning("Failed to load more commits: \(error.localizedDescription)")
}

// CalyxWindowController.swift:1636 (expandCommit)
} catch {
    logger.warning("Failed to expand commit \(hash): \(error.localizedDescription)")
}
```

**Why**: Silent failures make debugging impossible. Two catch blocks currently swallow errors.

**Visible effect**: Easier debugging when git operations fail; visible in Console.app logs.

## 10. ✅ Document nonisolated(unsafe) usage

**What**: Add a `CONCURRENCY.md` in `docs/` explaining:
- Why 25 `nonisolated(unsafe)` instances exist
- Which are C interop pointers (write-once, read-only after init)
- Which are static caches (formatters, paths)
- Which are callback captures (temporary, scoped)

**Why**: Future maintainer needs to understand these are intentional escape hatches, not bugs.

**Visible effect**: Faster onboarding; fewer accidental concurrency mistakes when modifying these files.
