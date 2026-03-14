//
//  MCPClient.swift
//  CalyxCLI
//
//  HTTP client that communicates directly with Calyx BrowserServer.
//

import Foundation

struct BrowserClient {
    let port: Int

    /// Read connection info from ~/.config/calyx/browser.json
    static func fromStateFile() throws -> BrowserClient {
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calyx/browser.json")

        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            throw CLIError.notRunning
        }

        let data = try Data(contentsOf: stateFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int else {
            throw CLIError.invalidStateFile
        }
        return BrowserClient(port: port)
    }

    /// Send a browser command and return the result.
    func call(command: String, args: [String: Any] = [:]) throws -> String {
        let requestBody: [String: Any] = [
            "command": command,
            "args": args,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        guard let bodyStr = String(data: bodyData, encoding: .utf8) else {
            throw CLIError.invalidResponse
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-s", "--connect-timeout", "5",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", bodyStr,
            "http://127.0.0.1:\(port)/browser",
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw CLIError.connectionFailed("curl exit code \(proc.terminationStatus)")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? "(binary)"
            throw CLIError.connectionFailed("Invalid response: \(raw.prefix(500))")
        }

        if let ok = json["ok"] as? Bool, ok, let result = json["result"] as? String {
            return result
        }

        if let error = json["error"] as? String {
            throw CLIError.toolError(error)
        }

        throw CLIError.invalidResponse
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notRunning
    case invalidStateFile
    case connectionFailed(String)
    case invalidResponse
    case toolError(String)

    var description: String {
        switch self {
        case .notRunning:
            return "Calyx is not running. Start Calyx first."
        case .invalidStateFile:
            return "Invalid state file at ~/.config/calyx/browser.json"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from server"
        case .toolError(let msg):
            return msg
        }
    }
}
