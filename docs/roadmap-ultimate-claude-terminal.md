# Roadmap: The Ultimate Terminal for Claude & Codex

Calyx's goal is to be the best environment in the world for running AI coding agents — not just a terminal that happens to run `claude`, but a platform where Claude and Codex instances can *see* the terminal, *control* it, coordinate with each other, and operate with full situational awareness.

## Current Foundation

Calyx already provides:
- **MCP server** with peer-to-peer IPC: Claude instances in different panes can register, message each other, broadcast, and thread replies
- **Multi-agent workflows**: Solo / Pair / Team templates that auto-spawn and connect agents
- **Browser automation**: Claude can control a browser tab and read page snapshots
- **Git sidebar + diff review**: view status, commits, diffs, and submit review comments back to Claude
- **Compose overlay with broadcast**: type once, send to all panes simultaneously
- **Token usage monitor**: tracks daily/model-level spend from Claude session logs
- **Quick terminal toggle** via MCP tool
- **Named workspaces**: save and restore multi-tab session layouts

---

## Tier 1 — Game Changers

### 1. Expanded MCP Tool Surface ✅ **(Implemented in this iteration)**

Claude should control the terminal itself — not just communicate through it. New tools:

| Tool | What Claude Can Do |
|---|---|
| `get_workspace_state` | See all tabs, groups, and panes with their IDs, titles, and working directories |
| `create_tab` | Open a new terminal tab (with optional pwd, title, and startup command) |
| `create_split` | Split the active pane horizontally or vertically |
| `run_in_pane` | Inject a command into any specific pane by tab ID or pane UUID |
| `focus_pane` | Move keyboard focus to a specific pane |
| `set_tab_title` | Rename a tab |
| `show_notification` | Push a macOS desktop notification |
| `get_git_status` | Get dirty files and current branch |
| `get_pane_output` | Read currently-selected text from a pane |

**Why this matters**: Claude goes from *living inside* the terminal to *operating* it. It can spawn its own workspaces, route output between panes, name tabs by task, and surface information to the user — all without human hand-holding.

---

### 2. Live Agent Status Panel ✅ **(Implemented)**

A sidebar or HUD overlay showing every running Claude/Codex instance across all panes:

- **Status badge**: `active` / `idle` / `away` (inferred from `Peer.lastSeen` in IPCStore)
- **Task identity**: peer name + role from `register_peer`
- **Time since last activity**: staleness indicator
- **Nudge button**: injects "Continue with the next step" into the matching pane (with ✓ confirmation)

---

### 3. Context Bridge / Output Capture ✅ **(Implemented)**

- **Selection → Claude**: select any terminal output → right-click → "Send to Claude" or "Ask Claude to explain"
- Routes to the Claude pane via `runInPaneMatching("claude", ...)`, with desktop notification fallback if no pane is found

---

## Tier 2 — Major Quality of Life

### 4. Prompt Library ✅ **(Implemented)**

- **Save** named prompts via command palette "Save Prompt As…" (dialog with name + content fields)
- **Inject** any saved prompt into the focused pane via command palette `Prompt: {title}`
- **Delete** prompts via command palette `Delete Prompt: {title}`
- Persisted to `~/.calyx/prompts.json` via atomic writes; commands auto-refresh on changes

---

### 5. Pre-Edit Checkpoint Commits ✅ **(Implemented)**

When a Claude session registers via IPC (`register_peer`):
- Auto-creates a `wip: checkpoint before Claude [timestamp]` git commit if the repo is dirty and checkpointing is enabled
- 5-minute cooldown prevents duplicate checkpoints across rapid reconnects
- **Roll back to checkpoint** button appears in the git sidebar when a checkpoint commit is in the recent 10 commits — confirmation alert before `git reset --hard`
- **Command palette**: "Checkpoint Now" (immediate), "Enable/Disable Auto-Checkpoint"
- Enabled flag persisted to `~/.calyx/checkpoint-enabled`; off by default

---

### 6. File Change Tracker ✅ **(Implemented)**

Sidebar tab listing all files modified *in this session* by Claude:
- Grouped by agent/pane
- One-click to open diff for any file
- "All changes" aggregate diff across all agents

---

### 7. Auto-Accept Mode Per Pane ✅ **(Implemented)**

Toggle per pane: when Claude prompts for a tool confirmation, auto-approve it.
- Visual badge `⚡` on the pane's tab while active
- Logged locally so the session record shows what was auto-approved
- This is the single biggest friction point in long autonomous runs

Implemented: `AutoAcceptMonitor` polls each tab's surfaces every 400ms, detects confirmation patterns in the last 12 viewport lines, injects an Enter keypress with 3s cooldown. Visual ⚡ badge in tab bar chip and sidebar row when active. Session log on `Tab.autoAcceptLog`. Toggle via command palette "Toggle Auto-Accept Mode".

---

## Tier 3 — Polish & Power

### 8. Visual IPC Mesh

Minimap-style view showing all connected peers and message flow:
- Nodes = registered peers (Claude instances)
- Arrows animate when messages are sent
- Shows which agents are actively talking
- Click a node to jump to that pane

This is purely presentational — all the data exists in `IPCStore` already.

---

### 9. Token Budget HUD

Per-pane overlay (subtle, top-right corner):
- Tokens used in current session
- Estimated cost
- Warning glow when approaching context limit (~80%)
- Drawn from `ClaudeUsageMonitor` + a per-session context usage estimate

---

### 10. Sequential Task Queue for Codex

Queue multiple tasks for a Codex pane to process one after another:
- Task 1 completes → result context is prepended to task 2 → auto-start
- Backed by the IPC message bus: orchestrator agent manages the queue
- UI: simple list in the sidebar, drag to reorder

---

## Implementation Order

```
✅ Phase 1 (now):     MCP tool surface (9 new tools via TerminalControlBridge)
○  Phase 2 (next):    Agent status panel + nudge
○  Phase 3:           Context bridge / output capture
○  Phase 4:           Prompt library + system prompts
○  Phase 5:           Pre-edit checkpoint commits
✅ Phase 6:           File change tracker
✅ Phase 7:           Auto-accept mode
○  Phase 8-10:        Visual mesh, token HUD, task queue
```

---

## Design Principles

1. **Claude controls Calyx, not the other way around.** Every feature should make Claude more capable of operating autonomously in this environment.
2. **The MCP surface is the primary API.** New capabilities are exposed as MCP tools first; UI second.
3. **Minimal friction.** The fewer clicks required to get an agent running and productive, the better.
4. **Visible state.** The user should always be able to see what every Claude instance is doing.
