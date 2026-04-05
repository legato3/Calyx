// ProjectContextProvider.swift
// CTerm
//
// Gathers live project context for ambient injection into new agent sessions.
// All operations are synchronous and fast (<50ms typical) — safe to call from
// background MCP handler threads.
//
// Context budgeting: total output is capped to avoid bloating agent prompts.
// Memories are filtered by relevance, not dumped wholesale.

import Foundation

enum ProjectContextProvider {

    // MARK: - Budget Constants

    /// Max total characters for the formatted context block.
    private static let totalBudget = 6000
    /// Max characters allocated to CLAUDE.md content.
    private static let claudeMdBudget = 2000
    /// Max characters allocated to AGENTS.md content.
    private static let agentsMdBudget = 2000
    /// Max characters allocated to memories.
    private static let memoryBudget = 1500
    /// Max number of memories to include.
    private static let maxMemories = 15

    // MARK: - Public API

    /// Build a context dictionary for the given working directory.
    /// Includes: CLAUDE.md (budgeted), git branch, recent commits, dirty files,
    /// relevant agent memories (scored), failing tests, and active peers.
    static func gather(workDir: String, intent: String? = nil) -> [String: Any] {
        let gitRoot = gitOutput(["-C", workDir, "rev-parse", "--show-toplevel"], in: workDir)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let root = gitRoot ?? workDir

        var ctx: [String: Any] = ["cwd": workDir]

        // CLAUDE.md — look at git root first, then cwd. Budget-trimmed.
        if let md = readFile(atPath: "\(root)/CLAUDE.md") ?? readFile(atPath: "\(workDir)/CLAUDE.md") {
            ctx["claude_md"] = budgetClaudeMd(md)
        }

        // AGENTS.md — agent-specific instructions. Priority: .cterm/AGENTS.md at
        // root, then AGENTS.md at root, then at cwd. Budget-trimmed separately
        // from CLAUDE.md so both can coexist.
        let agentsPaths = [
            "\(root)/.cterm/AGENTS.md",
            "\(root)/AGENTS.md",
            "\(workDir)/AGENTS.md",
        ]
        if let agents = agentsPaths.lazy.compactMap({ readFile(atPath: $0) }).first {
            ctx["agents_md"] = budgetMarkdown(agents, limit: agentsMdBudget)
        }

        // Git metadata
        if let branch = gitOutput(["-C", workDir, "branch", "--show-current"], in: workDir)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            ctx["branch"] = branch
        }

        let commits = gitOutput(["-C", workDir, "log", "--oneline", "-5"], in: workDir)?
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !commits.isEmpty { ctx["recent_commits"] = commits }

        // Dirty files: staged + unstaged, deduplicated
        let staged = gitOutput(["-C", workDir, "diff", "--name-only", "--cached"], in: workDir)?
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        let unstaged = gitOutput(["-C", workDir, "diff", "--name-only"], in: workDir)?
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        let dirty = Array(Set(staged + unstaged)).sorted()
        if !dirty.isEmpty { ctx["dirty_files"] = dirty }

        // Agent memories — relevance-filtered, not a full dump
        let projectKey = AgentMemoryStore.key(for: workDir)
        let memories: [MemoryEntry]
        if let intent, !intent.isEmpty {
            memories = AgentMemoryStore.shared.relevantMemories(
                projectKey: projectKey,
                intent: intent,
                limit: Self.maxMemories
            )
        } else {
            // No intent — return highest-scoring memories across all categories
            memories = AgentMemoryStore.shared.relevantMemories(
                projectKey: projectKey,
                intent: "",
                limit: Self.maxMemories
            )
        }
        if !memories.isEmpty {
            ctx["memories"] = budgetMemories(memories)
        }

        // Memory stats for awareness
        let stats = AgentMemoryStore.shared.stats(projectKey: projectKey)
        if stats.totalCount > 0 {
            ctx["memory_stats"] = [
                "total": stats.totalCount,
                "hint": stats.totalCount > Self.maxMemories
                    ? "Showing top \(min(memories.count, Self.maxMemories)) of \(stats.totalCount) memories. Use recall() with a query to find specific facts."
                    : "All memories shown."
            ]
        }

        // Failing tests (main-actor read)
        let failureNames: [String] = MainActor.assumeIsolated {
            TestRunnerStore.shared.failures.map(\.name)
        }
        if !failureNames.isEmpty { ctx["failing_tests"] = failureNames }

        // Active peers (main-actor read via IPCAgentState mirror)
        let peerPairs: [[String: String]] = MainActor.assumeIsolated {
            IPCAgentState.shared.peers.map { ["name": $0.name, "role": $0.role] }
        }
        if !peerPairs.isEmpty { ctx["active_peers"] = peerPairs }

        return ctx
    }

    /// Fast preview of memory keys that `gather(workDir:intent:)` would inject
    /// into a new session's enriched prompt. Used by the run panel's
    /// "memories used" chip to surface what the agent knows going in,
    /// without re-running the full gather pipeline.
    static func memoryKeysForPreview(workDir: String?, intent: String) -> [String] {
        guard let workDir, !workDir.isEmpty else { return [] }
        let projectKey = AgentMemoryStore.key(for: workDir)
        return AgentMemoryStore.shared
            .relevantMemories(projectKey: projectKey, intent: intent, limit: Self.maxMemories)
            .map(\.key)
    }

    // MARK: - Formatted prompt block

    /// Returns a human-readable context block suitable for prepending to a prompt.
    /// Respects the total budget to avoid bloating agent context windows.
    static func formattedBlock(for workDir: String, intent: String? = nil) -> String {
        let ctx = gather(workDir: workDir, intent: intent)
        var lines: [String] = ["<cterm_project_context>"]

        if let cwd = ctx["cwd"] as? String { lines.append("cwd: \(cwd)") }
        if let branch = ctx["branch"] as? String { lines.append("branch: \(branch)") }

        if let commits = ctx["recent_commits"] as? [String], !commits.isEmpty {
            lines.append("recent_commits:")
            commits.forEach { lines.append("  \($0)") }
        }

        if let dirty = ctx["dirty_files"] as? [String], !dirty.isEmpty {
            lines.append("dirty_files: \(dirty.joined(separator: ", "))")
        }

        if let memories = ctx["memories"] as? [[String: Any]], !memories.isEmpty {
            lines.append("memories:")
            for m in memories {
                if let k = m["key"] as? String, let v = m["value"] as? String {
                    let cat = (m["category"] as? String).map { " [\($0)]" } ?? ""
                    let score = (m["score"] as? String).map { " (score: \($0))" } ?? ""
                    lines.append("  \(k)\(cat)\(score): \(v)")
                }
            }
        }

        if let stats = ctx["memory_stats"] as? [String: Any],
           let hint = stats["hint"] as? String {
            lines.append("memory_hint: \(hint)")
        }

        if let tests = ctx["failing_tests"] as? [String], !tests.isEmpty {
            lines.append("failing_tests: \(tests.joined(separator: ", "))")
        }

        if let peers = ctx["active_peers"] as? [[String: String]], !peers.isEmpty {
            lines.append("active_peers: \(peers.compactMap { $0["name"] }.joined(separator: ", "))")
        }

        if let agents = ctx["agents_md"] as? String {
            lines.append("agents_md: |")
            agents.components(separatedBy: "\n").forEach { lines.append("  \($0)") }
        }

        if let md = ctx["claude_md"] as? String {
            lines.append("claude_md: |")
            md.components(separatedBy: "\n").forEach { lines.append("  \($0)") }
        }

        lines.append("</cterm_project_context>")

        let result = lines.joined(separator: "\n")

        // Final safety trim if somehow over total budget
        if result.count > Self.totalBudget {
            return String(result.prefix(Self.totalBudget)) + "\n[...context trimmed to fit budget]"
        }
        return result
    }

    // MARK: - Budget Helpers

    /// Trim CLAUDE.md intelligently: keep the first section (usually project overview),
    /// then key sections like "Build", "Test", "Architecture". Drop the rest.
    private static func budgetClaudeMd(_ content: String) -> String {
        guard content.count > claudeMdBudget else { return content }

        let lines = content.components(separatedBy: "\n")
        var kept: [String] = []
        var charCount = 0
        var inImportantSection = true // first section is always important

        let importantHeaders = ["build", "test", "architecture", "setup", "install", "run", "deploy", "convention"]

        for line in lines {
            // Detect markdown headers
            if line.hasPrefix("#") {
                let headerText = line.lowercased()
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespaces)
                inImportantSection = importantHeaders.contains { headerText.contains($0) }
            }

            if inImportantSection {
                let lineLen = line.count + 1
                if charCount + lineLen > claudeMdBudget {
                    kept.append("[...truncated]")
                    break
                }
                kept.append(line)
                charCount += lineLen
            }
        }

        return kept.joined(separator: "\n")
    }

    /// Generic markdown trimmer: keep from the top until we hit the budget.
    /// Used for AGENTS.md where every section is assumed relevant.
    private static func budgetMarkdown(_ content: String, limit: Int) -> String {
        guard content.count > limit else { return content }
        return String(content.prefix(limit)) + "\n[...truncated]"
    }

    /// Format memories for context injection, respecting the memory budget.
    private static func budgetMemories(_ memories: [MemoryEntry]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var charCount = 0

        for entry in memories {
            let valueLen = entry.key.count + entry.value.count + 30 // overhead for dict keys
            if charCount + valueLen > memoryBudget { break }

            var item: [String: Any] = [
                "key": entry.key,
                "value": entry.value.count > 200 ? String(entry.value.prefix(200)) + "…" : entry.value,
                "category": entry.category.rawValue,
                "score": String(format: "%.2f", entry.relevanceScore),
            ]
            if let exp = entry.expiresAt {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                item["expires_at"] = iso.string(from: exp)
            }
            result.append(item)
            charCount += valueLen
        }

        return result
    }

    // MARK: - Helpers

    private static func gitOutput(_ args: [String], in dir: String) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func readFile(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
