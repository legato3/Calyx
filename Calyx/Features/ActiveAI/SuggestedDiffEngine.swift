// SuggestedDiffEngine.swift
// Calyx
//
// Warp-style "Suggested Code Diffs" — when a command fails with a compiler/build
// error, automatically generates a fix diff and surfaces it inline.
// The diff is shown as a proposed patch the user can accept or dismiss.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.terminal", category: "SuggestedDiff")

// MARK: - Model

struct SuggestedDiff: Identifiable, Sendable {
    let id: UUID
    let blockID: UUID
    let errorSnippet: String
    let filePath: String?
    let patchText: String       // unified diff format
    let explanation: String
    let generatedAt: Date

    init(blockID: UUID, errorSnippet: String, filePath: String?, patchText: String, explanation: String) {
        self.id = UUID()
        self.blockID = blockID
        self.errorSnippet = errorSnippet
        self.filePath = filePath
        self.patchText = patchText
        self.explanation = explanation
        self.generatedAt = Date()
    }

    /// True if the patch looks like a real unified diff.
    var isValidPatch: Bool {
        patchText.contains("@@") && (patchText.contains("---") || patchText.contains("+++"))
    }
}

enum SuggestedDiffStatus: Sendable {
    case idle
    case generating
    case ready(SuggestedDiff)
    case dismissed
    case applied
    case failed(String)
}

// MARK: - Engine

@Observable
@MainActor
final class SuggestedDiffEngine {

    private(set) var status: SuggestedDiffStatus = .idle
    private var generationTask: Task<Void, Never>?

    // Error patterns that warrant a diff suggestion
    private static let diffTriggerPatterns: [String] = [
        "error[E",          // Rust
        "error:",           // Swift, clang, tsc
        "Error:",           // Python, Node
        "Build failed",
        "make: ***",
        "FAILED",
        "❌",
        "fatal error:",
        "SyntaxError",
        "TypeError",
        "NameError",
        "AttributeError",
        "ImportError",
    ]

    // MARK: - Public API

    var currentDiff: SuggestedDiff? {
        if case .ready(let diff) = status { return diff }
        return nil
    }

    var isGenerating: Bool {
        if case .generating = status { return true }
        return false
    }

    /// Called when a command block finishes with a failure. Decides whether to generate a diff.
    func onBlockFailed(_ block: TerminalCommandBlock, pwd: String?) {
        guard UserDefaults.standard.bool(forKey: AppStorageKeys.suggestedDiffsEnabled) else { return }
        guard block.status == .failed else { return }
        guard let snippet = block.primarySnippet, !snippet.isEmpty else { return }
        guard shouldGenerateDiff(for: snippet) else { return }

        logger.info("SuggestedDiff: triggering for block '\(block.titleText.prefix(60))'")
        generate(block: block, errorSnippet: snippet, pwd: pwd)
    }

    func dismiss() {
        generationTask?.cancel()
        status = .dismissed
    }

    func markApplied() {
        status = .applied
    }

    func reset() {
        generationTask?.cancel()
        status = .idle
    }

    // MARK: - Generation

    private func shouldGenerateDiff(for snippet: String) -> Bool {
        Self.diffTriggerPatterns.contains { snippet.range(of: $0, options: [.caseInsensitive]) != nil }
    }

    private func generate(block: TerminalCommandBlock, errorSnippet: String, pwd: String?) {
        generationTask?.cancel()
        status = .generating

        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if case .generating = self.status { self.status = .idle } }

            let context = await TerminalContextGatherer.gather(pwd: pwd)
            let filePath = extractFilePath(from: errorSnippet, pwd: pwd)

            // Read the file content if we can identify it
            var fileContent: String? = nil
            if let path = filePath, let content = try? String(contentsOfFile: path, encoding: .utf8) {
                fileContent = String(content.prefix(4000))
            }

            let prompt = buildDiffPrompt(
                command: block.titleText,
                errorSnippet: errorSnippet,
                filePath: filePath,
                fileContent: fileContent,
                context: context
            )

            do {
                let response = try await OllamaCommandService.generateCommand(for: prompt, pwd: pwd)
                guard !Task.isCancelled else { return }

                let (patch, explanation) = parseDiffResponse(response)

                if !patch.isEmpty {
                    let diff = SuggestedDiff(
                        blockID: block.id,
                        errorSnippet: errorSnippet,
                        filePath: filePath,
                        patchText: patch,
                        explanation: explanation
                    )
                    self.status = .ready(diff)
                    logger.info("SuggestedDiff: generated patch for '\(block.titleText.prefix(40))'")
                } else {
                    // No patch but we have an explanation — surface as a text suggestion
                    let diff = SuggestedDiff(
                        blockID: block.id,
                        errorSnippet: errorSnippet,
                        filePath: filePath,
                        patchText: "",
                        explanation: explanation.isEmpty ? response : explanation
                    )
                    self.status = .ready(diff)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
                logger.warning("SuggestedDiff: generation failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func extractFilePath(from snippet: String, pwd: String?) -> String? {
        // Common patterns: "src/foo.swift:12:5: error:", "./foo.py:34:", "foo.ts(12,5):"
        let patterns = [
            #"([^\s:]+\.(swift|py|ts|js|tsx|jsx|rs|go|rb|cpp|c|h|m|kt|java)):(\d+)"#,
            #"([^\s]+\.(swift|py|ts|js|tsx|jsx|rs|go|rb|cpp|c|h|m|kt|java))\((\d+)"#,
        ]
        for pattern in patterns {
            if let range = snippet.range(of: pattern, options: .regularExpression),
               let match = snippet[range].components(separatedBy: ":").first {
                let path = match.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { return path }
                if let pwd { return "\(pwd)/\(path)" }
                return path
            }
        }
        return nil
    }

    private func buildDiffPrompt(
        command: String,
        errorSnippet: String,
        filePath: String?,
        fileContent: String?,
        context: TerminalContext
    ) -> String {
        var parts: [String] = []
        parts.append("You are a code fix assistant. Generate a unified diff patch to fix the error below.")
        parts.append("")
        parts.append("Rules:")
        parts.append("- Output a valid unified diff (--- a/file, +++ b/file, @@ ... @@) if you can identify the fix.")
        parts.append("- If you cannot generate a diff, output EXPLANATION: followed by a concise fix description.")
        parts.append("- Do not include markdown fences.")
        parts.append("- Keep the patch minimal — only change what's needed.")
        parts.append("")
        parts.append("Context:")
        parts.append(context.contextBlock)
        parts.append("")
        parts.append("Failed command: \(command)")
        parts.append("")
        parts.append("Error output:")
        parts.append(String(errorSnippet.prefix(1500)))
        if let path = filePath {
            parts.append("")
            parts.append("File: \(path)")
        }
        if let content = fileContent {
            parts.append("")
            parts.append("File content:")
            parts.append(content)
        }
        return parts.joined(separator: "\n")
    }

    private func parseDiffResponse(_ response: String) -> (patch: String, explanation: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("EXPLANATION:") {
            let explanation = trimmed.dropFirst("EXPLANATION:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return ("", explanation)
        }

        // Extract diff block
        if trimmed.contains("@@") {
            // Find the start of the diff
            if let range = trimmed.range(of: "---") {
                let patch = String(trimmed[range...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (patch, "")
            }
            return (trimmed, "")
        }

        return ("", trimmed)
    }
}
