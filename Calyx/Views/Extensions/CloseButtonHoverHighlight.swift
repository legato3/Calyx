// CloseButtonHoverHighlight.swift
// Calyx
//
// Circular hover highlight for close buttons.
// Uses AssumeInsideHover for robust cursor detection under stationary cursors.

import SwiftUI

struct CloseButtonHoverHighlight: ViewModifier {
    let size: CGFloat
    let isVisible: Bool
    var hoverOpacity: Double = 0.12

    @State private var isHovering = false

    private var shouldHighlight: Bool { isHovering && isVisible }

    func body(content: Content) -> some View {
        content
            .background(
                Circle()
                    .fill(Color.primary.opacity(shouldHighlight ? hoverOpacity : 0))
                    .frame(width: size, height: size)
                    .animation(.easeInOut(duration: 0.15), value: shouldHighlight)
            )
            .background {
                if isVisible {
                    AssumeInsideHover(isHovering: $isHovering)
                }
            }
            .onChange(of: isVisible) { _, newValue in
                if !newValue { isHovering = false }
            }
    }
}

extension View {
    func closeButtonHoverHighlight(size: CGFloat = 16, isVisible: Bool, hoverOpacity: Double = 0.12) -> some View {
        modifier(CloseButtonHoverHighlight(size: size, isVisible: isVisible, hoverOpacity: hoverOpacity))
    }
}
