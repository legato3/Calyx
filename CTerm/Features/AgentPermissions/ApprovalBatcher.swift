// ApprovalBatcher.swift
// CTerm
//
// Groups multiple pending agent actions into a single approval prompt when
// they share the same risk tier. Reduces approval fatigue for medium-risk
// operations while keeping high/critical actions individually visible.
//
// Batching rules:
//   - Low-risk actions are never batched (they auto-approve).
//   - Medium-risk actions within the same plan are grouped into one prompt.
//   - High-risk actions are shown individually but can be approved as a group.
//   - Critical actions always require individual confirmation.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ApprovalBatcher")

// MARK: - Approval Batch

struct ApprovalBatch: Identifiable, Sendable {
    let id: UUID
    let tier: RiskTier
    let items: [ApprovalItem]
    let combinedExplanation: String

    init(tier: RiskTier, items: [ApprovalItem]) {
        self.id = UUID()
        self.tier = tier
        self.items = items
        self.combinedExplanation = Self.buildCombinedExplanation(items)
    }

    var stepIDs: [UUID] { items.map(\.stepID) }

    private static func buildCombinedExplanation(_ items: [ApprovalItem]) -> String {
        if items.count == 1 {
            return items[0].assessment.explanation
        }
        let commands = items.prefix(5).map { "  • \($0.command.prefix(60))" }
        let suffix = items.count > 5 ? "\n  … and \(items.count - 5) more" : ""
        return "Batch of \(items.count) actions:\n" + commands.joined(separator: "\n") + suffix
    }
}

// MARK: - Approval Item

struct ApprovalItem: Identifiable, Sendable {
    let id: UUID
    let stepID: UUID
    let command: String
    let assessment: RiskAssessment

    init(stepID: UUID, command: String, assessment: RiskAssessment) {
        self.id = UUID()
        self.stepID = stepID
        self.command = command
        self.assessment = assessment
    }
}

// MARK: - Batcher

@MainActor
enum ApprovalBatcher {

    /// Given a list of plan steps, produce approval batches grouped by risk tier.
    /// Low-risk steps are returned as auto-approved (empty batch list).
    /// Returns (autoApproved: [stepID], batches: [ApprovalBatch]).
    static func batch(
        steps: [AgentPlanStep],
        pwd: String? = nil,
        gitBranch: String? = nil,
        memory: ApprovalMemory? = nil
    ) -> (autoApproved: [UUID], batches: [ApprovalBatch]) {
        var autoApproved: [UUID] = []
        var mediumItems: [ApprovalItem] = []
        var highItems: [ApprovalItem] = []
        var criticalItems: [ApprovalItem] = []

        for step in steps where step.status == .pending {
            guard let command = step.command, !command.isEmpty else {
                // Informational steps are always auto-approved
                autoApproved.append(step.id)
                continue
            }

            let assessment = RiskScorer.assess(
                command: command,
                pwd: pwd,
                gitBranch: gitBranch
            )

            // Check approval memory — if user previously allowed this pattern, auto-approve
            if let memory, memory.isRemembered(command: command, projectKey: pwd) {
                autoApproved.append(step.id)
                logger.debug("ApprovalBatcher: auto-approved via memory: \(command.prefix(60))")
                continue
            }

            let item = ApprovalItem(stepID: step.id, command: command, assessment: assessment)

            switch assessment.tier {
            case .low:
                autoApproved.append(step.id)
            case .medium:
                mediumItems.append(item)
            case .high:
                highItems.append(item)
            case .critical:
                criticalItems.append(item)
            }
        }

        var batches: [ApprovalBatch] = []

        // Medium-risk: group into one batch
        if !mediumItems.isEmpty {
            batches.append(ApprovalBatch(tier: .medium, items: mediumItems))
        }

        // High-risk: group into one batch (user sees all, approves together or individually)
        if !highItems.isEmpty {
            batches.append(ApprovalBatch(tier: .high, items: highItems))
        }

        // Critical: one batch per item (force individual review)
        for item in criticalItems {
            batches.append(ApprovalBatch(tier: .critical, items: [item]))
        }

        logger.info("ApprovalBatcher: \(autoApproved.count) auto-approved, \(batches.count) batch(es)")
        return (autoApproved, batches)
    }
}
