// ConfidenceScorerTests.swift
// CTermTests

import XCTest
@testable import CTerm

final class ConfidenceScorerTests: XCTestCase {

    // MARK: - Helpers

    private func makeBlock(
        command: String,
        status: TerminalCommandStatus = .succeeded,
        exitCode: Int? = nil,
        outputSnippet: String? = nil,
        errorSnippet: String? = nil
    ) -> TerminalCommandBlock {
        TerminalCommandBlock(
            id: UUID(),
            source: .shell,
            surfaceID: nil,
            command: command,
            startedAt: Date(),
            finishedAt: Date(),
            status: status,
            outputSnippet: outputSnippet,
            errorSnippet: errorSnippet,
            exitCode: exitCode,
            durationNanoseconds: nil
        )
    }

    // MARK: - Trivial Command Detection

    func testTrivialCommandsDetected() {
        XCTAssertTrue(ConfidenceScorer.isTrivialCommand("ls"))
        XCTAssertTrue(ConfidenceScorer.isTrivialCommand("ls -la"))
        XCTAssertTrue(ConfidenceScorer.isTrivialCommand("pwd"))
        XCTAssertTrue(ConfidenceScorer.isTrivialCommand("cd .."))
        XCTAssertTrue(ConfidenceScorer.isTrivialCommand("clear"))
        XCTAssertTrue(ConfidenceScorer.isTrivialCommand("echo hello"))
    }

    func testNonTrivialCommandsNotDetected() {
        XCTAssertFalse(ConfidenceScorer.isTrivialCommand("git push origin main"))
        XCTAssertFalse(ConfidenceScorer.isTrivialCommand("npm run build"))
        XCTAssertFalse(ConfidenceScorer.isTrivialCommand("xcodebuild -scheme CTerm build"))
        XCTAssertFalse(ConfidenceScorer.isTrivialCommand("cargo test"))
    }

    // MARK: - Generic Suggestion Detection

    func testGenericSuggestionsDetected() {
        XCTAssertTrue(ConfidenceScorer.isGenericSuggestion("Try again"))
        XCTAssertTrue(ConfidenceScorer.isGenericSuggestion("Check the logs for more info"))
        XCTAssertTrue(ConfidenceScorer.isGenericSuggestion("Read the documentation"))
        XCTAssertTrue(ConfidenceScorer.isGenericSuggestion("Retry"))
        XCTAssertTrue(ConfidenceScorer.isGenericSuggestion("short"))  // too short
    }

    func testSpecificSuggestionsNotGeneric() {
        XCTAssertFalse(ConfidenceScorer.isGenericSuggestion("Fix the missing import in AppDelegate.swift"))
        XCTAssertFalse(ConfidenceScorer.isGenericSuggestion("Add --verbose flag to see detailed output"))
        XCTAssertFalse(ConfidenceScorer.isGenericSuggestion("Run npm install to resolve missing dependencies"))
    }

    // MARK: - Actionable Error Detection

    func testActionableErrorsDetected() {
        XCTAssertTrue(ConfidenceScorer.containsActionableError("AppDelegate.swift:42: error: missing return"))
        XCTAssertTrue(ConfidenceScorer.containsActionableError("error[E0308]: mismatched types"))
        XCTAssertTrue(ConfidenceScorer.containsActionableError("TS2304: Cannot find name 'foo'"))
        XCTAssertTrue(ConfidenceScorer.containsActionableError("npm ERR! missing script: build"))
        XCTAssertTrue(ConfidenceScorer.containsActionableError("ModuleNotFoundError: No module named 'flask'"))
        XCTAssertTrue(ConfidenceScorer.containsActionableError("bash: jq: command not found"))
    }

    func testNonActionableOutputNotDetected() {
        XCTAssertFalse(ConfidenceScorer.containsActionableError("Build succeeded"))
        XCTAssertFalse(ConfidenceScorer.containsActionableError("All tests passed"))
        XCTAssertFalse(ConfidenceScorer.containsActionableError(""))
    }

    // MARK: - Suggestion Scoring

    func testFailedCommandWithActionableErrorScoresHigh() {
        let block = makeBlock(
            command: "swift build",
            status: .failed,
            exitCode: 1,
            errorSnippet: "Sources/App.swift:12:5: error: missing return in function"
        )
        let score = ConfidenceScorer.scoreSuggestion(
            block: block,
            suggestionText: "Fix the missing return in App.swift line 12",
            recentCommands: [],
            hasRelevantMemory: false
        )
        XCTAssertGreaterThan(score.value, ConfidenceScore.chipThreshold)
        XCTAssertTrue(score.reason.contains("failed_command"))
        XCTAssertTrue(score.reason.contains("actionable_error"))
    }

    func testTrivialCommandScoresLow() {
        let block = makeBlock(command: "ls", status: .succeeded)
        let score = ConfidenceScorer.scoreSuggestion(
            block: block,
            suggestionText: "Explain the output of: ls",
            recentCommands: [],
            hasRelevantMemory: false
        )
        XCTAssertLessThan(score.value, ConfidenceScore.chipThreshold)
    }

    func testGenericSuggestionTextPenalized() {
        let block = makeBlock(command: "npm run build", status: .failed, exitCode: 1)
        let score = ConfidenceScorer.scoreSuggestion(
            block: block,
            suggestionText: "Try again",
            recentCommands: [],
            hasRelevantMemory: false
        )
        // Even though the command failed, generic text should be penalized
        XCTAssertLessThan(score.value, 0.6)
    }

    func testRepeatedFailuresBoostScore() {
        let failedBlock = makeBlock(command: "cargo build", status: .failed, exitCode: 1)
        let history = [
            makeBlock(command: "cargo build", status: .failed, exitCode: 1),
            makeBlock(command: "cargo build", status: .failed, exitCode: 1),
            makeBlock(command: "cargo build", status: .failed, exitCode: 1),
        ]
        let score = ConfidenceScorer.scoreSuggestion(
            block: failedBlock,
            suggestionText: "Fix the compilation error in main.rs",
            recentCommands: history,
            hasRelevantMemory: false
        )
        XCTAssertTrue(score.reason.contains("repeated_failure"))
        XCTAssertGreaterThan(score.value, 0.7)
    }

    // MARK: - Prediction Scoring

    func testPredictionMatchingHistoryScoresHigh() {
        let history = [
            makeBlock(command: "git status", status: .succeeded),
            makeBlock(command: "git add .", status: .succeeded),
        ]
        let score = ConfidenceScorer.scorePrediction(
            prefix: "git",
            predicted: "git status",
            recentCommands: history,
            pwd: "/tmp/project",
            projectType: nil
        )
        XCTAssertGreaterThan(score.value, ConfidenceScore.ghostTextThreshold)
        XCTAssertTrue(score.reason.contains("matches_history"))
    }

    func testPredictionEchoingPrefixScoresZero() {
        let score = ConfidenceScorer.scorePrediction(
            prefix: "git",
            predicted: "git",
            recentCommands: [],
            pwd: nil,
            projectType: nil
        )
        XCTAssertEqual(score.value, 0)
    }

    func testNaturalLanguagePredictionPenalized() {
        let score = ConfidenceScorer.scorePrediction(
            prefix: "git",
            predicted: "git please push the changes to the remote repository",
            recentCommands: [],
            pwd: nil,
            projectType: nil
        )
        XCTAssertLessThan(score.value, ConfidenceScore.ghostTextThreshold)
        XCTAssertTrue(score.reason.contains("natural_language"))
    }

    func testMultiLinePredictionPenalized() {
        let score = ConfidenceScorer.scorePrediction(
            prefix: "git",
            predicted: "git add .\ngit commit -m 'fix'",
            recentCommands: [],
            pwd: nil,
            projectType: nil
        )
        XCTAssertTrue(score.reason.contains("multi_line"))
    }

    func testRepeatingFailedCommandPenalized() {
        let history = [
            makeBlock(command: "npm run build", status: .failed, exitCode: 1),
        ]
        let score = ConfidenceScorer.scorePrediction(
            prefix: "npm",
            predicted: "npm run build",
            recentCommands: history,
            pwd: nil,
            projectType: "Node.js"
        )
        XCTAssertTrue(score.reason.contains("repeats_failure"))
    }

    func testProjectFitBoostsPrediction() {
        let score = ConfidenceScorer.scorePrediction(
            prefix: "cargo",
            predicted: "cargo test --release",
            recentCommands: [],
            pwd: "/tmp/myproject",
            projectType: "Rust (Cargo)"
        )
        XCTAssertTrue(score.reason.contains("fits_project"))
    }

    // MARK: - Natural Language Detection

    func testNaturalLanguageDetection() {
        XCTAssertTrue(ConfidenceScorer.looksLikeNaturalLanguage("please run the tests"))
        XCTAssertTrue(ConfidenceScorer.looksLikeNaturalLanguage("I think you should try this"))
        XCTAssertTrue(ConfidenceScorer.looksLikeNaturalLanguage("NOTE: this is important"))
        XCTAssertFalse(ConfidenceScorer.looksLikeNaturalLanguage("git push origin main"))
        XCTAssertFalse(ConfidenceScorer.looksLikeNaturalLanguage("npm run build"))
    }

    // MARK: - Known Command Detection

    func testKnownCommandDetection() {
        XCTAssertTrue(ConfidenceScorer.startsWithKnownCommand("git status"))
        XCTAssertTrue(ConfidenceScorer.startsWithKnownCommand("npm install"))
        XCTAssertTrue(ConfidenceScorer.startsWithKnownCommand("./build.sh"))
        XCTAssertTrue(ConfidenceScorer.startsWithKnownCommand("/usr/bin/env python3"))
        XCTAssertFalse(ConfidenceScorer.startsWithKnownCommand("foobarqux --flag"))
    }
}
