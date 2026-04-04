// SidebarContentView.swift
// Calyx
//
// SwiftUI sidebar with a vertical icon rail and collapsible content panel.

import SwiftUI

struct SidebarContentView: View {
    let groups: [TabGroup]
    let activeGroupID: UUID?
    let activeTabID: UUID?
    @Binding var sidebarMode: SidebarMode?
    var gitChangesState: GitChangesState = .notLoaded
    var gitEntries: [GitFileEntry] = []
    var gitCommits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    var commitFiles: [String: [CommitFileEntry]] = [:]
    var onTabSelected: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onTabRenamed: (() -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?
    var onRollbackToCheckpoint: ((GitCommit) -> Void)?
    var onOpenDiff: ((DiffSource) -> Void)?
    var onOpenAggregateDiff: ((String) -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var agentState: IPCAgentState { IPCAgentState.shared }

    private var activeTab: Tab? {
        guard let group = groups.first(where: { $0.id == activeGroupID }),
              let tabID = group.activeTabID else { return nil }
        return group.tabs.first { $0.id == tabID }
    }

    var body: some View {
        HStack(spacing: 0) {
            iconRail

            Rectangle()
                .fill(Color.white.opacity(reduceTransparency ? 0.14 : 0.08))
                .frame(width: 1)

            if let mode = sidebarMode {
                contentPanel(for: mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(SidebarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityIdentifier(AccessibilityID.Sidebar.container)
    }

    // MARK: - Icon Rail

    private var iconRail: some View {
        ScrollView {
            VStack(spacing: 2) {
                railButton(mode: .tabs, icon: "square.on.square", help: "Tabs")
                railButton(mode: .changes, icon: "arrow.triangle.2.circlepath", help: "Changes")
                railButton(mode: .agents, icon: "person.2.fill", help: "Agents")
                    .overlay(alignment: .topTrailing) {
                        if agentState.unreadCount > 0 && sidebarMode != .agents {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                                .offset(x: -2, y: 4)
                                .allowsHitTesting(false)
                        }
                    }
                railButton(mode: .mesh, icon: "network", help: "Mesh")
                railButton(mode: .taskQueue, icon: "checklist", help: "Task Queue")
                railButton(mode: .agentPermissions, icon: "lock.shield", help: "Agent Permissions")
                railButton(mode: .usage, icon: "chart.bar.fill", help: "Usage")
                railButton(mode: .context, icon: "doc.text.fill", help: "Context")
                railButton(mode: .fileChanges, icon: "clock.arrow.circlepath", help: "File Changes")
                railButton(mode: .agentMemory, icon: "brain.head.profile", help: "Agent Memory")
                railButton(mode: .testRunner, icon: "testtube.2", help: "Test Runner")
                railButton(mode: .triggers, icon: "bolt.fill", help: "Triggers")
                railButton(mode: .auditLog, icon: "scroll", help: "Session Log")
            }
            .padding(.vertical, 10)
        }
        .frame(width: 40)
        .scrollIndicators(.never)
    }

    private func railButton(mode: SidebarMode, icon: String, help: String) -> some View {
        let isSelected = sidebarMode == mode
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                sidebarMode = isSelected ? nil : mode
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13.5))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Content Panel

    @ViewBuilder
    private func contentPanel(for mode: SidebarMode) -> some View {
        switch mode {
        case .tabs:
            flatTabsContent
        case .changes:
            GitChangesView(
                gitChangesState: gitChangesState,
                gitEntries: gitEntries,
                gitCommits: gitCommits,
                expandedCommitIDs: expandedCommitIDs,
                commitFiles: commitFiles,
                onWorkingFileSelected: onWorkingFileSelected,
                onCommitFileSelected: onCommitFileSelected,
                onRefresh: onRefreshGitStatus,
                onLoadMore: onLoadMoreCommits,
                onExpandCommit: onExpandCommit,
                onRollbackToCheckpoint: onRollbackToCheckpoint
            )
            .padding(.top, 10)
        case .agents:
            IPCAgentsView()
                .padding(.top, 4)
        case .mesh:
            IPCMeshView()
                .padding(.top, 4)
        case .taskQueue:
            TaskQueueView()
                .padding(.top, 4)
        case .agentMemory:
            AgentMemoryView()
                .padding(.top, 4)
        case .testRunner:
            TestRunnerView()
                .padding(.top, 4)
        case .triggers:
            TriggerEngineView()
                .padding(.top, 4)
        case .agentPermissions:
            AgentPermissionsView()
                .padding(.top, 4)
        case .auditLog:
            SessionAuditView()
                .padding(.top, 4)
        case .usage:
            ClaudeUsageView()
                .padding(.top, 4)
        case .fileChanges:
            FileChangesView(
                onOpenDiff: onOpenDiff,
                onOpenAggregateDiff: onOpenAggregateDiff
            )
            .padding(.top, 4)
        case .context:
            ContextView(pwd: activeTab?.pwd)
                .padding(.top, 4)
        }
    }

    // MARK: - Flat Tabs

    private var flatTabsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    ForEach(group.tabs) { tab in
                        TabRowItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID && group.id == activeGroupID,
                            onSelected: { onTabSelected?(tab.id) },
                            onClose: { onCloseTab?(tab.id) },
                            onTabRenamed: onTabRenamed
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .padding(.top, 8)
    }
}

// MARK: - Background Modifier

private struct SidebarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool
    @AppStorage(AppStorageKeys.terminalGlassOpacity) private var glassOpacity = 0.7
    @AppStorage(AppStorageKeys.themeColorPreset) private var themePreset = "original"
    @AppStorage(AppStorageKeys.themeColorCustomHex) private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    private var chromeScheme: ColorScheme {
        let tint = GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        return ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea(.all, edges: .top))
        } else {
            content
                .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(GlassTheme.specularStroke.opacity(0.70))
                        .frame(width: 1)
                }
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 32)
                    .allowsHitTesting(false)
                }
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}

// MARK: - Tab Row Item

private struct TabRowItemView: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isEditing = false
    @State private var isHovering = false
    @State private var claudePulse = false

    private var tabIcon: String {
        switch tab.content {
        case .terminal: "terminal"
        case .browser: "globe"
        case .diff: "doc.text"
        }
    }

    private var visibleTitle: String {
        tab.titleOverride ?? tab.title
    }

    var body: some View {
        let displayText = visibleTitle.isEmpty ? fallbackTitle : visibleTitle

        HStack(spacing: 4) {
            Image(systemName: tabIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isEditing {
                InlineTextField(
                    initialText: displayText,
                    accessibilityID: AccessibilityID.Sidebar.tabNameTextField(tab.id),
                    fontSize: 12.5,
                    fontWeight: isActive ? .semibold : .medium,
                    onCommit: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        tab.titleOverride = trimmed.isEmpty ? nil : trimmed
                        isEditing = false
                        onTabRenamed?()
                    },
                    onCancel: {
                        isEditing = false
                    }
                )
            } else {
                if visibleTitle.lowercased().contains("claude") {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .opacity(claudePulse ? 1.0 : 0.3)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                                claudePulse = true
                            }
                        }
                        .onDisappear { claudePulse = false }
                        .help("Claude Code is running in this tab")
                }
                if tab.autoAcceptEnabled {
                    Text("⚡")
                        .font(.system(size: 9))
                        .help("Auto-accept active")
                }
                Text(displayText)
                    .lineLimit(1)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .medium, design: .rounded))
            }
            Spacer()
            if tab.unreadNotifications > 0 {
                Text(tab.unreadNotifications > 99 ? "99+" : "\(tab.unreadNotifications)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Color.red))
            }
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .opacity(isHovering || isActive ? 1 : 0)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .closeButtonHoverHighlight(size: 16, isVisible: (isHovering || isActive) && !isEditing)
            .allowsHitTesting((isHovering || isActive) && !isEditing)
            .accessibilityIdentifier(AccessibilityID.Sidebar.tabCloseButton(tab.id))
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(TabChromeModifier(
            isActive: isActive,
            cornerRadius: 12,
            reduceTransparency: reduceTransparency
        ))
        .onTapGesture { if !isEditing { onSelected?() } }
        .highPriorityGesture(TapGesture(count: 2).onEnded { if !isEditing { isEditing = true } })
        .onAssumeInsideHover($isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Sidebar.tab(tab.id))
    }

    private var fallbackTitle: String {
        if case .browser(let url) = tab.content {
            return url.host() ?? url.absoluteString
        }
        return "Terminal"
    }
}

extension TabContent {
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    var isDiff: Bool {
        if case .diff = self { return true }
        return false
    }
}
