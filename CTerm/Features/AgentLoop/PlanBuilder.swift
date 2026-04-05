// PlanBuilder.swift
// CTerm
//
// Generates a short, visible step plan before execution begins.
// For simple intents (explain, inspect), produces a single-step plan.
// For complex intents (fix, workflow), uses the LLM to generate multi-step plans.
// Supports streaming preview via OllamaCommandService.streamAgentPlan.
// Reuses AgentPlanStep from the existing AgentPlan module.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "PlanBuilder")

@MainActor
enum PlanBuilder {

    /// Callback for streaming plan preview text during LLM generation.
    /// Set by AgentLoopCoordinator before calling buildPlan.
    nonisolated(unsafe) static var onStreamingPreview: ((_ text: String) -> Void)?

    // MARK: - Public API

    /// Build a plan for the given session state. Mutates the session in place.
    static func buildPlan(for session: AgentSessionState, pwd: String?) async {
        session.transitionTo(.planning)

        guard let intent = session.classifiedIntent else {
            session.fail(message: "Cannot build plan: intent not classified")
            return
        }

        let steps: [AgentPlanStep]

        switch intent {
        case .explain:
            steps = [AgentPlanStep(title: "Explain: \(session.displayIntent.prefix(60))")]

        case .generateCommand:
            steps = [AgentPlanStep(title: "Generate command for: \(session.displayIntent.prefix(60))")]

        case .inspectRepo:
            steps = buildInspectPlan(session.userIntent, pwd: pwd)

        case .executeCommand:
            steps = buildExecutePlan(session.userIntent)

        case .fixError:
            steps = await buildFixPlanStreaming(session.userIntent, pwd: pwd)

        case .runWorkflow:
            steps = await buildWorkflowPlanStreaming(session.userIntent, pwd: pwd)

        case .delegateToPeer:
            steps = buildDelegatePlan(session.userIntent)
        }

        session.planSteps = steps
        session.approvalRequirement = intent.defaultApproval

        if steps.isEmpty {
            session.fail(message: "Could not generate a plan for this goal.")
        } else if session.approvalRequirement == .none {
            // Auto-approve all steps for safe intents
            for i in session.planSteps.indices {
                session.planSteps[i].status = .approved
            }
            session.transitionTo(.executing)
        } else {
            session.transitionTo(.awaitingApproval)
        }

        logger.info("PlanBuilder: generated \(steps.count) step(s) for intent \(intent.rawValue)")
    }

    // MARK: - Inspect Plans

    private static func buildInspectPlan(_ input: String, pwd: String?) -> [AgentPlanStep] {
        let lower = input.lowercased()
        var steps: [AgentPlanStep] = []

        if lower.contains("status") || lower.contains("diff") {
            steps.append(AgentPlanStep(title: "Check git status", command: "git status"))
        }
        if lower.contains("log") || lower.contains("history") {
            steps.append(AgentPlanStep(title: "Show recent commits", command: "git log --oneline -10"))
        }
        if lower.contains("structure") || lower.contains("files") || lower.contains("list") {
            steps.append(AgentPlanStep(title: "List project structure", command: "find . -maxdepth 2 -type f | head -50"))
        }

        if steps.isEmpty {
            steps.append(AgentPlanStep(title: "Inspect: \(input.prefix(60))", command: "git status && ls -la"))
        }

        return steps
    }

    // MARK: - Execute Plans

    private static func buildExecutePlan(_ input: String) -> [AgentPlanStep] {
        let lower = input.lowercased()

        // Try to extract a direct command
        if lower.hasPrefix("run ") {
            let command = String(input.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                return [AgentPlanStep(title: "Run: \(command.prefix(60))", command: command)]
            }
        }

        // Common shortcuts
        if lower.contains("test") {
            return [AgentPlanStep(title: "Run tests", command: "make test || npm test || swift test || cargo test")]
        }
        if lower.contains("build") {
            return [AgentPlanStep(title: "Build project", command: "make build || npm run build || swift build || cargo build")]
        }
        if lower.contains("lint") {
            return [AgentPlanStep(title: "Run linter", command: "npm run lint || cargo clippy || swiftlint")]
        }

        return [AgentPlanStep(title: "Execute: \(input.prefix(60))")]
    }

    // MARK: - Fix Plans (LLM-assisted, streaming)

    private static func buildFixPlanStreaming(_ input: String, pwd: String?) async -> [AgentPlanStep] {
        do {
            let steps = try await OllamaCommandService.streamAgentPlan(
                goal: input,
                pwd: pwd,
                recentCommandContext: ""
            ) { partial in
                onStreamingPreview?(partial)
            }
            if !steps.isEmpty { return steps }
        } catch {
            logger.debug("PlanBuilder: streaming fix plan failed, using fallback: \(error.localizedDescription)")
        }

        // Fallback: generic fix plan
        return [
            AgentPlanStep(title: "Reproduce the error", command: nil),
            AgentPlanStep(title: "Identify root cause"),
            AgentPlanStep(title: "Apply fix"),
            AgentPlanStep(title: "Verify fix"),
        ]
    }

    // MARK: - Workflow Plans (LLM-assisted, streaming)

    private static func buildWorkflowPlanStreaming(_ input: String, pwd: String?) async -> [AgentPlanStep] {
        do {
            let steps = try await OllamaCommandService.streamAgentPlan(
                goal: input,
                pwd: pwd,
                recentCommandContext: ""
            ) { partial in
                onStreamingPreview?(partial)
            }
            if !steps.isEmpty { return steps }
        } catch {
            logger.debug("PlanBuilder: streaming workflow plan failed, using single-step fallback: \(error.localizedDescription)")
        }

        return [AgentPlanStep(title: "Execute: \(input.prefix(60))")]
    }

    // MARK: - Delegate Plans

    private static func buildDelegatePlan(_ input: String) -> [AgentPlanStep] {
        [
            AgentPlanStep(title: "Send task to peer agent"),
            AgentPlanStep(title: "Wait for peer response"),
            AgentPlanStep(title: "Review peer output"),
        ]
    }
}
