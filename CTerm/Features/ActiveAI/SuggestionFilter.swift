// SuggestionFilter.swift
// CTerm
//
// Deduplication, low-value suppression, and ranking for Active AI suggestion chips.
// Pure logic — no LLM calls, no side effects. Fully unit-testable.

import Foundation

enum SuggestionFilter {

    /// Maximum number of chips to show at once.
    static let maxVisibleChips = 3

    /// Filter and rank suggestions. Returns at most `maxVisibleChips` items,
    /// sorted by usefulness (best first).
    static func filterAndRank(
        _ suggestions: [ActiveAISuggestion],
        block: TerminalCommandBlock,
        recentCommands: [TerminalCommandBlock],
        hasRelevantMemory: Bool
    ) -> [ActiveAISuggestion] {
        var scored: [(suggestion: ActiveAISuggestion, score: ConfidenceScore)] = []

        for suggestion in suggestions {
            let confidence = ConfidenceScorer.scoreSuggestion(
                block: block,
                suggestionText: suggestion.prompt,
                recentCommands: recentCommands,
                hasRelevantMemory: hasRelevantMemory
            )
            // Gate: drop anything below threshold
            guard confidence.isAboveChipThreshold else { continue }
            scored.append((suggestion, confidence))
        }

        // Deduplicate by normalized prompt text
        var seen = Set<String>()
        scored = scored.filter { item in
            let key = normalizeForDedup(item.suggestion.prompt)
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        // Deduplicate by kind — keep at most one of each kind (prefer higher score)
        var bestByKind: [String: (suggestion: ActiveAISuggestion, score: ConfidenceScore)] = [:]
        for item in scored {
            let kindKey = kindKey(item.suggestion.kind)
            if let existing = bestByKind[kindKey] {
                if item.score > existing.score {
                    bestByKind[kindKey] = item
                }
            } else {
                bestByKind[kindKey] = item
            }
        }

        // Sort by score descending, then take top N
        let ranked = bestByKind.values
            .sorted { $0.score > $1.score }
            .prefix(maxVisibleChips)
            .map(\.suggestion)

        return Array(ranked)
    }

    /// Check if a suggestion is a duplicate of any existing suggestion.
    static func isDuplicate(
        _ suggestion: ActiveAISuggestion,
        existingSuggestions: [ActiveAISuggestion]
    ) -> Bool {
        let normalized = normalizeForDedup(suggestion.prompt)
        return existingSuggestions.contains { normalizeForDedup($0.prompt) == normalized }
    }

    /// Check if an LLM-generated suggestion is worth showing.
    static func isLLMSuggestionWorthShowing(
        _ text: String,
        block: TerminalCommandBlock,
        existingSuggestions: [ActiveAISuggestion]
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or starts with meta-commentary
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("NOTE:") || trimmed.hasPrefix("I ") { return false }

        // Generic junk
        if ConfidenceScorer.isGenericSuggestion(trimmed) { return false }

        // Too long for a chip
        if trimmed.count > 80 { return false }

        // Duplicate of existing
        let normalized = normalizeForDedup(trimmed)
        if existingSuggestions.contains(where: { normalizeForDedup($0.prompt) == normalized }) {
            return false
        }

        // Essentially restates the command
        let commandNorm = normalizeForDedup(block.titleText)
        if normalized == commandNorm { return false }
        if normalized.hasPrefix("run ") && normalizeForDedup(String(normalized.dropFirst(4))) == commandNorm {
            return false
        }

        return true
    }

    // MARK: - Helpers

    private static func normalizeForDedup(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func kindKey(_ kind: ActiveAISuggestion.Kind) -> String {
        switch kind {
        case .fix: return "fix"
        case .explain: return "explain"
        case .nextStep: return "nextStep"
        case .continueAgent: return "continueAgent"
        case .custom(let label): return "custom_\(label)"
        }
    }
}
