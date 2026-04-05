// AgentLoopCoordinator.swift
// CTerm
//
// Top-level coordinator for the agent pipeline:
// intent → classify → plan → approve → execute → observe → summarize → suggest.
//
// Owns the AgentSessionState and orchestrates the pipeline stages.
// Wires output back into ActiveAISuggestionEngine as clickable chips.
// Supports streaming plan preview, observation→replan feedback, and cost budget.
// One coordinator per active agent session (typically one per tab).

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentLoopCoordinator")

@Observable
@MainActor
final class AgentLoopCoordinator {

    /// The active session being coordinated. Nil when idle.
    private(set) var activeSession: AgentSessionState?

    /// History of completed sessions (most recent first). Capped at 20.
    private(set) var sessionHistory: [AgentSessionState] = []

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

    /// Start the full agent pipeline for a user request.
    func startSession(
        intent: String,
        tabID: UUID? = nil,
        pwd: String?,
        activeTab: Tab? = nil
    ) async {
        // Cancel any existing session
        if let existing = activeSession, !existing.phase.isTerminal {
            existing.transitionTo(.completed)
            archiveSession(existing)
        }

        // Build enriched prompt with context (now includes cross-session handoff)
        let enrichedIntent = AgentPromptContextBuilder.buildPrompt(goal: intent, activeTab: activeTab)

        let session = AgentSessionState(userIntent: enrichedIntent, tabID: tabID)
        activeSession = session
        streamingPreview = nil

        logger.info("AgentLoop: starting session for: \(session.displayIntent.prefix(80))")

        // Phase 1: Classify intent
        session.transitionTo(.classifying)
        let (category, confidence) = IntentRouter.classify(enrichedIntent)

        // Use LLM classification if keyword confidence is low
        if confidence < 0.4 {
            let llmCategory = await IntentRouter.classifyWithLLM(intent, pwd: pwd)
            session.classifiedIntent = llmCategory
        } else {
            session.classifiedIntent = category
        }

        guard !session.phase.isTerminal else { return }

        // Wire streaming preview callback
        PlanBuilder.onStreamingPreview = { [weak self] text in
            self?.streamingPreview = text
        }

        // Phase 2: Build plan (with streaming preview for LLM-generated plans)
        await PlanBuilder.buildPlan(for: session, pwd: pwd)

        // Clear streaming preview once plan is ready
        streamingPreview = nil
        PlanBuilder.onStreamingPreview = nil

        guard !session.phase.isTerminal else { return }

        // If awaiting approval, stop here — user will call approveAndExecute()
        if session.phase == .awaitingApproval {
            logger.info("AgentLoop: plan ready, awaiting approval (\(session.planSteps.count) steps)")
            return
        }

        // Phase 3+: Execute (auto-approved intents proceed immediately)
        await executeSession(pwd: pwd)
    }

    // MARK: - Approval

    /// Approve all pending steps and begin execution.
    func approveAndExecute(pwd: String?) async {
        guard let session = activeSession,
              session.phase == .awaitingApproval else { return }

        for i in session.planSteps.indices where session.planSteps[i].status == .pending {
            session.planSteps[i].status = .approved
        }

        // Post approval notification for TriggerEngine
        NotificationCenter.default.post(
            name: .agentPlanApproved,
            object: nil,
            userInfo: [
                "goal": session.displayIntent,
                "totalSteps": session.planSteps.count,
            ]
        )

        await executeSession(pwd: pwd)
    }

    /// Batch-approve steps using risk-aware batching.
    /// Auto-approves low-risk steps and returns batches for user review.
    func batchApproveSteps(pwd: String?, gitBranch: String? = nil) -> [ApprovalBatch] {
        guard let session = activeSession,
              session.phase == .awaitingApproval else { return [] }

        let projectKey = pwd.map { AgentMemoryStore.key(for: $0) }
        let (autoApproved, batches) = ApprovalBatcher.batch(
            steps: session.planSteps,
            pwd: pwd,
            gitBranch: gitBranch,
            memory: ApprovalMemory.shared
        )

        // Auto-approve low-risk steps immediately
        for stepID in autoApproved {
            if let idx = session.planSteps.firstIndex(where: { $0.id == stepID }) {
                session.planSteps[idx].status = .approved
            }
        }

        return batches
    }

    /// Approve a specific batch and optionally remember the decision.
    func approveBatch(_ batch: ApprovalBatch, rememberScope: ApprovalScope?, pwd: String?) {
        guard let session = activeSession else { return }

        for stepID in batch.stepIDs {
            if let idx = session.planSteps.firstIndex(where: { $0.id == stepID }) {
                session.planSteps[idx].status = .approved
            }
        }

        // Remember if requested
        if let scope = rememberScope {
            let projectKey = pwd.map { AgentMemoryStore.key(for: $0) }
            ApprovalMemory.shared.rememberBatch(batch, scope: scope, projectKey: projectKey)
        }
    }

    /// Deny a batch and propose safer alternatives.
    func denyBatch(_ batch: ApprovalBatch) -> [DenialAlternative] {
        guard let session = activeSession else { return [] }

        var alternatives: [DenialAlternative] = []
        for item in batch.items {
            if let idx = session.planSteps.firstIndex(where: { $0.id == item.stepID }) {
                session.planSteps[idx].status = .skipped
            }
            if let alt = DenialHandler.proposeSaferAlternative(
                command: item.command,
                assessment: item.assessment
            ) {
                alternatives.append(alt)
            }
        }
        return alternatives
    }

    /// Approve a single step by ID.
    func approveStep(id: UUID) {
        guard let session = activeSession else { return }
        if let idx = session.planSteps.firstIndex(where: { $0.id == id }) {
            session.planSteps[idx].status = .approved
        }
    }

    /// Skip a step by ID.
    func skipStep(id: UUID) {
        guard let session = activeSession else { return }
        if let idx = session.planSteps.firstIndex(where: { $0.id == id }) {
            session.planSteps[idx].status = .skipped
        }
    }

    // MARK: - Stop

    func stopSession() {
        guard let session = activeSession else { return }
        executionCoordinator?.stop()
        session.transitionTo(.completed)
        session.summary = "Stopped by user."
        archiveSession(session)
        activeSession = nil
    }

    // MARK: - Command Finished (from terminal)

    /// Called when a command block finishes in the terminal.
    func handleCommandFinished(exitCode: Int, output: String?) {
        executionCoordinator?.handleCommandFinished(exitCode: exitCode, output: output)
    }

    // MARK: - Execution

    private func executeSession(pwd: String?) async {
        guard let session = activeSession else { return }

        let executor = AgentPlanExecutor(planStore: planStore)
        let coordinator = ExecutionCoordinator(
            session: session,
            planStore: planStore,
            executor: executor
        )
        self.executionCoordinator = coordinator

        // Wire completion callback
        coordinator.onAllStepsCompleted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.summarizeAndSuggest(pwd: pwd)
            }
        }

        // Wire observation callback
        coordinator.onObservation = { [weak self] stepIndex, output in
            guard let self, let session = self.activeSession else { return }
            // Track file changes from output
            let changedFiles = FileChangeStore.shared.recentPaths(limit: 5)
            for file in changedFiles {
                session.addArtifact(AgentArtifact(kind: .fileChanged, value: file))
            }
        }

        // Wire replan callback — uses LLM to generate replacement steps on failure
        coordinator.onReplanNeeded = { [weak self] failedStep, output in
            guard self != nil else { return nil }
            return await Self.generateReplanSteps(failedStep: failedStep, output: output, pwd: pwd)
        }

        coordinator.start()
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

        // Phase 5: Summarize
        await ResultSummarizer.summarize(session, pwd: pwd)

        // Phase 6: Wire suggestions into ActiveAI chips
        wireSuggestionsToActiveAI(session)

        // Archive and clear
        archiveSession(session)
    }

    // MARK: - ActiveAI Integration

    private func wireSuggestionsToActiveAI(_ session: AgentSessionState) {
        suggestionEngine.clear()

        // Add completion chip
        let completionChip = ActiveAISuggestion(
            prompt: session.summary ?? "Session completed",
            icon: session.planSteps.contains(where: { $0.status == .failed })
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill",
            kind: .continueAgent
        )
        suggestionEngine.injectSuggestion(completionChip)

        // Add next-action chips
        for action in session.nextActions {
            let chip = ActiveAISuggestion(
                prompt: action,
                icon: "arrow.right.circle",
                kind: .nextStep
            )
            suggestionEngine.injectSuggestion(chip)
        }

        logger.info("AgentLoop: wired \(session.nextActions.count + 1) suggestion(s) to ActiveAI")
    }

    // MARK: - History

    private func archiveSession(_ session: AgentSessionState) {
        sessionHistory.insert(session, at: 0)
        if sessionHistory.count > 20 {
            sessionHistory = Array(sessionHistory.prefix(20))
        }
    }
}
