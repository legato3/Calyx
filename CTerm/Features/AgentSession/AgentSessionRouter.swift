// AgentSessionRouter.swift
// CTerm
//
// Single entry point for starting agent sessions. All spawners (compose bar,
// MCP queue_task, MCP delegate_task, AgentLoopCoordinator, trigger engine)
// construct sessions by calling AgentSessionRouter.shared.start(request:).
//
// The router:
//   1. Enriches the prompt with project context when requested
//   2. Constructs an AgentSession of the right kind
//   3. Registers it with AgentSessionRegistry
//   4. Returns the session so the caller can attach observers / drive it
//
// The router does NOT drive execution itself. Kind-specific drivers
// (InlineAgentDriver, AgentLoopCoordinator, DelegationCoordinator,
// TaskQueueStore) pick up the session and run it.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.legato3.cterm", category: "AgentSessionRouter")

struct AgentSessionRequest {
    let intent: String
    let kind: AgentSessionKind
    let backend: AgentBackend
    let tabID: UUID?
    let pwd: String?
    /// When true, the raw intent is enriched via AgentPromptContextBuilder before
    /// being stored as rawPrompt on the session.
    let enrichContext: Bool
    /// Optional pre-computed enriched prompt. When set, enrichContext is ignored.
    let preEnrichedPrompt: String?
    /// Optional name of the trigger rule that spawned this session.
    let triggeredBy: String?

    init(
        intent: String,
        kind: AgentSessionKind,
        backend: AgentBackend,
        tabID: UUID? = nil,
        pwd: String? = nil,
        enrichContext: Bool = false,
        preEnrichedPrompt: String? = nil,
        triggeredBy: String? = nil
    ) {
        self.intent = intent
        self.kind = kind
        self.backend = backend
        self.tabID = tabID
        self.pwd = pwd
        self.enrichContext = enrichContext
        self.preEnrichedPrompt = preEnrichedPrompt
        self.triggeredBy = triggeredBy
    }
}

@MainActor
final class AgentSessionRouter {

    static let shared = AgentSessionRouter()

    private let registry: AgentSessionRegistry

    private init(registry: AgentSessionRegistry = .shared) {
        self.registry = registry
    }

    // MARK: - Start

    @discardableResult
    func start(_ request: AgentSessionRequest, activeTab: Tab? = nil) -> AgentSession {
        let raw: String
        if let preEnriched = request.preEnrichedPrompt {
            raw = preEnriched
        } else if request.enrichContext {
            raw = AgentPromptContextBuilder.buildPrompt(goal: request.intent, activeTab: activeTab)
        } else {
            raw = request.intent
        }

        let session = AgentSession(
            intent: request.intent,
            rawPrompt: raw,
            tabID: request.tabID,
            kind: request.kind,
            backend: request.backend,
            triggeredBy: request.triggeredBy
        )
        registry.register(session)
        logger.info("AgentSessionRouter: started \(request.kind.rawValue) session \(session.id.uuidString.prefix(8)) — \(request.intent.prefix(60))")
        return session
    }

    // MARK: - Lifecycle helpers

    func approve(sessionID: UUID, scope: ApprovalScope) {
        guard let session = registry.session(id: sessionID) else { return }
        session.resolveApproval(decision: .approved, scope: scope)
    }

    func deny(sessionID: UUID) {
        guard let session = registry.session(id: sessionID) else { return }
        session.resolveApproval(decision: .denied, scope: .once)
    }

    func cancel(sessionID: UUID) {
        guard let session = registry.session(id: sessionID) else { return }
        session.cancel()
        registry.archive(session)
    }

    func archive(sessionID: UUID) {
        guard let session = registry.session(id: sessionID) else { return }
        registry.archive(session)
    }

    // MARK: - Queries (thin pass-through to registry)

    func session(id: UUID) -> AgentSession? {
        registry.session(id: id)
    }

    var active: [AgentSession] { registry.active }
    var history: [AgentSession] { registry.history }
}
