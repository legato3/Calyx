# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Audit

A full codebase audit lives in `docs/audit/`. Read it before major changes. Key docs:
- `docs/audit/02-architecture.md` — structural risks, the CTermWindowController god class problem
- `docs/audit/07-fragility-map.md` — what breaks easily and why
- `docs/audit/10-refactor-plan.md` — incremental decomposition plan

## What This Is

CTerm is a macOS 26+ native terminal application built on [libghostty](https://github.com/ghostty-org/ghostty). It wraps the Ghostty terminal engine (via xcframework) with a native Liquid Glass UI, adding tabs, splits, sidebar, browser tabs, IPC, and other features on top.

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

Must re-run whenever `project.yml` changes. `CTerm.xcodeproj` is generated and not committed.

### Build

```bash
xcodebuild -project CTerm.xcodeproj -scheme CTerm -configuration Debug build
```

### Run tests

```bash
# All unit tests
xcodebuild -project CTerm.xcodeproj -scheme CTermTests -configuration Debug test

# Single test class
xcodebuild -project CTerm.xcodeproj -scheme CTermTests -configuration Debug test -only-testing:CTermTests/SplitTreeTests

# UI tests
xcodebuild -project CTerm.xcodeproj -scheme CTermUITests -configuration Debug test
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
- **All ghostty C API calls go through `GhosttyFFI`** (`CTerm/GhosttyBridge/GhosttyFFI.swift`). This is a thin enum of static wrapper methods — no business logic there.
- **NotificationCenter remains the event bus** — notification payload decoding should go through the typed wrappers in `CTerm/GhosttyBridge/GhosttyNotificationEvents.swift`. Do not add new raw `userInfo` parsing in controllers. **Exception:** agent session lifecycle events (phase changes, approvals, artifacts, completion) flow through the typed `AgentSessionObserver` protocol instead of `NotificationCenter`. Subscribe to sessions via `session.addObserver(self)`.
- **`WindowActions` replaces the old closure explosion** — view-to-controller actions are injected through the SwiftUI environment from `CTermWindowController`.
- **`GhosttyAppController.shared`** is the singleton that owns `ghostty_app_t`, manages config reload, and handles C callbacks from libghostty.
- **No force unwraps, force casts, or `try!` in production code.** Keep it that way.
- **`nonisolated(unsafe)`** is used for documented C interop and read-only-after-init patterns. Follow `docs/CONCURRENCY.md` before adding new ones.

### Known architectural issues

- **`CTermWindowController` is still too large** — despite the extracted controllers (`GitController`, `ReviewController`, `FocusManager`, `BrowserManager`, `ComposeOverlayController`, `SplitController`, `IPCWindowController`, `TabLifecycleController`), it still concentrates too much responsibility. Avoid adding new concerns there.
- **Session and tab lifecycle logic is still distributed** across `AppDelegate`, `CTermWindowController`, and feature controllers. Be careful when changing restore, close, or cleanup behavior.
- **Singleton-heavy design remains** — `GhosttyAppController.shared`, `CTermMCPServer.shared`, `BrowserServer.shared`, `SessionPersistenceActor.shared`, and others still own global state.

### Directory structure

- `CTerm/App/` — `AppDelegate`, `main.swift`
- `CTerm/GhosttyBridge/` — all ghostty integration: `GhosttyFFI`, `GhosttyApp`, `GhosttyConfig`, `GhosttySurface`, `SurfaceView`, `MetalView`, config watcher/reloader, event translation
- `CTerm/Models/` — data model: `AppSession`, `WindowSession`, `TabGroup`, `Tab`, `SplitTree`, `SurfaceRegistry`, `ThemeColor`
- `CTerm/Views/` — SwiftUI views organized by area: `MainWindow/`, `Sidebar/`, `TabBar/`, `Split/`, `Browser/`, `Git/`, `Glass/`, `Agent/` (run panel + activity strip + finding cards), `Approval/` (approval sheet + scope picker)
- `CTerm/Features/` — self-contained feature modules: `ActiveAI/`, `AgentLoop/`, `AgentMemory/`, `AgentPermissions/`, `AgentPlan/`, `AgentSession/`, `Audit/`, `Browser/`, `CommandPalette/`, `ComposeOverlay/`, `Delegation/`, `Git/`, `IPC/`, `Notifications/`, `Ollama/`, `Persistence/`, `QuickTerminal/`, `Search/`, `SecureInput/`, `Settings/`, `TaskQueue/`, `TerminalSearch/`, `TestRunner/`, `TriggerEngine/`, `Usage/`
- `CTerm/Input/` — global event tap, shortcut manager
- `CTerm/Helpers/` — utilities
- `CTermCLI/` — the `cterm` CLI tool (bundled into app; uses `swift-argument-parser`)
- `CTermTests/` — unit tests
- `CTermUITests/` — UI tests (pass `--uitesting` launch arg)

### Split pane model

`SplitTree` is an immutable value-type binary tree (`SplitNode` enum: `.leaf(id: UUID)` or `.split(SplitData)`). Each leaf UUID maps to a `GhosttySurface` via `SurfaceRegistry`. Mutations produce new tree values — no in-place mutation.

### Ghostty config

`GhosttyConfigManager` reads `~/.config/ghostty/config` and applies overrides for CTerm-managed keys (background opacity, blur, etc.). The file watcher triggers debounced reloads via `ConfigReloadCoordinator`. Config changes propagate via `ghostty_app_reload_config`.

### IPC / MCP server

`CTermMCPServer` implements a local MCP server (port 41830-41839) enabling Claude Code and Codex CLI instances in different terminal panes to communicate. `IPCConfigManager` writes the MCP config to `~/.claude.json` and `~/.codex/config.toml`. Backed by `IPCStore` actor with TTL-based peer/message expiration. See `docs/audit/04-networking.md`.

### Browser scripting

`BrowserServer` binds to the first available localhost port in `41840...41849`. `BrowserTabBroker` coordinates between `BrowserTabController` instances and the CLI. The `cterm browser` subcommand (in `CTermCLI/BrowserCommands.swift`) communicates with this server. Both servers use a hand-rolled `HTTPParser` and bearer token auth. See `docs/audit/04-networking.md`.

## Project configuration

`project.yml` (XcodeGen spec) is the source of truth for targets, dependencies, and build settings. Targets:
- **CTerm** — main app, depends on `GhosttyKit.xcframework`, system frameworks, and `CTermCLI`
- **CTermCLI** — `cterm` command-line tool, depends on `swift-argument-parser`
- **CTermTests** / **CTermUITests** — test bundles

The `CTerm-Bridging-Header.h` (listed as a `fileGroup`) bridges GhosttyKit C headers into Swift.

## Session persistence

`SessionPersistenceActor` (Swift actor) saves/restores to `~/.cterm/sessions.json` with atomic temp+rename writes, backup rotation, and crash-loop detection (max 3 recovery attempts). Debounced saves trigger on every meaningful state change via `requestSave()`. Diff tabs are excluded from persistence by design.

## Agent subsystem

The agent stack is unified around one canonical `AgentSession` type. **Every** agent-spawning path — compose bar, multi-step pipeline, MCP `queue_task`, MCP `delegate_task`, trigger rules — flows through `AgentSessionRouter` and registers with `AgentSessionRegistry`. Don't add a new parallel session type.

### Core types (`CTerm/Features/AgentSession/`)

- **`AgentSession`** (`AgentSession.swift`) — `@Observable @MainActor` class. Holds `intent`, `rawPrompt`, `phase`, `plan`, `artifacts`, `result`, `approval`, `triggeredBy`, `memoryKeysUsed`, inline-kind state (`pendingCommand`, `inlineSteps`, etc.), and `browserResearchSession`.
- **`AgentSessionKind`** (`AgentSessionKind.swift`) — `.inline` (compose bar loop) / `.multiStep` (full plan pipeline) / `.queued` (from `TaskQueueStore`) / `.delegated` (projection of a `DelegationContract`). Plus `AgentBackend`: `.ollama`, `.claudeSubscription`, `.peer(name:)`.
- **`AgentPhase`** (`AgentPhase.swift`) — unified 8-state machine: `idle / thinking / awaitingApproval / running / summarizing / completed / failed / cancelled`.
- **`AgentSessionRouter`** (`AgentSessionRouter.swift`) — singleton. All spawners call `.start(AgentSessionRequest(...))`. Enriches the prompt via `AgentPromptContextBuilder`/`ProjectContextProvider` when `enrichContext: true`, snapshots `memoryKeysUsed`, and registers.
- **`AgentSessionRegistry`** (`AgentSessionRegistry.swift`) — live sessions + bounded history. Kind-grouped queries: `.inlineSessions / .multiStepSessions / .queuedSessions / .delegatedSessions / .active / .sessions(forTab:)`.
- **`AgentSessionObserver`** (`AgentSessionObserver.swift`) — protocol with `didTransitionTo`, `didRequestApproval`, `didProduce(artifact:)`, `didComplete(result:)`. Implemented by `ActiveAISuggestionEngine` and `ApprovalPresenter`.
- **`AgentResult`** + **`NextAction`** (`AgentResult.swift`) — post-run summary with `summary`, `filesChanged`, `nextActions` (confidence-scored), `durationMs`, `handoffMemoryKey`, `exitStatus`. Built by `ResultSummarizer` and delivered via `session.complete(with:)`.

### Approval pipeline (`CTerm/Features/AgentPermissions/`)

Every shell / browser action routes through `ApprovalGate.evaluate(...)` which composes:

1. **`HardStopGuard`** — `rm -rf /`, `git push --force` to protected branches, `git reset --hard` on main, `sudo rm`/`dd`/`mkfs`, `--no-verify`. Returns a `HardStopReason` that forces the approval sheet with scope locked to `.once`.
2. **`AgentGrantStore`** — scope cache (`.once / .thisTask / .thisRepo / .thisSession`). In-memory for session/task, file-per-repo at `~/.cterm/grants/<sha256(pwd).prefix(16)>.json` for repo-scope. Matches on `(category, riskTier, commandPrefix)`.
3. **`AgentPermissionsStore`** — global trust mode fallback (`askMe / trustSession`).

`ApprovalPresenter` observes every registered session. When one calls `requestApproval(ApprovalContext)`, it shows `ApprovalSheet`. On resolve it records the grant and invokes the executor's `onApprovalResolved` callback to resume. `ExecutionCoordinator.presentApproval(...)` parks the step and wires the callback.

### Drivers

- **`AgentLoopCoordinator`** (`Features/AgentLoop/`) — multi-step pipeline. Classifies intent (`IntentRouter`), builds plan (`PlanBuilder`), auto-approves safe steps or transitions to `.awaitingApproval`, drives `ExecutionCoordinator`, calls `ResultSummarizer` on completion.
- **`ExecutionCoordinator`** — reads `AgentPlanStep.kind` directly (no more command-prefix parsing), dispatches via strategy (`.localShell / .browserAction / .browserResearch / .peerDelegation / .informational`), watchdog, replan-on-failure, budget check.
- **Inline loop** — `ComposeOverlayController.planNextAgentStep` for `kind: .inline` sessions attached to a `Tab` via `Tab.ollamaAgentSession`.
- **`TaskQueueStore`** — wraps each queued task in an `AgentSession(kind: .queued)` via the router; `syncSessionPhase` keeps session phase aligned with queue state.
- **`DelegationCoordinator`** — creates an `AgentSession(kind: .delegated, backend: .peer(name:))` per contract; `syncSessionPhase` mirrors contract status changes.
- **`TriggerEngine`** — fires rules, logs every action to `SessionAuditLogger` as `.triggerFired`. When a rule spawns an agent action, `triggeredBy: rule.name` gets set on the resulting session.

### Planning (`CTerm/Features/AgentPlan/`)

`AgentPlan` holds `[AgentPlanStep]`. Each step carries explicit `kind: StepKind` (`.shell / .browser / .peer / .manual`, inferred by `StepKind.infer(from: command)` when not set) and a pre-computed `willAsk: Bool` — a simulation of `ApprovalGate` at plan-build time so the run panel can flag risky rows up front. `AgentPlanStore.approveSafeSteps()` lets the user approve all `!willAsk` rows in one click.

### UI surfaces (`CTerm/Views/Agent/` + `CTerm/Views/Approval/`)

- **`AgentRunPanelRegion`** — renders below terminal content, above compose bar. Picks strip vs card based on `session.isRunPanelCollapsed`. Currently bound to `activeTab.ollamaAgentSession` (inline kind), remains visible after terminal phases so the user can review summary + findings. Handles per-step approve/skip + browser finding save + NextAction prefill.
- **`AgentRunPanelView`** — the card. Header with `🧠 N` memory chip, `⚡ rule` trigger chip, kind icon. Status line, plan stepper (via `AgentRunPlanStepper` with per-row kind badges + will-ask warning + inline Approve/Skip), running block, approval block, summary block (exit-status line + files changed + failed disclosure + NextAction buttons + "Continue: <goal>" from handoff memory), browser research block.
- **`AgentActivityStrip`** + **`AgentActivityChip`** — horizontal chip strip below the compose bar sourced from `AgentSessionRegistry.active`. Shows every non-terminal session across tabs/kinds. Clicking chips switches tabs / opens `TaskQueue`/`Delegations` sidebars.
- **`ApprovalSheet`** + **`ApprovalScopePicker`** + **`ApprovalSheetHost`** — modal sheet with what/why/impact/rollback rows; hard-stops render red with scope locked to `.once`.
- **`BrowserFindingCard`** + **`BrowserResearchProgressStrip`** — browser workflow finding cards (URL + preview + expand + Save) + live progress line with step counter.

### Memory (`CTerm/Features/AgentMemory/`)

- **`AgentMemoryStore`** — project-scoped at `~/.cterm/memories/<projectKey>.json`, 7 categories with default TTLs/importance, relevance-scored retrieval, handoff persistence (`saveHandoff` / `lastHandoff`).
- **`ProjectContextProvider`** — gathers git branch, dirty files, CLAUDE.md, failing tests, active peers, and top-15 relevance-scored memories into an `<cterm_project_context>` block injected by `AgentPromptContextBuilder`. New fast query `memoryKeysForPreview(workDir:intent:)` powers the run panel's 🧠 N chip.

### Persistence

Active `AgentSession` records are serialized into `SessionSnapshot.agentSessions` (schema v5+) via `AgentSessionSnapshot`. On app launch `AppDelegate.restoreSession()` rehydrates them into the registry before tab restoration. Covers `intent`, `phase`, `kind`, `backend`, `triggeredBy`, `pendingCommand`, `inlineSteps`, etc. Scoped grants persist to `~/.cterm/grants/`.

### Audit

`SessionAuditLogger` records phase transitions, command dispatches, browser steps, memory writes, and trigger fires (`.triggerFired` event with `'<rule>' → <action>: <context>`). Rendered in the Session Log sidebar.
