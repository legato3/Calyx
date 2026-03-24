// IPCMeshView.swift
// Calyx
//
// Phase 8: Visual IPC Mesh — a canvas-based minimap showing connected peers
// as nodes with animated edges representing message flow.

import SwiftUI

// MARK: - Edge

private struct MeshEdge: Identifiable {
    let id: String
    let from: CGPoint
    let to: CGPoint
    let fromPeerID: UUID
    let toPeerID: UUID
    let recentActivity: Bool   // message in last 10s → animate
}

// MARK: - Node Layout

private struct MeshNode {
    let peer: Peer
    let status: AgentStatus
    let position: CGPoint
    let isHub: Bool            // true for calyx-app
    let recentMessages: Int    // messages from this peer in last 60s
}

// MARK: - IPCMeshView

struct IPCMeshView: View {
    @State private var agentState: IPCAgentState = .shared
    @State private var animationPhase: CGFloat = 0
    @State private var pulsePhase: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if !agentState.isRunning {
                offlineView
            } else if visiblePeers.isEmpty {
                emptyView
            } else {
                GeometryReader { geo in
                    ZStack {
                        meshCanvas(in: geo.size)
                        tapTargetOverlay(in: geo.size)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: meshHeight)
                .padding(.horizontal, 8)
                .padding(.top, 8)

                recentMessages
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                animationPhase = 1
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Image(systemName: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("IPC Mesh")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            if agentState.isRunning {
                Label(":\(agentState.port)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var offlineView: some View {
        VStack(spacing: 6) {
            Image(systemName: "network.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("MCP server offline")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No peers connected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Start Claude Code in a pane to appear here")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
    }

    private var recentMessages: some View {
        let recent = Array(agentState.activityLog.suffix(4).reversed())
        return VStack(alignment: .leading, spacing: 0) {
            if !recent.isEmpty {
                Divider().padding(.horizontal, 8).padding(.top, 4)
                Text("Recent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(recent, id: \.id) { msg in
                    MessageMiniRow(msg: msg, peerNameMap: peerNameMap)
                }
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private func meshCanvas(in size: CGSize) -> some View {
        let nodes = layoutNodes(in: size)
        let edges = buildEdges(nodes: nodes)

        Canvas { ctx, _ in
            // Draw edges first
            for edge in edges {
                drawEdge(ctx: ctx, edge: edge, phase: animationPhase)
            }
            // Draw nodes on top
            for node in nodes {
                drawNode(ctx: ctx, node: node, phase: pulsePhase ? 1.0 : 0.6)
            }
        }
    }

    private func drawEdge(ctx: GraphicsContext, edge: MeshEdge, phase: CGFloat) {
        let path = Path { p in
            p.move(to: edge.from)
            p.addLine(to: edge.to)
        }

        let baseOpacity: CGFloat = edge.recentActivity ? 0.6 : 0.2
        ctx.stroke(path, with: .color(.white.opacity(baseOpacity)), lineWidth: 1)

        guard edge.recentActivity else { return }

        // Animated flow dot along the edge
        let t = phase.truncatingRemainder(dividingBy: 1)
        let dotX = edge.from.x + (edge.to.x - edge.from.x) * t
        let dotY = edge.from.y + (edge.to.y - edge.from.y) * t
        let dotRect = CGRect(x: dotX - 3, y: dotY - 3, width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(Color.accentColor.opacity(0.9)))
    }

    private func drawNode(ctx: GraphicsContext, node: MeshNode, phase: Double) {
        let r: CGFloat = node.isHub ? 18 : 14
        let nodeRect = CGRect(
            x: node.position.x - r,
            y: node.position.y - r,
            width: r * 2,
            height: r * 2
        )

        // Status color
        let color = statusColor(node.status)

        // Pulse ring for active nodes
        if node.status == .active && !node.isHub {
            let pulseR = r + 6 * phase
            let pulseRect = CGRect(
                x: node.position.x - pulseR,
                y: node.position.y - pulseR,
                width: pulseR * 2,
                height: pulseR * 2
            )
            ctx.stroke(
                Path(ellipseIn: pulseRect),
                with: .color(color.opacity(0.3 * (1 - phase))),
                lineWidth: 1.5
            )
        }

        // Fill
        ctx.fill(Path(ellipseIn: nodeRect), with: .color(color.opacity(node.isHub ? 0.35 : 0.25)))

        // Stroke
        ctx.stroke(
            Path(ellipseIn: nodeRect),
            with: .color(color.opacity(node.isHub ? 0.9 : 0.7)),
            lineWidth: node.isHub ? 2 : 1.5
        )

        // Label below node
        let label = node.isHub ? "Calyx" : shortName(node.peer.name)
        var text = Text(label)
            .font(.system(size: 9, weight: node.isHub ? .bold : .medium, design: .rounded))
        ctx.draw(text.foregroundStyle(Color.white.opacity(0.8)), at: CGPoint(x: node.position.x, y: node.position.y + r + 9))

        // Role label (tiny, below name)
        if !node.isHub {
            let roleText = Text(node.peer.role)
                .font(.system(size: 7.5, design: .rounded))
            ctx.draw(roleText.foregroundStyle(Color.white.opacity(0.35)), at: CGPoint(x: node.position.x, y: node.position.y + r + 19))
        }
    }

    // MARK: - Tap Overlay

    @ViewBuilder
    private func tapTargetOverlay(in size: CGSize) -> some View {
        let nodes = layoutNodes(in: size)
        ForEach(nodes, id: \.peer.id) { node in
            let r: CGFloat = node.isHub ? 22 : 18
            Circle()
                .fill(Color.clear)
                .frame(width: r * 2, height: r * 2)
                .contentShape(Circle())
                .position(node.position)
                .onTapGesture {
                    guard !node.isHub else { return }
                    _ = TerminalControlBridge.shared.delegate?.runInPaneMatching(
                        titleContains: node.peer.name,
                        text: "",
                        pressEnter: false
                    )
                }
                .help(nodeTooltip(node))
        }
    }

    // MARK: - Layout Calculation

    private func layoutNodes(in size: CGSize) -> [MeshNode] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let hubPeerID = CalyxMCPServer.shared.appPeerID

        var nodes: [MeshNode] = []
        let nonHub = visiblePeers.filter { $0.id != hubPeerID }
        let now = Date()

        // Hub node (calyx-app)
        if hubPeerID != nil || agentState.isRunning {
            let hubPeer: Peer
            if let id = hubPeerID, let p = agentState.peers.first(where: { $0.id == id }) {
                hubPeer = p
            } else {
                // Synthesize a hub representation even if not registered as peer
                hubPeer = Peer(
                    id: hubPeerID ?? UUID(),
                    name: "calyx-app",
                    role: "review-ui",
                    lastSeen: now,
                    registeredAt: now
                )
            }
            nodes.append(MeshNode(
                peer: hubPeer,
                status: .active,
                position: center,
                isHub: true,
                recentMessages: 0
            ))
        }

        // Non-hub peers arranged in a circle
        let count = nonHub.count
        guard count > 0 else { return nodes }

        let radius: CGFloat = min(size.width, size.height) / 2 - 32
        let startAngle: CGFloat = -.pi / 2   // top

        for (i, peer) in nonHub.enumerated() {
            let angle = startAngle + (.pi * 2 / CGFloat(count)) * CGFloat(i)
            let pos = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            let recent = agentState.activityLog.filter {
                $0.from == peer.id && now.timeIntervalSince($0.timestamp) < 60
            }.count
            nodes.append(MeshNode(
                peer: peer,
                status: AgentStatus.infer(from: peer),
                position: pos,
                isHub: false,
                recentMessages: recent
            ))
        }

        return nodes
    }

    private func buildEdges(nodes: [MeshNode]) -> [MeshEdge] {
        let now = Date()
        let posMap: [UUID: CGPoint] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.peer.id, $0.position) })
        var edges: [MeshEdge] = []
        var seen: Set<String> = []

        for msg in agentState.activityLog {
            let key = [msg.from, msg.to].sorted(by: { $0.uuidString < $1.uuidString })
                .map(\.uuidString).joined(separator: "-")
            guard !seen.contains(key),
                  let fromPos = posMap[msg.from],
                  let toPos = posMap[msg.to]
            else { continue }
            seen.insert(key)
            let recent = now.timeIntervalSince(msg.timestamp) < 10
            edges.append(MeshEdge(
                id: key,
                from: fromPos,
                to: toPos,
                fromPeerID: msg.from,
                toPeerID: msg.to,
                recentActivity: recent
            ))
        }

        return edges
    }

    // MARK: - Helpers

    private var visiblePeers: [Peer] {
        agentState.peers
    }

    private var peerNameMap: [UUID: String] {
        Dictionary(uniqueKeysWithValues: agentState.peers.map { ($0.id, $0.name) })
    }

    private var meshHeight: CGFloat {
        let count = max(1, visiblePeers.count)
        return count <= 2 ? 160 : count <= 4 ? 200 : 240
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .active:       return .green
        case .idle:         return .yellow
        case .disconnected: return .gray
        }
    }

    private func shortName(_ name: String) -> String {
        // "claude-architect" → "architect", trim to 12 chars
        let stripped = name
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "codex-", with: "")
        return String(stripped.prefix(12))
    }

    private func nodeTooltip(_ node: MeshNode) -> String {
        guard !node.isHub else { return "Calyx (this app)" }
        let age = Int(Date().timeIntervalSince(node.peer.lastSeen))
        return "\(node.peer.name) · \(node.peer.role) · last seen \(age)s ago — tap to focus"
    }

}

// MARK: - MessageMiniRow

private struct MessageMiniRow: View {
    let msg: Message
    let peerNameMap: [UUID: String]

    private var fromName: String { peerNameMap[msg.from] ?? msg.from.uuidString.prefix(8).description }
    private var toName: String { peerNameMap[msg.to] ?? msg.to.uuidString.prefix(8).description }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(topicColor)
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(shortName(fromName))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                    Text(shortName(toName))
                        .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    Spacer()
                    Text(relativeTime(msg.timestamp))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(msg.content.prefix(60))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var topicColor: Color {
        switch msg.topic {
        case "review-request": return .orange
        case "status":         return .blue
        case "control":        return .purple
        default:               return .gray
        }
    }

    private func shortName(_ name: String) -> String {
        String(name
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "calyx-", with: "")
            .prefix(14))
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m"
    }
}
