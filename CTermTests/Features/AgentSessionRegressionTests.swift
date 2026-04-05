import Foundation
import Testing
@testable import CTerm

@MainActor
@Suite("Agent Session Regressions")
struct AgentSessionRegressionTests {
    @Test("ApprovalPresenter resumes with the explicit answer even after clearing approval state")
    func approvalPresenterForwardsResolvedAnswer() {
        let presenter = ApprovalPresenter.shared
        let session = AgentSession(
            intent: "Run a safe command",
            rawPrompt: "Run a safe command",
            tabID: nil,
            kind: .multiStep,
            backend: .ollama
        )
        let context = ApprovalContext(
            stepID: nil,
            riskScore: 55,
            riskTier: .high,
            action: ActionDescriptor(
                what: "Run: ls",
                why: "Inspect the repo",
                impact: "Read-only",
                rollback: nil
            )
        )

        var resolvedAnswer: ApprovalAnswer?
        session.onApprovalResolved = { answer in
            resolvedAnswer = answer
        }

        presenter.setRepoPath(nil)
        presenter.session(session, didRequestApproval: context)
        presenter.resolve(answer: .approved, scope: .once)

        #expect(resolvedAnswer == .approved)
        #expect(session.approval == nil)
    }

    @Test("Trigger routeToClaude does not register a detached idle agent session")
    func triggerRouteDoesNotCreateGhostSession() async {
        let registry = AgentSessionRegistry.shared
        registry._resetForTesting()

        let engine = TriggerEngine.shared
        let originalRules = engine.rules
        defer {
            engine.stop()
            engine.rules = originalRules
            registry._resetForTesting()
        }

        engine.stop()
        engine.rules = [
            TriggerRule(
                name: "Route failing command",
                triggerType: .commandFail,
                actionType: .routeToClaude,
                actionMessage: "Please investigate {snippet}"
            )
        ]
        engine.start()

        NotificationCenter.default.post(
            name: .shellErrorCaptured,
            object: nil,
            userInfo: [
                "snippet": "Tests failed",
                "tabTitle": "Main",
            ]
        )

        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(registry.active.isEmpty)
    }
}
