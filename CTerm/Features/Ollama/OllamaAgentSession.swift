import Foundation

enum AgentPlanningBackend: String, Sendable {
    case ollama
    case claudeSubscription
}

enum OllamaAgentStatus: String, Sendable {
    case planning
    case awaitingApproval
    case runningCommand
    case completed
    case failed
    case stopped

    var label: String {
        switch self {
        case .planning: return "Planning"
        case .awaitingApproval: return "Awaiting Approval"
        case .runningCommand: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped:
            return true
        case .planning, .awaitingApproval, .runningCommand:
            return false
        }
    }
}

enum OllamaAgentStepKind: String, Sendable {
    case goal
    case plan
    case command
    case observation
    case summary
    case error

    var title: String {
        switch self {
        case .goal: return "Goal"
        case .plan: return "Plan"
        case .command: return "Command"
        case .observation: return "Observation"
        case .summary: return "Summary"
        case .error: return "Error"
        }
    }
}

struct OllamaAgentStep: Identifiable, Sendable {
    let id: UUID
    let kind: OllamaAgentStepKind
    let text: String
    let command: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: OllamaAgentStepKind,
        text: String,
        command: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.command = command
        self.createdAt = createdAt
    }
}

struct OllamaAgentSession: Identifiable, Sendable {
    let id: UUID
    let goal: String
    let backend: AgentPlanningBackend
    var status: OllamaAgentStatus
    var pendingCommand: String?
    var pendingMessage: String?
    var lastCommandBlockID: UUID?
    var iteration: Int
    var startedAt: Date
    var updatedAt: Date
    var steps: [OllamaAgentStep]

    init(goal: String, backend: AgentPlanningBackend) {
        let now = Date()
        self.id = UUID()
        self.goal = goal
        self.backend = backend
        self.status = .planning
        self.pendingCommand = nil
        self.pendingMessage = nil
        self.lastCommandBlockID = nil
        self.iteration = 0
        self.startedAt = now
        self.updatedAt = now
        self.steps = [OllamaAgentStep(kind: .goal, text: goal)]
    }

    var canApprove: Bool {
        status == .awaitingApproval && pendingCommand?.isEmpty == false
    }

    var latestPlanText: String? {
        if let pendingMessage, !pendingMessage.isEmpty {
            return pendingMessage
        }
        return steps.last(where: { $0.kind == .plan || $0.kind == .summary || $0.kind == .error })?.text
    }
}

extension Tab {
    func startOllamaAgent(goal: String, backend: AgentPlanningBackend) {
        ollamaAgentSession = OllamaAgentSession(goal: goal, backend: backend)
    }

    func updateOllamaAgentPlanPreview(_ text: String) {
        guard var session = ollamaAgentSession else { return }
        session.pendingMessage = text
        session.status = .planning
        session.updatedAt = Date()
        ollamaAgentSession = session
    }

    func setOllamaAgentAwaitingApproval(command: String, message: String) {
        guard var session = ollamaAgentSession else { return }
        session.status = .awaitingApproval
        session.pendingCommand = command
        session.pendingMessage = message
        session.updatedAt = Date()
        session.steps.insert(
            OllamaAgentStep(kind: .plan, text: message, command: command),
            at: 0
        )
        ollamaAgentSession = session
    }

    func markOllamaAgentRunning(blockID: UUID?) {
        guard var session = ollamaAgentSession else { return }
        let command = session.pendingCommand
        let message = session.pendingMessage
        session.status = .runningCommand
        session.lastCommandBlockID = blockID
        session.iteration += 1
        session.updatedAt = Date()
        session.pendingCommand = nil
        session.pendingMessage = nil
        if let command {
            session.steps.insert(
                OllamaAgentStep(kind: .command, text: message ?? command, command: command),
                at: 0
            )
        }
        ollamaAgentSession = session
    }

    func recordOllamaAgentObservation(_ text: String) {
        guard var session = ollamaAgentSession else { return }
        session.updatedAt = Date()
        session.steps.insert(OllamaAgentStep(kind: .observation, text: text), at: 0)
        ollamaAgentSession = session
    }

    func completeOllamaAgent(summary: String) {
        guard var session = ollamaAgentSession else { return }
        session.status = .completed
        session.pendingCommand = nil
        session.pendingMessage = summary
        session.updatedAt = Date()
        session.steps.insert(OllamaAgentStep(kind: .summary, text: summary), at: 0)
        ollamaAgentSession = session
    }

    func failOllamaAgent(_ message: String) {
        guard var session = ollamaAgentSession else { return }
        session.status = .failed
        session.pendingCommand = nil
        session.pendingMessage = message
        session.updatedAt = Date()
        session.steps.insert(OllamaAgentStep(kind: .error, text: message), at: 0)
        ollamaAgentSession = session
    }

    func stopOllamaAgent() {
        guard var session = ollamaAgentSession else { return }
        session.status = .stopped
        session.pendingCommand = nil
        session.pendingMessage = "Agent stopped."
        session.updatedAt = Date()
        ollamaAgentSession = session
    }
}
