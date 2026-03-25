//
//  MCPProtocol.swift
//  Calyx
//
//  MCP (Model Context Protocol) JSON-RPC types and router for the Calyx IPC system.
//

import Foundation

// MARK: - AnyCodable

/// Type-erased Codable + Equatable wrapper for JSON values.
struct AnyCodable: @unchecked Sendable, Codable, Equatable {

    private enum Storage: Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
        case null
    }

    private let storage: Storage

    // MARK: Typed Initializers

    init(_ value: String) {
        self.storage = .string(value)
    }

    init(_ value: Int) {
        self.storage = .int(value)
    }

    init(_ value: Double) {
        self.storage = .double(value)
    }

    init(_ value: Bool) {
        self.storage = .bool(value)
    }

    init(_ value: [AnyCodable]) {
        self.storage = .array(value)
    }

    init(_ value: [String: AnyCodable]) {
        self.storage = .dictionary(value)
    }

    /// Initialize from an untyped JSON-compatible value.
    /// Accepts String, Int, Double, Bool, [Any], [String: Any], AnyCodable, or nil.
    init(_ value: Any) {
        switch value {
        case let a as AnyCodable:
            self.storage = a.storage
        case let s as String:
            self.storage = .string(s)
        case let b as Bool:
            // Bool must be checked before Int/Double because NSNumber(bool) bridges to both.
            self.storage = .bool(b)
        case let i as Int:
            self.storage = .int(i)
        case let d as Double:
            self.storage = .double(d)
        case let arr as [Any]:
            self.storage = .array(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            self.storage = .dictionary(dict.mapValues { AnyCodable($0) })
        default:
            self.storage = .null
        }
    }

    // MARK: Codable

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.storage = .null
        } else if let b = try? container.decode(Bool.self) {
            self.storage = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self.storage = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self.storage = .double(d)
        } else if let s = try? container.decode(String.self) {
            self.storage = .string(s)
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.storage = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.storage = .dictionary(dict)
        } else {
            self.storage = .null
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .string(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .bool(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .dictionary(let v):
            try container.encode(v)
        case .null:
            try container.encodeNil()
        }
    }

    // MARK: Value Accessors

    var stringValue: String? {
        if case .string(let s) = storage { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = storage { return b }
        return nil
    }

    var dictionaryValue: [String: Any]? {
        guard case .dictionary(let d) = storage else { return nil }
        return d.compactMapValues { $0.rawValue }
    }

    var anyCodableDictionaryValue: [String: AnyCodable]? {
        guard case .dictionary(let d) = storage else { return nil }
        return d
    }

    /// Unwraps the stored value to a plain Swift/Foundation type.
    var rawValue: Any? {
        switch storage {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return nil
        case .array(let v): return v.compactMap { $0.rawValue }
        case .dictionary: return dictionaryValue
        }
    }

    // MARK: Internal Helpers

    /// Convert any Encodable value to AnyCodable via JSON serialization roundtrip.
    fileprivate static func from<T: Encodable>(_ value: T) -> AnyCodable {
        guard let data = try? JSONEncoder().encode(value),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return AnyCodable([String: AnyCodable]())
        }
        return AnyCodable(jsonObject)
    }
}

// MARK: - JSON-RPC Base Types

/// JSON-RPC id — either an integer or a string.
enum JSONRPCId: Sendable, Codable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCId.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected Int or String for JSON-RPC id"
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i):
            try container.encode(i)
        case .string(let s):
            try container.encode(s)
        }
    }
}

/// JSON-RPC 2.0 request.
struct JSONRPCRequest: Sendable, Codable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: [String: AnyCodable]?
}

/// JSON-RPC 2.0 error object.
struct JSONRPCError: Sendable, Codable {
    let code: Int
    let message: String
}

/// JSON-RPC 2.0 response.
struct JSONRPCResponse: Sendable, Codable {
    let jsonrpc: String
    let id: JSONRPCId?
    let result: AnyCodable?
    let error: JSONRPCError?
}

// MARK: - MCP Types

/// Result of the MCP `initialize` method.
struct MCPInitializeResult: Sendable, Codable {
    let protocolVersion: String
    let capabilities: MCPCapabilities
    let serverInfo: MCPServerInfo
    let instructions: String?
}

/// MCP server capabilities.
struct MCPCapabilities: Sendable, Codable {
    let tools: MCPToolsCapability
}

/// MCP tools capability.
struct MCPToolsCapability: Sendable, Codable {
    let listChanged: Bool
}

/// MCP server information.
struct MCPServerInfo: Sendable, Codable {
    let name: String
    let version: String
}

/// MCP tool definition.
struct MCPTool: Sendable, Codable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]
}

/// Result of the MCP `tools/list` method.
struct MCPToolsListResult: Sendable, Codable {
    let tools: [MCPTool]
}

/// Result of an MCP tool call.
struct MCPToolCallResult: Sendable, Codable {
    let content: [MCPContent]
    let isError: Bool
}

/// MCP content block (text type).
struct MCPContent: Sendable, Codable {
    let type: String
    let text: String
}

// MARK: - MCPRouter

/// Routes MCP JSON-RPC requests and builds responses.
struct MCPRouter: Sendable {

    // MARK: - Schema Helpers

    private static func prop(_ type: String, _ desc: String) -> AnyCodable {
        AnyCodable(["type": AnyCodable(type), "description": AnyCodable(desc)] as [String: AnyCodable])
    }

    private static func arrayProp(_ itemType: String, _ desc: String) -> AnyCodable {
        AnyCodable([
            "type": AnyCodable("array"),
            "items": AnyCodable(["type": AnyCodable(itemType)] as [String: AnyCodable]),
            "description": AnyCodable(desc),
        ] as [String: AnyCodable])
    }

    private static func schema(
        properties: [String: AnyCodable],
        required: [String] = []
    ) -> [String: AnyCodable] {
        var s: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
        ]
        if !required.isEmpty {
            s["required"] = AnyCodable(required.map { AnyCodable($0) } as [AnyCodable])
        }
        return s
    }

    /// All tool definitions exposed by this MCP server.
    static var tools: [MCPTool] {
        [
            MCPTool(
                name: "register_peer",
                description: "Register this Claude Code instance as a peer for IPC communication. Call once per session — if a peer with the same name already exists and hasn't expired, your existing peer ID is returned instead of creating a duplicate. Returns your peer_id AND automatically injects live project context (CLAUDE.md content, current git branch, last 5 commits, dirty files, agent memories, failing tests, and active peers) so you can orient yourself without asking the user. Save the returned peer_id — it is required for send_message, receive_messages, broadcast, heartbeat, and report_file_change.",
                inputSchema: schema(
                    properties: [
                        "name": prop("string", "Peer display name — use something descriptive like your working directory or task (e.g. 'calyx-frontend', 'api-refactor')"),
                        "role": prop("string", "Peer role describing your function (e.g. 'reviewer', 'implementer', 'orchestrator')"),
                    ],
                    required: ["name"]
                )
            ),
            MCPTool(
                name: "list_peers",
                description: "List all registered, non-expired peers. Use this to discover other Claude Code instances before sending messages.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "send_message",
                description: "Send a message to a specific peer. The 'to' field accepts either a peer ID (UUID) or a peer name (case-insensitive). Optionally include a 'topic' for structured filtering and 'reply_to' (a message ID) to thread a reply.",
                inputSchema: schema(
                    properties: [
                        "from": prop("string", "Your peer ID"),
                        "to": prop("string", "Target peer ID or peer name"),
                        "content": prop("string", "Message content (max 64KB)"),
                        "topic": prop("string", "Optional topic label for filtering (e.g. 'review-request', 'task-complete', 'question')"),
                        "reply_to": prop("string", "Optional message ID this is a reply to, for threading"),
                    ],
                    required: ["from", "to", "content"]
                )
            ),
            MCPTool(
                name: "broadcast",
                description: "Broadcast a message to all other registered peers (excludes the sender). Useful for announcements like task completion or status updates.",
                inputSchema: schema(
                    properties: [
                        "from": prop("string", "Your peer ID"),
                        "content": prop("string", "Message content (max 64KB)"),
                        "topic": prop("string", "Optional topic label (e.g. 'announcement', 'status')"),
                    ],
                    required: ["from", "content"]
                )
            ),
            MCPTool(
                name: "receive_messages",
                description: "Receive pending messages for this peer. Messages expire after 5 minutes. Use 'since' as a cursor (ISO 8601 timestamp of the last message you received) to avoid re-processing old messages — no ack needed when using a cursor. Use 'topic' to filter to a specific message type.",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Your peer ID"),
                        "since": prop("string", "Optional ISO 8601 timestamp — only return messages newer than this (use as a cursor to avoid re-reading)"),
                        "topic": prop("string", "Optional topic filter — only return messages with this topic"),
                    ],
                    required: ["peer_id"]
                )
            ),
            MCPTool(
                name: "ack_messages",
                description: "Explicitly delete specific messages from your inbox by ID. Optional when using the 'since' cursor on receive_messages — use this only when you want to remove messages before they expire.",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Your peer ID"),
                        "message_ids": arrayProp("string", "Message IDs to delete"),
                    ],
                    required: ["peer_id", "message_ids"]
                )
            ),
            MCPTool(
                name: "get_peer_status",
                description: "Get status information for a specific peer by ID, including name, role, and last activity time.",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Peer ID to look up"),
                    ],
                    required: ["peer_id"]
                )
            ),
            MCPTool(
                name: "heartbeat",
                description: "Signal that this peer is still active without sending a message. Call this periodically during long tasks to prevent your peer registration from expiring (TTL: 10 minutes).",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Your peer ID"),
                    ],
                    required: ["peer_id"]
                )
            ),
            MCPTool(
                name: "show_quick_terminal",
                description: "Toggle the Calyx quick terminal panel (slide-in overlay terminal). Calling this when the panel is hidden shows it; calling it when visible hides it.",
                inputSchema: schema(properties: [:])
            ),

            // MARK: - Terminal Control Tools

            MCPTool(
                name: "get_workspace_state",
                description: "Get the current state of the Calyx workspace: all tab groups, tabs, and panes with their IDs, titles, working directories, and focus state. Use this to discover pane IDs before calling run_in_pane, focus_pane, or set_tab_title.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "create_tab",
                description: "Open a new terminal tab in the active window. Optionally set a working directory, a tab title, and a shell command to run automatically once the shell is ready.",
                inputSchema: schema(
                    properties: [
                        "pwd": prop("string", "Working directory for the new tab. Defaults to the active tab's directory."),
                        "title": prop("string", "Optional title to set on the new tab."),
                        "command": prop("string", "Optional shell command to inject into the new tab once the shell is ready (e.g. 'claude\\n' to start Claude)."),
                    ]
                )
            ),
            MCPTool(
                name: "create_split",
                description: "Split the currently focused terminal pane. Use 'horizontal' to split top/bottom (new pane below) or 'vertical' to split left/right (new pane to the right).",
                inputSchema: schema(
                    properties: [
                        "direction": prop("string", "Split direction: 'horizontal' (new pane below) or 'vertical' (new pane to the right). Defaults to 'vertical'."),
                    ]
                )
            ),
            MCPTool(
                name: "run_in_pane",
                description: "Inject text or a shell command into a specific terminal pane. Use get_workspace_state to find pane IDs. If neither tab_id nor pane_id is given, the active pane is used.",
                inputSchema: schema(
                    properties: [
                        "text": prop("string", "Text to inject into the pane. Include a trailing newline (\\n) or set press_enter=true to execute as a command."),
                        "tab_id": prop("string", "UUID of the target tab. If omitted, the active tab is used."),
                        "pane_id": prop("string", "UUID of the specific pane (split leaf). If omitted, the focused pane in the tab is used."),
                        "press_enter": prop("boolean", "Whether to press Return after injecting the text. Default: false."),
                    ],
                    required: ["text"]
                )
            ),
            MCPTool(
                name: "focus_pane",
                description: "Move keyboard focus to a specific terminal pane by its UUID. Use get_workspace_state to find pane IDs.",
                inputSchema: schema(
                    properties: [
                        "pane_id": prop("string", "UUID of the pane to focus."),
                    ],
                    required: ["pane_id"]
                )
            ),
            MCPTool(
                name: "set_tab_title",
                description: "Rename a terminal tab. Use get_workspace_state to find tab IDs.",
                inputSchema: schema(
                    properties: [
                        "tab_id": prop("string", "UUID of the tab to rename."),
                        "title": prop("string", "New title for the tab."),
                    ],
                    required: ["tab_id", "title"]
                )
            ),
            MCPTool(
                name: "show_notification",
                description: "Push a macOS desktop notification visible to the user. Useful to signal task completion, errors, or milestones when running in the background.",
                inputSchema: schema(
                    properties: [
                        "title": prop("string", "Notification title (keep short)."),
                        "body": prop("string", "Notification body text."),
                    ],
                    required: ["title", "body"]
                )
            ),
            MCPTool(
                name: "get_git_status",
                description: "Get the git status of the active tab's working directory: modified/added/deleted files and current branch. Returns a formatted text summary.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "get_pane_output",
                description: "Read the currently selected text from a terminal pane. The user (or another tool like run_in_pane) must have selected text in the pane first — this returns the active selection. Returns empty string if nothing is selected.",
                inputSchema: schema(
                    properties: [
                        "tab_id": prop("string", "UUID of the target tab. Defaults to the active tab."),
                        "pane_id": prop("string", "UUID of the specific pane. Defaults to the focused pane."),
                    ]
                )
            ),
            MCPTool(
                name: "queue_task",
                description: "Add a task prompt to Calyx's sequential task queue. Tasks are injected one at a time into the target pane; when the current task's agent goes idle the next task starts automatically, with the previous result prepended as context.",
                inputSchema: schema(
                    properties: [
                        "prompt": prop("string", "The full prompt or command to send to the target pane."),
                        "target_peer": prop("string", "Name (or partial name) of the peer/pane to target. Omit to use the queue's configured default target."),
                        "position": prop("number", "Insert at this 0-based position in the queue. Omit to append at end."),
                    ],
                    required: ["prompt"]
                )
            ),
            MCPTool(
                name: "get_queue",
                description: "List all tasks in Calyx's task queue with their current status (pending/running/completed/failed/cancelled) and prompts.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "complete_task",
                description: "Mark the currently running task as completed and advance the queue to the next pending task. Call this from the target pane's agent when it finishes the work assigned by the queue.",
                inputSchema: schema(
                    properties: [
                        "result": prop("string", "Optional short summary of what was accomplished. Prepended as context for the next task."),
                    ]
                )
            ),
            MCPTool(
                name: "clear_queue",
                description: "Cancel and remove all pending tasks from the queue. Running tasks are not affected.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "report_file_change",
                description: "Report that you modified a file. Call this after each file edit so Calyx can track changes in the File Changes sidebar. The path can be relative (to work_dir) or absolute.",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Your peer ID"),
                        "path": prop("string", "Path of the modified file (relative to work_dir or absolute)"),
                        "work_dir": prop("string", "Git repository root (working directory). Defaults to the active tab's directory."),
                    ],
                    required: ["peer_id", "path"]
                )
            ),
            MCPTool(
                name: "get_last_error",
                description: "Get the most recent command failure detected in any terminal tab. Returns the error output snippet, the tab title it came from, and a timestamp. Returns null if no recent error was detected. Use this to proactively check whether a command you dispatched to another pane has failed.",
                inputSchema: schema(
                    properties: [
                        "tab_id": prop("string", "UUID of a specific tab to check. Omit to return the most recent error across all tabs."),
                    ]
                )
            ),
            MCPTool(
                name: "remember",
                description: "Store a persistent project-scoped fact in Calyx's agent memory. Facts survive across sessions and are accessible to any agent in the same project (same git repo). Use this for architecture decisions, conventions, warnings, commands, or anything worth remembering between sessions.",
                inputSchema: schema(
                    properties: [
                        "key": prop("string", "Short identifier for this fact, e.g. 'auth-system', 'test-command', 'avoid'"),
                        "value": prop("string", "The fact to remember. Can be multi-sentence."),
                        "ttl_days": prop("integer", "Optional: delete this memory after N days. Omit for permanent storage."),
                        "work_dir": prop("string", "Working directory to scope the memory to. Defaults to the active tab's directory."),
                        "namespace": prop("string", "Optional namespace prefix for key isolation. Use your peer name (e.g. 'orchestrator') to avoid key collisions with other agents. Keys are stored as '<namespace>/<key>' internally."),
                    ],
                    required: ["key", "value"]
                )
            ),
            MCPTool(
                name: "recall",
                description: "Search project-scoped agent memory for facts matching a query. Returns all memories whose key or value contains the query string. Call with an empty query to list all memories.",
                inputSchema: schema(
                    properties: [
                        "query": prop("string", "Search string. Matches keys and values (case-insensitive). Empty string returns all."),
                        "work_dir": prop("string", "Working directory to scope the search. Defaults to the active tab's directory."),
                        "namespace": prop("string", "Optional namespace prefix for key isolation. Use your peer name (e.g. 'orchestrator') to avoid key collisions with other agents. Keys are stored as '<namespace>/<key>' internally."),
                    ],
                    required: ["query"]
                )
            ),
            MCPTool(
                name: "forget",
                description: "Delete a specific memory by key from the project-scoped agent memory store.",
                inputSchema: schema(
                    properties: [
                        "key": prop("string", "The key of the memory to delete."),
                        "work_dir": prop("string", "Working directory to scope the deletion. Defaults to the active tab's directory."),
                        "namespace": prop("string", "Optional namespace prefix for key isolation. Use your peer name (e.g. 'orchestrator') to avoid key collisions with other agents. Keys are stored as '<namespace>/<key>' internally."),
                    ],
                    required: ["key"]
                )
            ),
            MCPTool(
                name: "list_memories",
                description: "List all persistent agent memories for this project, sorted by most recently updated. Returns key, value, age, and optional expiry for each entry.",
                inputSchema: schema(
                    properties: [
                        "work_dir": prop("string", "Working directory to scope the list. Defaults to the active tab's directory."),
                        "namespace": prop("string", "Optional namespace prefix for key isolation. Use your peer name (e.g. 'orchestrator') to avoid key collisions with other agents. Keys are stored as '<namespace>/<key>' internally."),
                    ]
                )
            ),
            MCPTool(
                name: "get_project_context",
                description: """
                    Get live project context for the current working directory: CLAUDE.md content, \
                    current git branch, last 5 commits, dirty files, agent memories, failing tests, \
                    and active peers. Call this at the start of a session to orient yourself without \
                    asking the user to re-explain the project.
                    """,
                inputSchema: schema(
                    properties: [
                        "work_dir": prop("string", "Working directory to gather context for. Defaults to the active tab's directory."),
                    ]
                )
            ),
            MCPTool(
                name: "get_session_summary",
                description: "Get a summary of the current Calyx session: total events, commands injected, errors routed, memories written, test runs, tasks completed, and checkpoints created. Use this at the end of a session to include an activity summary in a handoff message or status report.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "get_test_results",
                description: "Get the current test run results from Calyx's Test Runner sidebar. Returns pass/fail counts and a list of failing tests. Returns empty results if no test run has been performed yet.",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "run_tests",
                description: "Trigger a test run in Calyx's Test Runner sidebar. If a command is provided it overrides the saved command. Use get_test_results after a delay to read the outcome.",
                inputSchema: schema(
                    properties: [
                        "command": prop("string", "Test command to run, e.g. 'xcodebuild test -scheme CalyxTests'. Omit to use the previously saved command."),
                        "work_dir": prop("string", "Working directory for the test run. Defaults to the active tab's directory."),
                    ]
                )
            ),
            MCPTool(
                name: "search_terminal_output",
                description: "Full-text search across all terminal output captured by Calyx (current and past sessions in the scroll index). Useful for finding previous command output, error messages, or checking if a command was already run. Supports FTS5 syntax: \"exact phrase\", word*, column:value.",
                inputSchema: schema(
                    properties: [
                        "query": prop("string", "Search query. Plain text for substring match, or FTS5 expressions like \\\"exact phrase\\\", word*."),
                        "pane_id": prop("string", "Optional surface UUID to restrict search to a single pane. Omit to search all panes."),
                        "limit": prop("integer", "Maximum results to return (default 30, max 100)."),
                    ],
                    required: ["query"]
                )
            ),
            MCPTool(
                name: "wait_for_pane_idle",
                description: "Wait until a pane's shell is idle (prompt returned after a command). Use after run_in_pane to know when a command has finished before reading output or running the next command. Returns when idle or after timeout.",
                inputSchema: schema(
                    properties: [
                        "pane_id": prop("string", "UUID of the pane to watch. Defaults to the active pane."),
                        "timeout_seconds": prop("number", "Maximum seconds to wait (default 30, max 300)."),
                    ]
                )
            ),
        ]
    }

    /// Static, trusted instructions text. Never inject user-controlled content.
    static let instructions = """
    You are connected to Calyx IPC — a local MCP server that gives you full awareness of and control over the Calyx terminal environment.

    ## Startup ritual (do this immediately, in order)

    1. Call register_peer with a descriptive name and role. This returns your peer_id AND injects live project context (CLAUDE.md, git state, memories, active peers) so you orient yourself without asking the user. Save the peer_id — you need it for all peer tools.
    2. Call set_tab_title to label your terminal tab with your role (e.g. "orchestrator", "reviewer").
    3. Call receive_messages to pick up any queued instructions from other agents or the previous session.

    ## What you can do — tool categories

    ### Peer communication
    - list_peers — see all active Claude Code instances in this window
    - send_message — send a task, question, or result to a peer by name (no UUID lookup needed)
    - broadcast — announce status to all peers at once
    - receive_messages — poll for incoming messages (use 'since' cursor to avoid re-reading)
    - heartbeat — call every few minutes during long tasks to stay registered (TTL: 10 min)

    ### Terminal control
    - get_workspace_state — list all tabs and panes with their IDs, titles, and working directories
    - create_tab — open a new terminal tab, optionally with a command to run immediately
    - create_split — split the current pane horizontally or vertically
    - run_in_pane — inject text or commands into any pane by ID
    - focus_pane — move keyboard focus to a specific pane
    - set_tab_title — rename any tab
    - get_pane_output — read the currently selected text from a pane
    - search_terminal_output — full-text search across all captured terminal history (FTS5)

    ### Task queue (sequential multi-agent coordination)
    - queue_task — enqueue a prompt for a target agent; tasks run one at a time, result is prepended to the next
    - complete_task — signal that the current queued task is done and advance the queue
    - get_queue — inspect queue status (pending/running/completed)
    - clear_queue — cancel all pending tasks

    ### Persistent memory (survives across sessions, scoped to git repo)
    - remember — store a key/value fact (architecture decisions, conventions, warnings, commands)
    - recall — search memories by keyword
    - list_memories — list all memories for this project
    - forget — delete a memory by key

    ### Project context and diagnostics
    - get_project_context — CLAUDE.md, git branch, recent commits, dirty files, memories, failing tests, active peers — call this any time you need to re-orient
    - get_git_status — current branch and modified files
    - get_last_error — most recent shell error across all panes (check this after running commands in other panes)
    - get_session_summary — Calyx session audit log (events, errors routed, tasks completed)

    ### Testing and file tracking
    - run_tests — trigger a test run in Calyx's Test Runner sidebar
    - get_test_results — read pass/fail counts and failing test list
    - report_file_change — notify Calyx's File Changes sidebar when you edit a file

    ### Notifications
    - show_notification — push a macOS desktop notification (signal completion or errors to the user)
    - show_quick_terminal — toggle the quick terminal overlay

    ## Multi-agent patterns

    **Orchestrator**: register as "orchestrator", call get_project_context, use queue_task to assign work to implementer/reviewer agents, poll receive_messages for results, broadcast completion.
    **Implementer**: register, receive task via queue or message, do the work, call report_file_change for each edit, call complete_task when done, send_message result back to orchestrator.
    **Reviewer**: register, receive review-request messages, read context, send_message findings back.

    ## Messaging tips
    - send_message 'to' accepts peer name — no UUID lookup needed
    - Use 'topic' field: "review-request", "task-complete", "question", "error", "status"
    - Use 'reply_to' with a message ID to thread replies
    - Pass 'since' to receive_messages as a cursor to avoid re-reading old messages

    Browser automation tools (browser_*) are available when browser scripting is enabled via the Command Palette.
    """

    /// Build the response for `initialize`.
    static func buildInitializeResponse(id: JSONRPCId, peerID: UUID? = nil) -> JSONRPCResponse {
        var fullInstructions = instructions
        if let peerID {
            fullInstructions += "\n\nYour peer_id is: \(peerID.uuidString). Use this in send_message, receive_messages, and other peer tools."
        }

        let initResult = MCPInitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: MCPCapabilities(
                tools: MCPToolsCapability(listChanged: false)
            ),
            serverInfo: MCPServerInfo(name: "calyx-ipc", version: "1.0.0"),
            instructions: fullInstructions
        )

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(initResult),
            error: nil
        )
    }

    /// Build the response for `tools/list`.
    static func buildToolsListResponse(id: JSONRPCId) -> JSONRPCResponse {
        let toolsList = MCPToolsListResult(tools: tools)

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(toolsList),
            error: nil
        )
    }

    /// Build a JSON-RPC error response.
    static func buildErrorResponse(
        id: JSONRPCId?,
        code: Int,
        message: String
    ) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
    }

    /// Build a tool call result response.
    static func buildToolCallResponse(
        id: JSONRPCId,
        content: [MCPContent],
        isError: Bool
    ) -> JSONRPCResponse {
        let callResult = MCPToolCallResult(content: content, isError: isError)

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(callResult),
            error: nil
        )
    }
}
