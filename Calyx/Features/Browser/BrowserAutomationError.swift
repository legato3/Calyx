//
//  BrowserAutomationError.swift
//  Calyx
//

import Foundation

enum BrowserAutomationError: Error, LocalizedError {
    case scriptingDisabled
    case tabNotFound(UUID)
    case noActiveBrowserTab
    case evaluationFailed(String)
    case invalidResponse
    case restrictedPage(String)
    case screenshotFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .scriptingDisabled:
            return "Browser scripting is disabled"
        case .tabNotFound(let id):
            return "Browser tab not found: \(id.uuidString)"
        case .noActiveBrowserTab:
            return "No active browser tab"
        case .evaluationFailed(let message):
            return "JavaScript evaluation failed: \(message)"
        case .invalidResponse:
            return "Invalid response from browser"
        case .restrictedPage(let url):
            return "Cannot automate restricted page: \(url)"
        case .screenshotFailed:
            return "Failed to capture browser screenshot"
        case .timeout:
            return "Browser automation timed out"
        }
    }
}
