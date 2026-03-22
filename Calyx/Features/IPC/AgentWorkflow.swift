// AgentWorkflow.swift
// Calyx
//
// Templates for coordinated multi-agent Claude sessions.

import Foundation

struct WorkflowLaunchParams: Sendable {
    let workflow: AgentWorkflow
    let autoStart: Bool
    let sessionName: String
    let initialTask: String
}

struct AgentRole: Identifiable, Sendable {
    let id: UUID
    var name: String
    let description: String

    init(name: String, description: String) {
        self.id = UUID()
        self.name = name
        self.description = description
    }
}

struct AgentWorkflow: Identifiable, Sendable {
    let id: UUID
    let name: String
    let icon: String
    let description: String
    let roles: [AgentRole]

    init(name: String, icon: String, description: String, roles: [AgentRole]) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.description = description
        self.roles = roles
    }

    // MARK: - Role Prompt

    /// Generates the startup context message for a given role in a session.
    /// Shared by CalyxWindowController (terminal injection) and IPCAgentsView (MCP send_message).
    static func rolePrompt(roleName: String, allRoles: [String], port: Int) -> String {
        let teammates = allRoles.filter { $0.lowercased() != roleName.lowercased() }
        let teammatesStr = teammates.isEmpty
            ? "no other agents in this session"
            : teammates.map { "\"\($0)\"" }.joined(separator: " and ")

        let roleContext: String
        switch roleName.lowercased() {
        case "orchestrator":
            roleContext = "You are the ORCHESTRATOR. Your job is to plan the work, break it into concrete tasks, and delegate to your teammates."
        case "implementer":
            roleContext = "You are the IMPLEMENTER. Your job is to write and edit code as directed by the orchestrator."
        case "reviewer":
            roleContext = "You are the REVIEWER. Your job is to review code and give structured feedback when asked."
        default:
            roleContext = "You are the \(roleName.uppercased()) agent."
        }

        return """
        \(roleContext) Your teammates are: \(teammatesStr). \
        The Calyx IPC MCP server is running on port \(port) — use the calyx-ipc MCP tools to communicate with your team. \
        Start by calling register_peer with name "\(roleName)" and role "\(roleName)", \
        then list_peers to see who is connected, and coordinate from there.
        """
    }

    static let templates: [AgentWorkflow] = [
        AgentWorkflow(
            name: "Solo",
            icon: "person",
            description: "One agent for a single focused task",
            roles: [
                AgentRole(name: "agent", description: "Single Claude agent"),
            ]
        ),
        AgentWorkflow(
            name: "Pair",
            icon: "person.2",
            description: "Orchestrator plans while implementer codes",
            roles: [
                AgentRole(name: "orchestrator", description: "Plans and delegates tasks"),
                AgentRole(name: "implementer", description: "Writes and edits code"),
            ]
        ),
        AgentWorkflow(
            name: "Team",
            icon: "person.3",
            description: "Full loop: plan, implement, and review",
            roles: [
                AgentRole(name: "orchestrator", description: "Plans and delegates tasks"),
                AgentRole(name: "implementer", description: "Writes and edits code"),
                AgentRole(name: "reviewer", description: "Reviews and gives feedback"),
            ]
        ),
    ]
}
