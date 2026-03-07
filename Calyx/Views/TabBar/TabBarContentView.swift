// TabBarContentView.swift
// Calyx
//
// SwiftUI horizontal tab strip for the active tab group.

import SwiftUI

struct TabBarContentView: View {
    let tabs: [Tab]
    let activeTabID: UUID?
    var onTabSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        TabItemButton(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            onSelected: { onTabSelected?(tab.id) },
                            onClose: { onCloseTab?(tab.id) }
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: { onNewTab?() }) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabItemButton: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        Button(action: { onSelected?() }) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .lineLimit(1)
                    .font(.callout)
                    .padding(.leading, 8)

                Button(action: { onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                isActive
                    ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12))
                    : RoundedRectangle(cornerRadius: 4).fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
