// WorkspaceManager.swift
// Calyx
//
// Named workspace save/load. Persists to ~/.calyx/workspaces/{name}.json.
// Each workspace is an independently-encoded SessionSnapshot with a name tag.

import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "WorkspaceManager"
)

// MARK: - WorkspaceManager

@MainActor
enum WorkspaceManager {

    private static let workspacesDir: URL =
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".calyx/workspaces")

    // MARK: - Public API

    /// Persists `snapshot` under the given name, overwriting any existing workspace with the same name.
    static func save(_ snapshot: SessionSnapshot, name: String) throws {
        let sanitized = sanitize(name)
        guard !sanitized.isEmpty else {
            throw WorkspaceError.invalidName(name)
        }
        try FileManager.default.createDirectory(at: workspacesDir,
                                                withIntermediateDirectories: true)
        var tagged = snapshot
        tagged.workspaceName = sanitized
        let data = try JSONEncoder().encode(tagged)
        let dest = workspacesDir.appendingPathComponent("\(sanitized).json")
        // Atomic write via temp + rename
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItem(
            at: dest, withItemAt: tmp,
            backupItemName: nil, options: [],
            resultingItemURL: nil
        )
        logger.info("Saved workspace '\(sanitized)'")
    }

    /// Loads the workspace with `name`. Returns nil if it does not exist.
    static func load(name: String) -> SessionSnapshot? {
        let sanitized = sanitize(name)
        let url = workspacesDir.appendingPathComponent("\(sanitized).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(SessionSnapshot.self, from: data))
            .map { SessionSnapshot.migrate($0) }
    }

    /// Returns all workspace names sorted alphabetically.
    static func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workspacesDir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Deletes the workspace with `name`. Silently ignores missing files.
    static func delete(name: String) throws {
        let sanitized = sanitize(name)
        let url = workspacesDir.appendingPathComponent("\(sanitized).json")
        try? FileManager.default.removeItem(at: url)
        logger.info("Deleted workspace '\(sanitized)'")
    }

    // MARK: - Helpers

    /// Strips characters that are unsafe in file names.
    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
        return name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Errors

enum WorkspaceError: Error, LocalizedError {
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let n):
            return "'\(n)' is not a valid workspace name."
        }
    }
}

