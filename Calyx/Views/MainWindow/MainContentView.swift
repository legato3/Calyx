// MainContentView.swift
// Calyx
//
// SwiftUI root view composing sidebar, tab bar, and terminal content.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainContentView: View {
    @Bindable var windowSession: WindowSession
    let commandRegistry: CommandRegistry?
    let splitContainerView: SplitContainerView
    let viewState: WindowViewState

    @Binding var sidebarMode: SidebarMode?

    @Environment(WindowActions.self) private var actions
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppStorageKeys.terminalGlassOpacity) private var glassOpacity = 0.7
    @AppStorage(AppStorageKeys.themeColorPreset) private var themePreset = "original"
    @AppStorage(AppStorageKeys.themeColorCustomHex) private var customHex = "#050D1C"
    @AppStorage(AppStorageKeys.ollamaModel) private var ollamaModel = OllamaCommandService.defaultModel
    @AppStorage(AppStorageKeys.ollamaEndpoint) private var ollamaEndpoint = OllamaCommandService.defaultEndpoint
    private var secureInput: SecureInput { SecureInput.shared }
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    var body: some View {
        let activeGroup = windowSession.activeGroup
        let activeTab = activeGroup?.activeTab
        let activeTabs = activeGroup?.tabs ?? []
        let activeTabID = activeGroup?.activeTabID
        let chromeTint = Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))

        GlassEffectContainer {
            HStack(spacing: 0) {
                if windowSession.showSidebar {
                    let sidebarFrameWidth = sidebarMode == nil ? 40 : windowSession.sidebarWidth
                    SidebarContentView(
                        groups: windowSession.groups,
                        activeGroupID: windowSession.activeGroupID,
                        activeTabID: activeTabID,
                        sidebarMode: $sidebarMode,
                        gitChangesState: windowSession.git.changesState,
                        gitEntries: windowSession.git.entries,
                        gitCommits: windowSession.git.commits,
                        expandedCommitIDs: windowSession.git.expandedCommitIDs,
                        commitFiles: windowSession.git.commitFiles,
                        onTabSelected: actions.onTabSelected,
                        onCloseTab: actions.onCloseTab,
                        onTabRenamed: actions.onTabRenamed,
                        onWorkingFileSelected: actions.onWorkingFileSelected,
                        onCommitFileSelected: actions.onCommitFileSelected,
                        onRefreshGitStatus: actions.onRefreshGitStatus,
                        onLoadMoreCommits: actions.onLoadMoreCommits,
                        onExpandCommit: actions.onExpandCommit,
                        onRollbackToCheckpoint: actions.onRollbackToCheckpoint,
                        onOpenDiff: actions.onOpenDiff,
                        onOpenAggregateDiff: actions.onOpenAggregateDiff
                    )
                    .frame(width: sidebarFrameWidth)
                    .overlay(alignment: .trailing) {
                        if sidebarMode != nil {
                            SidebarResizeHandle(
                                currentWidth: windowSession.sidebarWidth,
                                onWidthChanged: { actions.onSidebarWidthChanged?($0) },
                                onDragCommitted: { actions.onSidebarDragCommitted?() }
                            )
                            .offset(x: 0)
                            .zIndex(1)
                        }
                    }

                    if reduceTransparency {
                        Divider()
                    }
                }

                ZStack {
                    VStack(spacing: 0) {
                        if !activeTabs.isEmpty {
                            TabBarContentView(
                                tabs: activeTabs,
                                activeTabID: activeTabID,
                                onTabSelected: actions.onTabSelected,
                                onNewTab: actions.onNewTab,
                                onCloseTab: actions.onCloseTab,
                                onMoveTab: activeGroup != nil
                                    ? { from, to in actions.onMoveTab?(activeGroup!.id, from, to) }
                                    : nil,
                                onRouteShellError: actions.onRouteShellError,
                                onDismissShellError: actions.onDismissShellError,
                                onTabRenamed: actions.onTabRenamed,
                                activeGroupID: activeGroup?.id
                            )
                        }

                        if let diffSource = viewState.activeDiffSource, let diffState = viewState.activeDiffState {
                            VStack(spacing: 0) {
                                DiffToolbarView(
                                    source: diffSource,
                                    reviewStore: viewState.activeDiffReviewStore,
                                    onSubmitReview: actions.onSubmitReview,
                                    onDiscardReview: actions.onDiscardReview,
                                    totalReviewCommentCount: viewState.totalReviewCommentCount,
                                    reviewFileCount: viewState.reviewFileCount,
                                    onSubmitAllReviews: actions.onSubmitAllReviews,
                                    onDiscardAllReviews: actions.onDiscardAllReviews
                                )
                                switch diffState {
                                case .loading:
                                    VStack {
                                        Spacer()
                                        ProgressView("Loading diff...")
                                        Spacer()
                                    }
                                case .success(let diff):
                                    DiffGlassContentView(
                                        diff: diff,
                                        reduceTransparency: reduceTransparency,
                                        glassOpacity: glassOpacity,
                                        reviewStore: viewState.activeDiffReviewStore,
                                        commentGeneration: viewState.reviewCommentGeneration
                                    )
                                        .accessibilityIdentifier(AccessibilityID.Diff.content)
                                case .error(let message):
                                    VStack(spacing: 12) {
                                        Spacer()
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.largeTitle)
                                            .foregroundStyle(.secondary)
                                        Text(message)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                            .glassEffect(.clear.tint(chromeTint), in: .rect)
                            .accessibilityIdentifier(AccessibilityID.Diff.container)
                        } else if let browserController = viewState.activeBrowserController {
                            BrowserContainerView(controller: browserController)
                        } else {
                            VStack(spacing: 0) {
                                TerminalContainerView(
                                    splitContainerView: splitContainerView,
                                    reduceTransparency: reduceTransparency,
                                    glassOpacity: glassOpacity
                                )
                                .padding(.top, -1)
                                .padding(.leading, 8)
                                .glassEffect(.clear.tint(chromeTint), in: .rect)
                                .onDrop(of: [.fileURL], delegate: TerminalDropDelegate(splitContainerView: splitContainerView))
                                .layoutPriority(1)
                                .overlay(alignment: .topTrailing) {
                                    if secureInput.enabled {
                                        SecureInputOverlay()
                                    }
                                }

                                if let assistant = actions.composeAssistantState {
                                    VStack(spacing: 0) {
                                        if windowSession.showComposeOverlay {
                                            ComposeResizeHandle(
                                                currentHeight: windowSession.composeOverlayHeight,
                                                onHeightChanged: { windowSession.composeOverlayHeight = $0 }
                                            )
                                        }

                                        let hasExpandedContent = windowSession.showComposeOverlay
                                            || assistant.isBusy
                                            || !assistant.interactions.isEmpty
                                            || !(activeTab?.commandBlocks.isEmpty ?? true)
                                            || activeTab?.ollamaAgentSession != nil
                                            || activeTab?.lastShellError != nil
                                        let composeBarHeight = hasExpandedContent
                                            ? max(windowSession.composeOverlayHeight, 260)
                                            : 122

                                        ComposeCommandBarView(
                                            assistant: assistant,
                                            commandBlocks: activeTab?.commandBlocks ?? [],
                                            agentSession: activeTab?.ollamaAgentSession,
                                            shellError: activeTab?.lastShellError,
                                            ollamaModel: ollamaModel,
                                            ollamaEndpoint: ollamaEndpoint,
                                            broadcastEnabled: actions.composeBroadcastEnabled,
                                            isExpanded: windowSession.showComposeOverlay,
                                            onToggleExpanded: { actions.onToggleComposeOverlay?() },
                                            onToggleBroadcast: { actions.onToggleComposeBroadcast?() },
                                            onSend: actions.onComposeOverlaySend,
                                            onDismiss: actions.onDismissComposeOverlay,
                                            onApplyEntry: actions.onApplyComposeAssistantEntry,
                                            onExplainEntry: actions.onExplainComposeAssistantEntry,
                                            onFixEntry: actions.onFixComposeAssistantEntry,
                                            onExplainCommandBlock: actions.onExplainCommandBlock,
                                            onFixCommandBlock: actions.onFixCommandBlock,
                                            onApproveAgent: actions.onApproveOllamaAgent,
                                            onStopAgent: actions.onStopOllamaAgent
                                        )
                                        .frame(height: composeBarHeight)
                                    }
                                    .glassEffect(.clear.tint(chromeTint), in: .rect)
                                }
                            }
                        }
                    }

                    if windowSession.showCommandPalette, let commandRegistry {
                        Color.black.opacity(0.01)
                            .onTapGesture { actions.onDismissCommandPalette?() }

                        VStack {
                            CommandPaletteContainerView(
                                registry: commandRegistry,
                                onDismiss: actions.onDismissCommandPalette
                            )
                            .frame(width: 500, height: 340)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))

                            Spacer()
                        }
                        .padding(.top, 40)
                    }

                    if windowSession.showTerminalSearch {
                        TerminalSearchContainer(
                            onDismiss: { windowSession.showTerminalSearch = false },
                            onJumpToPane: { paneID in
                                actions.onJumpToSearchPane?(paneID)
                                windowSession.showTerminalSearch = false
                            }
                        )
                    }
                }
            }
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    Color.white.opacity(0.001)
                        .frame(height: geo.safeAreaInsets.top + 1)
                        .glassEffect(.clear.tint(chromeTint), in: .rect)
                        .offset(y: -geo.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
            .background {
                if !reduceTransparency {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(nsColor: GlassTheme.atmosphereTop(for: themeColor, glassOpacity: glassOpacity)), Color(nsColor: GlassTheme.atmosphereBottom(for: themeColor, glassOpacity: glassOpacity))],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RadialGradient(
                                colors: [Color(nsColor: GlassTheme.accentGradient(for: themeColor)), Color.clear],
                                center: .bottomTrailing,
                                startRadius: 20,
                                endRadius: 420
                            )
                        )
                        .overlay(
                            Rectangle()
                                .stroke(GlassTheme.specularStroke.opacity(0.30), lineWidth: 1)
                        )
                        .ignoresSafeArea()
                }
            }
        }
    }
}

struct DiffGlassContentView: NSViewRepresentable {
    let diff: FileDiff
    let reduceTransparency: Bool
    let glassOpacity: Double
    var reviewStore: DiffReviewStore?
    var commentGeneration: Int = 0

    func makeNSView(context: Context) -> DiffGlassHostView {
        let host = DiffGlassHostView(
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
        host.diffView.reviewStore = reviewStore
        host.diffView.display(diff: diff)
        return host
    }

    func updateNSView(_ nsView: DiffGlassHostView, context: Context) {
        nsView.configureAppearance(
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
        nsView.diffView.reviewStore = reviewStore
        if nsView.diffView.currentDiff != diff {
            nsView.diffView.display(diff: diff)
        } else {
            // Diff unchanged but comments may have changed (submit/discard)
            nsView.diffView.redisplayWithComments()
        }
    }
}

@MainActor
final class DiffGlassHostView: NSView {
    let diffView = DiffView(frame: .zero)

    init(reduceTransparency: Bool, glassOpacity: Double) {
        super.init(frame: .zero)
        setupViews()
        configureAppearance(reduceTransparency: reduceTransparency, glassOpacity: glassOpacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        diffView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diffView)
        NSLayoutConstraint.activate([
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: topAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configureAppearance(reduceTransparency: Bool, glassOpacity: Double) {
        if reduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private struct ComposeCommandBarView: View {
    @Bindable var assistant: ComposeAssistantState
    let commandBlocks: [TerminalCommandBlock]
    let agentSession: OllamaAgentSession?
    let shellError: ShellErrorEvent?
    let ollamaModel: String
    let ollamaEndpoint: String
    let broadcastEnabled: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onToggleBroadcast: () -> Void
    let onSend: ((String) -> Bool)?
    let onDismiss: (() -> Void)?
    let onApplyEntry: ((UUID, Bool) -> Bool)?
    let onExplainEntry: ((UUID) -> Void)?
    let onFixEntry: ((UUID) -> Void)?
    let onExplainCommandBlock: ((UUID) -> Void)?
    let onFixCommandBlock: ((UUID) -> Void)?
    let onApproveAgent: (() -> Bool)?
    let onStopAgent: (() -> Void)?

    private var visibleCommandBlocks: [TerminalCommandBlock] {
        Array(commandBlocks.prefix(isExpanded ? 6 : 1))
    }

    private var latestCollapsedAssistantEntry: ComposeAssistantEntry? {
        assistant.interactions.first
    }

    private var latestCollapsedCommandBlock: TerminalCommandBlock? {
        visibleCommandBlocks.first
    }

    private var isOllamaMode: Bool {
        assistant.mode == .ollamaCommand || assistant.mode == .ollamaAgent
    }

    private var isThinking: Bool {
        assistant.isBusy || agentSession?.status == .planning
    }

    var body: some View {
        VStack(spacing: 10) {
            header

            if isExpanded, let shellError {
                errorBanner(shellError)
            }

            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }

            VStack(spacing: 6) {
                ComposeOverlayContainerView(
                    text: Binding(
                        get: { assistant.draftText },
                        set: { assistant.setDraftText($0) }
                    ),
                    onSend: onSend,
                    onDismiss: onDismiss,
                    placeholderText: assistant.placeholderText
                )
                .frame(minHeight: 78, maxHeight: 108)

                HStack {
                    Text(modeHintText)
                    Spacer()
                    Text("Esc closes")
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker(
                "",
                selection: Binding(
                    get: { assistant.mode },
                    set: { assistant.mode = $0 }
                )
            ) {
                ForEach(ComposeAssistantMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            if isOllamaMode {
                VStack(alignment: .leading, spacing: 1) {
                    Text(ollamaModel.isEmpty ? OllamaCommandService.defaultModel : ollamaModel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(ollamaEndpoint.isEmpty ? OllamaCommandService.defaultEndpoint : ollamaEndpoint)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Warp-style command bar")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if isThinking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(agentSession?.status == .planning ? "Planning…" : "Thinking…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !assistant.interactions.isEmpty {
                Button("Clear") { assistant.clearHistory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(isExpanded ? "Collapse" : "Expand", action: onToggleExpanded)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button(action: onToggleBroadcast) {
                Image(systemName: broadcastEnabled
                      ? "antenna.radiowaves.left.and.right.circle.fill"
                      : "antenna.radiowaves.left.and.right.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(broadcastEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(broadcastEnabled
                  ? "Broadcast: ON — sending to all panes"
                  : "Broadcast: OFF — sending to focused pane")
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if visibleCommandBlocks.isEmpty && assistant.interactions.isEmpty && agentSession == nil {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let agentSession {
                        agentSection(agentSession)
                    }

                    if !visibleCommandBlocks.isEmpty {
                        commandBlockSection(title: "Recent Commands", blocks: visibleCommandBlocks)
                    }

                    if !assistant.interactions.isEmpty {
                        assistantSection
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if let agentSession,
           shouldPrioritizeAgentSession(agentSession) {
            ComposeAgentSessionCard(
                session: agentSession,
                compact: true,
                onApprove: { _ = onApproveAgent?() },
                onStop: { onStopAgent?() }
            )
        } else if let entry = latestCollapsedAssistantEntry,
           shouldPrioritizeAssistantEntry(entry) {
            ComposeAssistantEntryCard(
                entry: entry,
                compact: true,
                onEdit: { _ = onApplyEntry?(entry.id, false) },
                onRun: { _ = onApplyEntry?(entry.id, true) },
                onExplain: { onExplainEntry?(entry.id) },
                onFix: { onFixEntry?(entry.id) }
            )
        } else if let block = latestCollapsedCommandBlock {
            ComposeCommandBlockCard(
                block: block,
                compact: true,
                onExplain: { onExplainCommandBlock?(block.id) },
                onFix: { onFixCommandBlock?(block.id) }
            )
        } else if let shellError {
            compactBanner(shellError.snippet, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        } else {
            compactBanner(
                assistant.mode == .ollamaAgent
                    ? "Give the agent a task, approve its next command, then let it continue from command results."
                    : assistant.mode == .ollamaCommand
                    ? "Ask Ollama for a command or expand to inspect recent command history."
                    : "Type a command or expand to inspect recent command history and follow-up actions.",
                systemImage: "terminal",
                tint: .secondary
            )
        }
    }

    private func shouldPrioritizeAssistantEntry(_ entry: ComposeAssistantEntry) -> Bool {
        guard let block = latestCollapsedCommandBlock else { return true }
        return entry.createdAt >= block.startedAt
    }

    private var modeHintText: String {
        switch assistant.mode {
        case .shell:
            return "Return sends the command. Shift-Return inserts a newline."
        case .ollamaCommand:
            return "Return asks Ollama for a command. Shift-Return inserts a newline."
        case .ollamaAgent:
            return "Return starts an agent run. Approve each proposed command from the card above."
        }
    }

    private func shouldPrioritizeAgentSession(_ session: OllamaAgentSession) -> Bool {
        if let entry = latestCollapsedAssistantEntry,
           entry.createdAt > session.updatedAt {
            return false
        }
        if let block = latestCollapsedCommandBlock,
           block.startedAt > session.updatedAt,
           session.status.isTerminal {
            return false
        }
        return true
    }

    private func agentSection(_ session: OllamaAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ComposeAgentSessionCard(
                session: session,
                compact: false,
                onApprove: { _ = onApproveAgent?() },
                onStop: { onStopAgent?() }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commandBlockSection(title: String, blocks: [TerminalCommandBlock]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(blocks) { block in
                ComposeCommandBlockCard(
                    block: block,
                    compact: false,
                    onExplain: { onExplainCommandBlock?(block.id) },
                    onFix: { onFixCommandBlock?(block.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assistant")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(assistant.interactions) { entry in
                ComposeAssistantEntryCard(
                    entry: entry,
                    onEdit: { _ = onApplyEntry?(entry.id, false) },
                    onRun: { _ = onApplyEntry?(entry.id, true) },
                    onExplain: { onExplainEntry?(entry.id) },
                    onFix: { onFixEntry?(entry.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run commands from here, then reuse the resulting blocks for Explain, Fix, or reruns.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Shell, one-shot Ollama suggestions, and the approval-based agent loop all stay in the same terminal bar.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func errorBanner(_ shellError: ShellErrorEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Latest shell error", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                Spacer()
                if let entry = assistant.latestRunnableEntry {
                    HStack(spacing: 6) {
                        Button("Explain") { onExplainEntry?(entry.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Fix") { onFixEntry?(entry.id) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            Text(shellError.snippet)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private func compactBanner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

private struct ComposeAgentSessionCard: View {
    let session: OllamaAgentSession
    let compact: Bool
    let onApprove: () -> Void
    let onStop: () -> Void

    private var statusTint: Color {
        switch session.status {
        case .planning:
            return .secondary
        case .awaitingApproval:
            return .orange
        case .runningCommand:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                Text("Agent")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Text(session.status.label)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(statusTint)

                Text("Step \(session.iteration + (session.status == .runningCommand ? 0 : 1))")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Goal")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text(session.goal)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 2 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let pendingCommand = session.pendingCommand, !pendingCommand.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next command")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(pendingCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(compact ? 3 : nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let planText = session.latestPlanText, !planText.isEmpty {
                Text(planText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(session.status == .failed ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(compact ? 3 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if session.canApprove || !session.status.isTerminal {
                HStack(spacing: 8) {
                    if session.canApprove {
                        Button("Approve & Run", action: onApprove)
                            .buttonStyle(.borderedProminent)
                            .controlSize(compact ? .mini : .small)
                    }

                    if !session.status.isTerminal {
                        Button("Stop", action: onStop)
                            .buttonStyle(.bordered)
                            .controlSize(compact ? .mini : .small)
                    }

                    Spacer()
                }
            }
        }
        .padding(compact ? 9 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(compact ? 0.04 : 0.05))
        )
    }
}

private struct ComposeCommandBlockCard: View {
    let block: TerminalCommandBlock
    let compact: Bool
    let onExplain: () -> Void
    let onFix: () -> Void

    private var statusTint: Color {
        switch block.status {
        case .running:
            return .secondary
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                Text(block.source.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Text(block.status.label)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(statusTint)

                if let durationText = block.durationText {
                    Text(durationText)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(block.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            Text(block.titleText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(compact ? 2 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let snippet = block.primarySnippet {
                Text(snippet)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(block.status == .failed ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(compact ? 3 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !compact {
                HStack(spacing: 8) {
                    if block.canExplain {
                        Button("Explain", action: onExplain)
                    }
                    if block.canFix {
                        Button("Fix", action: onFix)
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(compact ? 9 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(compact ? 0.04 : 0.05))
        )
    }
}

private struct ComposeAssistantEntryCard: View {
    let entry: ComposeAssistantEntry
    var compact: Bool = false
    let onEdit: () -> Void
    let onRun: () -> Void
    let onExplain: () -> Void
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                Text(entry.kind.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))

                Text(entry.status.label)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(entry.status == .failed ? .red : .secondary)

                Spacer()

                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if entry.kind == .explanation {
                Text(entry.primaryText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(entry.status == .failed ? .red : .primary)
                    .textSelection(.enabled)
                    .lineLimit(compact ? 4 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(entry.primaryText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.status == .failed ? .red : .primary)
                    .textSelection(.enabled)
                    .lineLimit(compact ? 4 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !compact,
               let contextSnippet = entry.contextSnippet,
               !contextSnippet.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(contextSnippet)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !compact {
                HStack(spacing: 8) {
                    if entry.canInsert {
                        Button("Edit", action: onEdit)
                    }
                    if entry.canRun {
                        Button(entry.kind == .shellDispatch ? "Run Again" : "Run", action: onRun)
                    }
                    if entry.canExplain {
                        Button("Explain", action: onExplain)
                    }
                    if entry.canFix {
                        Button("Fix", action: onFix)
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(compact ? 9 : 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(compact ? 0.04 : 0.05))
        )
    }
}

struct TerminalContainerView: NSViewRepresentable {
    let splitContainerView: SplitContainerView
    let reduceTransparency: Bool
    let glassOpacity: Double

    func makeNSView(context: Context) -> NSView {
        TerminalGlassHostView(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? TerminalGlassHostView else { return }
        host.update(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
    }
}

@MainActor
private final class TerminalGlassHostView: NSView {

    init(splitContainerView: SplitContainerView, reduceTransparency: Bool, glassOpacity: Double) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        update(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(splitContainerView: SplitContainerView, reduceTransparency: Bool, glassOpacity: Double) {
        if reduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        if splitContainerView.superview !== self {
            splitContainerView.removeFromSuperview()
            splitContainerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(splitContainerView)
            NSLayoutConstraint.activate([
                splitContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                splitContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
                splitContainerView.topAnchor.constraint(equalTo: topAnchor),
                splitContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}

// MARK: - Drag and Drop

@MainActor
struct TerminalDropDelegate: DropDelegate {
    let splitContainerView: SplitContainerView

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let window = splitContainerView.window,
              let surfaceView = window.firstResponder as? SurfaceView,
              let surfaceController = surfaceView.surfaceController else {
            return false
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        var paths: [(Int, String)] = []
        let lock = NSLock()

        for (i, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let escaped = ShellEscape.escape(url.path)
                lock.lock()
                paths.append((i, escaped))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let joined = paths.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
            if !joined.isEmpty {
                surfaceController.sendText(joined)
            }
        }
        return true
    }
}
