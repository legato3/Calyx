# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Calyx is a macOS 26+ native terminal application built on [libghostty](https://github.com/ghostty-org/ghostty). It wraps the Ghostty terminal engine (via xcframework) with a native Liquid Glass UI, adding tabs, splits, sidebar, browser tabs, IPC, and other features on top.

**Tech stack**: Swift 6.2, AppKit + SwiftUI (bridged via `NSHostingView`), libghostty (Metal GPU rendering), XcodeGen for project generation.

## Build Commands

### First-time setup (building libghostty)

```bash
cd ghostty
SSL_CERT_FILE=/etc/ssl/cert.pem zig build -Demit-xcframework=true -Dxcframework-target=native
cd ..
cp -R ghostty/macos/GhosttyKit.xcframework .
```

`SSL_CERT_FILE` is required — without it Zig's HTTP client fails with `TlsInitializationFailed` on macOS.

If you get `cannot execute tool 'metal' due to missing Metal Toolchain`, run:
```bash
xcodebuild -downloadComponent MetalToolchain
```

The `ghostty/` directory is a git submodule. Zig version must match what's in `ghostty/build.zig.zon`.

### Generate Xcode project

```bash
xcodegen generate
```

Must re-run whenever `project.yml` changes. The `.xcodeproj` is not committed.

### Build

```bash
xcodebuild -project Calyx.xcodeproj -scheme Calyx -configuration Debug build
```

### Run tests

```bash
# All unit tests
xcodebuild -project Calyx.xcodeproj -scheme CalyxTests -configuration Debug test

# Single test class
xcodebuild -project Calyx.xcodeproj -scheme CalyxTests -configuration Debug test -only-testing:CalyxTests/SplitTreeTests

# UI tests
xcodebuild -project Calyx.xcodeproj -scheme CalyxUITests -configuration Debug test
```

## Architecture

### Layer overview

```
AppDelegate
  └── GhosttyAppController.shared   (ghostty_app_t singleton, config, callbacks)
  └── AppSession                    (all windows)
       └── WindowSession            (tabs + groups for one NSWindow)
            └── TabGroup            (colored group of tabs)
                 └── Tab            (browser tab OR terminal tab)
                      └── SplitTree (binary tree of panes)
                           └── leaf UUID → SurfaceRegistry → GhosttySurface
```

### Key conventions

- **`@MainActor` everywhere** — all UI and model code is `@MainActor`. Never dispatch UI work off the main actor.
- **All ghostty C API calls go through `GhosttyFFI`** (`Calyx/GhosttyBridge/GhosttyFFI.swift`). This is a thin enum of static wrapper methods — no business logic there.
- **Action dispatch via `NotificationCenter`** — inter-component communication uses named notifications rather than direct calls.
- **`GhosttyAppController.shared`** is the singleton that owns `ghostty_app_t`, manages config reload, and handles C callbacks from libghostty.

### Directory structure

- `Calyx/App/` — `AppDelegate`, `main.swift`
- `Calyx/GhosttyBridge/` — all ghostty integration: `GhosttyFFI`, `GhosttyApp`, `GhosttyConfig`, `GhosttySurface`, `SurfaceView`, `MetalView`, config watcher/reloader, event translation
- `Calyx/Models/` — data model: `AppSession`, `WindowSession`, `TabGroup`, `Tab`, `SplitTree`, `SurfaceRegistry`, `ThemeColor`
- `Calyx/Views/` — SwiftUI views organized by area: `MainWindow/`, `Sidebar/`, `TabBar/`, `Split/`, `Browser/`, `Git/`, `Glass/`
- `Calyx/Features/` — self-contained feature modules: `Browser/`, `CommandPalette/`, `ComposeOverlay/`, `Git/`, `IPC/`, `Notifications/`, `Persistence/`, `QuickTerminal/`, `Search/`, `SecureInput/`, `Settings/`, `Update/`
- `Calyx/Input/` — global event tap, shortcut manager
- `Calyx/Helpers/` — utilities
- `CalyxCLI/` — the `calyx` CLI tool (bundled into app; uses `swift-argument-parser`)
- `CalyxTests/` — unit tests
- `CalyxUITests/` — UI tests (pass `--uitesting` launch arg)

### Split pane model

`SplitTree` is an immutable value-type binary tree (`SplitNode` enum: `.leaf(id: UUID)` or `.split(SplitData)`). Each leaf UUID maps to a `GhosttySurface` via `SurfaceRegistry`. Mutations produce new tree values — no in-place mutation.

### Ghostty config

`GhosttyConfigManager` reads `~/.config/ghostty/config` and applies overrides for Calyx-managed keys (background opacity, blur, etc.). The file watcher triggers debounced reloads via `ConfigReloadCoordinator`. Config changes propagate via `ghostty_app_reload_config`.

### IPC / MCP server

`CalyxMCPServer` implements a local MCP server enabling Claude Code and Codex CLI instances in different terminal panes to communicate. `IPCConfigManager` writes the MCP config to `~/.claude.json` and `~/.codex/config.toml`.

### Browser scripting

`BrowserServer` runs on `localhost:41840`. `BrowserTabBroker` coordinates between `BrowserTabController` instances and the CLI. The `calyx browser` subcommand (in `CalyxCLI/BrowserCommands.swift`) communicates with this server.

## Project configuration

`project.yml` (XcodeGen spec) is the source of truth for targets, dependencies, and build settings. Targets:
- **Calyx** — main app, depends on `GhosttyKit.xcframework`, Sparkle, CalyxCLI
- **CalyxCLI** — `calyx` command-line tool, depends on `swift-argument-parser`
- **CalyxTests** / **CalyxUITests** — test bundles

The `Calyx-Bridging-Header.h` (listed as a `fileGroup`) bridges GhosttyKit C headers into Swift.
