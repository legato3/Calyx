// PredictionContextTests.swift
// CTermTests

import XCTest
@testable import CTerm

final class PredictionContextTests: XCTestCase {

    // MARK: - Helpers

    private func makeBlock(
        command: String,
        status: TerminalCommandStatus = .succeeded
    ) -> TerminalCommandBlock {
        TerminalCommandBlock(
            id: UUID(),
            source: .shell,
            surfaceID: nil,
            command: command,
            startedAt: Date(),
            finishedAt: Date(),
            status: status,
            outputSnippet: nil,
            errorSnippet: nil,
            exitCode: status == .failed ? 1 : 0,
            durationNanoseconds: nil
        )
    }

    private func makeContext(
        pwd: String? = "/tmp/project",
        gitBranch: String? = "main"
    ) -> TerminalContext {
        TerminalContext(
            pwd: pwd,
            shell: "/bin/zsh",
            gitBranch: gitBranch,
            gitStatusLines: nil,
            projectType: "Node.js",
            activeEnv: nil
        )
    }

    // MARK: - Workflow Phase Detection

    func testBuildPhaseDetected() {
        let blocks = [
            makeBlock(command: "npm run build"),
            makeBlock(command: "npm run build"),
            makeBlock(command: "git status"),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.workflowPhase, .building)
    }

    func testTestPhaseDetected() {
        let blocks = [
            makeBlock(command: "npm test"),
            makeBlock(command: "jest --watch"),
            makeBlock(command: "npm run build"),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.workflowPhase, .testing)
    }

    func testDebuggingPhaseOnFailureStreak() {
        let blocks = [
            makeBlock(command: "cargo build", status: .failed),
            makeBlock(command: "cargo build", status: .failed),
            makeBlock(command: "cargo build", status: .failed),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.workflowPhase, .debugging)
        XCTAssertEqual(ctx.failureStreak, 3)
    }

    func testGitFlowDetected() {
        let blocks = [
            makeBlock(command: "git add ."),
            makeBlock(command: "git commit -m 'fix'"),
            makeBlock(command: "git push"),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.workflowPhase, .gitFlow)
    }

    func testExploringPhaseDetected() {
        let blocks = [
            makeBlock(command: "ls -la"),
            makeBlock(command: "cat README.md"),
            makeBlock(command: "find . -name '*.swift'"),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.workflowPhase, .exploring)
    }

    func testUnknownPhaseOnEmptyHistory() {
        let ctx = PredictionContextBuilder.build(
            blocks: [], pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.workflowPhase, .unknown)
    }

    // MARK: - Failure Streak

    func testFailureStreakCountsConsecutiveFailures() {
        let blocks = [
            makeBlock(command: "make", status: .failed),
            makeBlock(command: "make", status: .failed),
            makeBlock(command: "make clean", status: .succeeded),
            makeBlock(command: "make", status: .failed),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: nil, terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.failureStreak, 2, "Should count only consecutive failures from the top")
    }

    func testNoFailureStreak() {
        let blocks = [
            makeBlock(command: "git status", status: .succeeded),
            makeBlock(command: "npm test", status: .succeeded),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: nil, terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.failureStreak, 0)
    }

    // MARK: - Context Block

    func testEnrichedContextBlockIncludesPhase() {
        let blocks = [makeBlock(command: "npm test")]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: "/tmp/project", terminalContext: makeContext()
        )
        XCTAssertTrue(ctx.enrichedContextBlock.contains("Workflow phase:"))
    }

    func testEnrichedContextBlockIncludesFailureStreak() {
        let blocks = [
            makeBlock(command: "cargo build", status: .failed),
            makeBlock(command: "cargo build", status: .failed),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: nil, terminalContext: makeContext()
        )
        XCTAssertTrue(ctx.enrichedContextBlock.contains("Failure streak: 2"))
    }

    // MARK: - History Block

    func testHistoryBlockFormatsCorrectly() {
        let blocks = [
            makeBlock(command: "git status", status: .succeeded),
            makeBlock(command: "npm run build", status: .failed),
        ]
        let ctx = PredictionContextBuilder.build(
            blocks: blocks, pwd: nil, terminalContext: makeContext()
        )
        XCTAssertTrue(ctx.historyBlock.contains("[ok] git status"))
        XCTAssertTrue(ctx.historyBlock.contains("[failed] npm run build"))
    }

    func testEmptyHistoryBlock() {
        let ctx = PredictionContextBuilder.build(
            blocks: [], pwd: nil, terminalContext: makeContext()
        )
        XCTAssertEqual(ctx.historyBlock, "(none)")
    }
}
