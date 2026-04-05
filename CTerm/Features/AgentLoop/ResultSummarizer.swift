// ResultSummarizer.swift
// CTerm
//
// Produces a short completion summary after an agent session finishes.
// Includes: what changed, what succeeded/failed, and suggested next actions.
// Feeds suggestions back into ActiveAISuggestionEngine as clickable chips.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "ResultSummarizer")

@MainActor
enum ResultSummarizer {

    // MARK: - Public API

    /// Summarize a completed session. Mutates the session with summary and next actions.
    static func summarize(_ session: AgentSessionState, pwd: String?) async {
        session.transitionTo(.summarizing)

        let summary = buildSummary(session)
        session.summary = summary

        // Generate next-step suggestions
        let nextActions = await generateNextActions(session, pwd: pwd)
        session.nextActions = nextActions

        // Persist handoff to memory for cross-session continuity
        persistHandoff(session, pwd: pwd)

        session.transitionTo(.completed)

        // Post notification for ActiveAI to pick up
        NotificationCenter.default.post(
            name: .agentSessionCompleted,
            object: nil,
            userInfo: [
                "sessionID": session.id.uuidString,
                "intent": session.displayIntent,
                "summary": summary,
                "nextActions": nextActions,
                "artifactCount": session.artifacts.count,
            ]
        )

        logger.info("ResultSummarizer: session completed — \(summary.prefix(100))")
    }

    // MARK: - Summary Construction

    private static func buildSummary(_ session: AgentSessionState) -> String {
        let total = session.planSteps.count
        let succeeded = session.planSteps.filter { $0.status == .succeeded }.count
        let failed = session.planSteps.filter { $0.status == .failed }.count
        let skipped = session.planSteps.filter { $0.status == .skipped }.count

        var parts: [String] = []

        // Intent
        parts.append("Goal: \(session.displayIntent.prefix(80))")

        // Step results
        if total > 0 {
            var stepSummary = "\(succeeded)/\(total) steps succeeded"
            if failed > 0 { stepSummary += ", \(failed) failed" }
            if skipped > 0 { stepSummary += ", \(skipped) skipped" }
            parts.append(stepSummary)
        }

        // Artifacts
        let fileChanges = session.artifacts.filter { $0.kind == .fileChanged }
        if !fileChanges.isEmpty {
            parts.append("Files changed: \(fileChanges.map(\.value).joined(separator: ", "))")
        }

        // Duration
        let duration = session.elapsedSeconds
        if duration < 60 {
            parts.append("Completed in \(Int(duration))s")
        } else {
            parts.append("Completed in \(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s")
        }

        return parts.joined(separator: ". ") + "."
    }

    // MARK: - Next Action Generation

    private static func generateNextActions(_ session: AgentSessionState, pwd: String?) async -> [String] {
        var actions: [String] = []

        // Static suggestions based on outcome
        let hasFailed = session.planSteps.contains { $0.status == .failed }

        if hasFailed {
            let failedStep = session.planSteps.first { $0.status == .failed }
            if let step = failedStep {
                actions.append("Fix: \(step.title.prefix(50))")
            }
            actions.append("Retry failed steps")
        } else {
            // Success path
            switch session.classifiedIntent {
            case .executeCommand:
                actions.append("Run tests to verify")
            case .fixError:
                actions.append("Run tests to confirm fix")
                actions.append("Review the changes")
            case .runWorkflow:
                actions.append("Review changes and commit")
            case .inspectRepo:
                actions.append("Dig deeper into findings")
            default:
                break
            }
        }

        // LLM-generated next step (if Ollama is available)
        if let llmSuggestion = await generateLLMNextAction(session, pwd: pwd) {
            actions.append(llmSuggestion)
        }

        return Array(actions.prefix(3)) // Cap at 3 suggestions
    }

    private static func generateLLMNextAction(_ session: AgentSessionState, pwd: String?) async -> String? {
        let lastOutput = session.planSteps.last(where: { $0.output != nil })?.output ?? ""
        let prompt = """
        Based on this completed task, suggest the single most useful next action as a short prompt (max 12 words).
        The prompt will be sent to an AI coding agent.

        Task: \(session.displayIntent.prefix(200))
        Outcome: \(session.summary ?? "completed")
        Last output: \(lastOutput.prefix(300))

        Respond with only the prompt text, no explanation.
        """

        do {
            let result = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("NOTE:"), trimmed.count < 100 else { return nil }
            return trimmed
        } catch {
            return nil
        }
    }

    // MARK: - Handoff Persistence

    private static func persistHandoff(_ session: AgentSessionState, pwd: String?) {
        guard let pwd else { return }
        let projectKey = AgentMemoryStore.key(for: pwd)

        // Save handoff summary
        AgentMemoryStore.shared.saveHandoff(
            projectKey: projectKey,
            goal: session.displayIntent,
            stepsCompleted: session.planSteps.filter { $0.status == .succeeded }.count,
            totalSteps: session.planSteps.count,
            filesChanged: session.artifacts.filter { $0.kind == .fileChanged }.map(\.value),
            outcome: session.phase.label
        )

        // Save file changes to memory
        let changedFiles = session.artifacts.filter { $0.kind == .fileChanged }.map(\.value)
        if !changedFiles.isEmpty {
            AgentMemoryStore.shared.remember(
                projectKey: projectKey,
                key: "last_session_files",
                value: changedFiles.joined(separator: ", "),
                ttlDays: 7
            )
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let agentSessionCompleted = Notification.Name("com.legato3.cterm.agentSessionCompleted")
}
