// BrowserResearchProgressStrip.swift
// CTerm
//
// Live progress line rendered inside the agent run panel while a browser
// research workflow is executing. Reads the @Observable
// BrowserResearchSession that ExecutionCoordinator attaches to AgentSession.

import SwiftUI

struct BrowserResearchProgressStrip: View {
    let session: BrowserResearchSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(.teal)
            Text(hostFragment)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(stepLabel)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(session.findingsCount) finding\(session.findingsCount == 1 ? "" : "s")")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.teal)
            Spacer(minLength: 0)
            if !session.isComplete {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var hostFragment: String {
        guard let urlString = session.currentURL,
              let host = URL(string: urlString)?.host else {
            return session.currentURL ?? "—"
        }
        return host
    }

    private var stepLabel: String {
        let done = session.stepsCompleted
        let total = session.totalSteps
        return total > 0 ? "step \(done)/\(total)" : "starting"
    }
}
