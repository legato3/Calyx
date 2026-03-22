// ClaudeUsageMonitor.swift
// Calyx
//
// Parses ~/.claude JSONL session files to surface Claude Code token usage.
// Runs parsing off the main actor; publishes results as @Observable state.

import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx",
    category: "ClaudeUsage"
)

// MARK: - Models

struct DayActivity: Identifiable, Sendable {
    let date: String  // "YYYY-MM-DD"
    var id: String { date }

    var inputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var outputTokens: Int = 0
    var messageCount: Int = 0
    var toolCallCount: Int = 0

    /// Approximate "billed" tokens (excludes cache reads, which are cheaper).
    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
}

struct ModelActivity: Identifiable, Sendable {
    let model: String
    var id: String { model }

    var inputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var outputTokens: Int = 0
    var messageCount: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens }

    /// Human-readable name, e.g. "claude-sonnet-4-6" → "Sonnet 4.6"
    var shortName: String {
        var s = model
        s = s.replacingOccurrences(of: "claude-", with: "")
        // Strip date suffixes like -20251001
        if let range = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Monitor

@Observable
@MainActor
final class ClaudeUsageMonitor {

    static let shared = ClaudeUsageMonitor()

    /// Last 30 days of activity, newest first.
    private(set) var recentDays: [DayActivity] = []
    /// Per-model breakdown for the same window.
    private(set) var modelBreakdown: [ModelActivity] = []
    /// All-time totals from ~/.claude/stats-cache.json.
    private(set) var totalSessions: Int = 0
    private(set) var totalMessages: Int = 0
    private(set) var firstSessionDate: Date?
    private(set) var isLoaded = false

    var today: DayActivity {
        let key = Self.isoDay(Date())
        return recentDays.first { $0.date == key } ?? DayActivity(date: key)
    }

    private var watchSource: DispatchSourceFileSystemObject?

    // MARK: - Lifecycle

    func start() {
        reload()
        watchProjectsDir()
    }

    func reload() {
        Task.detached(priority: .utility) {
            let result = await Self.compute()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recentDays = result.days
                self.modelBreakdown = result.models
                self.totalSessions = result.totalSessions
                self.totalMessages = result.totalMessages
                self.firstSessionDate = result.firstDate
                self.isLoaded = true
            }
        }
    }

    /// Watch ~/.claude/projects for new/modified JSONL files.
    private func watchProjectsDir() {
        let path = Self.projectsDir
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchSource = src
    }

    // MARK: - Parsing (off main actor)

    private static let claudeDir = NSHomeDirectory() + "/.claude"
    private static let projectsDir = claudeDir + "/projects"
    private static let statsCachePath = claudeDir + "/stats-cache.json"

    private struct ComputeResult: Sendable {
        var days: [DayActivity]
        var models: [ModelActivity]
        var totalSessions: Int
        var totalMessages: Int
        var firstDate: Date?
    }

    private static func compute() async -> ComputeResult {
        var dayMap: [String: DayActivity] = [:]
        var modelMap: [String: ModelActivity] = [:]
        var totalSessions = 0
        var totalMessages = 0
        var firstDate: Date?

        // Seed aggregate totals from stats-cache (fast JSON read)
        if let cache = readStatsCache() {
            totalSessions = cache.totalSessions
            totalMessages = cache.totalMessages
            firstDate = cache.firstDate
        }

        // Scan JSONL files modified in the last 30 days for per-day/model detail
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let paths = collectJSONLFiles(newerThan: cutoff)

        for path in paths {
            parseJSONL(at: path, dayMap: &dayMap, modelMap: &modelMap)
        }

        let days = dayMap.values.sorted { $0.date > $1.date }
        let models = modelMap.values.sorted { $0.totalTokens > $1.totalTokens }

        return ComputeResult(
            days: days,
            models: models,
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            firstDate: firstDate
        )
    }

    // MARK: - Stats Cache

    private struct CacheSummary {
        var totalSessions: Int
        var totalMessages: Int
        var firstDate: Date?
    }

    private static func readStatsCache() -> CacheSummary? {
        guard let data = FileManager.default.contents(atPath: statsCachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var summary = CacheSummary(
            totalSessions: json["totalSessions"] as? Int ?? 0,
            totalMessages: json["totalMessages"] as? Int ?? 0
        )
        if let str = json["firstSessionDate"] as? String {
            summary.firstDate = iso8601.date(from: str)
        }
        return summary
    }

    // MARK: - File Collection

    private static func collectJSONLFiles(newerThan cutoff: Date) -> [String] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        var paths: [String] = []
        for project in projects {
            let projPath = projectsDir + "/" + project
            guard let files = try? fm.contentsOfDirectory(atPath: projPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = projPath + "/" + file
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let mtime = attrs[.modificationDate] as? Date,
                   mtime >= cutoff {
                    paths.append(fullPath)
                }
            }
        }
        return paths
    }

    // MARK: - JSONL Parsing

    private static func parseJSONL(
        at path: String,
        dayMap: inout [String: DayActivity],
        modelMap: inout [String: ModelActivity]
    ) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            let ts = (obj["timestamp"] as? String).flatMap { iso8601.date(from: $0) } ?? Date()
            let dateKey = isoDay(ts)

            switch type {
            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any]
                else { continue }

                let model = msg["model"] as? String ?? "unknown"
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

                var day = dayMap[dateKey] ?? DayActivity(date: dateKey)
                day.inputTokens += input
                day.outputTokens += output
                day.cacheCreationTokens += cacheCreate
                day.cacheReadTokens += cacheRead
                day.messageCount += 1
                dayMap[dateKey] = day

                var mod = modelMap[model] ?? ModelActivity(model: model)
                mod.inputTokens += input
                mod.outputTokens += output
                mod.cacheCreationTokens += cacheCreate
                mod.cacheReadTokens += cacheRead
                mod.messageCount += 1
                modelMap[model] = mod

            case "user":
                guard let msg = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]]
                else { continue }
                let toolCount = content.filter { ($0["type"] as? String) == "tool_result" }.count
                if toolCount > 0 {
                    var day = dayMap[dateKey] ?? DayActivity(date: dateKey)
                    day.toolCallCount += toolCount
                    dayMap[dateKey] = day
                }

            default:
                break
            }
        }
    }

    // MARK: - Helpers

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func isoDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
