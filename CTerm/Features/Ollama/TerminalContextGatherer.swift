// TerminalContextGatherer.swift
// CTerm
//
// Gathers rich shell context (git branch/status, project type, active env)
// to embed in AI prompts for smarter, context-aware suggestions.

import Foundation

struct TerminalContext: Sendable {
    let pwd: String?
    let shell: String
    let gitBranch: String?
    let gitStatusLines: String?
    let projectType: String?
    let activeEnv: String?
    /// CTerm-specific environment: pane identity, active capabilities.
    /// Nil when gathered outside a CTerm window context.
    let ctermEnvironment: CTermEnvironmentContext?

    /// Compact one-liner for embedding in prompts.
    var contextBlock: String {
        var lines: [String] = []
        lines.append("- Shell: \(shell)")
        if let pwd { lines.append("- Working directory: \(pwd)") }
        if let branch = gitBranch { lines.append("- Git branch: \(branch)") }
        if let status = gitStatusLines {
            lines.append("- Git status (short):\n  \(status.replacingOccurrences(of: "\n", with: "\n  "))")
        }
        if let proj = projectType { lines.append("- Project type: \(proj)") }
        if let env = activeEnv { lines.append("- Active environment: \(env)") }
        if let cterm = ctermEnvironment { lines.append(cterm.contextBlock) }
        return lines.joined(separator: "\n")
    }
}

/// Lightweight snapshot of the CTerm environment injected into every AI prompt.
/// Tells inline agents where they are and what they can do — without requiring
/// them to call register_peer or any MCP tool first.
struct CTermEnvironmentContext: Sendable {
    let tabID: String?
    let tabTitle: String?
    let paneID: String?
    let splitPaneCount: Int
    let activePeerCount: Int
    let browserAvailable: Bool
    let mcpPort: Int?

    var contextBlock: String {
        var parts: [String] = []

        if let title = tabTitle {
            var paneDesc = "- CTerm tab: \"\(title)\""
            if splitPaneCount > 1 { paneDesc += " (\(splitPaneCount) split panes)" }
            parts.append(paneDesc)
        }

        if activePeerCount > 0 {
            parts.append("- Active AI peers in this window: \(activePeerCount) (use MCP IPC tools to coordinate)")
        }

        var caps: [String] = []
        if browserAvailable { caps.append("browser automation") }
        if mcpPort != nil { caps.append("MCP IPC on port \(mcpPort!)") }
        if !caps.isEmpty {
            parts.append("- CTerm capabilities: \(caps.joined(separator: ", "))")
        }

        return parts.joined(separator: "\n")
    }
}

enum TerminalContextGatherer {
    private static let gitTimeout: TimeInterval = 2.0

    static func gather(pwd: String?) async -> TerminalContext {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        async let gitBranch = fetchGitBranch(pwd: pwd)
        async let gitStatus = fetchGitStatusLines(pwd: pwd)

        let projectType = pwd.flatMap { detectProjectType(at: $0) }
        let activeEnv = buildEnvSummary()
        let ctermEnv = await MainActor.run { buildCTermEnvironment(pwd: pwd) }

        return TerminalContext(
            pwd: pwd,
            shell: shell,
            gitBranch: await gitBranch,
            gitStatusLines: await gitStatus,
            projectType: projectType,
            activeEnv: activeEnv,
            ctermEnvironment: ctermEnv
        )
    }

    // MARK: - CTerm Environment

    /// Builds a lightweight CTerm environment snapshot on the main actor.
    /// Must be called from MainActor — reads @Observable singletons mutated on main.
    @MainActor
    private static func buildCTermEnvironment(pwd: String?) -> CTermEnvironmentContext? {
        let server = CTermMCPServer.shared
        let browser = BrowserServer.shared
        let ipcState = IPCAgentState.shared

        // Find the tab matching this pwd for pane identity
        let delegate = TerminalControlBridge.shared.delegate
        let session = delegate?.terminalWindowSession
        let matchingTab = session?.groups.flatMap(\.tabs)
            .first(where: { $0.pwd == pwd })

        return CTermEnvironmentContext(
            tabID: matchingTab?.id.uuidString,
            tabTitle: matchingTab?.title,
            paneID: matchingTab.flatMap { $0.splitTree.focusedLeafID?.uuidString },
            splitPaneCount: matchingTab?.splitTree.allLeafIDs().count ?? 1,
            activePeerCount: ipcState.activePeerCount,
            browserAvailable: browser.isRunning,
            mcpPort: server.isRunning ? server.port : nil
        )
    }

    // MARK: - Git

    private static func fetchGitBranch(pwd: String?) async -> String? {
        guard let pwd else { return nil }
        return await runTool("git", args: ["branch", "--show-current"], cwd: pwd, timeout: gitTimeout)
    }

    private static func fetchGitStatusLines(pwd: String?) async -> String? {
        guard let pwd else { return nil }
        guard let output = await runTool(
            "git", args: ["status", "--short"], cwd: pwd, timeout: gitTimeout
        ) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Cap at 10 lines to keep prompt size reasonable.
        let capped = trimmed.components(separatedBy: "\n").prefix(10).joined(separator: "\n")
        return capped
    }

    // MARK: - Project Detection

    private static func detectProjectType(at path: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(path)/Package.swift") { return "Swift Package" }
        if let contents = try? fm.contentsOfDirectory(atPath: path) {
            if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                let name = proj.replacingOccurrences(of: ".xcodeproj", with: "")
                return "Xcode project (\(name))"
            }
            if let ws = contents.first(where: {
                $0.hasSuffix(".xcworkspace") && !$0.contains(".xcodeproj")
            }) {
                let name = ws.replacingOccurrences(of: ".xcworkspace", with: "")
                return "Xcode workspace (\(name))"
            }
        }
        if fm.fileExists(atPath: "\(path)/Cargo.toml") { return "Rust (Cargo)" }
        if fm.fileExists(atPath: "\(path)/go.mod") { return "Go module" }
        if fm.fileExists(atPath: "\(path)/package.json") { return "Node.js" }
        if fm.fileExists(atPath: "\(path)/pyproject.toml")
            || fm.fileExists(atPath: "\(path)/setup.py") { return "Python" }
        if fm.fileExists(atPath: "\(path)/Gemfile") { return "Ruby" }
        return nil
    }

    // MARK: - Environment

    private static func buildEnvSummary() -> String? {
        let env = ProcessInfo.processInfo.environment
        var parts: [String] = []
        if let venv = env["VIRTUAL_ENV"] {
            parts.append("venv:\((venv as NSString).lastPathComponent)")
        }
        if let conda = env["CONDA_DEFAULT_ENV"], conda != "base" {
            parts.append("conda:\(conda)")
        }
        if let nodeEnv = env["NODE_ENV"] {
            parts.append("NODE_ENV=\(nodeEnv)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Process Runner

    static func runTool(_ tool: String, args: [String], cwd: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let execURL = resolveExecutable(tool) else {
                    continuation.resume(returning: nil)
                    return
                }
                let process = Process()
                process.executableURL = execURL
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                process.environment = ProcessInfo.processInfo.environment

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutItem
                )

                process.waitUntilExit()
                timeoutItem.cancel()

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text?.isEmpty == true ? nil : text)
            }
        }
    }

    private static func resolveExecutable(_ name: String) -> URL? {
        let candidates: [String] = [
            "/usr/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
