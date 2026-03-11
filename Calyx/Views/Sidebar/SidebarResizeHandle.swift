// SidebarResizeHandle.swift
// Calyx
//
// Draggable handle for resizing the sidebar.

import SwiftUI
import AppKit

struct SidebarResizeHandle: View {
    let currentWidth: CGFloat
    let onWidthChanged: (CGFloat) -> Void
    let onDragCommitted: () -> Void

    @State private var isHovering = false

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering && !isHovering {
                    NSCursor.resizeLeftRight.push()
                    isHovering = true
                } else if !hovering && isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let maxAllowed = WindowSession.maxSidebarWidth
                        let newWidth = max(
                            WindowSession.minSidebarWidth,
                            min(maxAllowed, currentWidth + value.translation.width)
                        )
                        onWidthChanged(newWidth)
                    }
                    .onEnded { value in
                        let maxAllowed = WindowSession.maxSidebarWidth
                        let newWidth = max(
                            WindowSession.minSidebarWidth,
                            min(maxAllowed, currentWidth + value.translation.width)
                        )
                        onWidthChanged(newWidth)
                        onDragCommitted()
                    }
            )
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}
