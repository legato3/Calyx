// TaskSidebarView.swift
// CTerm
//
// Warp-style task execution panel. Shows the active task with live progress,
// queued tasks, and completed task history. Users can ask broad questions
// ("fix this build", "inspect this repo") and watch the agent plan, execute,
// pause for approval, and summarize results.

import SwiftUI

// MARK: - TaskSidebarView

struct TaskSidebarView: View {
    let coordinator: TaskExecutionCoordinator
    let pwd: String?

    @State private var selectedTab: TaskPanelTab = .active
    @State private var newTaskPrompt: String = ""
    @State private var expandedTaskID: UUID?

    enum TaskPanelTab: String, CaseIterable {
        case active = "Active"
        case queue = "Queue"
        case history = "History"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.28)
            tabPicker
            Divider().opacity(0.20)
            tabContent
            Divider().opacity(0.20)
            inputBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.purple)
            Text("Tasks")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Spacer()

            if coordinator.pendingApprovalCount > 0 {
                Label("\(coordinator.pendingApprovalCount)", systemImage: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            }

            if !coordinator.activeTasks.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 6, height: 6)
                    Text("\(coordinator.activeTasks.count) running")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.purple)
                }
            }

            // Processing toggle
            Button(action: {
                if coordinator.isProcessing {
                    coordinator.stopProcessing()
                } else {
                    coordinator.startProcessing()
                }
            }) {
                Image(systemName: coordinator.isProcessing ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(coordinator.isProcessing ? .orange : .green)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(
                            coordinator.isProcessing
                                ? Color.orange.opacity(0.12)
                                : Color.green.opacity(0.12)
                        )
                    )
            }
            .buttonStyle(.plain)
            .help(coordinator.isProcessing ? "Pause queue" : "Start queue")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(TaskPanelTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .queue && !coordinator.queuedTasks.isEmpty {
                            Text("\(coordinator.queuedTasks.count)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.purple.opacity(0.6)))
                        }
                    }
                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(selectedTab == tab ? Color.white.opacity(0.08) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .active:
            activeTab
        case .queue:
            queueTab
        case .history:
            historyTab
        }
    }

    // MARK: - Active Tab

    private var activeTab: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let task = coordinator.activeTask {
                    TaskCard(
                        task: task,
                        isExpanded: expandedTaskID == task.id,
                        onToggleExpand: { toggleExpand(task.id) },
                        onApprove: { coordinator.approveTask(task) },
                        onPause: { coordinator.pauseTask(task) },
                        onResume: { coordinator.resumeTask(task) },
                        onCancel: { coordinator.cancelTask(task) },
                        onRetry: { coordinator.retryTask(task) },
                        onBackground: { coordinator.setExecutionMode(.background, for: task) },
                        onApproveStep: { coordinator.approveStep(task, stepID: $0) },
                        onSkipStep: { coordinator.skipStep(task, stepID: $0) }
                    )
                }

                // Background tasks
                if !coordinator.backgroundTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Background")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        ForEach(coordinator.backgroundTasks) { task in
                            TaskCompactRow(task: task, onCancel: {
                                coordinator.cancelTask(task)
                            }, onForeground: {
                                coordinator.setExecutionMode(.foreground, for: task)
                            })
                        }
                    }
                }

                if coordinator.activeTask == nil && coordinator.backgroundTasks.isEmpty {
                    emptyActiveState
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Queue Tab

    private var queueTab: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if coordinator.queuedTasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("Queue is empty")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Add tasks below or use ⌘⇧T")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(coordinator.queuedTasks) { task in
                        TaskQueueRow(task: task, onCancel: {
                            coordinator.cancelTask(task)
                        })
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - History Tab

    private var historyTab: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if coordinator.completedTasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No completed tasks")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    HStack {
                        Spacer()
                        Button("Clear") { coordinator.clearCompleted() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(coordinator.completedTasks) { task in
                        TaskHistoryRow(task: task, onRetry: {
                            coordinator.retryTask(task)
                        })
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Add a task…", text: $newTaskPrompt)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { submitTask() }

            Button(action: submitTask) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)
            .disabled(newTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyActiveState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.purple.opacity(0.6))

            Text("No active tasks")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text("Type a goal below — \"fix this build\", \"inspect this repo\", \"add a feature\" — and the agent will plan and execute it.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func submitTask() {
        let trimmed = newTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coordinator.enqueue(prompt: trimmed)
        newTaskPrompt = ""
        selectedTab = .active
        if !coordinator.isProcessing {
            coordinator.startProcessing()
        }
    }

    private func toggleExpand(_ id: UUID) {
        expandedTaskID = expandedTaskID == id ? nil : id
    }
}
