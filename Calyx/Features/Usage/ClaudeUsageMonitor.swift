// ClaudeUsageMonitor.swift
// Calyx
//
// Parses ~/.claude JSONL session files to surface Claude Code token usage and cost.
// Runs parsing off the main actor; publishes results as @Observable state.

import Foundation
import OSLog
import UserNotifications

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
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
    var costUSD: Double = 0

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
    var costUSD: Double = 0

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

    // MARK: - Initialization

    /// Production init — reads from the real `~/.claude`.
    private init() {
        self.homeDirectory = NSHomeDirectory()
    }

    #if DEBUG
    /// Test-only init: reads from `homeDirectory` instead of the real home.
    ///
    /// Dependency injection is viable here because `ClaudeUsageMonitor` is pure Swift
    /// (file I/O, `DispatchSource`, `UserDefaults`, notifications). The only external
    /// dependency that meaningfully varies between test and production is the root path
    /// used to derive `~/.claude`. Injecting `homeDirectory` lets each test create an
    /// isolated instance backed by a `tmp` directory, so tests cannot pollute each other
    /// or read the developer's real Claude history.
    ///
    /// Usage:
    /// ```swift
    /// let tmp = FileManager.default.temporaryDirectory.path
    /// let monitor = ClaudeUsageMonitor(homeDirectory: tmp)
    /// // Populate tmp/.claude/projects/... with fixture JSONL, then:
    /// monitor.reload()
    /// ```
    internal init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }
    #endif

    // MARK: - Home-relative paths

    /// The home directory this instance reads from.
    /// Captured at init time so tests can point at a temporary directory.
    private let homeDirectory: String

    private var claudeDir: String { homeDirectory + "/.claude" }
    private var projectsDir: String { claudeDir + "/projects" }
    private var statsCachePath: String { claudeDir + "/stats-cache.json" }

    /// Last 30 days of activity, newest first.
    private(set) var recentDays: [DayActivity] = []
    /// Per-model breakdown for the same window.
    private(set) var modelBreakdown: [ModelActivity] = []
    /// All-time totals from ~/.claude/stats-cache.json.
    private(set) var totalSessions: Int = 0
    private(set) var totalMessages: Int = 0
    private(set) var firstSessionDate: Date?
    private(set) var isLoaded = false

    /// Budget alert tracking — reset when the date changes.
    private var lastBudgetAlertDate: String = ""
    private var lastBudgetAlertLevel: Int = 0

    var today: DayActivity {
        let key = Self.isoDay(Date())
        return recentDays.first { $0.date == key } ?? DayActivity(date: key)
    }

    private var watchSource: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?

    // MARK: - Lifecycle

    func start() {
        if !isLoaded { reload() }
        if watchSource == nil { watchProjectsDir() }
    }

    func reload() {
        // Capture paths on MainActor before launching the detached task.
        let capturedProjectsDir = projectsDir
        let capturedStatsCachePath = statsCachePath
        Task.detached(priority: .utility) {
            let result = Self.computeSync(
                projectsDir: capturedProjectsDir,
                statsCachePath: capturedStatsCachePath
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recentDays = result.days
                self.modelBreakdown = result.models
                self.totalSessions = result.totalSessions
                self.totalMessages = result.totalMessages
                self.firstSessionDate = result.firstDate
                self.isLoaded = true
                self.checkBudget()
            }
        }
    }

    // MARK: - Budget Alerts

    private func checkBudget() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppStorageKeys.dailyCostBudgetEnabled) else { return }
        let budget = defaults.double(forKey: AppStorageKeys.dailyCostBudget)
        guard budget > 0 else { return }

        let todayKey = Self.isoDay(Date())
        let cost = today.costUSD

        // Reset tracking when the day rolls over
        if lastBudgetAlertDate != todayKey {
            lastBudgetAlertDate = todayKey
            lastBudgetAlertLevel = 0
        }

        let fraction = cost / budget
        let targetLevel: Int
        if fraction >= 1.0 {
            targetLevel = 2
        } else if fraction >= 0.8 {
            targetLevel = 1
        } else {
            return
        }

        guard targetLevel > lastBudgetAlertLevel else { return }
        lastBudgetAlertLevel = targetLevel

        let body: String
        if targetLevel == 2 {
            body = String(format: "Daily budget of $%.2f reached ($%.2f used).", budget, cost)
        } else {
            body = String(format: "80%% of daily budget used — $%.2f of $%.2f.", cost, budget)
        }

        let content = UNMutableNotificationContent()
        content.title = "Claude Budget"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "calyx.budget.\(todayKey).\(targetLevel)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("Budget notification failed: \(error)") }
        }
    }

    /// Watch ~/.claude/projects for new/modified JSONL files.
    private func watchProjectsDir() {
        let path = projectsDir
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload() }
            self.reloadDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchSource = src
    }

    // MARK: - Parsing (nonisolated — runs off the main actor in a detached task)


    private struct ComputeResult: Sendable {
        var days: [DayActivity]
        var models: [ModelActivity]
        var totalSessions: Int
        var totalMessages: Int
        var firstDate: Date?
    }

    /// Synchronous compute — call only from a detached task, never on the main thread.
    private nonisolated static func computeSync(
        projectsDir: String,
        statsCachePath: String
    ) -> ComputeResult {
        var dayMap: [String: DayActivity] = [:]
        var modelMap: [String: ModelActivity] = [:]
        var totalSessions = 0
        var totalMessages = 0
        var firstDate: Date?

        // Seed aggregate totals from stats-cache (fast JSON read)
        if let cache = readStatsCache(at: statsCachePath) {
            totalSessions = cache.totalSessions
            totalMessages = cache.totalMessages
            firstDate = cache.firstDate
        }

        // Scan JSONL files modified in the last 30 days for per-day/model detail
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let paths = Self.collectJSONLFiles(in: projectsDir, newerThan: cutoff)

        for path in paths {
            parseJSONL(at: path, dayMap: &dayMap, modelMap: &modelMap)
        }

        let days = dayMap.values.sorted { $0.date > $1.date }
        let models = modelMap.values.sorted { $0.costUSD > $1.costUSD }

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

    private nonisolated static func readStatsCache(at statsCachePath: String) -> CacheSummary? {
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

    private nonisolated static func collectJSONLFiles(
        in projectsDir: String,
        newerThan cutoff: Date
    ) -> [String] {
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

    private nonisolated static func parseJSONL(
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
                let cost = obj["costUSD"] as? Double ?? 0

                var day = dayMap[dateKey] ?? DayActivity(date: dateKey)
                day.inputTokens += input
                day.outputTokens += output
                day.cacheCreationTokens += cacheCreate
                day.cacheReadTokens += cacheRead
                day.messageCount += 1
                day.costUSD += cost
                dayMap[dateKey] = day

                var mod = modelMap[model] ?? ModelActivity(model: model)
                mod.inputTokens += input
                mod.outputTokens += output
                mod.cacheCreationTokens += cacheCreate
                mod.cacheReadTokens += cacheRead
                mod.messageCount += 1
                mod.costUSD += cost
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

    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    nonisolated static func isoDay(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    nonisolated static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
