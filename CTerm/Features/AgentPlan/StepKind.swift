// StepKind.swift
// CTerm
//
// Authoritative classification of an AgentPlanStep. Set by PlanBuilder at
// construction time; read by ExecutionCoordinator to pick an execution
// strategy. No more prefix-parsing at dispatch time.

import Foundation

enum StepKind: String, Sendable, Codable {
    case shell      // dispatched to terminal as a shell command
    case browser    // browse: / browser: / open http(s) — routed through BrowserToolHandler
    case peer       // delegate: or @peer — routed through peer delegation
    case manual     // no command; informational marker or user-driven step

    /// Infer the kind from a raw command string. Used when the planner did not
    /// specify one explicitly (legacy / LLM-generated steps).
    static func infer(from command: String?) -> StepKind {
        guard let raw = command, !raw.isEmpty else { return .manual }
        let c = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return .manual }
        if c.hasPrefix("@") || c.contains("delegate:") || c.contains("send_message") { return .peer }
        if c.hasPrefix("browse:") || c.hasPrefix("browser:") { return .browser }
        if c.hasPrefix("open http://") || c.hasPrefix("open https://") { return .browser }
        return .shell
    }

    var label: String {
        switch self {
        case .shell:   return "shell"
        case .browser: return "browser"
        case .peer:    return "peer"
        case .manual:  return "manual"
        }
    }

    var icon: String {
        switch self {
        case .shell:   return "terminal"
        case .browser: return "globe"
        case .peer:    return "person.2"
        case .manual:  return "hand.point.up"
        }
    }
}
