// ConfidenceScorer.swift
// CTerm
//
// Pure-logic confidence scoring for Active AI suggestions and next-command predictions.
// No LLM calls — uses heuristics on command output, exit codes, history patterns,
// and context signals to decide whether a suggestion is worth showing.

import Foundation

// MARK: - Confidence Score

struct ConfidenceScore: Sendable, Comparable {
    /// 0.0 (garbage) to 1.0 (certain).
    let value: Double
    let reason: String

    static func < (lhs: ConfidenceScore, rhs: ConfidenceScore) -> Bool {
        lhs.value < rhs.value
    }

    /// Minimum confidence to show a suggestion chip.
    static let chipThreshold: Double = 0.35
    /// Minimum confidence to show ghost-text prediction.
    static let ghostTextThreshold: Double = 0.45
    /// Minimum confidence for an LLM-generated next-step to be surfaced.
    static let llmSuggestionThreshold: Double = 0.40

    var isAboveChipThreshold: Bool { value >= Self.chipThreshold }
    var isAboveGhostTextThreshold: Bool { value >= Self.ghostTextThreshold }
    var isAboveLLMThreshold: Bool { value >= Self.llmSuggestionThreshold }
}

// MARK: - Scorer

enum ConfidenceScorer {

    // MARK: - Suggestion Confidence (Active AI chips)

    /// Score a potential suggestion chip based on the triggering block and context.
    static func scoreSuggestion(
        block: TerminalCommandBlock,
        suggestionText: String,
        recentCommands: [TerminalCommandBlock],
        hasRelevantMemory: Bool
    ) -> ConfidenceScore {
        var score: Double = 0.5
        var reasons: [String] = []

        // Failed commands with clear error output → high confidence for fix suggestions
        if block.status == .failed {
            score += 0.2
            reasons.append("failed_command")

            if let snippet = block.errorSnippet, containsActionableError(snippet) {
                score += 0.15
                reasons.append("actionable_error")
            }

            // Known error patterns boost confidence further
            if let snippet = block.primarySnippet, containsKnownErrorPattern(snippet) {
                score += 0.1
                reasons.append("known_pattern")
            }
        }

        // Succeeded commands with substantial output → moderate confidence for explain
        if block.status == .succeeded {
            score -= 0.1 // lower baseline for success — user may not need help
            if let snippet = block.outputSnippet, snippet.count > 200 {
                score += 0.15
                reasons.append("substantial_output")
            }
        }

        // Short/trivial commands → lower confidence (ls, pwd, cd, echo)
        if isTrivialCommand(block.titleText) {
            score -= 0.3
            reasons.append("trivial_command")
        }

        // Repeated failures on same command → boost (user is stuck)
        let recentFailCount = recentCommands.prefix(5).filter {
            $0.status == .failed && normalizeCommand($0.titleText) == normalizeCommand(block.titleText)
        }.count
        if recentFailCount >= 2 {
            score += 0.15
            reasons.append("repeated_failure(\(recentFailCount))")
        }

        // Memory context available → slight boost (we can be more specific)
        if hasRelevantMemory {
            score += 0.05
            reasons.append("has_memory")
        }

        // Penalize generic suggestion text
        if isGenericSuggestion(suggestionText) {
            score -= 0.25
            reasons.append("generic_text")
        }

        return ConfidenceScore(
            value: max(0, min(1, score)),
            reason: reasons.joined(separator: ", ")
        )
    }

    // MARK: - Prediction Confidence (Next Command ghost text)

    /// Score a predicted command completion.
    static func scorePrediction(
        prefix: String,
        predicted: String,
        recentCommands: [TerminalCommandBlock],
        pwd: String?,
        projectType: String?
    ) -> ConfidenceScore {
        var score: Double = 0.5
        var reasons: [String] = []

        let normalizedPrediction = predicted.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prediction is just the prefix repeated → zero confidence
        if normalizedPrediction.lowercased() == prefix.lowercased() {
            return ConfidenceScore(value: 0, reason: "echo_prefix")
        }

        // Prediction matches a recent command exactly → high confidence
        let recentTexts = recentCommands.prefix(10).map { normalizeCommand($0.titleText) }
        if recentTexts.contains(normalizeCommand(normalizedPrediction)) {
            score += 0.3
            reasons.append("matches_history")
        }

        // Prediction starts with a known shell command → boost
        if startsWithKnownCommand(normalizedPrediction) {
            score += 0.15
            reasons.append("known_command")
        } else {
            score -= 0.2
            reasons.append("unknown_command")
        }

        // Prediction fits the project type
        if let projectType, commandFitsProject(normalizedPrediction, projectType: projectType) {
            score += 0.1
            reasons.append("fits_project")
        }

        // Very long predictions are less likely to be right
        if normalizedPrediction.count > 120 {
            score -= 0.15
            reasons.append("too_long")
        }

        // Multi-line predictions → penalize (shell ghost text should be single-line)
        if normalizedPrediction.contains("\n") {
            score -= 0.3
            reasons.append("multi_line")
        }

        // Contains natural language instead of shell syntax → penalize
        if looksLikeNaturalLanguage(normalizedPrediction) {
            score -= 0.35
            reasons.append("natural_language")
        }

        // After a failed command, predicting the same command → penalize
        if let lastFailed = recentCommands.first, lastFailed.status == .failed,
           normalizeCommand(normalizedPrediction) == normalizeCommand(lastFailed.titleText) {
            score -= 0.3
            reasons.append("repeats_failure")
        }

        return ConfidenceScore(
            value: max(0, min(1, score)),
            reason: reasons.joined(separator: ", ")
        )
    }

    // MARK: - Heuristics

    /// Commands that are too trivial to warrant AI suggestions.
    private static let trivialCommands: Set<String> = [
        "ls", "pwd", "cd", "clear", "echo", "whoami", "date", "cal",
        "history", "which", "type", "true", "false", "exit", "logout",
    ]

    static func isTrivialCommand(_ command: String) -> Bool {
        let base = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        return trivialCommands.contains(base)
    }

    /// Generic junk suggestions that should be suppressed.
    private static let genericPatterns: [String] = [
        "try again",
        "check the logs",
        "check logs",
        "read the docs",
        "read the documentation",
        "look at the error",
        "see the output",
        "run it again",
        "retry",
        "google it",
        "search for",
        "check the output",
        "review the error",
    ]

    static func isGenericSuggestion(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Too short to be useful
        if lower.count < 8 { return true }
        // Matches a known generic pattern
        for pattern in genericPatterns {
            if lower.contains(pattern) { return true }
        }
        return false
    }

    /// Error output that contains actionable information (file paths, line numbers, error codes).
    static func containsActionableError(_ snippet: String) -> Bool {
        let patterns = [
            #"\w+\.(swift|py|ts|js|rs|go|rb|cpp|c|h|java|kt):\d+"#,  // file:line
            #"error\[E\d+\]"#,                                         // Rust error codes
            #"TS\d{4}:"#,                                              // TypeScript errors
            #"E\d{4}:"#,                                               // Python/pylint
            #"exit code:?\s*\d+"#,                                     // exit codes
            #"npm ERR!"#,
            #"ModuleNotFoundError"#,
            #"No such file or directory"#,
            #"command not found"#,
            #"Permission denied"#,
        ]
        for pattern in patterns {
            if snippet.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Known error patterns that we can reliably suggest fixes for.
    static func containsKnownErrorPattern(_ snippet: String) -> Bool {
        let patterns = [
            "cannot find module",
            "no such file or directory",
            "command not found",
            "permission denied",
            "syntax error",
            "type error",
            "undefined is not",
            "null reference",
            "segmentation fault",
            "build failed",
            "compilation failed",
            "missing import",
            "unresolved identifier",
            "use of undeclared",
        ]
        let lower = snippet.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    private static let knownCommands: Set<String> = [
        "ls", "cd", "pwd", "cat", "echo", "grep", "find", "rm", "mv", "cp",
        "mkdir", "touch", "chmod", "chown", "sudo", "git", "npm", "yarn", "pnpm",
        "swift", "swiftc", "xcodebuild", "xcodegen", "make", "cmake", "cargo",
        "rustc", "go", "python", "python3", "pip", "pip3", "node", "npx", "deno", "bun",
        "curl", "wget", "ssh", "scp", "tar", "zip", "unzip", "brew", "apt", "yum",
        "docker", "kubectl", "terraform", "aws", "gcloud", "az",
        "open", "code", "vim", "nvim", "nano", "less", "more", "head", "tail",
        "sed", "awk", "sort", "uniq", "wc", "diff", "patch", "xargs",
        "env", "export", "source", "which", "type", "kill", "ps", "top", "htop",
        "pytest", "jest", "vitest", "mocha", "rspec", "zig",
    ]

    static func startsWithKnownCommand(_ command: String) -> Bool {
        let first = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        // Also handle path-prefixed commands like ./script.sh
        if first.hasPrefix("./") || first.hasPrefix("../") || first.hasPrefix("/") { return true }
        return knownCommands.contains(first)
    }

    /// Check if a predicted command fits the detected project type.
    static func commandFitsProject(_ command: String, projectType: String) -> Bool {
        let lower = command.lowercased()
        let proj = projectType.lowercased()

        if proj.contains("swift") || proj.contains("xcode") {
            return lower.contains("swift") || lower.contains("xcodebuild") || lower.contains("xcodegen")
                || lower.contains("xcrun")
        }
        if proj.contains("cargo") || proj.contains("rust") {
            return lower.contains("cargo") || lower.contains("rustc")
        }
        if proj.contains("node") {
            return lower.contains("npm") || lower.contains("yarn") || lower.contains("pnpm")
                || lower.contains("node") || lower.contains("npx")
        }
        if proj.contains("python") {
            return lower.contains("python") || lower.contains("pip") || lower.contains("pytest")
        }
        if proj.contains("go ") || proj.contains("go module") {
            return lower.contains("go ")
        }
        return false
    }

    /// Detect if text looks like natural language rather than a shell command.
    static func looksLikeNaturalLanguage(_ text: String) -> Bool {
        let lower = text.lowercased()
        let nlIndicators = [
            "please", "could you", "can you", "i think", "maybe",
            "you should", "it seems", "note:", "the error",
            "this means", "because", "however", "therefore",
        ]
        for indicator in nlIndicators {
            if lower.contains(indicator) { return true }
        }
        // Sentences with periods mid-text (not file extensions)
        let periodCount = lower.filter { $0 == "." }.count
        let slashCount = lower.filter { $0 == "/" }.count
        if periodCount > 2 && slashCount == 0 { return true }
        return false
    }

    static func normalizeCommand(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
