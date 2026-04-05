// BrowserResearchWorkflow.swift
// CTerm
//
// Orchestrates browser-as-tool research within the agent loop.
// Detects when browser automation is the right tool, builds a short action plan,
// runs each step through BrowserToolHandler, captures structured findings,
// and summarizes them back into the terminal workflow.
//
// Every browser step is logged to SessionAuditLogger for full observability.
// Findings are persisted to AgentMemoryStore when they meet confidence thresholds.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.cterm", category: "BrowserResearch")

// MARK: - Finding

/// A structured finding extracted from a browser research step.
struct BrowserFinding: Identifiable, Sendable {
    let id: UUID
    let url: String
    let title: String
    let content: String
    let selector: String?
    let capturedAt: Date
    let stepIndex: Int

    init(url: String, title: String, content: String, selector: String? = nil, stepIndex: Int) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.content = content
        self.selector = selector
        self.capturedAt = Date()
        self.stepIndex = stepIndex
    }

    /// Truncated content for display (first 200 chars).
    var preview: String {
        content.count > 200 ? String(content.prefix(200)) + "…" : content
    }
}

// MARK: - Research Step Log Entry

/// Observable log entry for a single browser research step.
struct BrowserResearchLogEntry: Identifiable, Sendable {
    let id: UUID
    let stepIndex: Int
    let title: String
    let command: String?
    let startedAt: Date
    var completedAt: Date?
    var status: StepStatus
    var output: String?
    var finding: BrowserFinding?

    enum StepStatus: String, Sendable {
        case running
        case succeeded
        case failed
        case skipped
    }

    init(stepIndex: Int, title: String, command: String?) {
        self.id = UUID()
        self.stepIndex = stepIndex
        self.title = title
        self.command = command
        self.startedAt = Date()
        self.status = .running
    }
}

// MARK: - Research Session State

/// Observable state for a browser research session. Drives the UI.
@Observable
@MainActor
final class BrowserResearchSession: Identifiable {
    let id: UUID
    let goal: String
    let startedAt: Date

    private(set) var logEntries: [BrowserResearchLogEntry] = []
    private(set) var findings: [BrowserFinding] = []
    private(set) var summary: String?
    private(set) var isComplete: Bool = false
    var currentURL: String?

    var findingsCount: Int { findings.count }
    var stepsCompleted: Int { logEntries.filter { $0.status == .succeeded }.count }
    var totalSteps: Int { logEntries.count }

    init(goal: String) {
        self.id = UUID()
        self.goal = goal
        self.startedAt = Date()
    }

    func appendLog(_ entry: BrowserResearchLogEntry) {
        logEntries.append(entry)
    }

    func updateLog(at index: Int, status: BrowserResearchLogEntry.StepStatus, output: String?) {
        guard index < logEntries.count else { return }
        logEntries[index].status = status
        logEntries[index].completedAt = Date()
        logEntries[index].output = output
    }

    func addFinding(_ finding: BrowserFinding) {
        findings.append(finding)
        // Audit log
        SessionAuditLogger.log(
            type: .browserFindingCaptured,
            detail: "\(finding.title): \(finding.preview)"
        )
    }

    func complete(summary: String) {
        self.summary = summary
        self.isComplete = true
    }
}

// MARK: - Workflow Orchestrator

@MainActor
final class BrowserResearchWorkflow {

    private let toolHandler: BrowserToolHandler
    private(set) var activeSession: BrowserResearchSession?

    init(toolHandler: BrowserToolHandler) {
        self.toolHandler = toolHandler
    }

    /// Execute a full browser research workflow for the given agent session steps.
    /// Returns structured findings and a summary string.
    func execute(
        goal: String,
        steps: [AgentPlanStep],
        agentSession: AgentSession
    ) async -> (findings: [BrowserFinding], summary: String) {
        let session = BrowserResearchSession(goal: goal)
        activeSession = session
        // Publish to the owning AgentSession so the run panel can bind.
        agentSession.browserResearchSession = session

        logger.info("BrowserResearch: starting workflow — \(goal.prefix(80))")

        for (index, step) in steps.enumerated() {
            guard !agentSession.phase.isTerminal else { break }

            let logEntry = BrowserResearchLogEntry(
                stepIndex: index,
                title: step.title,
                command: step.command
            )
            session.appendLog(logEntry)

            // Audit: step started
            SessionAuditLogger.log(
                type: .browserStepStarted,
                detail: "Step \(index + 1): \(step.title)"
            )

            guard let command = step.command, !command.isEmpty else {
                // Informational step — mark succeeded
                session.updateLog(at: index, status: .succeeded, output: nil)
                SessionAuditLogger.log(
                    type: .browserStepCompleted,
                    detail: "Step \(index + 1) (informational): \(step.title)"
                )
                continue
            }

            // Check permissions
            let permissions = AgentPermissionsStore.shared
            if permissions.isBlocked(.browserAutomation) {
                session.updateLog(at: index, status: .failed, output: "Browser automation is disabled")
                logger.warning("BrowserResearch: blocked by permissions")
                break
            }

            // Execute the browser command
            let result = await dispatchBrowserCommand(command)
            session.currentURL = extractCurrentURL(from: result)

            if result.isError {
                session.updateLog(at: index, status: .failed, output: result.text)
                SessionAuditLogger.log(
                    type: .browserStepCompleted,
                    detail: "Step \(index + 1) FAILED: \(result.text.prefix(200))"
                )
                logger.warning("BrowserResearch: step \(index + 1) failed — \(result.text.prefix(100))")

                // Record as artifact
                agentSession.addArtifact(AgentArtifact(
                    kind: .commandOutput,
                    value: "Browser step failed: \(result.text.prefix(300))"
                ))
            } else {
                session.updateLog(at: index, status: .succeeded, output: String(result.text.prefix(2000)))
                SessionAuditLogger.log(
                    type: .browserStepCompleted,
                    detail: "Step \(index + 1) OK: \(step.title) (\(result.text.count) chars)"
                )

                // Extract finding from content-producing steps
                if isContentStep(command) {
                    let finding = BrowserFinding(
                        url: session.currentURL ?? "unknown",
                        title: step.title,
                        content: String(result.text.prefix(5000)),
                        selector: extractSelector(from: command),
                        stepIndex: index
                    )
                    session.addFinding(finding)

                    // Emit a typed browser-finding artifact so the run panel
                    // can render it as a card.
                    agentSession.addArtifact(AgentArtifact(
                        kind: .browserFinding,
                        value: AgentArtifact.encodeBrowserFinding(
                            url: finding.url,
                            title: finding.title,
                            content: finding.content
                        )
                    ))
                }
            }

            // Brief pause between steps for observability
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Build summary
        let summaryText = buildSummary(session)
        session.complete(summary: summaryText)

        // Persist findings to memory if worthwhile
        persistFindings(session)

        logger.info("BrowserResearch: completed — \(session.findingsCount) finding(s)")
        return (session.findings, summaryText)
    }

    // MARK: - Browser Command Dispatch

    /// Parse and dispatch a browser command. Same format as ExecutionCoordinator.
    private func dispatchBrowserCommand(_ command: String) async -> BrowserToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // "browse:<url>"
        if trimmed.lowercased().hasPrefix("browse:") {
            let url = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            return await toolHandler.handleTool(name: "browser_open", arguments: ["url": url])
        }

        // "open http..."
        if trimmed.lowercased().hasPrefix("open http") {
            let url = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return await toolHandler.handleTool(name: "browser_open", arguments: ["url": url])
        }

        // "browser:<tool_name> [json_args]"
        if trimmed.lowercased().hasPrefix("browser:") {
            let rest = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = rest.split(separator: " ", maxSplits: 1)
            let toolName = "browser_\(parts[0])"
            var args: [String: Any]? = nil
            if parts.count > 1 {
                let jsonStr = String(parts[1])
                if let data = jsonStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    args = parsed
                }
            }
            return await toolHandler.handleTool(name: toolName, arguments: args)
        }

        return BrowserToolResult(text: "Unrecognized browser command: \(trimmed.prefix(60))", isError: true)
    }

    // MARK: - Helpers

    /// Returns true for commands that produce extractable content.
    private func isContentStep(_ command: String) -> Bool {
        let lower = command.lowercased()
        let contentTools = ["get_text", "get_html", "get_links", "get_inputs",
                            "snapshot", "get_attribute", "eval"]
        return contentTools.contains { lower.contains($0) }
    }

    /// Extract CSS selector from a browser command's JSON args.
    private func extractSelector(from command: String) -> String? {
        guard let data = command.split(separator: " ", maxSplits: 1).last.map(String.init)?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selector = json["selector"] as? String
        else { return nil }
        return selector
    }

    /// Try to extract the current page URL from a browser result.
    private func extractCurrentURL(from result: BrowserToolResult) -> String? {
        guard !result.isError,
              let data = result.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["pageURL"] as? String
        else { return nil }
        return url
    }

    // MARK: - Summary

    private func buildSummary(_ session: BrowserResearchSession) -> String {
        let succeeded = session.logEntries.filter { $0.status == .succeeded }.count
        let failed = session.logEntries.filter { $0.status == .failed }.count
        let total = session.logEntries.count

        var parts: [String] = []
        parts.append("Browser research: \(session.goal.prefix(60))")
        parts.append("\(succeeded)/\(total) steps completed")
        if failed > 0 { parts.append("\(failed) failed") }
        parts.append("\(session.findingsCount) finding(s) captured")

        if !session.findings.isEmpty {
            let findingSummaries = session.findings.prefix(3).map { finding in
                "• \(finding.title): \(finding.preview.prefix(80))"
            }
            parts.append("Key findings:\n\(findingSummaries.joined(separator: "\n"))")
        }

        let elapsed = Date().timeIntervalSince(session.startedAt)
        parts.append("Completed in \(Int(elapsed))s")

        return parts.joined(separator: ". ")
    }

    // MARK: - Memory Persistence

    /// Persist worthwhile findings to AgentMemoryStore.
    private func persistFindings(_ session: BrowserResearchSession) {
        guard let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd else { return }
        let projectKey = AgentMemoryStore.key(for: pwd)
        let store = AgentMemoryStore.shared

        for finding in session.findings {
            // Only persist findings with substantial content
            guard finding.content.count > 50 else { continue }

            let key = "browser/\(sanitizeKey(finding.title))"
            let value = """
            URL: \(finding.url)
            \(finding.content.prefix(500))
            """

            store.remember(
                projectKey: projectKey,
                key: key,
                value: value,
                ttlDays: 7,
                category: .projectFact,
                importance: 0.65,
                confidence: 0.7,
                source: .browserResearch
            )
        }

        // Also persist a summary of the research session
        if !session.findings.isEmpty {
            store.remember(
                projectKey: projectKey,
                key: "browser/last-research",
                value: session.summary ?? "Browser research completed with \(session.findingsCount) findings",
                ttlDays: 7,
                category: .projectFact,
                importance: 0.6,
                confidence: 0.8,
                source: .browserResearch
            )
        }
    }

    private func sanitizeKey(_ input: String) -> String {
        let cleaned = input.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return String(cleaned.prefix(40))
    }
}
