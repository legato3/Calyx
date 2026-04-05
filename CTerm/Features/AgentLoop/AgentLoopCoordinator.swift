// AgentLoopCoordinator.swift
// CTerm
//
// Top-level coordinator for the agent pipeline.
// Simplified: approve the plan or don't. No batching, no denial negotiation.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentLoopCoordinator")

@Observable
@MainActor
final class AgentLoopCoordinator {

    /// The active session being coordinated. Nil when idle.
    private(set) var activeSession: AgentSession?

    /// History of completed sessions (most recent first). Capped at 20.
    private(set) var sessionHistory: [AgentSession] = []

    /// Streaming plan preview text (updated during LLM plan generation).
    private(set) var streamingPreview: String?

    private let planStore: AgentPlanStore
    private let suggestionEngine: ActiveAISuggestionEngine
    private var executionCoordinator: ExecutionCoordinator?
    private var sessionObserver: NSObjectProtocol?

    init(planStore: AgentPlanStore, suggestionEngine: ActiveAISuggestionEngine) {
        self.planStore = planStore
        self.suggestionEngine = suggestionEngine
    }

    // MARK: - Pipeline Entry Point

    func startSession(
        intent: String,
        tabID: UUID? = nil,
        pwd: String?,
        activeTab: Tab? = nil
    ) async {
        if let existing = activeSession, !existing.phase.isTerminal {
            existing.transition(to: .completed)
            archiveSession(existing)
        }

        let scope = IntentRouter.inferScope(intent)
        let enrichedIntent = AgentPromptContextBuilder.buildPrompt(
            goal: intent,
            activeTab: activeTab,
            scope: scope
        )
        // Route the planning backend through ModelRouter. The profile is
        // captured on the session after start(), so fold in the active
        // profile's preferredBackend as a hard-override up-front.
        let activeProfileBackend = AgentProfileStore.shared.activeProfile.preferredBackend
        let planningBackendAgent = ModelRouter.shared.pick(
            role: .planning,
            profileBackend: activeProfileBackend,
            fallback: .ollama
        )
        let session = AgentSessionRouter.shared.start(
            AgentSessionRequest(
                intent: intent,
                kind: .multiStep,
                backend: planningBackendAgent,
                tabID: tabID,
                preEnrichedPrompt: enrichedIntent
            ),
            activeTab: activeTab
        )
        // multiStep sessions expose a plan for explicit step tracking.
        let planningBackendLegacy = planningBackendAgent.planningBackend ?? .ollama
        session.plan = AgentPlan(goal: enrichedIntent, backend: planningBackendLegacy)
        session.classifiedScope = scope
        activeSession = session
        streamingPreview = nil

        logger.info("AgentLoop: starting session for: \(session.displayIntent.prefix(80))")

        // Classify
        session.transition(to: .thinking)
        let (category, confidence) = IntentRouter.classify(intent, scope: scope)
        if confidence < 0.4 {
            session.classifiedIntent = await IntentRouter.classifyWithLLM(intent, pwd: pwd, scope: scope)
        } else {
            session.classifiedIntent = category
        }
        guard !session.phase.isTerminal else { return }

        // Build plan
        PlanBuilder.onStreamingPreview = { [weak self] text in
            self?.streamingPreview = text
        }
        await PlanBuilder.buildPlan(for: session, pwd: pwd)
        streamingPreview = nil
        PlanBuilder.onStreamingPreview = nil

        guard !session.phase.isTerminal else { return }

        if session.phase == .awaitingApproval {
            logger.info("AgentLoop: plan ready, awaiting approval (\(session.plan?.steps.count ?? 0) steps)")
            return
        }

        await executeSession(pwd: pwd)
    }

    // MARK: - Approval (simple: approve all or stop)

    func approveAndExecute(pwd: String?) async {
        guard let session = activeSession,
              session.phase == .awaitingApproval,
              let plan = session.plan else { return }

        for i in plan.steps.indices where plan.steps[i].status == .pending {
            plan.steps[i].status = .approved
        }

        NotificationCenter.default.post(
            name: .agentPlanApproved,
            object: nil,
            userInfo: [
                "goal": session.displayIntent,
                "totalSteps": plan.steps.count,
            ]
        )

        await executeSession(pwd: pwd)
    }

    /// Skip a step by ID.
    func skipStep(id: UUID) {
        guard let plan = activeSession?.plan else { return }
        if let idx = plan.steps.firstIndex(where: { $0.id == id }) {
            plan.steps[idx].status = .skipped
        }
    }

    // MARK: - Stop

    func stopSession() {
        guard let session = activeSession else { return }
        executionCoordinator?.stop()
        session.transition(to: .completed)
        session.summary = "Stopped by user."
        archiveSession(session)
        activeSession = nil
    }

    // MARK: - Command Finished (from terminal)

    func handleCommandFinished(exitCode: Int, output: String?) {
        executionCoordinator?.handleCommandFinished(exitCode: exitCode, output: output)
    }

    // MARK: - Execution

    private func executeSession(pwd: String?) async {
        guard let session = activeSession else { return }

        let coordinator = ExecutionCoordinator(
            session: session,
            planStore: planStore
        )
        self.executionCoordinator = coordinator

        // Attach the suggestion engine as an observer so completion events flow
        // through the unified observer protocol instead of NotificationCenter.
        suggestionEngine.attach(to: session)

        coordinator.onAllStepsCompleted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.summarizeAndSuggest(pwd: pwd)
            }
        }

        coordinator.onObservation = { [weak self] _, _ in
            guard let self, let session = self.activeSession else { return }
            let changedFiles = FileChangeStore.shared.recentPaths(limit: 5)
            for file in changedFiles {
                session.addArtifact(AgentArtifact(kind: .fileChanged, value: file))
            }
        }

        coordinator.onReplanNeeded = { failedStep, output in
            return await Self.generateReplanSteps(failedStep: failedStep, output: output, pwd: pwd)
        }

        coordinator.onAdaptRequested = { completedStep, output, remaining in
            return await Self.generateAdaptedSteps(
                goal: session.displayIntent,
                completedStep: completedStep,
                output: output,
                remaining: remaining,
                pwd: pwd
            )
        }

        coordinator.start()
    }

    // MARK: - Adaptive Planning (post-step)

    /// Asks the LLM whether the remaining plan still fits the observed output.
    /// Returns nil to mean "keep the existing plan"; returns steps to replace
    /// the pending/approved tail with a new sequence.
    private static func generateAdaptedSteps(
        goal: String,
        completedStep: AgentPlanStep,
        output: String,
        remaining: [AgentPlanStep],
        pwd: String?
    ) async -> [AgentPlanStep]? {
        let remainingLines = remaining
            .map { "- \($0.title)\($0.command.map { " | CMD: \($0)" } ?? "")" }
            .joined(separator: "\n")

        let prompt = """
        You are adapting an agent plan mid-execution based on a step's actual output.

        Original goal: \(goal)

        Step just completed: \(completedStep.title)
        Command: \(completedStep.command ?? "(none)")
        Output (truncated):
        \(output.prefix(1200))

        Remaining plan:
        \(remainingLines)

        Decide: is the remaining plan still the right path?
        - If YES, respond with exactly: KEEP
        - If NO, respond with replacement steps, one per line:
          STEP: <title> | CMD: <shell command or empty>

        Only propose replacement when the output genuinely changes the plan
        (e.g. the step revealed a different root cause, skipped work, or an
        unexpected state). Prefer KEEP when in doubt.

        Decision:
        """

        do {
            let response = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("KEEP") { return nil }
            let steps = parseReplanResponse(trimmed)
            return steps.isEmpty ? nil : steps
        } catch {
            logger.debug("AgentLoop: adaptive step generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Replan

    private static func generateReplanSteps(
        failedStep: AgentPlanStep,
        output: String,
        pwd: String?
    ) async -> [AgentPlanStep]? {
        let prompt = """
        A step in an agent plan failed. Generate 1-3 replacement steps to recover.
        Format each step as: "STEP: <title> | CMD: <shell command or empty>"

        Failed step: \(failedStep.title)
        Command: \(failedStep.command ?? "(none)")
        Error output: \(output.prefix(500))

        Replacement steps:
        """

        do {
            let response = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
            let steps = parseReplanResponse(response)
            return steps.isEmpty ? nil : steps
        } catch {
            logger.debug("AgentLoop: replan generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseReplanResponse(_ response: String) -> [AgentPlanStep] {
        let lines = response.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var steps: [AgentPlanStep] = []
        for line in lines {
            if line.uppercased().hasPrefix("STEP:") {
                let content = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = content.components(separatedBy: " | CMD:")
                let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let command = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                let cmd = (command?.isEmpty == true || command == "empty") ? nil : command
                steps.append(AgentPlanStep(title: title, command: cmd))
            }
        }
        return steps
    }

    // MARK: - Summarization

    private func summarizeAndSuggest(pwd: String?) async {
        guard let session = activeSession else { return }
        await ResultSummarizer.summarize(session, pwd: pwd)
        wireSuggestionsToActiveAI(session)
        archiveSession(session)
    }

    // MARK: - ActiveAI Integration

    private func wireSuggestionsToActiveAI(_ session: AgentSession) {
        suggestionEngine.clear()

        let anyFailed = session.plan?.steps.contains(where: { $0.status == .failed }) ?? false
        let completionChip = ActiveAISuggestion(
            prompt: session.summary ?? "Session completed",
            icon: anyFailed
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill",
            kind: .continueAgent
        )
        suggestionEngine.injectSuggestion(completionChip)

        for action in session.nextActions {
            suggestionEngine.injectSuggestion(ActiveAISuggestion(
                prompt: action,
                icon: "arrow.right.circle",
                kind: .nextStep
            ))
        }
    }

    // MARK: - History

    private func archiveSession(_ session: AgentSession) {
        sessionHistory.insert(session, at: 0)
        if sessionHistory.count > 20 {
            sessionHistory = Array(sessionHistory.prefix(20))
        }
    }
}
