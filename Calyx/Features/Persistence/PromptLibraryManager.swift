// PromptLibraryManager.swift
// Calyx
//
// Persists user-saved prompts to ~/.calyx/prompts.json.
// Prompts are injected into terminal panes from the command palette.

import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "PromptLibraryManager"
)

// MARK: - PromptEntry

struct PromptEntry: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var content: String
    let createdAt: Date
}

// MARK: - PromptLibraryManager

/// Manages the user's saved prompt library, persisted to ~/.calyx/prompts.json.
@MainActor
enum PromptLibraryManager {

    private static let promptsURL: URL =
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".calyx/prompts.json")

    // MARK: - Public API

    /// Returns all saved prompts, sorted by creation date (oldest first).
    static func all() -> [PromptEntry] {
        guard let data = try? Data(contentsOf: promptsURL) else { return [] }
        return (try? JSONDecoder().decode([PromptEntry].self, from: data)) ?? []
    }

    /// Adds or updates a prompt (matched by id). Persists immediately.
    static func save(_ entry: PromptEntry) {
        var entries = all()
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        writeAll(entries)
    }

    /// Removes the prompt with the given id. Silently ignores missing ids.
    static func delete(id: UUID) {
        var entries = all()
        entries.removeAll { $0.id == id }
        writeAll(entries)
    }

    // MARK: - Helpers

    private static func writeAll(_ entries: [PromptEntry]) {
        do {
            let dir = promptsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            let tmp = promptsURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItem(
                at: promptsURL, withItemAt: tmp,
                backupItemName: nil, options: [],
                resultingItemURL: nil
            )
            logger.info("Saved prompt library (\(entries.count) entries)")
        } catch {
            logger.error("Failed to write prompt library: \(error.localizedDescription)")
        }
    }
}
