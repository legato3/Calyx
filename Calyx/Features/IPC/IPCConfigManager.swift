// IPCConfigManager.swift
// Calyx
//
// Coordinates IPC config registration across Claude Code and Codex,
// collecting results independently so one failure does not block the other.

import Foundation

// MARK: - ConfigStatus

enum ConfigStatus: Sendable {
    case success
    case skipped(reason: String)
    case failed(Error)
}

// MARK: - IPCConfigResult

struct IPCConfigResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus

    var anySucceeded: Bool {
        if case .success = claudeCode { return true }
        if case .success = codex { return true }
        return false
    }
}

// MARK: - IPCConfigManager

struct IPCConfigManager: Sendable {

    // MARK: - Public API

    /// Enables IPC MCP server config in both Claude Code and Codex config files.
    /// Each tool is handled independently — one failing does not prevent the other.
    static func enableIPC(port: Int, token: String) -> IPCConfigResult {
        let claudeCode = enableClaudeCode(port: port, token: token)
        let codex = enableCodex(port: port, token: token)
        return IPCConfigResult(claudeCode: claudeCode, codex: codex)
    }

    /// Disables IPC MCP server config in both Claude Code and Codex config files.
    /// Does not check directory existence — the individual managers handle missing files as no-ops.
    static func disableIPC() -> IPCConfigResult {
        let claudeCode = disableClaudeCode()
        let codex = disableCodex()
        return IPCConfigResult(claudeCode: claudeCode, codex: codex)
    }

    /// Returns whether IPC is currently enabled in each tool's config.
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool) {
        (
            claudeCode: ClaudeConfigManager.isIPCEnabled(),
            codex: CodexConfigManager.isIPCEnabled()
        )
    }

    // MARK: - Private: Claude Code

    private static func enableClaudeCode(port: Int, token: String) -> ConfigStatus {
        let claudeDir = NSHomeDirectory() + "/.claude/"
        guard directoryExists(at: claudeDir) else {
            return .skipped(reason: "not installed")
        }
        do {
            try ClaudeConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableClaudeCode() -> ConfigStatus {
        do {
            try ClaudeConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Codex

    private static func enableCodex(port: Int, token: String) -> ConfigStatus {
        let codexDir = NSHomeDirectory() + "/.codex/"
        guard directoryExists(at: codexDir) else {
            return .skipped(reason: "not installed")
        }
        do {
            try CodexConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableCodex() -> ConfigStatus {
        do {
            try CodexConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Helpers

    /// Checks that a path exists and is a directory (not a file).
    private static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
