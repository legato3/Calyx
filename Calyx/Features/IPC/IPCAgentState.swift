// IPCAgentState.swift
// Calyx
//
// Observable singleton that continuously polls the IPC store and maintains a
// persistent message log + unread count — independent of which sidebar tab is active.

import Foundation

// MARK: - AgentStatus

/// Inferred liveness of a registered peer based on heartbeat recency.
enum AgentStatus: Sendable {
    /// Heartbeat within the last 30 seconds — agent is actively running.
    case active
    /// Heartbeat 30 seconds–5 minutes ago — agent has gone quiet.
    case idle
    /// Heartbeat more than 5 minutes ago — near TTL expiry, likely disconnected.
    case disconnected

    static func infer(from peer: Peer) -> AgentStatus {
        let age = Date().timeIntervalSince(peer.lastSeen)
        switch age {
        case ..<30:   return .active
        case ..<300:  return .idle
        default:      return .disconnected
        }
    }

    var label: String {
        switch self {
        case .active:       return "active"
        case .idle:         return "idle"
        case .disconnected: return "away"
        }
    }

    var color: String {
        switch self {
        case .active:       return "green"
        case .idle:         return "yellow"
        case .disconnected: return "gray"
        }
    }
}

@MainActor @Observable
final class IPCAgentState {
    static let shared = IPCAgentState()

    // MARK: - State (read by views)

    private(set) var peers: [Peer] = []
    private(set) var activityLog: [Message] = []
    private(set) var isRunning: Bool = false
    private(set) var port: Int = 0
    var unreadCount: Int = 0

    /// Set true while the Agents sidebar tab is visible; resets unread count automatically.
    var isAgentsTabActive: Bool = false {
        didSet { if isAgentsTabActive { unreadCount = 0 } }
    }

    /// Role names from the most recently launched workflow; used by "Rejoin Session".
    var lastWorkflow: [String]? = nil

    // MARK: - Private

    private var seenMessageIDs: Set<UUID> = []
    private var pollTask: Task<Void, Never>?
    private static let maxLogSize = 500

    private init() {}

    // MARK: - Polling Lifecycle

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() {
        let server = CalyxMCPServer.shared
        isRunning = server.isRunning
        port = server.port
        guard isRunning else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let freshPeers = await CalyxMCPServer.shared.store.listPeers()
            let allMessages = await CalyxMCPServer.shared.store.peekAllMessages()
            self.peers = freshPeers
            let newCount = self.append(allMessages)
            if !self.isAgentsTabActive && newCount > 0 {
                self.unreadCount += newCount
            }
        }
    }

    // MARK: - Log Management

    /// Appends messages not yet seen. Returns the count of newly added messages.
    @discardableResult
    func append(_ messages: [Message]) -> Int {
        let new = messages.filter { !seenMessageIDs.contains($0.id) }
        for msg in new {
            seenMessageIDs.insert(msg.id)
            activityLog.append(msg)
            if msg.topic == "review-request" {
                NotificationCenter.default.post(name: .calyxIPCReviewRequested, object: nil)
            }
        }
        if activityLog.count > Self.maxLogSize {
            let excess = activityLog.count - Self.maxLogSize
            for msg in activityLog.prefix(excess) { seenMessageIDs.remove(msg.id) }
            activityLog.removeFirst(excess)
        }
        return new.count
    }

    func markRead() {
        unreadCount = 0
    }

    func clearLog() {
        activityLog.removeAll()
        seenMessageIDs.removeAll()
        unreadCount = 0
    }
}
