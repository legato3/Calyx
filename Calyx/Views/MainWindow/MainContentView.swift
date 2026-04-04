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
                                            || !actions.activeAISuggestions.isEmpty
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
                                            pwd: activeTab?.pwd,
                                            activeAISuggestions: actions.activeAISuggestions,
                                            nextCommandSuggestion: actions.nextCommandSuggestion,
                                            suggestedDiffStatus: actions.suggestedDiffStatus,
                                            attachedBlockIDs: actions.attachedBlockIDs,
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
                                            onStopAgent: actions.onStopOllamaAgent,
                                            onAcceptSuggestion: { actions.onAcceptActiveAISuggestion?($0) },
                                            onDismissSuggestions: { actions.onDismissActiveAISuggestions?() },
                                            onAcceptNextCommand: { actions.onAcceptNextCommand?() },
                                            onAcceptDiff: { actions.onAcceptSuggestedDiff?($0) },
                                            onDismissDiff: { actions.onDismissSuggestedDiff?() },
                                            onAttachBlock: { actions.onAttachBlock?($0) },
                                            onDetachBlock: { actions.onDetachBlock?($0) }
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
    let pwd: String?
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
    // Active AI
    var activeAISuggestions: [ActiveAISuggestion] = []
    var nextCommandSuggestion: String? = nil
    var suggestedDiffStatus: SuggestedDiffStatus = .idle
    var attachedBlockIDs: Set<UUID> = []
    var onAcceptSuggestion: ((ActiveAISuggestion) -> Void)? = nil
    var onDismissSuggestions: (() -> Void)? = nil
    var onAcceptNextCommand: (() -> String?)? = nil
    var onAcceptDiff: ((SuggestedDiff) -> Void)? = nil
    var onDismissDiff: (() -> Void)? = nil
    var onAttachBlock: ((UUID) -> Void)? = nil
    var onDetachBlock: ((UUID) -> Void)? = nil

    @State private var gitBranch: String? = nil

    private var visibleCommandBlocks: [TerminalCommandBlock] {
        Array(commandBlocks.prefix(isExpanded ? 6 : 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Warp-style: agent conversation view has distinct background
            if assistant.mode.isAgentMode && (isExpanded || agentSession != nil || !assistant.interactions.isEmpty) {
                agentConversationPanel
            } else if isExpanded {
                expandedShellPanel
            }

            // Warp-style input bar — always visible, minimal chrome
            warpInputBar
        }
        .task(id: pwd) {
            guard let pwd else { gitBranch = nil; return }
            gitBranch = await TerminalContextGatherer.runTool(
                "git", args: ["branch", "--show-current"], cwd: pwd, timeout: 2
            )
        }
    }

    // MARK: - Warp-style Input Bar

    private var warpInputBar: some View {
        VStack(spacing: 0) {
            // Suggested Code Diff panel (highest priority — shown above everything)
            if case .ready(let diff) = suggestedDiffStatus {
                SuggestedDiffPanel(
                    diff: diff,
                    onAccept: { onAcceptDiff?(diff) },
                    onDismiss: { onDismissDiff?() }
                )
            } else if case .generating = suggestedDiffStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Generating fix…")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { onDismissDiff?() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.06))
            }

            // Active AI suggestion chips
            if !activeAISuggestions.isEmpty {
                ActiveAISuggestionBar(
                    suggestions: activeAISuggestions,
                    onAccept: { onAcceptSuggestion?($0) },
                    onDismiss: { onDismissSuggestions?() }
                )
            }

            // Attached blocks indicator
            if !attachedBlockIDs.isEmpty {
                AttachedBlocksBar(
                    blocks: commandBlocks.filter { attachedBlockIDs.contains($0.id) },
                    onDetach: { onDetachBlock?($0) }
                )
            }

            contextHintBar
            HStack(alignment: .bottom, spacing: 8) {
                modeSelectorButton
                ZStack(alignment: .bottomLeading) {
                    ComposeOverlayContainerView(
                        text: Binding(get: { assistant.draftText }, set: { assistant.setDraftText($0) }),
                        onSend: onSend,
                        onDismiss: onDismiss,
                        onCmdReturn: {
                            if assistant.mode == .shell && assistant.detectedIntent == .agent {
                                assistant.mode = .claudeAgent
                            } else if assistant.mode == .claudeAgent || assistant.mode.isAgentMode {
                                let text = assistant.draftText
                                _ = onSend?(text)
                            }
                        },
                        placeholderText: assistant.placeholderText
                    )
                    .frame(minHeight: 36, maxHeight: 96)

                    // Next-command ghost text overlay
                    if let ghost = nextCommandSuggestion,
                       !ghost.isEmpty,
                       assistant.mode == .shell,
                       ghost.lowercased().hasPrefix(assistant.draftText.lowercased()),
                       ghost != assistant.draftText {
                        let suffix = String(ghost.dropFirst(assistant.draftText.count))
                        HStack(spacing: 0) {
                            Text(assistant.draftText)
                                .foregroundStyle(Color.clear)
                            Text(suffix)
                                .foregroundStyle(Color.secondary.opacity(0.45))
                            Spacer()
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.leading, 13)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                    }

                    // Auto-detected intent badge
                    if assistant.mode == .shell,
                       !assistant.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let intent = assistant.detectedIntent
                        if intent != .ambiguous {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(intent == .agent ? Color.purple : Color.green)
                                    .frame(width: 5, height: 5)
                                Text(intent.label)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(intent == .agent ? Color.purple : Color.green)
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill((intent == .agent ? Color.purple : Color.green).opacity(0.12)))
                            .offset(x: 8, y: -4)
                            .allowsHitTesting(false)
                        }
                    }
                }
                VStack(spacing: 4) {
                    Button(action: onToggleBroadcast) {
                        Image(systemName: broadcastEnabled
                              ? "antenna.radiowaves.left.and.right.circle.fill"
                              : "antenna.radiowaves.left.and.right.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(broadcastEnabled ? Color.accentColor : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(broadcastEnabled ? "Broadcast ON" : "Broadcast OFF")

                    Button(action: onToggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down.circle" : "chevron.up.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand history")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Next-command accept hint
            if let ghost = nextCommandSuggestion, !ghost.isEmpty, assistant.mode == .shell {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text("→ to accept: \(ghost.prefix(50))\(ghost.count > 50 ? "…" : "")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("→ Accept") {
                        if let accepted = onAcceptNextCommand?() {
                            assistant.setDraftText(accepted)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
    }

    // MARK: - Context Hint Bar (Warp-style message bar)

    @ViewBuilder
    private var contextHintBar: some View {
        let hint = contextHint
        if !hint.text.isEmpty {
            HStack(spacing: 6) {
                if let icon = hint.icon {
                    Image(systemName: icon).font(.system(size: 10)).foregroundStyle(hint.tint)
                }
                Text(hint.text)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(hint.tint.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if let actionLabel = hint.actionLabel, let onAction = hint.onAction {
                    Button(actionLabel, action: onAction)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
                Text("Esc")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(hint.tint.opacity(0.06))
        }
    }

    private struct ContextHint {
        var text: String
        var icon: String?
        var tint: Color
        var actionLabel: String?
        var onAction: (() -> Void)?
    }

    private var contextHint: ContextHint {
        if let shellError, assistant.mode == .shell {
            return ContextHint(
                text: "Last command failed — ⌘↩ to fix",
                icon: "exclamationmark.triangle.fill", tint: .orange,
                actionLabel: "Fix",
                onAction: { if let e = assistant.latestRunnableEntry { onFixEntry?(e.id) } }
            )
        }
        if let session = agentSession, session.canApprove {
            return ContextHint(
                text: "Agent is waiting — approve the next command",
                icon: "checkmark.circle", tint: .orange,
                actionLabel: "Approve", onAction: { _ = onApproveAgent?() }
            )
        }
        if let session = agentSession, session.status == .runningCommand {
            return ContextHint(
                text: "Agent running step \(session.iteration)…",
                icon: "arrow.trianglehead.2.clockwise.rotate.90", tint: .accentColor,
                actionLabel: "Stop", onAction: { onStopAgent?() }
            )
        }
        if agentSession?.status == .planning || assistant.isBusy {
            return ContextHint(text: "Thinking…", icon: "ellipsis", tint: .secondary)
        }
        let draft = assistant.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty && assistant.mode == .shell {
            let intent = assistant.detectedIntent
            if intent == .agent {
                return ContextHint(
                    text: "Looks like a prompt — ⌘↩ to send to Claude",
                    icon: "sparkles", tint: .purple,
                    actionLabel: "Use Claude", onAction: { assistant.mode = .claudeAgent }
                )
            }
            return ContextHint(text: "↩ to run  ·  Shift-↩ for newline", tint: .secondary)
        }
        switch assistant.mode {
        case .shell:
            let hasHistory = !commandBlocks.isEmpty || !assistant.interactions.isEmpty
            return ContextHint(
                text: hasHistory ? "⌘↩ new agent  ·  ↑ expand history" : "⌘↩ to start an agent session",
                tint: .secondary
            )
        case .ollamaCommand:
            return ContextHint(text: "↩ to ask Ollama for a command", icon: "wand.and.stars", tint: .secondary)
        case .ollamaAgent:
            return ContextHint(text: "↩ to start local agent loop", icon: "cpu", tint: .secondary)
        case .claudeAgent:
            return ContextHint(text: "↩ to launch Claude Code agent in a new tab", icon: "sparkles", tint: .purple)
        }
    }

    // MARK: - Mode Selector

    private var modeSelectorButton: some View {
        Menu {
            ForEach(ComposeAssistantMode.allCases) { mode in
                Button { assistant.mode = mode } label: {
                    Label(mode.displayName, systemImage: modeIcon(mode))
                }
            }
        } label: {
            Image(systemName: modeIcon(assistant.mode))
                .font(.system(size: 14))
                .foregroundStyle(assistant.mode.isAgentMode ? Color.purple : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(
                    assistant.mode.isAgentMode ? Color.purple.opacity(0.12) : Color.white.opacity(0.06)
                ))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28, height: 28)
        .help("Switch input mode (\(assistant.mode.displayName))")
    }

    private func modeIcon(_ mode: ComposeAssistantMode) -> String {
        switch mode {
        case .shell: return "terminal"
        case .ollamaCommand: return "wand.and.stars"
        case .ollamaAgent: return "cpu"
        case .claudeAgent: return "sparkles"
        }
    }

    // MARK: - Agent Conversation Panel (Warp-style dedicated view)

    private var agentConversationPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple)
                Text(assistant.mode == .claudeAgent ? "Claude Agent" : "Agent")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                if let branch = gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
                    .foregroundStyle(.secondary)
                }
                if isThinking {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(agentSession?.status == .planning ? "Planning…" : "Thinking…")
                            .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !assistant.interactions.isEmpty {
                    Button("Clear") { assistant.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                }
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.purple.opacity(0.06))

            Divider().opacity(0.3)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if let agentSession {
                        WarpAgentSessionView(
                            session: agentSession,
                            onApprove: { _ = onApproveAgent?() },
                            onStop: { onStopAgent?() }
                        )
                    }
                    ForEach(assistant.interactions) { entry in
                        WarpAssistantEntryView(
                            entry: entry,
                            onEdit: { _ = onApplyEntry?(entry.id, false) },
                            onRun: { _ = onApplyEntry?(entry.id, true) },
                            onExplain: { onExplainEntry?(entry.id) },
                            onFix: { onFixEntry?(entry.id) }
                        )
                    }
                    if assistant.interactions.isEmpty && agentSession == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(.purple.opacity(0.5))
                            Text("Ask Claude to build, fix, or explain something.")
                                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Text("Claude Code will open in a new tab and work autonomously.")
                                .font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1).scrollIndicators(.hidden)
        }
        .background(Color.purple.opacity(0.03))
    }

    // MARK: - Expanded Shell Panel

    @ViewBuilder
    private var expandedShellPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("History").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                if let branch = gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule()).foregroundStyle(.secondary)
                }
                Spacer()
                if !assistant.interactions.isEmpty {
                    Button("Clear") { assistant.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                }
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().opacity(0.3)
            if let shellError {
                errorBanner(shellError).padding(.horizontal, 12).padding(.top, 8)
            }
            if visibleCommandBlocks.isEmpty && assistant.interactions.isEmpty {
                Text("Run commands, then use Explain or Fix on the resulting blocks.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleCommandBlocks) { block in
                            ComposeCommandBlockCard(
                                block: block, compact: false,
                                isAttached: attachedBlockIDs.contains(block.id),
                                onExplain: { onExplainCommandBlock?(block.id) },
                                onFix: { onFixCommandBlock?(block.id) },
                                onAttach: { onAttachBlock?(block.id) },
                                onDetach: { onDetachBlock?(block.id) }
                            )
                        }
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
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1).scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Helpers

    private var isThinking: Bool {
        assistant.isBusy || agentSession?.status == .planning
    }

    @ViewBuilder
    private func errorBanner(_ shellError: ShellErrorEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Latest shell error", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.orange)
                Spacer()
                if let entry = assistant.latestRunnableEntry {
                    HStack(spacing: 6) {
                        Button("Explain") { onExplainEntry?(entry.id) }.buttonStyle(.bordered).controlSize(.small)
                        Button("Fix") { onFixEntry?(entry.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            Text(shellError.snippet)
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Warp-style Agent Session View

private struct WarpAgentSessionView: View {
    let session: OllamaAgentSession
    let onApprove: () -> Void
    let onStop: () -> Void

    private var statusColor: Color {
        switch session.status {
        case .planning: return .secondary
        case .awaitingApproval: return .orange
        case .runningCommand: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Goal header
            HStack(spacing: 8) {
                Image(systemName: "target").font(.system(size: 11)).foregroundStyle(.purple)
                Text(session.goal)
                    .font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(2)
                Spacer()
                HStack(spacing: 4) {
                    if session.status == .planning || session.status == .runningCommand {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                    Text(session.status.label)
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(statusColor)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(statusColor.opacity(0.1), in: Capsule())
            }

            // Step timeline
            if !session.steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.steps.prefix(8).enumerated()), id: \.element.id) { idx, step in
                        WarpAgentStepRow(step: step, isLast: idx == session.steps.prefix(8).count - 1)
                    }
                }
            }

            // Pending command approval
            if let pendingCommand = session.pendingCommand, !pendingCommand.isEmpty, session.canApprove {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill").font(.system(size: 10)).foregroundStyle(.orange)
                        Text("Proposed command")
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                        Spacer()
                    }
                    Text(pendingCommand)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 8) {
                        Button { onApprove() } label: {
                            Label("Approve & Run", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                        Button("Stop", action: onStop).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            }

            if !session.status.isTerminal && !session.canApprove {
                HStack {
                    Spacer()
                    Button("Stop Agent", action: onStop).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Warp-style Agent Step Row

private struct WarpAgentStepRow: View {
    let step: OllamaAgentStep
    let isLast: Bool

    private var stepIcon: String {
        switch step.kind {
        case .goal: return "target"
        case .plan: return "list.bullet"
        case .command: return "terminal"
        case .observation: return "eye"
        case .summary: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var stepColor: Color {
        switch step.kind {
        case .goal: return .purple
        case .plan: return .accentColor
        case .command: return .primary
        case .observation: return .secondary
        case .summary: return .green
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Image(systemName: stepIcon).font(.system(size: 10)).foregroundStyle(stepColor)
                    .frame(width: 18, height: 18)
                    .background(stepColor.opacity(0.1), in: Circle())
                if !isLast {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(stepColor.opacity(0.8))
                    .textCase(.uppercase).tracking(0.5)
                if let command = step.command, !command.isEmpty {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
                        .textSelection(.enabled).lineLimit(2)
                }
                if !step.text.isEmpty && step.text != step.command {
                    Text(step.text)
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Warp-style Assistant Entry View

private struct WarpAssistantEntryView: View {
    let entry: ComposeAssistantEntry
    let onEdit: () -> Void
    let onRun: () -> Void
    let onExplain: () -> Void
    let onFix: () -> Void

    private var entryColor: Color {
        switch entry.status {
        case .failed: return .red
        case .ran, .inserted: return .green
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.kind.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(entryColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(entryColor.opacity(0.1), in: Capsule())
                if entry.status == .pending { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                Spacer()
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .rounded)).foregroundStyle(.quaternary)
            }
            Text(entry.prompt)
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary).lineLimit(1)
            if !entry.primaryText.isEmpty && entry.primaryText != entry.prompt {
                Text(entry.primaryText)
                    .font(entry.usesMonospacedBody
                          ? .system(size: 12, design: .monospaced)
                          : .system(size: 11, design: .rounded))
                    .foregroundStyle(entry.status == .failed ? .red : .primary)
                    .textSelection(.enabled).lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            if entry.canRun || entry.canExplain || entry.canFix {
                HStack(spacing: 6) {
                    if entry.canInsert { Button("Edit", action: onEdit).buttonStyle(.bordered).controlSize(.small) }
                    if entry.canRun {
                        Button(entry.kind == .shellDispatch ? "Run Again" : "Run", action: onRun)
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if entry.canExplain { Button("Explain", action: onExplain).buttonStyle(.bordered).controlSize(.small) }
                    if entry.canFix { Button("Fix", action: onFix).buttonStyle(.bordered).controlSize(.small) }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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
    var isAttached: Bool = false
    let onExplain: () -> Void
    let onFix: () -> Void
    var onAttach: (() -> Void)? = nil
    var onDetach: (() -> Void)? = nil

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
                    // Warp-style block attachment
                    if isAttached {
                        Button {
                            onDetach?()
                        } label: {
                            Label("Attached", systemImage: "paperclip.circle.fill")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    } else {
                        Button {
                            onAttach?()
                        } label: {
                            Label("Attach", systemImage: "paperclip")
                                .font(.system(size: 10, design: .rounded))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Attach this block's output to the next agent prompt")
                    }
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

// MARK: - Active AI Suggestion Bar

private struct ActiveAISuggestionBar: View {
    let suggestions: [ActiveAISuggestion]
    let onAccept: (ActiveAISuggestion) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                        .padding(.leading, 12)

                    ForEach(suggestions) { suggestion in
                        Button {
                            onAccept(suggestion)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: suggestion.icon)
                                    .font(.system(size: 10))
                                Text(suggestion.prompt)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.purple)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
        }
        .background(Color.purple.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.purple.opacity(0.1)).frame(height: 1)
        }
    }
}

// MARK: - Attached Blocks Bar

private struct AttachedBlocksBar: View {
    let blocks: [TerminalCommandBlock]
    let onDetach: (UUID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 12)

            Text("Attached:")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(blocks) { block in
                        HStack(spacing: 4) {
                            Text(block.titleText)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Button {
                                onDetach(block.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentColor.opacity(0.1)).frame(height: 1)
        }
    }
}

// MARK: - Suggested Diff Panel

private struct SuggestedDiffPanel: View {
    let diff: SuggestedDiff
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Suggested Fix")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                if let path = diff.filePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(isExpanded ? "Collapse" : "View diff") {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                Button("Apply") { onAccept() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if isExpanded {
                Divider().opacity(0.3)
                if !diff.explanation.isEmpty {
                    Text(diff.explanation)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                if diff.isValidPatch {
                    ScrollView {
                        Text(diff.patchText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.orange.opacity(0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.15)).frame(height: 1)
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
