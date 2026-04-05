// AgentArtifact.swift
// CTerm
//
// Single observation/output produced during session execution. Artifacts
// accumulate on an AgentSession and feed the result summary, memory writes,
// and suggestion ranking.

import Foundation

struct AgentArtifact: Identifiable, Sendable, Codable {
    let id: UUID
    let kind: Kind
    let value: String
    let createdAt: Date

    enum Kind: String, Sendable, Codable {
        case fileChanged
        case commandOutput
        case memoryWritten
        case peerMessage
        case diffGenerated
        case browserFinding
    }

    init(kind: Kind, value: String) {
        self.id = UUID()
        self.kind = kind
        self.value = value
        self.createdAt = Date()
    }
}

// MARK: - Browser finding encoding

extension AgentArtifact {
    static let browserFindingDelimiter = "|||"

    /// Encode a browser finding into a `.browserFinding` artifact value.
    /// Format: "URL|||TITLE|||PREVIEW" (preview truncated to 500 chars).
    static func encodeBrowserFinding(url: String, title: String, content: String) -> String {
        let preview = String(content.prefix(500))
        return "\(url)\(browserFindingDelimiter)\(title)\(browserFindingDelimiter)\(preview)"
    }

    /// Decode a `.browserFinding` artifact. Returns nil if kind mismatches or format is malformed.
    func decodeBrowserFinding() -> (url: String, title: String, preview: String)? {
        guard kind == .browserFinding else { return nil }
        let parts = value.components(separatedBy: Self.browserFindingDelimiter)
        guard parts.count >= 3 else { return nil }
        let url = parts[0]
        let title = parts[1]
        let preview = parts.dropFirst(2).joined(separator: Self.browserFindingDelimiter)
        return (url, title, preview)
    }
}
