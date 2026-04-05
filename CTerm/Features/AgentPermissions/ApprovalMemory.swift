// ApprovalMemory.swift
// CTerm
//
// Tracks user approval decisions so repeated actions become less annoying.
// Three scopes of memory:
//   - Session: remembered until the tab/session closes
//   - Project: persisted per-project via AgentMemoryStore (survives restarts)
//   - Global:  persisted in UserDefaults (applies everywhere)
//
// Memory entries are keyed by a normalized "command pattern" — the command
// with variable parts (paths, hashes, numbers) replaced by placeholders.
// This means approving "git push origin feature/foo" also covers
// "git push origin feature/bar".

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ApprovalMemory")

// MARK: - Memory Scope

enum ApprovalScope: String, Codable, Sendable {
    case session  // until tab closes
    case project  // persisted per-project
    case global   // persisted globally
}

// MARK: - Remembered Approval

struct RememberedApproval: Codable, Sendable {
    let pattern: String
    let scope: ApprovalScope
    let tier: String          // RiskTier.rawValue at time of approval
    let approvedAt: Date
    let expiresAt: Date?      // nil = no expiry (session scope expires with session)

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }
}

// MARK: - Approval Memory

@MainActor
final class ApprovalMemory {
    static let shared = ApprovalMemory()

    /// Session-scoped approvals (cleared when session ends).
    private var sessionApprovals: [String: RememberedApproval] = [:]

    /// Project-scoped approvals loaded from AgentMemoryStore.
    /// Key: projectKey, Value: [pattern: approval]
    private var projectCache: [String: [String: RememberedApproval]] = [:]

    private let globalDefaultsKey = "cterm.approvalMemory.global"

    /// Global approvals from UserDefaults.
    private var globalApprovals: [String: RememberedApproval] = [:]

    private init() {
        loadGlobalApprovals()
    }

    // MARK: - Query

    /// Check if a command has been previously approved in any scope.
    func isRemembered(command: String, projectKey: String?) -> Bool {
        let pattern = Self.normalize(command)

        // Session scope (fastest)
        if let entry = sessionApprovals[pattern], !entry.isExpired {
            return true
        }

        // Project scope
        if let projectKey {
            loadProjectCacheIfNeeded(projectKey)
            if let entry = projectCache[projectKey]?[pattern], !entry.isExpired {
                return true
            }
        }

        // Global scope
        if let entry = globalApprovals[pattern], !entry.isExpired {
            return true
        }

        return false
    }

    // MARK: - Remember

    /// Record an approval decision.
    func remember(command: String, tier: RiskTier, scope: ApprovalScope, projectKey: String?) {
        let pattern = Self.normalize(command)
        let ttl: Date? = {
            switch scope {
            case .session: return nil // expires with session
            case .project: return Date().addingTimeInterval(30 * 86400) // 30 days
            case .global:  return Date().addingTimeInterval(90 * 86400) // 90 days
            }
        }()

        let approval = RememberedApproval(
            pattern: pattern,
            scope: scope,
            tier: tier.rawValue,
            approvedAt: Date(),
            expiresAt: ttl
        )

        switch scope {
        case .session:
            sessionApprovals[pattern] = approval

        case .project:
            guard let projectKey else { return }
            projectCache[projectKey, default: [:]][pattern] = approval
            persistProjectApprovals(projectKey)

        case .global:
            globalApprovals[pattern] = approval
            saveGlobalApprovals()
        }

        logger.info("ApprovalMemory: remembered \(pattern.prefix(60)) [\(scope.rawValue)]")
    }

    /// Bulk-remember all items in a batch.
    func rememberBatch(_ batch: ApprovalBatch, scope: ApprovalScope, projectKey: String?) {
        for item in batch.items {
            remember(command: item.command, tier: batch.tier, scope: scope, projectKey: projectKey)
        }
    }

    // MARK: - Clear

    func clearSession() {
        sessionApprovals.removeAll()
    }

    func clearProject(_ projectKey: String) {
        projectCache.removeValue(forKey: projectKey)
        AgentMemoryStore.shared.forget(projectKey: projectKey, key: "approval_memory")
    }

    func clearGlobal() {
        globalApprovals.removeAll()
        UserDefaults.standard.removeObject(forKey: globalDefaultsKey)
    }

    // MARK: - Pattern Normalization

    /// Normalize a command into a pattern by replacing variable parts with placeholders.
    /// "git push origin feature/login" → "git push origin <branch>"
    /// "rm -rf /tmp/build-12345" → "rm -rf <path>"
    static func normalize(_ command: String) -> String {
        var result = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Replace git hashes (7+ hex chars)
        result = result.replacingOccurrences(
            of: "\\b[0-9a-f]{7,40}\\b",
            with: "<hash>",
            options: .regularExpression
        )

        // Replace branch names after git push/pull/checkout/switch
        let branchCommands = ["git push", "git pull", "git checkout", "git switch",
                              "git merge", "git rebase"]
        for prefix in branchCommands {
            if result.hasPrefix(prefix) {
                // Keep the remote name (e.g., "origin") but replace branch
                let parts = result.split(whereSeparator: \.isWhitespace)
                if parts.count >= 4 {
                    // "git push origin branch-name" → "git push origin <branch>"
                    let base = parts.prefix(3).joined(separator: " ")
                    result = base + " <branch>"
                }
            }
        }

        // Replace numeric suffixes (build numbers, PIDs, ports)
        result = result.replacingOccurrences(
            of: "\\b\\d{4,}\\b",
            with: "<num>",
            options: .regularExpression
        )

        // Replace absolute paths with <path> (keep first two components)
        result = result.replacingOccurrences(
            of: "(/[\\w.-]+){3,}",
            with: "<path>",
            options: .regularExpression
        )

        return result
    }

    // MARK: - Persistence

    private func loadGlobalApprovals() {
        guard let data = UserDefaults.standard.data(forKey: globalDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: RememberedApproval].self, from: data)
        else { return }
        globalApprovals = decoded.filter { !$0.value.isExpired }
    }

    private func saveGlobalApprovals() {
        let live = globalApprovals.filter { !$0.value.isExpired }
        if let data = try? JSONEncoder().encode(live) {
            UserDefaults.standard.set(data, forKey: globalDefaultsKey)
        }
    }

    private func loadProjectCacheIfNeeded(_ projectKey: String) {
        guard projectCache[projectKey] == nil else { return }
        let entries = AgentMemoryStore.shared.recall(projectKey: projectKey, query: "approval_memory")
        guard let entry = entries.first,
              let data = entry.value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: RememberedApproval].self, from: data)
        else {
            projectCache[projectKey] = [:]
            return
        }
        projectCache[projectKey] = decoded.filter { !$0.value.isExpired }
    }

    private func persistProjectApprovals(_ projectKey: String) {
        guard let approvals = projectCache[projectKey] else { return }
        let live = approvals.filter { !$0.value.isExpired }
        guard let data = try? JSONEncoder().encode(live),
              let json = String(data: data, encoding: .utf8) else { return }
        AgentMemoryStore.shared.remember(
            projectKey: projectKey,
            key: "approval_memory",
            value: json,
            ttlDays: 30
        )
    }
}
