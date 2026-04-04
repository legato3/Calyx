// GitService.swift
// Calyx
//
// Executes git commands and parses output. All methods run off-main-thread.

import Foundation

/// Mutable container used to safely pass results out of concurrent DispatchQueue blocks.
/// Each instance is written by exactly one queue, making this safe despite @unchecked Sendable.
private final class DataCapture: @unchecked Sendable { var data = Data() }

enum GitService {
    enum GitError: Error, LocalizedError {
        case notARepository
        case gitNotFound
        case permissionDenied(path: String)
        case commandFailed(exitCode: Int32, stderr: String, command: String)
        case timeout(command: String)
        case diffTooLarge(path: String, size: Int)

        var errorDescription: String? {
            switch self {
            case .notARepository:
                "Not a git repository"
            case .gitNotFound:
                "git not found (checked /usr/bin, /opt/homebrew/bin, /usr/local/bin)"
            case .permissionDenied(let path):
                "Permission denied: \(path)"
            case .commandFailed(let exitCode, let stderr, let command):
                "git \(command) failed (exit \(exitCode)): \(stderr)"
            case .timeout(let command):
                "git \(command) timed out"
            case .diffTooLarge(let path, let size):
                "Diff too large for \(path) (\(size) bytes)"
            }
        }
    }

    private static let gitPath: String = {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/git"
    }()
    private static let maxDiffSize = 1_000_000

    // MARK: - Public API

    static func repoRoot(workDir: String) async throws -> String {
        let output = try await run(args: ["rev-parse", "--show-toplevel"], workDir: workDir)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isGitRepository(workDir: String) async -> Bool {
        do {
            _ = try await repoRoot(workDir: workDir)
            return true
        } catch {
            return false
        }
    }

    static func gitStatus(workDir: String) async throws -> [GitFileEntry] {
        let output = try await run(args: ["status", "--porcelain=v2", "-z"], workDir: workDir)
        return parseStatus(output)
    }

    /// Returns true if the working tree has any uncommitted changes (staged or unstaged).
    static func isRepoDirty(workDir: String) async -> Bool {
        let output = (try? await run(args: ["status", "--porcelain"], workDir: workDir)) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stages all changes in the working tree (`git add -A`).
    static func stageAll(workDir: String) async throws {
        _ = try await run(args: ["add", "-A"], workDir: workDir)
    }

    /// Creates a commit with the given message. Returns the new commit hash.
    static func commit(message: String, workDir: String) async throws -> String {
        let output = try await run(args: ["commit", "-m", message], workDir: workDir)
        // Parse the short hash from the first line, e.g. "[main abcd123] message"
        if let match = output.firstMatch(of: #/\[[\w/]+ ([0-9a-f]+)\]/#) {
            return String(match.output.1)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resets the working tree to the given commit hash (`git reset --hard`).
    static func resetHard(to hash: String, workDir: String) async throws {
        _ = try await run(args: ["reset", "--hard", hash], workDir: workDir)
    }

    static func commitLog(workDir: String, maxCount: Int, skip: Int) async throws -> [GitCommit] {
        let format = "%x1f%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%P%x1e"
        let output = try await run(
            args: ["log", "--all", "--graph", "--format=\(format)",
                   "--max-count=\(maxCount)", "--skip=\(skip)"],
            workDir: workDir
        )
        return parseCommitLog(output)
    }

    static func commitFiles(hash: String, workDir: String) async throws -> [CommitFileEntry] {
        guard isValidRef(hash) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "Invalid commit hash", command: "diff-tree")
        }

        // Check if root commit (no parents)
        let parentCheck = try? await run(args: ["rev-parse", "\(hash)^"], workDir: workDir)
        let isRoot = parentCheck == nil

        var args: [String]
        if isRoot {
            args = ["diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-z", hash]
        } else {
            args = ["diff-tree", "--no-commit-id", "-r", "--name-status", "-z", hash]
        }

        let output = try await run(args: args, workDir: workDir)
        return parseCommitFiles(output, commitHash: hash)
    }

    static func fileDiff(source: DiffSource) async throws -> String {
        let args: [String]
        let workDir: String

        switch source {
        case .unstaged(let path, let wd):
            args = ["diff", "--", path]
            workDir = wd
        case .staged(let path, let wd):
            args = ["diff", "--cached", "--", path]
            workDir = wd
        case .commit(let hash, let path, let wd):
            guard isValidRef(hash) else {
                throw GitError.commandFailed(exitCode: -1, stderr: "Invalid commit hash", command: "show")
            }
            args = ["show", "--format=", "--patch", hash, "--", path]
            workDir = wd
        case .untracked(let path, let wd):
            return try await untrackedFileDiff(path: path, workDir: wd)
        case .allChanges(let wd):
            args = ["diff", "HEAD"]
            workDir = wd
        }

        let output = try await run(args: args, workDir: workDir)

        if output.utf8.count > maxDiffSize {
            let index = output.utf8.index(output.utf8.startIndex, offsetBy: maxDiffSize)
            return String(output[..<index])
        }

        return output
    }

    /// Synthesize a unified diff for an untracked file by reading its content.
    private static func untrackedFileDiff(path: String, workDir: String) async throws -> String {
        let fullPath = (workDir as NSString).appendingPathComponent(path)
        let url = URL(fileURLWithPath: fullPath)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GitError.commandFailed(exitCode: -1, stderr: "Cannot read file: \(path)", command: "diff")
        }

        // Binary check: look for null bytes in first 8KB
        let checkSize = min(data.count, 8192)
        if data.prefix(checkSize).contains(0) {
            return "Binary files /dev/null and b/\(path) differ\n"
        }

        guard var content = String(data: data, encoding: .utf8) else {
            return "Binary files /dev/null and b/\(path) differ\n"
        }

        if content.utf8.count > maxDiffSize {
            let idx = content.utf8.index(content.utf8.startIndex, offsetBy: maxDiffSize)
            content = String(content[..<idx])
        }

        let lines = content.components(separatedBy: "\n")
        // Remove trailing empty element from split if file ends with newline
        let effectiveLines = lines.last == "" ? Array(lines.dropLast()) : lines
        let lineCount = effectiveLines.count

        var result = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        result += "@@ -0,0 +1,\(lineCount) @@\n"
        for line in effectiveLines {
            result += "+\(line)\n"
        }
        return result
    }

    // MARK: - Process Execution

    private static func run(args: [String], workDir: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw GitError.gitNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                process.environment = [
                    "LC_ALL": "C",
                    "GIT_PAGER": "cat",
                    "GIT_TERMINAL_PROMPT": "0",
                    "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin",
                    "HOME": NSHomeDirectory(),
                ]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var didTimeout = false
                let timeoutItem = DispatchWorkItem {
                    didTimeout = true
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

                // Read both pipes concurrently to avoid deadlock
                let stdoutCapture = DataCapture()
                let stderrCapture = DataCapture()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global().async {
                    stdoutCapture.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global().async {
                    stderrCapture.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                readGroup.wait()
                let stdoutData = stdoutCapture.data
                let stderrData = stderrCapture.data

                process.waitUntilExit()
                timeoutItem.cancel()

                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()

                if didTimeout {
                    let cmd = args.first ?? "unknown"
                    continuation.resume(throwing: GitError.timeout(command: cmd))
                    return
                }

                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    let cmd = args.first ?? "unknown"

                    if stderr.contains("not a git repository") {
                        continuation.resume(throwing: GitError.notARepository)
                        return
                    }
                    if stderr.contains("Permission denied") {
                        continuation.resume(throwing: GitError.permissionDenied(path: workDir))
                        return
                    }

                    continuation.resume(throwing: GitError.commandFailed(exitCode: exitCode, stderr: stderr, command: cmd))
                    return
                }

                let result = String(data: stdoutData, encoding: .utf8) ?? ""
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Parsers

    static func parseStatus(_ output: String) -> [GitFileEntry] {
        guard !output.isEmpty else { return [] }

        var entries: [GitFileEntry] = []
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0

        while i < parts.count {
            let part = String(parts[i])
            guard !part.isEmpty else { i += 1; continue }

            let firstChar = part.first!

            if firstChar == "?" {
                let path = String(part.dropFirst(2))
                entries.append(GitFileEntry(
                    path: path, origPath: nil,
                    status: .untracked, isStaged: false, renameScore: nil
                ))
                i += 1
            } else if firstChar == "!" {
                i += 1
            } else if firstChar == "1" {
                let fields = part.split(separator: " ", maxSplits: 8)
                guard fields.count >= 9 else { i += 1; continue }
                let xy = String(fields[1])
                let path = String(fields[8])

                let xChar = xy.first ?? "."
                let yChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")

                if xChar != "." {
                    if let status = mapStatusChar(xChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: nil,
                            status: status, isStaged: true, renameScore: nil
                        ))
                    }
                }
                if yChar != "." {
                    if let status = mapStatusChar(yChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: nil,
                            status: status, isStaged: false, renameScore: nil
                        ))
                    }
                }
                i += 1
            } else if firstChar == "2" {
                let fields = part.split(separator: " ", maxSplits: 9)
                guard fields.count >= 10 else { i += 1; continue }
                let xy = String(fields[1])
                let scoreField = String(fields[8])
                let path = String(fields[9])

                let xChar = xy.first ?? "."
                let yChar = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : Character(".")

                let scoreChar = scoreField.first ?? "R"
                let score = Int(scoreField.dropFirst())

                var origPath: String? = nil
                if i + 1 < parts.count {
                    origPath = String(parts[i + 1])
                    i += 2
                } else {
                    i += 1
                }

                if xChar != "." {
                    let status: GitFileStatus = scoreChar == "C" ? .copied : .renamed
                    entries.append(GitFileEntry(
                        path: path, origPath: origPath,
                        status: status, isStaged: true, renameScore: score
                    ))
                }
                if yChar != "." {
                    if let status = mapStatusChar(yChar) {
                        entries.append(GitFileEntry(
                            path: path, origPath: origPath,
                            status: status, isStaged: false, renameScore: nil
                        ))
                    }
                }
            } else if firstChar == "u" {
                let fields = part.split(separator: " ", maxSplits: 10)
                guard fields.count >= 11 else { i += 1; continue }
                let path = String(fields[10])
                entries.append(GitFileEntry(
                    path: path, origPath: nil,
                    status: .unmerged, isStaged: false, renameScore: nil
                ))
                i += 1
            } else {
                i += 1
            }
        }

        return entries
    }

    static func parseCommitLog(_ output: String) -> [GitCommit] {
        guard !output.isEmpty else { return [] }

        var commits: [GitCommit] = []
        let lines = output.components(separatedBy: "\n")
        var accumulatedGraphPrefix = ""
        var accumulatedData = ""

        for line in lines {
            // Split at the first unit-separator (U+001F) or record-separator (U+001E)
            // rather than iterating character-by-character.
            let graphPart: String
            let dataPart: String
            if let splitIdx = line.firstIndex(where: { $0 == "\u{1F}" || $0 == "\u{1E}" }) {
                graphPart = String(line[..<splitIdx])
                dataPart  = String(line[splitIdx...])
            } else {
                graphPart = line
                dataPart  = ""
            }

            accumulatedData += dataPart
            if accumulatedGraphPrefix.isEmpty || graphPart.contains("*") {
                accumulatedGraphPrefix = graphPart
            }

            if accumulatedData.contains("\u{1E}") {
                let records = accumulatedData.components(separatedBy: "\u{1E}")
                for record in records {
                    let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let fields = trimmed.components(separatedBy: "\u{1F}")
                    // Fields: ["", hash, shortHash, message, author, relativeDate, parents]
                    // First field is empty because record starts with \x1f
                    guard fields.count >= 6 else { continue }
                    let hash = fields[1]
                    let shortHash = fields[2]
                    let message = fields[3]
                    let author = fields[4]
                    let relativeDate = fields[5]
                    let parentIDsStr = fields.count > 6 ? fields[6] : ""
                    let parentIDs = parentIDsStr.isEmpty ? [] : parentIDsStr.split(separator: " ").map(String.init)

                    commits.append(GitCommit(
                        id: hash,
                        shortHash: shortHash,
                        message: message,
                        author: author,
                        relativeDate: relativeDate,
                        parentIDs: parentIDs,
                        graphPrefix: accumulatedGraphPrefix
                    ))
                }
                accumulatedData = ""
                accumulatedGraphPrefix = ""
            }
        }

        return commits
    }

    static func parseCommitFiles(_ output: String, commitHash: String) -> [CommitFileEntry] {
        guard !output.isEmpty else { return [] }

        var entries: [CommitFileEntry] = []
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < parts.count {
            let part = parts[i]
            guard !part.isEmpty else { i += 1; continue }

            let statusChar = part.first!

            switch statusChar {
            case "M", "A", "D", "T":
                if i + 1 < parts.count {
                    let path = parts[i + 1]
                    if let status = GitFileStatus(rawValue: String(statusChar)) {
                        entries.append(CommitFileEntry(
                            commitHash: commitHash, path: path,
                            origPath: nil, status: status
                        ))
                    }
                    i += 2
                } else {
                    i += 1
                }
            case "R", "C":
                if i + 2 < parts.count {
                    let origPath = parts[i + 1]
                    let newPath = parts[i + 2]
                    let status: GitFileStatus = statusChar == "R" ? .renamed : .copied
                    entries.append(CommitFileEntry(
                        commitHash: commitHash, path: newPath,
                        origPath: origPath, status: status
                    ))
                    i += 3
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }

        return entries
    }

    private static func isValidRef(_ ref: String) -> Bool {
        let pattern = /^[0-9a-fA-F]{4,40}$/
        return ref.wholeMatch(of: pattern) != nil
    }

    private static func mapStatusChar(_ char: Character) -> GitFileStatus? {
        switch char {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        default: nil
        }
    }
}
