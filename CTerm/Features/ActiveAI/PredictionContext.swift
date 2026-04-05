// PredictionContext.swift
// CTerm
//
// Richer context builder for Active AI and Next Command predictions.
// Incorporates command history patterns, failure streaks, agent memory,
// and project-specific signals to produce better prompts.

import Foundation

/// Enriched context snapshot for AI predictions.
struct PredictionContext: Sendable {
    let terminalContext: TerminalContext
    let recentCommands: [CommandSummary]
    let failureStreak: Int
    let lastFailedCommand: String?
    let lastFailureSnippet: String?
    let memoryHints: [String]
    let workflowPhase: WorkflowPhase

    /// Compact context block for embedding in prompts.
    var enrichedContextBlock: String {
        var lines: [String] = []
        lines.append(terminalContext.contextBlock)

        if failureStreak > 0 {
            lines.append("- Failure streak: \(failureStreak) consecutive failures")
            if let cmd = lastFailedCommand {
                lines.append("- Last failed: \(cmd)")
            }
            if let snippet = lastFailureSnippet {
                lines.append("- Error excerpt: \(String(snippet.prefix(200)))")
            }
        }

        if !memoryHints.isEmpty {
            lines.append("- Project notes: \(memoryHints.prefix(3).joined(separator: "; "))")
        }

        lines.append("- Workflow phase: \(workflowPhase.label)")

        return lines.joined(separator: "\n")
    }

    /// Recent command history formatted for prompts.
    var historyBlock: String {
        if recentCommands.isEmpty { return "(none)" }
        return recentCommands.map { cmd in
            let status = cmd.succeeded ? "[ok]" : "[failed]"
            return "\(status) \(cmd.command)"
        }.joined(separator: "\n")
    }
}

struct CommandSummary: Sendable {
    let command: String
    let succeeded: Bool
    let hasOutput: Bool
    let durationMs: Int?
}

/// Inferred workflow phase based on recent command patterns.
enum WorkflowPhase: String, Sendable {
    case building       // recent build/compile commands
    case testing        // recent test commands
    case debugging      // repeated failures, fix attempts
    case deploying      // deploy/push commands
    case exploring      // ls, cat, find, grep
    case gitFlow        // git commands
    case unknown

    var label: String {
        switch self {
        case .building: return "building"
        case .testing: return "testing"
        case .debugging: return "debugging (repeated failures)"
        case .deploying: return "deploying"
        case .exploring: return "exploring files"
        case .gitFlow: return "git workflow"
        case .unknown: return "general"
        }
    }
}

// MARK: - Builder

enum PredictionContextBuilder {

    /// Build an enriched prediction context from the current tab state.
    static func build(
        blocks: [TerminalCommandBlock],
        pwd: String?,
        terminalContext: TerminalContext
    ) -> PredictionContext {
        let recentCommands = blocks.prefix(12).map { block in
            CommandSummary(
                command: block.titleText,
                succeeded: block.status == .succeeded,
                hasOutput: block.primarySnippet != nil,
                durationMs: block.durationNanoseconds.map { Int($0 / 1_000_000) }
            )
        }

        let failureStreak = countFailureStreak(blocks)
        let lastFailed = blocks.first(where: { $0.status == .failed })
        let memoryHints = fetchMemoryHints(pwd: pwd)
        let phase = detectWorkflowPhase(blocks)

        return PredictionContext(
            terminalContext: terminalContext,
            recentCommands: Array(recentCommands),
            failureStreak: failureStreak,
            lastFailedCommand: lastFailed?.titleText,
            lastFailureSnippet: lastFailed?.primarySnippet,
            memoryHints: memoryHints,
            workflowPhase: phase
        )
    }

    // MARK: - Failure Streak

    private static func countFailureStreak(_ blocks: [TerminalCommandBlock]) -> Int {
        var count = 0
        for block in blocks {
            guard block.status == .failed else { break }
            count += 1
        }
        return count
    }

    // MARK: - Memory Integration

    private static func fetchMemoryHints(pwd: String?) -> [String] {
        guard let pwd else { return [] }
        let projectKey = AgentMemoryStore.key(for: pwd)
        let memories = AgentMemoryStore.shared.listAll(projectKey: projectKey)
        // Return the most recent, relevant memory values (capped)
        return memories.prefix(5).map { "\($0.key): \($0.value)" }
    }

    // MARK: - Workflow Phase Detection

    private static func detectWorkflowPhase(_ blocks: [TerminalCommandBlock]) -> WorkflowPhase {
        let recent = blocks.prefix(5).map { $0.titleText.lowercased() }
        guard !recent.isEmpty else { return .unknown }

        let buildKeywords = ["build", "make", "cargo build", "swift build", "xcodebuild", "npm run build", "cmake", "gcc", "clang"]
        let testKeywords = ["test", "pytest", "jest", "vitest", "rspec", "cargo test", "swift test", "xcodebuild test"]
        let deployKeywords = ["deploy", "push", "publish", "release", "docker push", "kubectl apply", "terraform apply"]
        let exploreKeywords = ["ls", "cat", "find", "grep", "tree", "head", "tail", "less", "file"]
        let gitKeywords = ["git "]

        // Count matches
        var scores: [WorkflowPhase: Int] = [:]
        for cmd in recent {
            if buildKeywords.contains(where: { cmd.contains($0) }) { scores[.building, default: 0] += 1 }
            if testKeywords.contains(where: { cmd.contains($0) }) { scores[.testing, default: 0] += 1 }
            if deployKeywords.contains(where: { cmd.contains($0) }) { scores[.deploying, default: 0] += 1 }
            if exploreKeywords.contains(where: { cmd.hasPrefix($0) }) { scores[.exploring, default: 0] += 1 }
            if gitKeywords.contains(where: { cmd.hasPrefix($0) }) { scores[.gitFlow, default: 0] += 1 }
        }

        // Debugging override: if there's a failure streak >= 2, it's debugging
        let failureStreak = countFailureStreak(blocks)
        if failureStreak >= 2 { return .debugging }

        // Return the phase with the highest score
        return scores.max(by: { $0.value < $1.value })?.key ?? .unknown
    }
}
