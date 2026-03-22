import Foundation
import GhosttyKit

/// Typed wrappers for the 5 highest-traffic ghostty notifications.
/// Each type decodes from a raw Notification so handlers avoid untyped userInfo access.

struct GhosttyCloseSurfaceEvent {
    let surfaceView: SurfaceView
    let processAlive: Bool

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        let processAlive = notification.userInfo?["process_alive"] as? Bool ?? true
        return GhosttyCloseSurfaceEvent(surfaceView: surfaceView, processAlive: processAlive)
    }
}

struct GhosttyNewSplitEvent {
    let surfaceView: SurfaceView
    let direction: ghostty_action_split_direction_e
    let inheritedConfig: ghostty_surface_config_s?

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e
            ?? GHOSTTY_SPLIT_DIRECTION_RIGHT
        let inheritedConfig = notification.userInfo?["inherited_config"] as? ghostty_surface_config_s
        return GhosttyNewSplitEvent(
            surfaceView: surfaceView,
            direction: direction,
            inheritedConfig: inheritedConfig
        )
    }
}

struct GhosttySetTitleEvent {
    let surfaceView: SurfaceView
    let title: String

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let title = notification.userInfo?["title"] as? String else { return nil }
        return GhosttySetTitleEvent(surfaceView: surfaceView, title: title)
    }
}

struct GhosttySetPwdEvent {
    let surfaceView: SurfaceView
    let pwd: String

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let pwd = notification.userInfo?["pwd"] as? String else { return nil }
        return GhosttySetPwdEvent(surfaceView: surfaceView, pwd: pwd)
    }
}

struct GhosttyGotoSplitEvent {
    let surfaceView: SurfaceView
    let direction: ghostty_action_goto_split_e

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        let direction = notification.userInfo?["direction"] as? ghostty_action_goto_split_e
            ?? GHOSTTY_GOTO_SPLIT_NEXT
        return GhosttyGotoSplitEvent(surfaceView: surfaceView, direction: direction)
    }
}
