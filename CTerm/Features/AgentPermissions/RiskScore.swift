// RiskScore.swift
// CTerm
//
// Per-action risk scoring engine. Replaces the binary safe/unsafe command lists
// with a numeric 0–100 risk score that considers command type, destructive flags,
// working directory, network destination, git branch context, and file scope.
//
// Risk tiers:
//   0–19  Low    → auto-approve (read-only, observational)
//  20–49  Medium → batch-approvable, or auto-approve if remembered
//  50–79  High   → requires explicit confirmation
//  80–100 Critical → blocked or requires per-action confirmation + explanation

import Foundation

// MARK: - Risk Tier

enum RiskTier: String, Sendable, Comparable {
    case low      // 0–19
    case medium   // 20–49
    case high     // 50–79
    case critical // 80–100

    var label: String {
        switch self {
        case .low:      return "Low Risk"
        case .medium:   return "Medium Risk"
        case .high:     return "High Risk"
        case .critical: return "Critical Risk"
        }
    }

    var icon: String {
        switch self {
        case .low:      return "checkmark.shield"
        case .medium:   return "shield.lefthalf.filled"
        case .high:     return "exclamationmark.shield"
        case .critical: return "xmark.shield.fill"
        }
    }

    var tintName: String {
        switch self {
        case .low:      return "green"
        case .medium:   return "yellow"
        case .high:     return "orange"
        case .critical: return "red"
        }
    }

    static func from(score: Int) -> RiskTier {
        switch score {
        case ..<20:  return .low
        case ..<50:  return .medium
        case ..<80:  return .high
        default:     return .critical
        }
    }

    static func < (lhs: RiskTier, rhs: RiskTier) -> Bool {
        lhs.numericFloor < rhs.numericFloor
    }

    private var numericFloor: Int {
        switch self {
        case .low: return 0; case .medium: return 20
        case .high: return 50; case .critical: return 80
        }
    }
}

// MARK: - Risk Assessment

/// The result of scoring a single agent action.
struct RiskAssessment: Sendable {
    let score: Int           // 0–100
    let tier: RiskTier
    let factors: [RiskFactor]
    let command: String
    let category: AgentActionCategory
    let explanation: String  // human-readable one-liner
    let rollbackHint: String? // how to undo, if possible

    init(score: Int, factors: [RiskFactor], command: String, category: AgentActionCategory) {
        let clamped = max(0, min(100, score))
        self.score = clamped
        self.tier = .from(score: clamped)
        self.factors = factors
        self.command = command
        self.category = category
        self.explanation = Self.buildExplanation(factors: factors)
        self.rollbackHint = Self.buildRollbackHint(command: command, category: category)
    }

    private static func buildExplanation(factors: [RiskFactor]) -> String {
        let top = factors.sorted { $0.weight > $1.weight }.prefix(2)
        return top.map(\.reason).joined(separator: "; ")
    }

    private static func buildRollbackHint(command: String, category: AgentActionCategory) -> String? {
        let lower = command.lowercased()
        switch category {
        case .gitOperations:
            if lower.contains("git commit") { return "git reset HEAD~1" }
            if lower.contains("git push") { return "git revert HEAD (remote already updated)" }
            if lower.contains("git merge") { return "git merge --abort or git reset --hard HEAD~1" }
            if lower.contains("git rebase") { return "git rebase --abort" }
            return "git reflog to find previous state"
        case .deleteFiles:
            return "Restore from git or Time Machine"
        case .writeFiles:
            return "git checkout -- <file> to restore"
        default:
            return nil
        }
    }
}

// MARK: - Risk Factor

struct RiskFactor: Sendable {
    let kind: Kind
    let weight: Int    // contribution to total score
    let reason: String

    enum Kind: String, Sendable {
        case destructiveFlag      // rm -rf, --force, --hard
        case broadScope           // recursive, wildcard, root-level
        case networkExposure      // external host, untrusted registry
        case privilegeEscalation  // sudo, chmod, chown
        case gitMutation          // push, force-push, rebase, reset
        case protectedBranch      // main, master, release/*
        case irreversible         // no easy undo
        case outputRedirect       // > or >> to file
        case pipeChain            // piped into mutating command
        case unknownCommand       // not in any known-safe list
        case safeReadOnly         // known read-only command (negative weight)
        case trustedScope         // inside project directory
    }
}
