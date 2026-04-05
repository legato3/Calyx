// SuggestionFilterTests.swift
// CTermTests

import XCTest
@testable import CTerm

final class SuggestionFilterTests: XCTestCase {

    // MARK: - Helpers

    private func makeBlock(
        command: String,
        status: TerminalCommandStatus = .failed,
        exitCode: Int? = 1,
        errorSnippet: String? = "error: something went wrong"
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
            errorSnippet: errorSnippet,
            exitCode: exitCode,
            durationNanoseconds: nil
        )
    }

    private func makeSuggestion(
        prompt: String,
        kind: ActiveAISuggestion.Kind = .fix,
        confidence: Double = 0.6
    ) -> ActiveAISuggestion {
        ActiveAISuggestion(prompt: prompt, icon: "wrench", kind: kind, confidence: confidence)
    }

    // MARK: - Filtering

    func testLowConfidenceSuggestionsFiltered() {
        let block = makeBlock(command: "ls", status: .succeeded, exitCode: 0, errorSnippet: nil)
        let suggestions = [
            makeSuggestion(prompt: "Explain the output of: ls", kind: .explain, confidence: 0.2),
        ]
        let result = SuggestionFilter.filterAndRank(
            suggestions, block: block, recentCommands: [], hasRelevantMemory: false
        )
        XCTAssertTrue(result.isEmpty, "Low-confidence suggestions should be filtered out")
    }

    func testHighConfidenceSuggestionsKept() {
        let block = makeBlock(command: "swift build")
        let suggestions = [
            makeSuggestion(
                prompt: "Fix the missing import in AppDelegate.swift",
                kind: .fix,
                confidence: 0.7
            ),
        ]
        let result = SuggestionFilter.filterAndRank(
            suggestions, block: block, recentCommands: [], hasRelevantMemory: false
        )
        XCTAssertEqual(result.count, 1)
    }

    func testDuplicatesRemoved() {
        let block = makeBlock(command: "npm run build")
        let suggestions = [
            makeSuggestion(prompt: "Fix this error: npm run build", kind: .fix, confidence: 0.6),
            makeSuggestion(prompt: "fix this error: npm run build", kind: .fix, confidence: 0.5),
        ]
        let result = SuggestionFilter.filterAndRank(
            suggestions, block: block, recentCommands: [], hasRelevantMemory: false
        )
        // Should deduplicate — only one fix chip
        XCTAssertEqual(result.count, 1)
    }

    func testMaxChipsCapped() {
        let block = makeBlock(command: "cargo build")
        let suggestions = (0..<10).map { i in
            makeSuggestion(
                prompt: "Suggestion \(i) for cargo build error",
                kind: .custom("custom_\(i)"),
                confidence: 0.6
            )
        }
        let result = SuggestionFilter.filterAndRank(
            suggestions, block: block, recentCommands: [], hasRelevantMemory: false
        )
        XCTAssertLessThanOrEqual(result.count, SuggestionFilter.maxVisibleChips)
    }

    func testRankingPrefersHigherConfidence() {
        let block = makeBlock(command: "swift build")
        let suggestions = [
            makeSuggestion(prompt: "Explain why swift build failed", kind: .explain, confidence: 0.4),
            makeSuggestion(prompt: "Fix the missing return in main.swift:12", kind: .fix, confidence: 0.8),
            makeSuggestion(prompt: "Run swift build again with --verbose", kind: .nextStep, confidence: 0.5),
        ]
        let result = SuggestionFilter.filterAndRank(
            suggestions, block: block, recentCommands: [], hasRelevantMemory: false
        )
        // Fix should be first (highest confidence)
        XCTAssertEqual(result.first?.kind.debugDescription, "fix")
    }

    // MARK: - LLM Suggestion Validation

    func testLLMGenericSuggestionRejected() {
        let block = makeBlock(command: "npm test")
        XCTAssertFalse(SuggestionFilter.isLLMSuggestionWorthShowing(
            "Try again", block: block, existingSuggestions: []
        ))
        XCTAssertFalse(SuggestionFilter.isLLMSuggestionWorthShowing(
            "Check the logs", block: block, existingSuggestions: []
        ))
    }

    func testLLMEmptySuggestionRejected() {
        let block = makeBlock(command: "npm test")
        XCTAssertFalse(SuggestionFilter.isLLMSuggestionWorthShowing(
            "", block: block, existingSuggestions: []
        ))
        XCTAssertFalse(SuggestionFilter.isLLMSuggestionWorthShowing(
            "NOTE: something", block: block, existingSuggestions: []
        ))
    }

    func testLLMTooLongSuggestionRejected() {
        let block = makeBlock(command: "npm test")
        let longText = String(repeating: "a", count: 100)
        XCTAssertFalse(SuggestionFilter.isLLMSuggestionWorthShowing(
            longText, block: block, existingSuggestions: []
        ))
    }

    func testLLMDuplicateSuggestionRejected() {
        let block = makeBlock(command: "npm test")
        let existing = [makeSuggestion(prompt: "Fix the test failure in auth.test.ts")]
        XCTAssertFalse(SuggestionFilter.isLLMSuggestionWorthShowing(
            "Fix the test failure in auth.test.ts", block: block, existingSuggestions: existing
        ))
    }

    func testLLMSpecificSuggestionAccepted() {
        let block = makeBlock(command: "npm test")
        XCTAssertTrue(SuggestionFilter.isLLMSuggestionWorthShowing(
            "Fix the TypeError in auth.test.ts line 42", block: block, existingSuggestions: []
        ))
    }

    // MARK: - Duplicate Detection

    func testIsDuplicateDetectsNormalizedMatch() {
        let existing = [makeSuggestion(prompt: "Fix the build error")]
        let candidate = makeSuggestion(prompt: "fix the build error")
        XCTAssertTrue(SuggestionFilter.isDuplicate(candidate, existingSuggestions: existing))
    }

    func testIsDuplicateAllowsDifferentSuggestions() {
        let existing = [makeSuggestion(prompt: "Fix the build error")]
        let candidate = makeSuggestion(prompt: "Run tests after fixing the build")
        XCTAssertFalse(SuggestionFilter.isDuplicate(candidate, existingSuggestions: existing))
    }
}

// MARK: - Kind Debug Description

private extension ActiveAISuggestion.Kind {
    var debugDescription: String {
        switch self {
        case .fix: return "fix"
        case .explain: return "explain"
        case .nextStep: return "nextStep"
        case .continueAgent: return "continueAgent"
        case .custom(let label): return "custom(\(label))"
        }
    }
}
