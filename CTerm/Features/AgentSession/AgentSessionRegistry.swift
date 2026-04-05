// AgentSessionRegistry.swift
// CTerm
//
// In-memory store of all active and recently-completed agent sessions.
// Indexed by session id and by tabID for per-tab lookups. Completed sessions
// are retained briefly in history (cap 20) so observers can query them.

import Foundation
import Observation

@Observable
@MainActor
final class AgentSessionRegistry {

    static let shared = AgentSessionRegistry()

    /// Live sessions keyed by id. Includes terminal sessions until they're archived.
    private(set) var sessionsByID: [UUID: AgentSession] = [:]

    /// Completed session history, most recent first. Capped at 20.
    private(set) var history: [AgentSession] = []

    private let historyCap = 20

    private init() {}

    // MARK: - Registration

    func register(_ session: AgentSession) {
        sessionsByID[session.id] = session
    }

    func archive(_ session: AgentSession) {
        sessionsByID.removeValue(forKey: session.id)
        history.insert(session, at: 0)
        if history.count > historyCap {
            history.removeLast(history.count - historyCap)
        }
    }

    // MARK: - Queries

    func session(id: UUID) -> AgentSession? {
        sessionsByID[id] ?? history.first(where: { $0.id == id })
    }

    var active: [AgentSession] {
        sessionsByID.values.filter { !$0.phase.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
    }

    var all: [AgentSession] {
        Array(sessionsByID.values).sorted { $0.startedAt > $1.startedAt }
    }

    func sessions(forTab tabID: UUID) -> [AgentSession] {
        sessionsByID.values.filter { $0.tabID == tabID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Most recently-started non-terminal session attached to the tab.
    /// Drives the run panel selection for the active tab.
    func activeSession(forTab tabID: UUID) -> AgentSession? {
        sessions(forTab: tabID).first { !$0.phase.isTerminal }
    }

    // MARK: - Test / reset hook

    #if DEBUG
    func _resetForTesting() {
        sessionsByID.removeAll()
        history.removeAll()
    }
    #endif
}
