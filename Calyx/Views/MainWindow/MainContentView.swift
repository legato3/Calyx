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

    @Binding var sidebarMode: SidebarMode

    @Environment(WindowActions.self) private var actions
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppStorageKeys.terminalGlassOpacity) private var glassOpacity = 0.7
    @AppStorage(AppStorageKeys.themeColorPreset) private var themePreset = "original"
    @AppStorage(AppStorageKeys.themeColorCustomHex) private var customHex = "#050D1C"
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
        let activeTabs = activeGroup?.tabs ?? []
        let activeTabID = activeGroup?.activeTabID
        let chromeTint = Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))

        GlassEffectContainer {
            HStack(spacing: 0) {
                if windowSession.showSidebar {
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
                        onGroupSelected: actions.onGroupSelected,
                        onTabSelected: actions.onTabSelected,
                        onNewGroup: actions.onNewGroup,
                        onCloseTab: actions.onCloseTab,
                        onGroupRenamed: actions.onGroupRenamed,
                        onTabRenamed: actions.onTabRenamed,
                        onCollapseToggled: actions.onCollapseToggled,
                        onCloseAllTabsInGroup: actions.onCloseAllTabsInGroup,
                        onWorkingFileSelected: actions.onWorkingFileSelected,
                        onCommitFileSelected: actions.onCommitFileSelected,
                        onRefreshGitStatus: actions.onRefreshGitStatus,
                        onLoadMoreCommits: actions.onLoadMoreCommits,
                        onExpandCommit: actions.onExpandCommit,
                        onRollbackToCheckpoint: actions.onRollbackToCheckpoint,
                        onMoveTab: actions.onMoveTab,
                        onOpenDiff: actions.onOpenDiff,
                        onOpenAggregateDiff: actions.onOpenAggregateDiff
                    )
                    .frame(width: windowSession.sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(
                            currentWidth: windowSession.sidebarWidth,
                            onWidthChanged: { actions.onSidebarWidthChanged?($0) },
                            onDragCommitted: { actions.onSidebarDragCommitted?() }
                        )
                        .offset(x: 0)
                        .zIndex(1)
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

                                if windowSession.showComposeOverlay {
                                    VStack(spacing: 0) {
                                        ComposeResizeHandle(
                                            currentHeight: windowSession.composeOverlayHeight,
                                            onHeightChanged: { windowSession.composeOverlayHeight = $0 }
                                        )

                                        ZStack(alignment: .topTrailing) {
                                            ComposeOverlayContainerView(
                                                onSend: actions.onComposeOverlaySend,
                                                onDismiss: actions.onDismissComposeOverlay
                                            )
                                            .frame(height: windowSession.composeOverlayHeight)

                                            Button(action: { actions.onToggleComposeBroadcast?() }) {
                                                Image(systemName: actions.composeBroadcastEnabled
                                                      ? "antenna.radiowaves.left.and.right.circle.fill"
                                                      : "antenna.radiowaves.left.and.right.circle")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(actions.composeBroadcastEnabled
                                                                     ? Color.accentColor : Color.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(8)
                                            .help(actions.composeBroadcastEnabled
                                                  ? "Broadcast: ON — sending to all panes"
                                                  : "Broadcast: OFF — sending to focused pane")
                                        }
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
