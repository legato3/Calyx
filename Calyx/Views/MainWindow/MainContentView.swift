// MainContentView.swift
// Calyx
//
// SwiftUI root view composing sidebar, tab bar, and terminal content.

import SwiftUI

struct MainContentView: View {
    let groups: [TabGroup]
    let activeGroupID: UUID?
    let activeTabs: [Tab]
    let activeTabID: UUID?
    let showSidebar: Bool
    let splitContainerView: SplitContainerView

    var onTabSelected: ((UUID) -> Void)?
    var onGroupSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onToggleSidebar: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarContentView(
                    groups: groups,
                    activeGroupID: activeGroupID,
                    activeTabID: activeTabID,
                    onGroupSelected: onGroupSelected,
                    onTabSelected: onTabSelected,
                    onNewGroup: onNewGroup,
                    onCloseTab: onCloseTab
                )
                .frame(width: 220)

                Divider()
            }

            VStack(spacing: 0) {
                if activeTabs.count > 1 {
                    TabBarContentView(
                        tabs: activeTabs,
                        activeTabID: activeTabID,
                        onTabSelected: onTabSelected,
                        onNewTab: onNewTab,
                        onCloseTab: onCloseTab
                    )
                }

                TerminalContainerView(splitContainerView: splitContainerView)
            }
        }
    }
}

struct TerminalContainerView: NSViewRepresentable {
    let splitContainerView: SplitContainerView

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        splitContainerView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(splitContainerView)
        NSLayoutConstraint.activate([
            splitContainerView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            splitContainerView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            splitContainerView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            splitContainerView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if splitContainerView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            splitContainerView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(splitContainerView)
            NSLayoutConstraint.activate([
                splitContainerView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                splitContainerView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
                splitContainerView.topAnchor.constraint(equalTo: nsView.topAnchor),
                splitContainerView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
            ])
        }
    }
}
