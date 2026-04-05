import Foundation

struct ClaudeCLIHealth: Sendable {
    let configuredPath: String?
    let resolvedPath: String?
    let version: String?
    let loggedIn: Bool?
    let authMethod: String?
    let apiProvider: String?
    let errorDescription: String?

    var isInstalled: Bool { resolvedPath != nil }

    var summaryText: String {
        if let errorDescription {
            return errorDescription
        }

        guard let resolvedPath else {
            return "Status: Not found\nPath: Set a Claude CLI path override or install the CLI."
        }

        var lines: [String] = []
        lines.append("Status: \(loggedIn == true ? "Logged in" : "Logged out")")
        if let version, !version.isEmpty {
            lines.append("Version: \(version)")
        }
        if let authMethod, !authMethod.isEmpty {
            let provider = (apiProvider?.isEmpty == false) ? apiProvider! : "unknown"
            lines.append("Auth: \(authMethod) via \(provider)")
        }
        lines.append("Resolved path: \(resolvedPath)")
        if let configuredPath, !configuredPath.isEmpty {
            lines.append("Override: \(configuredPath)")
        }
        return lines.joined(separator: "\n")
    }
}

enum ClaudeCLIServiceError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case invalidResponse(String)
    case noActiveTerminalWindow

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Claude CLI was not found. Set a path override in Settings or install the CLI."
        case .launchFailed(let message):
            return message
        case .timedOut:
            return "Claude CLI timed out before returning a result."
        case .invalidResponse(let message):
            return message
        case .noActiveTerminalWindow:
            return "No active CTerm window is available to open a Claude login tab."
        }
    }
}

private struct ClaudeCLIAuthStatus: Decodable {
    let loggedIn: Bool
    let authMethod: String
    let apiProvider: String
}

private struct ClaudeCLIProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

enum ClaudeCLIService {
    private static let defaultTimeout: TimeInterval = 45

    static func configuredPathOverride() -> String? {
        let trimmed = UserDefaults.standard.string(forKey: AppStorageKeys.claudeCLIPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    static func resolveExecutableURL(pathOverride: String? = nil) -> URL? {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let override = (pathOverride ?? configuredPathOverride())?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let override, !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override)
                ? URL(fileURLWithPath: override)
                : nil
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var candidates = envPath
            .split(separator: ":")
            .map { String($0) + "/claude" }

        candidates.append(contentsOf: [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/bin/claude",
        ])

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func healthCheck(pathOverride: String? = nil) async -> ClaudeCLIHealth {
        let configuredPath = (pathOverride ?? configuredPathOverride())?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let executableURL = resolveExecutableURL(pathOverride: configuredPath) else {
            return ClaudeCLIHealth(
                configuredPath: configuredPath,
                resolvedPath: nil,
                version: nil,
                loggedIn: nil,
                authMethod: nil,
                apiProvider: nil,
                errorDescription: "Status: Not found\nPath: CTerm could not locate the `claude` CLI."
            )
        }

        do {
            async let versionResult = runProcess(
                executableURL: executableURL,
                arguments: ["--version"],
                cwd: nil,
                timeout: 10
            )
            async let authResult = runProcess(
                executableURL: executableURL,
                arguments: ["auth", "status"],
                cwd: nil,
                timeout: 10
            )

            let (versionProcess, authProcess) = try await (versionResult, authResult)
            let version = versionProcess.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty

            var loggedIn: Bool?
            var authMethod: String?
            var apiProvider: String?
            var errorDescription: String?

            if let data = authProcess.stdout.data(using: .utf8),
               let status = try? JSONDecoder().decode(ClaudeCLIAuthStatus.self, from: data) {
                loggedIn = status.loggedIn
                authMethod = status.authMethod
                apiProvider = status.apiProvider
            } else if !authProcess.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorDescription = "Status: Unknown\nAuth check failed: \(authProcess.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }

            return ClaudeCLIHealth(
                configuredPath: configuredPath,
                resolvedPath: executableURL.path,
                version: version,
                loggedIn: loggedIn,
                authMethod: authMethod,
                apiProvider: apiProvider,
                errorDescription: errorDescription
            )
        } catch {
            return ClaudeCLIHealth(
                configuredPath: configuredPath,
                resolvedPath: executableURL.path,
                version: nil,
                loggedIn: nil,
                authMethod: nil,
                apiProvider: nil,
                errorDescription: "Status: Error\n\(error.localizedDescription)"
            )
        }
    }

    static func runPrintPrompt(
        _ prompt: String,
        cwd: String?,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        guard let executableURL = resolveExecutableURL() else {
            throw ClaudeCLIServiceError.executableNotFound
        }

        let result = try await runProcess(
            executableURL: executableURL,
            arguments: [
                "-p",
                "--output-format", "text",
                "--permission-mode", "dontAsk",
                prompt
            ],
            cwd: cwd,
            timeout: timeout
        )

        if result.terminationStatus != 0 {
            let statusText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

            if statusText.contains("\"loggedIn\": false") || errorText.localizedCaseInsensitiveContains("Not logged in") {
                throw ClaudeCLIServiceError.launchFailed(
                    "Claude Subscription is not logged in for the CLI. Use Settings > Claude CLI > Start Login."
                )
            }

            let message = errorText.nilIfEmpty ?? statusText.nilIfEmpty ?? "Claude CLI exited with status \(result.terminationStatus)."
            throw ClaudeCLIServiceError.launchFailed("Claude Subscription agent failed: \(message)")
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw ClaudeCLIServiceError.invalidResponse("Claude CLI returned an empty response.")
        }
        return output
    }

    @MainActor
    static func startLoginInCTerm() throws {
        guard let executableURL = resolveExecutableURL() else {
            throw ClaudeCLIServiceError.executableNotFound
        }
        guard let delegate = TerminalControlBridge.shared.delegate else {
            throw ClaudeCLIServiceError.noActiveTerminalWindow
        }

        let command = shellQuote(executableURL.path) + " auth login --claudeai"
        delegate.createTab(
            pwd: delegate.activeTabPwd ?? NSHomeDirectory(),
            title: "Claude Login",
            command: command
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        cwd: String?,
        timeout: TimeInterval
    ) async throws -> ClaudeCLIProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                if let cwd, !cwd.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }
                process.environment = ProcessInfo.processInfo.environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                // Drain pipes concurrently as data arrives. If we only read after
                // waitUntilExit(), a child that writes more than the pipe buffer
                // (~64KB) blocks on write and never exits — a classic deadlock.
                let stdoutLock = NSLock()
                let stderrLock = NSLock()
                nonisolated(unsafe) var stdoutBuffer = Data()
                nonisolated(unsafe) var stderrBuffer = Data()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    stdoutLock.lock()
                    stdoutBuffer.append(chunk)
                    stdoutLock.unlock()
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    stderrLock.lock()
                    stderrBuffer.append(chunk)
                    stderrLock.unlock()
                }

                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ClaudeCLIServiceError.launchFailed("Failed to launch Claude CLI: \(error.localizedDescription)"))
                    return
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()

                // Drain any data that arrived between the final readabilityHandler
                // callback and exit, then detach the handlers.
                let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutLock.lock()
                stdoutBuffer.append(remainingStdout)
                let stdoutData = stdoutBuffer
                stdoutLock.unlock()
                stderrLock.lock()
                stderrBuffer.append(remainingStderr)
                let stderrData = stderrBuffer
                stderrLock.unlock()

                let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ClaudeCLIServiceError.timedOut)
                    return
                }

                continuation.resume(returning: ClaudeCLIProcessResult(
                    terminationStatus: process.terminationStatus,
                    stdout: stdoutText,
                    stderr: stderrText
                ))
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
