// AgentTools.swift
// CTerm
//
// Tool-use foundation for a reactive agent loop. Defines a minimal tool
// protocol + a whitelist-gated registry with three concrete tools:
// list_dir, read_file, and execute_command.
//
// These tools let the agent explore the workspace dynamically instead of
// relying only on pre-gathered context — the key missing piece that makes
// Warp's agent feel "sighted" while a pre-built-plan agent feels blind.
//
// Integration: call AgentToolRegistry.shared.invoke(name:args:session:) from
// within a reactive planning loop. The registry handles permission checks
// and path whitelisting. Shell execution still flows through ApprovalGate.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentTools")

// MARK: - Tool Protocol

/// One callable tool. `name` is the identifier the LLM uses; `schema` is a
/// JSON-serializable description suitable for function-calling APIs.
@MainActor
protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema describing the tool's arguments. Shape mirrors OpenAI /
    /// Ollama function-calling conventions.
    var parametersSchema: [String: Any] { get }

    /// Execute the tool. Returns a result string the model will see.
    /// Throwing marks the tool call as failed; the error text is fed back.
    func invoke(arguments: [String: Any], context: AgentToolContext) async throws -> String
}

/// Passed to every tool. Gives the tool access to the session's workdir
/// and any scope data it needs for sandboxing.
struct AgentToolContext: Sendable {
    let sessionID: UUID
    let workDir: String?
    let gitBranch: String?
}

enum AgentToolError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, reason: String)
    case pathOutsideSandbox(String)
    case fileTooLarge(Int)
    case notAllowed(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidArgument(let name, let reason):
            return "Invalid argument '\(name)': \(reason)"
        case .pathOutsideSandbox(let path):
            return "Path is outside the allowed sandbox: \(path)"
        case .fileTooLarge(let size):
            return "File too large to read (\(size) bytes; max 200 KB)"
        case .notAllowed(let detail):
            return "Operation not allowed: \(detail)"
        }
    }
}

// MARK: - Registry

@MainActor
final class AgentToolRegistry {
    static let shared = AgentToolRegistry()

    private var tools: [String: AgentTool] = [:]

    private init() {
        register(ListDirTool())
        register(ReadFileTool())
        // execute_command is intentionally NOT registered by default —
        // call-sites should explicitly add it after confirming the session
        // has the right approval posture. Keeping it opt-in avoids accidental
        // command execution during non-interactive loops.
    }

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func unregister(name: String) {
        tools.removeValue(forKey: name)
    }

    var all: [AgentTool] { Array(tools.values) }

    func tool(named name: String) -> AgentTool? { tools[name] }

    /// Invoke a tool by name. Returns a string the model can read.
    /// Never throws to the caller — failures are packaged as error text so
    /// the reactive loop can feed them back to the model.
    func invoke(
        name: String,
        arguments: [String: Any],
        context: AgentToolContext
    ) async -> String {
        guard let tool = tools[name] else {
            logger.warning("AgentTools: unknown tool '\(name)'")
            return "Error: unknown tool '\(name)'"
        }
        do {
            let result = try await tool.invoke(arguments: arguments, context: context)
            logger.debug("AgentTools: \(name) succeeded (\(result.count) chars)")
            return result
        } catch {
            logger.debug("AgentTools: \(name) failed — \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Serialize all registered tools as a JSON-compatible `tools` array
    /// for function-calling LLM requests.
    func schemaPayload() -> [[String: Any]] {
        tools.values.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersSchema,
                ],
            ]
        }
    }
}

// MARK: - Sandbox Helpers

enum AgentPathSandbox {
    /// Resolve a path against the session workdir and confirm it's inside
    /// the workdir subtree. Rejects absolute paths outside the sandbox.
    static func resolve(_ path: String, against workDir: String?) throws -> URL {
        guard let workDir, !workDir.isEmpty else {
            throw AgentToolError.notAllowed("no working directory set for session")
        }
        let base = URL(fileURLWithPath: workDir).standardizedFileURL
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            candidate = base.appendingPathComponent(path).standardizedFileURL
        }
        let baseStr = base.path
        let candStr = candidate.path
        // Allow base itself or any child under base.
        if candStr == baseStr || candStr.hasPrefix(baseStr + "/") {
            return candidate
        }
        throw AgentToolError.pathOutsideSandbox(path)
    }
}

// MARK: - list_dir

struct ListDirTool: AgentTool {
    let name = "list_dir"
    let description = "List files and subdirectories at a path relative to the project root. Use this to explore the codebase structure."
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Path relative to the project root (use '.' for root)",
                ],
                "max_entries": [
                    "type": "integer",
                    "description": "Maximum entries to return (default 50, max 200)",
                ],
            ],
            "required": ["path"],
        ]
    }

    func invoke(arguments: [String: Any], context: AgentToolContext) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw AgentToolError.missingArgument("path")
        }
        let maxEntries = min(200, (arguments["max_entries"] as? Int) ?? 50)
        let url = try AgentPathSandbox.resolve(path, against: context.workDir)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw AgentToolError.invalidArgument("path", reason: "not a directory")
        }

        let entries = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).prefix(maxEntries)

        var lines: [String] = []
        lines.append("Contents of \(path):")
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let name = entry.lastPathComponent
            if isDir {
                lines.append("  \(name)/")
            } else {
                let size = values?.fileSize ?? 0
                lines.append("  \(name) (\(size) bytes)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - read_file

struct ReadFileTool: AgentTool {
    static let maxBytes = 200_000 // 200 KB
    static let defaultMaxLines = 400

    let name = "read_file"
    let description = "Read the contents of a text file, relative to the project root. Returns the file contents with line numbers."
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Path relative to the project root",
                ],
                "max_lines": [
                    "type": "integer",
                    "description": "Max lines to return (default 400)",
                ],
            ],
            "required": ["path"],
        ]
    }

    func invoke(arguments: [String: Any], context: AgentToolContext) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw AgentToolError.missingArgument("path")
        }
        let maxLines = (arguments["max_lines"] as? Int) ?? Self.defaultMaxLines
        let url = try AgentPathSandbox.resolve(path, against: context.workDir)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AgentToolError.invalidArgument("path", reason: "file does not exist or is a directory")
        }

        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            throw AgentToolError.fileTooLarge(size)
        }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("path", reason: "file is not UTF-8 text")
        }

        let lines = text.components(separatedBy: "\n")
        let truncated = lines.count > maxLines
        let head = lines.prefix(maxLines)
        let numbered = head.enumerated().map { idx, line in
            String(format: "%5d  %@", idx + 1, line)
        }.joined(separator: "\n")

        if truncated {
            return numbered + "\n[...truncated after \(maxLines) lines of \(lines.count) total]"
        }
        return numbered
    }
}

// MARK: - execute_command (opt-in)

/// Runs a shell command through ApprovalGate. Only register this tool on
/// sessions where shell execution is expected (i.e. agent sessions that
/// already had ApprovalGate wired up). The result includes exit code + output.
struct ExecuteCommandTool: AgentTool {
    let name = "execute_command"
    let description = "Run a shell command. Subject to approval — dangerous commands will be blocked or prompt the user."
    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "Shell command to execute",
                ],
            ],
            "required": ["command"],
        ]
    }

    func invoke(arguments: [String: Any], context: AgentToolContext) async throws -> String {
        guard let command = arguments["command"] as? String, !command.isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        // Direct execution isn't safe from here because approval is
        // session-scoped. Call-sites that want execute_command must wire it
        // into ExecutionCoordinator instead. Return a sentinel so the caller
        // knows to route the command through the coordinator.
        return "PENDING_EXECUTION: \(command)"
    }
}
