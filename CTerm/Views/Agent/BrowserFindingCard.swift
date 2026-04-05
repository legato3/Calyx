// BrowserFindingCard.swift
// CTerm
//
// Expandable card rendered inside the agent run panel for each browser
// finding produced by a research workflow. Per-card "Save" writes the
// finding to AgentMemoryStore as a durable entry.

import SwiftUI
import AppKit

struct BrowserFindingCard: View {
    let url: String
    let title: String
    let preview: String
    let fullContent: String?
    var isKept: Bool
    var onSave: () -> Void

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.teal)
                Text(hostFragment)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.teal)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture { copyURL() }
                    .help("Click to copy: \(url)")
                Spacer(minLength: 6)
                if isKept {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .help("Saved to memory")
                } else {
                    Button("Save") { onSave() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.teal)
                }
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(displayedContent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: expanded)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private var hostFragment: String {
        URL(string: url)?.host ?? url
    }

    private var displayedContent: String {
        expanded ? (fullContent ?? preview) : preview
    }

    private func copyURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
    }
}
