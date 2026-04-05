// RiskScorer.swift
// CTerm
//
// Stateless risk scoring engine. Evaluates a command string + context into a
// RiskAssessment. Replaces the hardcoded safe-command lists in
// ComposeOverlayController and AgentPlanExecutor with a single source of truth.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "RiskScorer")

@MainActor
enum RiskScorer {

    // MARK: - Public API

    /// Score a command in context. Returns a full RiskAssessment.
    static func assess(
        command: String,
        pwd: String? = nil,
        gitBranch: String? = nil
    ) -> RiskAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else {
            return RiskAssessment(score: 0, factors: [], command: command, category: .runCommands)
        }

        let category = categorize(lower)
        var factors: [RiskFactor] = []

        // 1. Base category score
        factors.append(contentsOf: baseCategoryFactors(category, lower: lower))

        // 2. Destructive flags
        factors.append(contentsOf: destructiveFlagFactors(lower))

        // 3. Scope analysis
        factors.append(contentsOf: scopeFactors(lower))

        // 4. Network exposure
        factors.append(contentsOf: networkFactors(lower))

        // 5. Privilege escalation
        factors.append(contentsOf: privilegeFactors(lower))

        // 6. Git-specific risks
        factors.append(contentsOf: gitFactors(lower, branch: gitBranch))

        // 7. Output redirection / pipe chains
        factors.append(contentsOf: redirectFactors(lower))

        // 8. Safe read-only bonus (negative weight)
        factors.append(contentsOf: safeReadOnlyFactors(lower))

        // 9. Working directory trust
        factors.append(contentsOf: directoryTrustFactors(lower, pwd: pwd))

        let total = factors.reduce(0) { $0 + $1.weight }
        let clamped = max(0, min(100, total))

        let assessment = RiskAssessment(
            score: clamped,
            factors: factors,
            command: command,
            category: category
        )

        logger.debug("RiskScorer: \(command.prefix(60)) → \(clamped) (\(assessment.tier.rawValue))")
        return assessment
    }

    /// Quick check: is this command low-risk enough to auto-run?
    static func isAutoApprovable(
        command: String,
        pwd: String? = nil,
        gitBranch: String? = nil,
        threshold: Int = 20
    ) -> Bool {
        assess(command: command, pwd: pwd, gitBranch: gitBranch).score < threshold
    }

    // MARK: - Categorization

    static func categorize(_ lower: String) -> AgentActionCategory {
        let firstToken = lower.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""

        if ["rm", "rmdir", "trash"].contains(firstToken) { return .deleteFiles }

        let gitMutating = ["git commit", "git push", "git merge", "git rebase",
                           "git reset", "git cherry-pick", "git tag"]
        if gitMutating.contains(where: { lower.hasPrefix($0) }) { return .gitOperations }

        let gitReadOnly = ["git status", "git log", "git diff", "git branch",
                           "git show", "git stash list", "git remote", "git describe"]
        if gitReadOnly.contains(where: { lower.hasPrefix($0) }) { return .readFiles }

        let netCommands = ["curl", "wget", "npm install", "npm ci", "yarn add",
                           "pip install", "pip3 install", "cargo install",
                           "brew install", "brew upgrade", "apt install",
                           "docker pull", "docker push"]
        if netCommands.contains(where: { lower.hasPrefix($0) }) { return .networkAccess }

        let readOnly = ["cat", "ls", "ll", "find", "grep", "rg", "head", "tail",
                        "wc", "file", "pwd", "echo", "which", "type", "env",
                        "printenv", "date", "uname", "whoami", "df", "du", "ps",
                        "diff", "sort", "uniq", "cut", "awk", "sed -n", "jq",
                        "swift --version", "swiftc --version", "node --version",
                        "npm --version", "cargo --version", "rustc --version",
                        "python --version", "python3 --version", "go version",
                        "ruby --version", "xcodebuild -version"]
        if readOnly.contains(where: { lower.hasPrefix($0) }) { return .readFiles }

        let writeCommands = ["sed -i", "tee ", "mv ", "cp "]
        if writeCommands.contains(where: { lower.contains($0) }) { return .writeFiles }

        if lower.contains(" > ") || lower.contains(" >> ") { return .writeFiles }

        return .runCommands
    }

    // MARK: - Factor Generators

    private static func baseCategoryFactors(_ category: AgentActionCategory, lower: String) -> [RiskFactor] {
        switch category {
        case .readFiles:
            return [RiskFactor(kind: .safeReadOnly, weight: 0, reason: "Read-only operation")]
        case .writeFiles:
            return [RiskFactor(kind: .unknownCommand, weight: 25, reason: "Modifies files")]
        case .runCommands:
            return [RiskFactor(kind: .unknownCommand, weight: 30, reason: "Arbitrary shell command")]
        case .networkAccess:
            return [RiskFactor(kind: .networkExposure, weight: 35, reason: "Network access")]
        case .gitOperations:
            return [RiskFactor(kind: .gitMutation, weight: 40, reason: "Git mutation")]
        case .deleteFiles:
            return [RiskFactor(kind: .destructiveFlag, weight: 50, reason: "File deletion")]
        }
    }

    private static func destructiveFlagFactors(_ lower: String) -> [RiskFactor] {
        var factors: [RiskFactor] = []

        if lower.contains(" -rf ") || lower.contains(" -rf\n") || lower.hasSuffix(" -rf") {
            factors.append(RiskFactor(kind: .destructiveFlag, weight: 30,
                                      reason: "Recursive force flag (-rf)"))
        }
        if lower.contains("--force") || lower.contains(" -f ") {
            factors.append(RiskFactor(kind: .destructiveFlag, weight: 15,
                                      reason: "Force flag"))
        }
        if lower.contains("--hard") {
            factors.append(RiskFactor(kind: .destructiveFlag, weight: 25,
                                      reason: "Hard reset — rewrites history"))
        }
        if lower.contains("--no-verify") {
            factors.append(RiskFactor(kind: .destructiveFlag, weight: 10,
                                      reason: "Skips verification hooks"))
        }
        return factors
    }

    private static func scopeFactors(_ lower: String) -> [RiskFactor] {
        var factors: [RiskFactor] = []

        // Wildcard or root-level targets
        if lower.contains(" * ") || lower.contains(" /*") || lower.contains(" ~/") {
            factors.append(RiskFactor(kind: .broadScope, weight: 20,
                                      reason: "Broad target scope (wildcard or home/root)"))
        }
        if lower.contains(" /") && !lower.contains(" /dev/null") {
            // Absolute path outside project
            factors.append(RiskFactor(kind: .broadScope, weight: 10,
                                      reason: "Targets absolute path outside project"))
        }
        if lower.contains(" -r ") || lower.contains(" -R ") || lower.contains("--recursive") {
            factors.append(RiskFactor(kind: .broadScope, weight: 10,
                                      reason: "Recursive operation"))
        }
        return factors
    }

    private static func networkFactors(_ lower: String) -> [RiskFactor] {
        var factors: [RiskFactor] = []

        // External URLs
        if lower.contains("http://") || lower.contains("https://") {
            // Check for known-safe vs unknown hosts
            let trustedHosts = ["github.com", "npmjs.org", "registry.npmjs.org",
                                "crates.io", "pypi.org", "rubygems.org",
                                "localhost", "127.0.0.1"]
            let hasTrusted = trustedHosts.contains { lower.contains($0) }
            if !hasTrusted {
                factors.append(RiskFactor(kind: .networkExposure, weight: 15,
                                          reason: "Connects to external host"))
            }
        }

        // Package install from untrusted source
        if lower.contains("| sh") || lower.contains("| bash") || lower.contains("| zsh") {
            factors.append(RiskFactor(kind: .networkExposure, weight: 30,
                                      reason: "Pipes remote content to shell"))
        }
        return factors
    }

    private static func privilegeFactors(_ lower: String) -> [RiskFactor] {
        var factors: [RiskFactor] = []

        if lower.hasPrefix("sudo ") {
            factors.append(RiskFactor(kind: .privilegeEscalation, weight: 40,
                                      reason: "Runs with elevated privileges (sudo)"))
        }
        if lower.contains("chmod") || lower.contains("chown") {
            factors.append(RiskFactor(kind: .privilegeEscalation, weight: 20,
                                      reason: "Changes file permissions/ownership"))
        }
        return factors
    }

    private static func gitFactors(_ lower: String, branch: String?) -> [RiskFactor] {
        var factors: [RiskFactor] = []

        // Force push
        if lower.contains("push") && (lower.contains("--force") || lower.contains(" -f")) {
            factors.append(RiskFactor(kind: .irreversible, weight: 30,
                                      reason: "Force push — rewrites remote history"))
        }

        // Protected branch detection
        if let branch = branch?.lowercased() {
            let protectedPatterns = ["main", "master", "release", "production", "prod"]
            if protectedPatterns.contains(where: { branch.hasPrefix($0) }) {
                let isMutating = ["git push", "git merge", "git rebase", "git reset",
                                  "git commit"].contains(where: { lower.hasPrefix($0) })
                if isMutating {
                    factors.append(RiskFactor(kind: .protectedBranch, weight: 25,
                                              reason: "Mutating protected branch (\(branch))"))
                }
            }
        }
        return factors
    }

    private static func redirectFactors(_ lower: String) -> [RiskFactor] {
        var factors: [RiskFactor] = []

        if lower.contains(" > ") {
            factors.append(RiskFactor(kind: .outputRedirect, weight: 15,
                                      reason: "Overwrites file via redirect"))
        }
        if lower.contains(" >> ") {
            factors.append(RiskFactor(kind: .outputRedirect, weight: 10,
                                      reason: "Appends to file via redirect"))
        }

        // Pipe into destructive command
        let destructivePipes = ["rm", "xargs rm", "tee", "dd"]
        if lower.contains("|") {
            let afterPipe = lower.components(separatedBy: "|").dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for segment in afterPipe {
                if destructivePipes.contains(where: { segment.hasPrefix($0) }) {
                    factors.append(RiskFactor(kind: .pipeChain, weight: 20,
                                              reason: "Pipes into destructive command"))
                }
            }
        }
        return factors
    }

    private static func safeReadOnlyFactors(_ lower: String) -> [RiskFactor] {
        let safeCommands: Set<String> = [
            "ls", "ll", "cat", "pwd", "echo", "which", "type",
            "head", "tail", "wc", "diff", "file",
            "git log", "git status", "git branch", "git diff",
            "git show", "git stash list", "git remote", "git describe",
            "find", "rg", "grep", "awk", "sort", "uniq", "cut", "jq",
            "env", "printenv", "date", "uname", "whoami", "df", "du", "ps",
        ]

        let firstToken = lower.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let firstTwo = lower.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")

        if safeCommands.contains(firstToken) || safeCommands.contains(firstTwo) {
            return [RiskFactor(kind: .safeReadOnly, weight: -15,
                               reason: "Known read-only command")]
        }

        // Version checks
        if lower.hasSuffix("--version") || lower.hasSuffix("-v") || lower.hasSuffix("-V") {
            return [RiskFactor(kind: .safeReadOnly, weight: -10,
                               reason: "Version check")]
        }

        return []
    }

    private static func directoryTrustFactors(_ lower: String, pwd: String?) -> [RiskFactor] {
        guard let pwd else { return [] }

        // If the command targets paths outside the project, add risk
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if lower.contains(homeDir) && !lower.contains(pwd) {
            return [RiskFactor(kind: .broadScope, weight: 10,
                               reason: "Targets files outside project directory")]
        }

        // Inside project directory is a trust signal
        return [RiskFactor(kind: .trustedScope, weight: -5,
                           reason: "Operating within project directory")]
    }
}
