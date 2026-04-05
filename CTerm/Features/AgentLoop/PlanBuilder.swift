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
    static func buildPlan(for session: AgentSession, pwd: String?) async {
        session.transition(to: .thinking)

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

        case .browserResearch:
            steps = await buildBrowserResearchPlan(session.userIntent, pwd: pwd)
        }

        // Tag willAsk per step by running a lightweight gate simulation.
        // Kind is inferred by AgentPlanStep's initializer from the command prefix.
        session.planSteps = assessWillAsk(steps, pwd: pwd)
        session.approvalRequirement = intent.defaultApproval

        if steps.isEmpty {
            session.fail(message: "Could not generate a plan for this goal.")
        } else if session.approvalRequirement == .none {
            // Auto-approve all steps for safe intents
            for i in session.planSteps.indices {
                session.planSteps[i].status = .approved
            }
            session.transition(to: .running)
        } else {
            session.transition(to: .awaitingApproval)
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

    // MARK: - Browser Research Plans

    private static func buildBrowserResearchPlan(_ input: String, pwd: String?) async -> [AgentPlanStep] {
        // Try LLM-generated plan first
        let llmSteps = await buildBrowserResearchPlanStreaming(input, pwd: pwd)
        if !llmSteps.isEmpty { return llmSteps }

        // Fallback: heuristic plan based on keywords
        return buildBrowserResearchPlanFallback(input)
    }

    private static func buildBrowserResearchPlanStreaming(_ input: String, pwd: String?) async -> [AgentPlanStep] {
        let prompt = """
        Generate a short browser research plan (2-5 steps) for this task.
        Each step must use browser automation commands.

        Format each step as: "STEP: <title> | CMD: <browser command>"

        Available browser commands:
        - browse:<url>                    — open a URL
        - browser:get_text {"selector":"<css>"}  — extract text from element
        - browser:get_links {}            — get all links on page
        - browser:snapshot {}             — get page structure
        - browser:click {"selector":"<css>"}     — click an element
        - browser:fill {"selector":"<css>","value":"<text>"} — fill a form field
        - browser:navigate {"url":"<url>"}       — navigate to URL
        - browser:wait {"selector":"<css>"}      — wait for element

        Task: \(input.prefix(500))

        Steps:
        """

        do {
            let response = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
            let steps = parseBrowserPlanResponse(response)
            if !steps.isEmpty { return steps }
        } catch {
            logger.debug("PlanBuilder: browser research LLM plan failed: \(error.localizedDescription)")
        }
        return []
    }

    private static func buildBrowserResearchPlanFallback(_ input: String) -> [AgentPlanStep] {
        let lower = input.lowercased()
        var steps: [AgentPlanStep] = []

        // Detect URL in input
        if let url = extractURL(from: input) {
            steps.append(AgentPlanStep(title: "Open target page", command: "browse:\(url)"))
            steps.append(AgentPlanStep(title: "Capture page snapshot", command: "browser:snapshot {}"))
            steps.append(AgentPlanStep(title: "Extract relevant content", command: "browser:get_text {\"selector\":\"main, article, .content, body\"}"))
        } else if lower.contains("release notes") || lower.contains("changelog") {
            steps.append(AgentPlanStep(title: "Search for release notes"))
            steps.append(AgentPlanStep(title: "Open release page", command: "browse:https://github.com"))
            steps.append(AgentPlanStep(title: "Extract release content", command: "browser:get_text {\"selector\":\".markdown-body, main, article\"}"))
        } else if lower.contains("docs") || lower.contains("documentation") || lower.contains("api") {
            steps.append(AgentPlanStep(title: "Open documentation site"))
            steps.append(AgentPlanStep(title: "Navigate to relevant section"))
            steps.append(AgentPlanStep(title: "Extract documentation", command: "browser:get_text {\"selector\":\"main, article, .content\"}"))
        } else if lower.contains("dashboard") || lower.contains("web form") || lower.contains("inspect") {
            steps.append(AgentPlanStep(title: "Open target page"))
            steps.append(AgentPlanStep(title: "Capture page snapshot", command: "browser:snapshot {}"))
            steps.append(AgentPlanStep(title: "Extract form inputs", command: "browser:get_inputs {}"))
            steps.append(AgentPlanStep(title: "Extract visible content", command: "browser:get_text {\"selector\":\"body\"}"))
        } else {
            // Generic research
            steps.append(AgentPlanStep(title: "Open research target"))
            steps.append(AgentPlanStep(title: "Capture page structure", command: "browser:snapshot {}"))
            steps.append(AgentPlanStep(title: "Extract findings", command: "browser:get_text {\"selector\":\"main, article, body\"}"))
        }

        // Always end with a summarize step
        steps.append(AgentPlanStep(title: "Summarize findings"))
        return steps
    }

    private static func parseBrowserPlanResponse(_ response: String) -> [AgentPlanStep] {
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

    // MARK: - Will-Ask Pre-Assessment

    /// Runs a lightweight dry-run of ApprovalGate so the stepper can flag
    /// risky rows before the user approves the plan. Peer/manual steps never
    /// ask; shell/browser steps consult RiskScorer + HardStopGuard + trust mode.
    @MainActor
    private static func assessWillAsk(_ steps: [AgentPlanStep], pwd: String?) -> [AgentPlanStep] {
        steps.map { step in
            guard let command = step.command, !command.isEmpty else { return step }
            var s = step
            switch step.kind {
            case .shell:
                s.willAsk = shellWillAsk(command: command, pwd: pwd)
            case .browser:
                s.willAsk = browserWillAsk(command: command)
            case .peer, .manual:
                s.willAsk = false
            }
            return s
        }
    }

    @MainActor
    private static func shellWillAsk(command: String, pwd: String?) -> Bool {
        if HardStopGuard.isHardStop(command, gitBranch: nil) != nil { return true }
        let assessment = RiskScorer.assess(command: command, pwd: pwd, gitBranch: nil)
        switch AgentPermissionsStore.shared.decide(for: assessment) {
        case .autoApprove:     return false
        case .requireApproval: return true
        case .blocked:         return true
        }
    }

    @MainActor
    private static func browserWillAsk(command: String) -> Bool {
        // Mirror ExecutionCoordinator.browserRiskScore heuristic.
        let lower = command.lowercased()
        let score: Int
        if lower.contains("eval") { score = 45 }
        else if lower.contains("click") || lower.contains("fill") || lower.contains("type")
            || lower.contains("press") || lower.contains("check") || lower.contains("select") {
            score = 25
        } else { score = 10 }
        switch AgentPermissionsStore.shared.trustMode {
        case .askMe:        return score >= 20
        case .trustSession: return score >= 80
        }
    }

    private static func extractURL(from input: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(input.startIndex..., in: input)
        if let match = detector?.firstMatch(in: input, range: range),
           let url = match.url {
            return url.absoluteString
        }
        return nil
    }
}
