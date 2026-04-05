// AgentSessionSnapshot.swift
// CTerm
//
// Codable projection of AgentSession for persistence across launches. Active
// sessions are snapshotted inside their owning window's snapshot. Only a
// subset of fields persist — large fields (artifacts, step outputs) are
// truncated or omitted to keep the snapshot compact.

import Foundation

struct AgentSessionSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let intent: String
    let rawPrompt: String
    let tabID: UUID?
    let kind: AgentSessionKind
    let backendRaw: String             // stores AgentBackend as a simple string
    let peerName: String?              // populated when backend is .peer
    let startedAt: Date
    let phase: AgentPhase
    let summary: String?
    let errorMessage: String?
    let pendingCommand: String?
    let pendingMessage: String?
    let inlineIteration: Int
    let inlineSteps: [InlineAgentStep]
    let triggeredBy: String?
}

extension AgentBackend {
    init(rawSerialized: String, peerName: String?) {
        switch rawSerialized {
        case "ollama":             self = .ollama
        case "claudeSubscription": self = .claudeSubscription
        case "peer":               self = .peer(name: peerName ?? "peer")
        default:                   self = .ollama
        }
    }

    var rawSerialized: String {
        switch self {
        case .ollama: return "ollama"
        case .claudeSubscription: return "claudeSubscription"
        case .peer:   return "peer"
        }
    }
}

extension AgentSession {
    func persistenceSnapshot() -> AgentSessionSnapshot {
        let peerName: String?
        if case .peer(let name) = backend { peerName = name } else { peerName = nil }
        return AgentSessionSnapshot(
            id: id,
            intent: intent,
            rawPrompt: rawPrompt,
            tabID: tabID,
            kind: kind,
            backendRaw: backend.rawSerialized,
            peerName: peerName,
            startedAt: startedAt,
            phase: phase,
            summary: summary,
            errorMessage: errorMessage,
            pendingCommand: pendingCommand,
            pendingMessage: pendingMessage,
            inlineIteration: inlineIteration,
            // Cap to prevent runaway growth — 50 steps is plenty of context
            inlineSteps: Array(inlineSteps.prefix(50)),
            triggeredBy: triggeredBy
        )
    }

    convenience init(snapshot: AgentSessionSnapshot) {
        self.init(
            id: snapshot.id,
            intent: snapshot.intent,
            rawPrompt: snapshot.rawPrompt,
            tabID: snapshot.tabID,
            kind: snapshot.kind,
            backend: AgentBackend(rawSerialized: snapshot.backendRaw, peerName: snapshot.peerName),
            triggeredBy: snapshot.triggeredBy,
            startedAt: snapshot.startedAt
        )
        self.summary = snapshot.summary
        self.errorMessage = snapshot.errorMessage
        self.pendingCommand = snapshot.pendingCommand
        self.pendingMessage = snapshot.pendingMessage
        self.inlineIteration = snapshot.inlineIteration
        self.inlineSteps = snapshot.inlineSteps
        self.transition(to: snapshot.phase)
    }
}
