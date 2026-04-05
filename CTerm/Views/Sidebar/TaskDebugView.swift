// TaskDebugView.swift
// CTerm
//
// Debug inspector for task lifecycle state. Shows phase history,
// partial results, retry attempts, and agent session binding.
// Accessible via the expand chevron on any task card.

import SwiftUI

struct TaskDebugView: View {
    let task: ManagedTask

    @State private var selectedSection: DebugSection = .timeline

    enum DebugSection: String, CaseIterable {
        case timeline = "Timeline"
        case results = "Results"
        case session = "Session"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section picker
            HStack(spacing: 0) {
                ForEach(DebugSection.allCases, id: \.self) { section in
                    Button(action: { selectedSection = section }) {
                        Text(section.rawValue)
                            .font(.system(size: 10, weight: selectedSection == section ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(selectedSection == section ? .primary : .tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(selectedSection == section ? Color.white.opacity(0.06) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.03))

            Divider().opacity(0.15)

            ScrollView {
                switch selectedSection {
                case .timeline:
                    timelineSection
                case .results:
                    resultsSection
                case .session:
                    sessionSection
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: 300)
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(task.phaseHistory.enumerated()), id: \.offset) { _, transition in
                HStack(spacing: 6) {
                    Text(formatTime(transition.at))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .frame(width: 60, alignment: .trailing)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)

                    Text(transition.from.rawValue)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("→")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)

                    Text(transition.to.rawValue)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(transition.to.isTerminal ? .red : .primary)
                }
            }

            if task.phaseHistory.isEmpty {
                Text("No transitions yet")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
            }

            // Retry info
            if task.attemptCount > 0 {
                Divider().opacity(0.15).padding(.vertical, 4)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("Attempt \(task.attemptCount + 1) of \(task.retryPolicy.maxAttempts)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if let lastFail = task.lastFailureMessage {
                    Text("Last failure: \(lastFail)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(3)
                }
            }
        }
        .padding(10)
    }

    // MARK: - Results

    private var resultsSection: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if task.partialResults.isEmpty {
                Text("No results captured yet")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
            } else {
                ForEach(task.partialResults) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("Step \(result.stepIndex + 1)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            if let code = result.exitCode {
                                Text("exit \(code)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(code == 0 ? .green : .red)
                            }
                            Spacer()
                            Text(formatTime(result.timestamp))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.quaternary)
                        }
                        Text(result.output)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(10)
    }

    // MARK: - Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            debugRow("Task ID", task.id.uuidString.prefix(8))
            debugRow("Phase", task.phase.rawValue)
            debugRow("Priority", task.priority.label)
            debugRow("Mode", task.executionMode.label)
            debugRow("Model", task.model.displayName)
            debugRow("Created", formatTime(task.createdAt))
            debugRow("Updated", formatTime(task.updatedAt))
            debugRow("Elapsed", task.elapsedFormatted)
            debugRow("Steps", "\(task.planSteps.count)")
            debugRow("Succeeded", "\(task.succeededStepCount)")
            debugRow("Failed", "\(task.failedStepCount)")
            debugRow("Partial Results", "\(task.partialResults.count)")
            debugRow("Retry Attempts", "\(task.attemptCount)/\(task.retryPolicy.maxAttempts)")

            if let session = task.agentSession {
                Divider().opacity(0.15)
                Text("Agent Session")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                debugRow("Session ID", session.id.uuidString.prefix(8))
                debugRow("Agent Phase", session.phase.rawValue)
                if let intent = session.classifiedIntent {
                    debugRow("Intent", intent.rawValue)
                }
                debugRow("Artifacts", "\(session.artifacts.count)")
            }
        }
        .padding(10)
    }

    // MARK: - Helpers

    private func debugRow(_ label: String, _ value: some StringProtocol) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: date)
    }
}
