// DenialHandler.swift
// CTerm
//
// When a user denies an agent action, proposes a safer alternative instead of
// stopping the pipeline awkwardly. Maps risky commands to lower-risk equivalents.

import Foundation

@MainActor
enum DenialHandler {

    /// Given a denied command and its risk assessment, propose a safer alternative.
    /// Returns nil if no reasonable alternative exists.
    static func proposeSaferAlternative(
        command: String,
        assessment: RiskAssessment
    ) -> DenialAlternative? {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // rm -rf → show what would be deleted
        if lower.hasPrefix("rm ") {
            let target = command.replacingOccurrences(of: "rm ", with: "")
                .replacingOccurrences(of: "-rf ", with: "")
                .replacingOccurrences(of: "-r ", with: "")
                .replacingOccurrences(of: "-f ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return DenialAlternative(
                saferCommand: "ls -la \(target)",
                explanation: "List the files that would be deleted instead of removing them",
                riskReduction: "Read-only — no files will be modified"
            )
        }

        // git push --force → regular push
        if lower.contains("git push") && (lower.contains("--force") || lower.contains(" -f")) {
            let safer = command
                .replacingOccurrences(of: "--force-with-lease", with: "")
                .replacingOccurrences(of: "--force", with: "")
                .replacingOccurrences(of: " -f ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return DenialAlternative(
                saferCommand: safer,
                explanation: "Push without force — fails safely if remote has diverged",
                riskReduction: "Won't overwrite remote history"
            )
        }

        // git push → dry run
        if lower.hasPrefix("git push") {
            return DenialAlternative(
                saferCommand: command + " --dry-run",
                explanation: "Dry-run push to see what would be sent without actually pushing",
                riskReduction: "No remote changes"
            )
        }

        // git reset --hard → soft reset
        if lower.contains("git reset") && lower.contains("--hard") {
            let safer = command.replacingOccurrences(of: "--hard", with: "--soft")
            return DenialAlternative(
                saferCommand: safer,
                explanation: "Soft reset keeps your changes staged instead of discarding them",
                riskReduction: "No data loss — changes remain in staging area"
            )
        }

        // git merge/rebase → show diff first
        if lower.hasPrefix("git merge") || lower.hasPrefix("git rebase") {
            let branch = command.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "HEAD"
            return DenialAlternative(
                saferCommand: "git diff HEAD...\(branch) --stat",
                explanation: "Preview the changes that would be merged/rebased",
                riskReduction: "Read-only — no branch modifications"
            )
        }

        // sudo → explain what it does
        if lower.hasPrefix("sudo ") {
            let inner = String(command.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return DenialAlternative(
                saferCommand: "echo 'Would run with sudo: \(inner)'",
                explanation: "Show the command that would run with elevated privileges",
                riskReduction: "No execution — just displays the command"
            )
        }

        // npm install / pip install → show what would be installed
        if lower.hasPrefix("npm install") || lower.hasPrefix("npm i ") {
            return DenialAlternative(
                saferCommand: command.replacingOccurrences(of: "npm install", with: "npm pack --dry-run")
                    .replacingOccurrences(of: "npm i ", with: "npm pack --dry-run "),
                explanation: "Preview what would be installed without modifying node_modules",
                riskReduction: "No filesystem or network changes"
            )
        }

        // curl piped to shell → just fetch and show
        if lower.contains("| sh") || lower.contains("| bash") {
            let fetchOnly = command.components(separatedBy: "|").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? command
            return DenialAlternative(
                saferCommand: fetchOnly,
                explanation: "Fetch the script content for review instead of executing it",
                riskReduction: "Downloads but does not execute"
            )
        }

        // Generic: offer to explain the command
        if assessment.tier >= .high {
            return DenialAlternative(
                saferCommand: nil,
                explanation: "This action was blocked. You can modify the command or skip this step.",
                riskReduction: nil
            )
        }

        return nil
    }
}

// MARK: - Denial Alternative

struct DenialAlternative: Sendable {
    /// A safer command to run instead, or nil if no command alternative exists.
    let saferCommand: String?
    /// Why this alternative is safer.
    let explanation: String
    /// What risk is reduced.
    let riskReduction: String?
}
