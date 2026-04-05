//
//  ComposeOverlayTests.swift
//  CTermTests
//
//  Tests for ComposeOverlayView, trusted paste, and WindowSession compose state.
//  Written before implementation (TDD Red phase) -- all tests must FAIL.
//
//  Coverage:
//  - ComposeOverlayView: Enter sends text via onSend
//  - ComposeOverlayView: Shift+Enter inserts newline without sending
//  - ComposeOverlayView: Escape triggers onDismiss
//  - ComposeOverlayView: Empty text is not sent
//  - GhosttyAppController: trustedPasteContent defaults nil
//  - GhosttyAppController: trustedPasteContent round-trip
//  - WindowSession: showComposeOverlay defaults false
//  - WindowSession: showComposeOverlay toggleable
//

import XCTest
@testable import CTerm

// MARK: - ComposeOverlayView Tests

@MainActor
final class ComposeOverlayViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT() -> ComposeOverlayView {
        ComposeOverlayView()
    }

    // ==================== 1. Enter Sends Text via onSend ====================

    func test_should_invoke_onSend_when_insertNewline_called() {
        // Arrange
        let sut = makeSUT()
        var receivedText: String?
        sut.onSend = { text in
            receivedText = text
            return true
        }

        // Simulate typing "hello" into the internal text view
        sut.textView.string = "hello"

        // Act -- insertNewline is the NSResponder selector triggered by Enter
        sut.insertNewline(nil)

        // Assert
        XCTAssertEqual(receivedText, "hello",
                       "onSend should receive the current text when Enter is pressed")
    }

    // ==================== 2. Shift+Enter Inserts Newline Without Sending ====================

    func test_should_insert_actual_newline_for_shift_enter() {
        // Arrange
        let sut = makeSUT()
        var sendCalled = false
        sut.onSend = { _ in
            sendCalled = true
            return true
        }

        sut.textView.string = "line1"

        // Act -- insertNewlineIgnoringFieldEditor is the selector for Shift+Enter
        sut.insertNewlineIgnoringFieldEditor(nil)

        // Assert
        XCTAssertTrue(sut.textView.string.contains("\n"),
                      "Shift+Enter should insert a literal newline into the text")
        XCTAssertFalse(sendCalled,
                       "onSend must NOT be called for Shift+Enter")
    }

    // ==================== 3. Escape Triggers onDismiss ====================

    func test_should_invoke_onDismiss_when_escape_pressed() {
        // Arrange
        let sut = makeSUT()
        var dismissCalled = false
        sut.onDismiss = {
            dismissCalled = true
        }

        // Act -- cancelOperation is the NSResponder selector triggered by Escape
        sut.cancelOperation(nil)

        // Assert
        XCTAssertTrue(dismissCalled,
                      "onDismiss should fire when Escape (cancelOperation) is invoked")
    }

    // ==================== 3.5. Enter Clears Text After Send ====================

    func test_should_clear_text_after_send() {
        // Arrange
        let sut = makeSUT()
        sut.onSend = { _ in true }
        sut.textView.string = "hello"

        // Act
        sut.insertNewline(nil)

        // Assert
        XCTAssertTrue(sut.textView.string.isEmpty,
                      "Text should be cleared after Enter sends")
    }

    // ==================== 4. Empty Text Is Not Sent ====================

    func test_should_not_send_empty_text() {
        // Arrange
        let sut = makeSUT()
        var sendCalled = false
        sut.onSend = { _ in
            sendCalled = true
            return true
        }

        // Leave text empty (default state)
        sut.textView.string = ""

        // Act
        sut.insertNewline(nil)

        // Assert
        XCTAssertFalse(sendCalled,
                       "onSend should NOT be called when the text is empty")
    }
}

// MARK: - Trusted Paste Tests

@MainActor
final class TrustedPasteTests: XCTestCase {

    // Use an isolated instance so tests never touch the live ghostty C runtime.
    private var controller: GhosttyAppController!

    override func setUp() {
        super.setUp()
        controller = GhosttyAppController(forTesting: ())
    }

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    // ==================== 5. trustedPasteContent Defaults to nil ====================

    func test_trustedPasteContent_should_be_nil_by_default() {
        // Assert
        XCTAssertNil(controller.trustedPasteContent,
                     "trustedPasteContent should be nil when no paste is pending")
    }

    // ==================== 6. trustedPasteContent Round-Trip ====================

    func test_trustedPasteContent_should_be_settable_and_readable() {
        // Arrange
        let testContent = "echo 'dangerous command'"

        // Act
        controller.trustedPasteContent = testContent

        // Assert
        XCTAssertEqual(controller.trustedPasteContent, testContent,
                       "trustedPasteContent should return the value that was set")

        // Cleanup — reset so tearDown is clean
        controller.trustedPasteContent = nil
    }
}

// MARK: - WindowSession Compose Overlay Tests

@MainActor
final class WindowSessionComposeOverlayTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT() -> WindowSession {
        WindowSession()
    }

    // ==================== 7. showComposeOverlay Defaults to false ====================

    func test_showComposeOverlay_should_default_to_false() {
        // Arrange & Act
        let sut = makeSUT()

        // Assert
        XCTAssertFalse(sut.showComposeOverlay,
                       "showComposeOverlay should be false by default")
    }

    // ==================== 8. showComposeOverlay Is Toggleable ====================

    func test_showComposeOverlay_should_be_toggleable() {
        // Arrange
        let sut = makeSUT()

        // Act
        sut.showComposeOverlay = true

        // Assert
        XCTAssertTrue(sut.showComposeOverlay,
                      "showComposeOverlay should be true after being set to true")
    }
}

// MARK: - Agent Prompt Context Tests

@MainActor
final class AgentPromptContextBuilderTests: XCTestCase {

    func test_buildPrompt_includesProjectContextShellErrorAndAttachedBlocks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "Follow the local conventions.".write(
            to: tempDir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let tab = Tab(title: "Claude", pwd: tempDir.path)
        tab.lastShellError = ShellErrorEvent(
            tabID: tab.id,
            tabTitle: "Claude",
            snippet: "Tests failed in ComposeOverlayTests",
            exitCode: 1
        )
        let block = TerminalCommandBlock(
            id: UUID(),
            source: .shell,
            surfaceID: nil,
            command: "swift test",
            startedAt: Date(),
            finishedAt: Date(),
            status: .failed,
            outputSnippet: "1 test failed",
            errorSnippet: "ComposeOverlayTests.test_agent_launch",
            exitCode: 1,
            durationNanoseconds: 2_000_000_000
        )
        tab.commandBlocks = [block]
        tab.attachBlock(block.id)

        let prompt = AgentPromptContextBuilder.buildPrompt(
            goal: "Fix the failing tests",
            activeTab: tab
        )

        XCTAssertTrue(prompt.contains("Fix the failing tests"))
        XCTAssertTrue(prompt.contains("<cterm_agent_context>"))
        XCTAssertTrue(prompt.contains("<cterm_project_context>"))
        XCTAssertTrue(prompt.contains("cwd: \(tempDir.path)"))
        XCTAssertTrue(prompt.contains("Follow the local conventions."))
        XCTAssertTrue(prompt.contains("<latest_shell_error>"))
        XCTAssertTrue(prompt.contains("Tests failed in ComposeOverlayTests"))
        XCTAssertTrue(prompt.contains("<attached_terminal_blocks>"))
        XCTAssertTrue(prompt.contains("Command: swift test"))
    }

    func test_buildPrompt_returnsTrimmedGoal_whenNoContextExists() {
        let prompt = AgentPromptContextBuilder.buildPrompt(goal: "  Explain this output  ", activeTab: nil)
        XCTAssertEqual(prompt, "Explain this output")
    }

    func test_buildPrompt_skipsProjectContext_forSystemScopedGoal() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "Repo-only guidance.".write(
            to: tempDir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let tab = Tab(title: "Local Agent", pwd: tempDir.path)
        tab.commandBlocks = [
            TerminalCommandBlock(
                id: UUID(),
                source: .shell,
                surfaceID: nil,
                command: "git status",
                startedAt: Date(),
                finishedAt: Date(),
                status: .succeeded,
                outputSnippet: "working tree clean",
                errorSnippet: nil,
                exitCode: 0,
                durationNanoseconds: 500_000_000
            )
        ]

        let prompt = AgentPromptContextBuilder.buildPrompt(
            goal: "Check for issues on my Mac",
            activeTab: tab,
            scope: .system
        )

        XCTAssertTrue(prompt.contains("Check for issues on my Mac"))
        XCTAssertFalse(prompt.contains("<cterm_project_context>"))
        XCTAssertFalse(prompt.contains("Repo-only guidance."))
        XCTAssertFalse(prompt.contains("<recent_terminal_activity>"))
    }
}

// MARK: - Claude Workflow Launch Tests

@MainActor
final class ComposeOverlayControllerAgentLaunchTests: XCTestCase {

    func test_launchClaudeAgentWorkflow_postsCurrentDirectoryForQuickLaunch() {
        let controller = ComposeOverlayController()
        let tab = Tab(title: "Claude", pwd: "/tmp/project")
        let expectation = expectation(description: "workflow notification posted")

        var capturedEvent: CTermIPCLaunchWorkflowEvent?
        let observer = NotificationCenter.default.addObserver(
            forName: .ctermIPCLaunchWorkflow,
            object: nil,
            queue: .main
        ) { note in
            capturedEvent = CTermIPCLaunchWorkflowEvent.from(note)
            expectation.fulfill()
        }

        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        XCTAssertTrue(controller.launchClaudeAgentWorkflow(goal: "Investigate the failing build", activeTab: tab))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedEvent?.initialTask, "Investigate the failing build")
        XCTAssertEqual(capturedEvent?.workingDirectory, "/tmp/project")
        XCTAssertEqual(capturedEvent?.skipDirectoryPrompt, true)
        XCTAssertEqual(capturedEvent?.runtime.preset, .claudeCode)
    }
}

// MARK: - Inline Agent Completion Heuristics

@MainActor
final class InlineAgentCompletionHeuristicsTests: XCTestCase {

    func test_shouldNotShortCircuit_systemTroubleshootingGoal_afterFirstSuccess() {
        let session = AgentSession(
            intent: "troubleshoot my mac",
            rawPrompt: "troubleshoot my mac",
            tabID: nil,
            kind: .inline,
            backend: .claudeSubscription
        )
        session.inlineSteps = [
            InlineAgentStep(kind: .command, text: "Run a first diagnostic", command: "sw_vers"),
        ]
        let block = TerminalCommandBlock(
            id: UUID(),
            source: .assistant,
            surfaceID: nil,
            command: "sw_vers",
            startedAt: Date(),
            finishedAt: Date(),
            status: .succeeded,
            outputSnippet: "ProductName: macOS",
            errorSnippet: nil,
            exitCode: 0,
            durationNanoseconds: 100_000_000
        )

        let result = InlineAgentCompletionHeuristics.shouldShortCircuitFirstSuccess(
            intent: session.intent,
            session: session,
            block: block
        )

        XCTAssertFalse(result)
    }

    func test_shouldShortCircuit_simpleInspectGoal_afterFirstSuccess() {
        let session = AgentSession(
            intent: "list files",
            rawPrompt: "list files",
            tabID: nil,
            kind: .inline,
            backend: .claudeSubscription
        )
        session.inlineSteps = [
            InlineAgentStep(kind: .command, text: "List files", command: "ls"),
        ]
        let block = TerminalCommandBlock(
            id: UUID(),
            source: .assistant,
            surfaceID: nil,
            command: "ls",
            startedAt: Date(),
            finishedAt: Date(),
            status: .succeeded,
            outputSnippet: "CTerm\nCTermTests",
            errorSnippet: nil,
            exitCode: 0,
            durationNanoseconds: 100_000_000
        )

        let result = InlineAgentCompletionHeuristics.shouldShortCircuitFirstSuccess(
            intent: session.intent,
            session: session,
            block: block
        )

        XCTAssertTrue(result)
    }
}
