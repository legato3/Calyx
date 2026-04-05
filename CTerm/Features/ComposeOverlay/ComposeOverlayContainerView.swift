// ComposeOverlayContainerView.swift
// CTerm
//
// NSViewRepresentable wrapper for the compose overlay.

import SwiftUI
import AppKit

struct ComposeOverlayContainerView: NSViewRepresentable {
    @Binding var text: String
    var onSend: ((String) -> Bool)?
    var onDismiss: (() -> Void)?
    var onCmdReturn: (() -> Void)?
    var onTabComplete: (() -> Bool)?
    var placeholderText: String = "Type here..."
    /// When provided, registers a focus callback on WindowActions so the
    /// FocusManager can redirect keyboard focus here (Warp-mode single input).
    var actions: WindowActions?

    func makeNSView(context: Context) -> ComposeOverlayView {
        let view = ComposeOverlayView()
        view.text = text
        view.onTextChange = { newValue in
            context.coordinator.text.wrappedValue = newValue
        }
        view.onSend = onSend
        view.onDismiss = onDismiss
        view.onCmdReturn = onCmdReturn
        view.onTabComplete = onTabComplete
        view.placeholderText = placeholderText
        // Register focus callback so FocusManager can redirect here.
        actions?.onFocusComposeTextField = { [weak view] in
            view?.focusTextView()
        }
        return view
    }

    func updateNSView(_ nsView: ComposeOverlayView, context: Context) {
        context.coordinator.text.wrappedValue = text
        nsView.text = text
        nsView.onTextChange = { newValue in
            context.coordinator.text.wrappedValue = newValue
        }
        nsView.onSend = onSend
        nsView.onDismiss = onDismiss
        nsView.onCmdReturn = onCmdReturn
        nsView.onTabComplete = onTabComplete
        nsView.placeholderText = placeholderText
        // Keep focus callback up to date.
        actions?.onFocusComposeTextField = { [weak nsView] in
            nsView?.focusTextView()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }
}

extension ComposeOverlayContainerView {
    @MainActor
    final class Coordinator {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }
    }
}

struct ComposeResizeHandle: View {
    let currentHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Color.clear
            .frame(height: 16)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard !isDragging else { return }
                if hovering && !isHovering {
                    NSCursor.resizeUpDown.push()
                    isHovering = true
                } else if !hovering && isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        NSCursor.resizeUpDown.set()
                        let newHeight = max(
                            WindowSession.composeMinHeight,
                            min(WindowSession.composeMaxHeight, currentHeight - value.translation.height)
                        )
                        onHeightChanged(newHeight)
                    }
                    .onEnded { value in
                        let newHeight = max(
                            WindowSession.composeMinHeight,
                            min(WindowSession.composeMaxHeight, currentHeight - value.translation.height)
                        )
                        onHeightChanged(newHeight)
                        isDragging = false
                        NSCursor.arrow.set()
                    }
            )
            .onDisappear {
                if isHovering || isDragging {
                    NSCursor.pop()
                    isHovering = false
                    isDragging = false
                }
            }
    }
}
