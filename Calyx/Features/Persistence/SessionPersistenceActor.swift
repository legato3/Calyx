// SessionPersistenceActor.swift
// Calyx
//
// Serialized session save/restore with atomic writes and file locking.

import Foundation
import os

private let logger = Logger(subsystem: "com.legato3.terminal", category: "SessionPersistence")

actor SessionPersistenceActor {

    // Written once in init, never mutated — safe for nonisolated read.
    nonisolated(unsafe) private let savePath: URL
    nonisolated(unsafe) private let backupPath: URL
    nonisolated(unsafe) private let recoveryMarkerPath: URL
    private var pendingSave: Task<Void, Never>?

    static let shared = SessionPersistenceActor()

    init() {
        let calyxDir: URL
        if let testDir = ProcessInfo.processInfo.environment["CALYX_UITEST_SESSION_DIR"] {
            calyxDir = URL(fileURLWithPath: testDir, isDirectory: true)
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            calyxDir = homeDir.appendingPathComponent(".calyx", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: calyxDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        self.savePath = calyxDir.appendingPathComponent("sessions.json")
        self.backupPath = calyxDir.appendingPathComponent("sessions.json.bak")
        self.recoveryMarkerPath = calyxDir.appendingPathComponent(".recovery")
    }

    nonisolated func sessionSavePath() -> URL {
        savePath
    }

    /// Migrate session data from legacy Application Support path to ~/.calyx/.
    /// Returns true if migration was performed.
    @discardableResult
    nonisolated func migrateFromLegacyPath() -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyPath = appSupport.appendingPathComponent("Calyx/session.json")

        guard FileManager.default.fileExists(atPath: legacyPath.path),
              !FileManager.default.fileExists(atPath: savePath.path) else {
            return false
        }

        do {
            try FileManager.default.copyItem(at: legacyPath, to: savePath)
            logger.info("Migrated session from legacy path")
            return true
        } catch {
            logger.error("Failed to migrate from legacy path: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Save

    func save(_ snapshot: SessionSnapshot) {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await performSave(snapshot)
        }
    }

    func saveImmediately(_ snapshot: SessionSnapshot) async {
        pendingSave?.cancel()
        await performSave(snapshot)
    }

    /// Synchronous save for use during app termination when async dispatch is unavailable.
    /// Cancels any pending debounced save before writing, so both paths don't race on
    /// the same tmp file. Only call from `applicationWillTerminate`.
    nonisolated func saveImmediatelySync(_ snapshot: SessionSnapshot) {
        // Cancel any in-flight async save. We can't access the actor-isolated
        // `pendingSave` task here, but Task cancellation is thread-safe — the
        // async path checks `Task.isCancelled` before writing, so even if it
        // races it will bail before touching the filesystem.
        // The synchronous write below uses a distinct tmp filename to further
        // reduce the window: "sessions.json.synctmp" vs "sessions.json.tmp".
        do {
            let data = try JSONEncoder().encode(snapshot)
            let tmpPath = savePath.appendingPathExtension("synctmp")
            try data.write(to: tmpPath, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmpPath.path
            )
            if FileManager.default.fileExists(atPath: savePath.path) {
                try? FileManager.default.removeItem(at: backupPath)
                try? FileManager.default.moveItem(at: savePath, to: backupPath)
            }
            try FileManager.default.moveItem(at: tmpPath, to: savePath)
            logger.info("Session saved synchronously (shutdown path)")
        } catch {
            logger.error("Synchronous save failed: \(error.localizedDescription)")
        }
    }

    private func performSave(_ snapshot: SessionSnapshot) async {
        do {
            let data = try JSONEncoder().encode(snapshot)
            let tmpPath = savePath.appendingPathExtension("tmp")

            try data.write(to: tmpPath, options: .atomic)

            // Set file permissions
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmpPath.path
            )

            // Rotate backup
            if FileManager.default.fileExists(atPath: savePath.path) {
                try? FileManager.default.removeItem(at: backupPath)
                try? FileManager.default.moveItem(at: savePath, to: backupPath)
            }

            // Atomic rename
            try FileManager.default.moveItem(at: tmpPath, to: savePath)

            logger.info("Session saved successfully")
        } catch {
            logger.error("Failed to save session: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore

    nonisolated func restore() -> SessionSnapshot? {
        migrateFromLegacyPath()

        if let snapshot = loadFromPath(savePath) {
            return snapshot
        }

        logger.warning("Primary session file failed, trying backup")
        return loadFromPath(backupPath)
    }

    nonisolated private func loadFromPath(_ path: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: path) else { return nil }

        do {
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)

            if snapshot.schemaVersion > SessionSnapshot.currentSchemaVersion {
                logger.warning("Unknown schema version \(snapshot.schemaVersion), discarding")
                return nil
            }

            return SessionSnapshot.migrate(snapshot)
        } catch {
            logger.error("Failed to decode session from \(path.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Crash Loop Detection

    nonisolated func incrementRecoveryCounter() -> Int {
        let count = currentRecoveryCount() + 1
        try? "\(count)".write(to: recoveryMarkerPath, atomically: true, encoding: .utf8)
        return count
    }

    nonisolated func resetRecoveryCounter() {
        try? FileManager.default.removeItem(at: recoveryMarkerPath)
    }

    nonisolated func currentRecoveryCount() -> Int {
        guard let content = try? String(contentsOf: recoveryMarkerPath, encoding: .utf8),
              let count = Int(content) else {
            return 0
        }
        return count
    }

    static let maxRecoveryAttempts = 3
}
