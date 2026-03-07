// CommandPaletteContainerView.swift
// Calyx
//
// NSViewRepresentable wrapper for the command palette.

import SwiftUI

struct CommandPaletteContainerView: NSViewRepresentable {
    let registry: CommandRegistry
    var onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> CommandPaletteView {
        let view = CommandPaletteView(registry: registry)
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: CommandPaletteView, context: Context) {
        nsView.onDismiss = onDismiss
    }
}
