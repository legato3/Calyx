// CheckpointManager.swift
// Calyx
//
// Creates "wip: checkpoint" git commits before Claude edits, so users can always
// roll back. Auto-triggered on IPC peer registration when enabled.

import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "CheckpointManager"
)

private let enabledFlagURL: URL =
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".calyx/checkpoint-enabled")

/// Minimum seconds between automatic checkpoints (debounce).
private let autoCheckpointCooldown: TimeInterval = 300  // 5 minutes

@MainActor
final class CheckpointManager {

    static let shared = CheckpointManager()

    // MARK: - State

    /// Whether automatic checkpointing is active. Persisted to disk.
    var isEnabled: Bool {
        didSet { persistEnabled() }
    }

    /// Hash of the most recently created checkpoint commit, if any.
    private(set) var lastCheckpointHash: String?
    private(set) var lastCheckpointDate: Date?

    private var lastAutoCheckpointDate: Date?

    // MARK: - Init

    private init() {
        isEnabled = FileManager.default.fileExists(atPath: enabledFlagURL.path)
    }

    // MARK: - Public API

    /// Immediately creates a checkpoint commit for the given working directory.
    /// Stages all changes, commits with a timestamped message.
    /// - Returns: the new commit hash, or nil if the repo is clean or an error occurred.
    @discardableResult
    func checkpoint(workDir: String) async -> String? {
        do {
            let root = try await GitService.repoRoot(workDir: workDir)
            guard await GitService.isRepoDirty(workDir: root) else {
                logger.info("Checkpoint skipped — repo is clean at \(root)")
                return nil
            }
            try await GitService.stageAll(workDir: root)
            let dateStr = ISO8601DateFormatter().string(from: Date())
            let message = "wip: checkpoint before Claude [\(dateStr)]"
            let hash = try await GitService.commit(message: message, workDir: root)
            lastCheckpointHash = hash
            lastCheckpointDate = Date()
            logger.info("Checkpoint created: \(hash) at \(root)")
            return hash
        } catch {
            logger.error("Checkpoint failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Called automatically on IPC peer registration. Creates a checkpoint only if:
    ///  - `isEnabled` is true
    ///  - `workDir` is non-nil and inside a git repo
    ///  - The repo is dirty
    ///  - At least `autoCheckpointCooldown` seconds have passed since the last auto-checkpoint
    func maybeAutoCheckpoint(workDir: String?) async {
        guard isEnabled else { return }
        guard let workDir else { return }

        if let last = lastAutoCheckpointDate,
           Date().timeIntervalSince(last) < autoCheckpointCooldown {
            logger.debug("Auto-checkpoint skipped — cooldown active")
            return
        }

        lastAutoCheckpointDate = Date()
        await checkpoint(workDir: workDir)
    }

    /// Rolls back the working tree to the given commit hash using `git reset --hard`.
    /// Callers are responsible for confirming with the user before calling this.
    func rollback(to hash: String, workDir: String) async throws {
        let root = try await GitService.repoRoot(workDir: workDir)
        try await GitService.resetHard(to: hash, workDir: root)
        lastCheckpointHash = nil
        lastCheckpointDate = nil
        logger.info("Rolled back to \(hash) at \(root)")
    }

    // MARK: - Persistence

    private func persistEnabled() {
        if isEnabled {
            try? "1".write(to: enabledFlagURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: enabledFlagURL)
        }
    }
}
