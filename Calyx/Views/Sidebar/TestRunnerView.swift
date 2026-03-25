// TestRunnerView.swift
// Calyx
//
// Sidebar panel for managing test runs, viewing live results, and routing
// failures to Claude.

import SwiftUI

struct TestRunnerView: View {
    @State private var store = TestRunnerStore.shared
    @State private var expandedFailures: Set<UUID> = []
    @State private var targetPaneID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            Divider().opacity(0.4)

            if store.results.isEmpty && !store.isRunning {
                emptyState
            } else {
                resultsList
            }

            if store.isRunning || hasResults {
                bottomBar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .testRunnerFinished)) { _ in
            // Auto-expand all failures when run completes
            expandedFailures = Set(store.failures.map(\.id))
        }
    }

    private var hasResults: Bool { !store.results.isEmpty }

    // MARK: - Command Bar

    private var commandBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Label("Tests", systemImage: "testtube.2")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack(spacing: 6) {
                TextField("Test command…", text: $store.command)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                runStopButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var runStopButton: some View {
        Group {
            if store.isRunning {
                Button(action: { store.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Stop test run")
            } else {
                Button(action: {
                    if let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd {
                        store.workDir = pwd
                    }
                    store.run()
                }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(store.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run tests")
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if store.isRunning {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                Text("Running…")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else if hasResults {
            HStack(spacing: 6) {
                if store.passCount > 0 {
                    Text("\(store.passCount) passed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                }
                if store.failCount > 0 {
                    Text("\(store.failCount) failed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if hasResults {
                    progressBar
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }

                if store.failCount > 0 {
                    failuresSection
                }

                if store.passCount > 0 {
                    passesSection
                }
            }
        }
    }

    private var progressBar: some View {
        let total = store.passCount + store.failCount
        let passRatio = total > 0 ? CGFloat(store.passCount) / CGFloat(total) : 0

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.35))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.green.opacity(0.75))
                    .frame(width: geo.size.width * passRatio)
                    .animation(.easeInOut(duration: 0.3), value: passRatio)
            }
        }
        .frame(height: 6)
    }

    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Failures", icon: "xmark.circle.fill", color: .red)
            ForEach(store.failures) { result in
                TestResultRow(
                    result: result,
                    isExpanded: expandedFailures.contains(result.id)
                ) {
                    if expandedFailures.contains(result.id) {
                        expandedFailures.remove(result.id)
                    } else {
                        expandedFailures.insert(result.id)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var passesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Passed", icon: "checkmark.circle.fill", color: .green)
            ForEach(store.results.filter { $0.status == .passed }) { result in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green.opacity(0.7))
                    Text(result.name)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let dur = result.duration {
                        Text(dur)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color.opacity(0.8))
            .padding(.vertical, 4)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Button(action: routeFailuresToClaude) {
                    Label("Route failures to Claude", systemImage: "arrow.up.forward.circle")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.failCount > 0 ? Color.orange : Color.secondary)
                .disabled(store.failCount == 0)
                .help(store.failCount > 0
                      ? "Inject failure details into the nearest Claude pane"
                      : "No failures to route")
                Spacer()
                Button(action: { store.results = []; expandedFailures = [] }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear results")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "testtube.2")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No test results")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Enter a test command above and press ▶ to run.\nWorks with xcodebuild, cargo, pytest, jest, go test, and more.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Routing

    private func routeFailuresToClaude() {
        let failures = store.failures
        guard !failures.isEmpty else { return }

        let names = failures.map { "  ❌ \($0.name)" }.joined(separator: "\n")
        let message = """
        The test suite has \(failures.count) failing \(failures.count == 1 ? "test" : "tests"):

        \(names)

        Please fix the failing tests.
        """
        TerminalControlBridge.shared.routeToNearestClaudePaneOrActive(text: message)
    }
}

// MARK: - Test result row

private struct TestResultRow: View {
    let result: TestCaseResult
    let isExpanded: Bool
    var onToggle: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.8))
                Text(result.name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let dur = result.duration {
                    Text(dur)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if !result.output.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(isHovering ? 0.12 : 0.07))
            )
            .onAssumeInsideHover($isHovering)
            .onTapGesture { onToggle?() }

            if isExpanded && !result.output.isEmpty {
                Text(result.output.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(6)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 1)
    }
}
