import Foundation
import GhosttyKit

/// Typed wrappers for ghostty notifications.
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

struct GhosttyResizeSplitEvent {
    let surfaceView: SurfaceView
    let resize: ghostty_action_resize_split_s

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let resize = notification.userInfo?["resize"] as? ghostty_action_resize_split_s
        else { return nil }
        return GhosttyResizeSplitEvent(surfaceView: surfaceView, resize: resize)
    }
}

struct GhosttyGotoTabEvent {
    let surfaceView: SurfaceView?
    let tab: Int32

    static func from(_ notification: Notification) -> Self? {
        guard let rawValue = notification.userInfo?["tab"] as? Int32 else { return nil }
        return GhosttyGotoTabEvent(
            surfaceView: notification.object as? SurfaceView,
            tab: rawValue
        )
    }
}

struct GhosttyCloseTabEvent {
    let surfaceView: SurfaceView
    let mode: ghostty_action_close_tab_mode_e?

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        let mode = notification.userInfo?["mode"] as? ghostty_action_close_tab_mode_e
        return GhosttyCloseTabEvent(surfaceView: surfaceView, mode: mode)
    }
}

struct GhosttyShowChildExitedEvent {
    let surfaceView: SurfaceView
    let exitCode: UInt32
    let runtimeMs: UInt32

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        let exitCode = notification.userInfo?["exit_code"] as? UInt32 ?? 0
        let runtimeMs = notification.userInfo?["runtime_ms"] as? UInt32 ?? 0
        return GhosttyShowChildExitedEvent(surfaceView: surfaceView, exitCode: exitCode, runtimeMs: runtimeMs)
    }
}

struct GhosttyCommandFinishedEvent {
    let surfaceView: SurfaceView
    let exitCode: Int?
    let durationNanoseconds: UInt64

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        let durationNanoseconds = notification.userInfo?["duration_ns"] as? UInt64 ?? 0
        let exitCodeValue = notification.userInfo?["exit_code"] as? Int
        return GhosttyCommandFinishedEvent(
            surfaceView: surfaceView,
            exitCode: exitCodeValue,
            durationNanoseconds: durationNanoseconds
        )
    }
}

struct GhosttyRendererHealthEvent {
    let surfaceView: SurfaceView
    let health: ghostty_action_renderer_health_e

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let health = notification.userInfo?["health"] as? ghostty_action_renderer_health_e
        else { return nil }
        return GhosttyRendererHealthEvent(surfaceView: surfaceView, health: health)
    }
}

struct GhosttyColorChangeEvent {
    let surfaceView: SurfaceView
    let change: ghostty_action_color_change_s

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let change = notification.userInfo?["change"] as? ghostty_action_color_change_s
        else { return nil }
        return GhosttyColorChangeEvent(surfaceView: surfaceView, change: change)
    }
}

struct GhosttyInitialSizeEvent {
    let surfaceView: SurfaceView
    let width: UInt32
    let height: UInt32

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let width = notification.userInfo?["width"] as? UInt32,
              let height = notification.userInfo?["height"] as? UInt32
        else { return nil }
        return GhosttyInitialSizeEvent(surfaceView: surfaceView, width: width, height: height)
    }
}

struct GhosttySizeLimitEvent {
    let surfaceView: SurfaceView
    let minWidth: UInt32
    let minHeight: UInt32
    let maxWidth: UInt32
    let maxHeight: UInt32

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView else { return nil }
        return GhosttySizeLimitEvent(
            surfaceView: surfaceView,
            minWidth: notification.userInfo?["min_width"] as? UInt32 ?? 0,
            minHeight: notification.userInfo?["min_height"] as? UInt32 ?? 0,
            maxWidth: notification.userInfo?["max_width"] as? UInt32 ?? 0,
            maxHeight: notification.userInfo?["max_height"] as? UInt32 ?? 0
        )
    }
}

struct GhosttyDesktopNotificationEvent {
    let surfaceView: SurfaceView
    let title: String
    let body: String

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let title = notification.userInfo?["title"] as? String
        else { return nil }
        let body = notification.userInfo?["body"] as? String ?? ""
        return GhosttyDesktopNotificationEvent(surfaceView: surfaceView, title: title, body: body)
    }
}

struct GhosttyConfirmClipboardEvent {
    let surfaceView: SurfaceView
    let contents: String
    let surface: ghostty_surface_t
    let request: ghostty_clipboard_request_e
    let state: UnsafeMutableRawPointer?

    static func from(_ notification: Notification) -> Self? {
        guard let surfaceView = notification.object as? SurfaceView,
              let contents = notification.userInfo?["contents"] as? String,
              let surface = notification.userInfo?["surface"] as? ghostty_surface_t,
              let request = notification.userInfo?["request"] as? ghostty_clipboard_request_e
        else { return nil }
        let state = notification.userInfo?["state"] as? UnsafeMutableRawPointer
        return GhosttyConfirmClipboardEvent(
            surfaceView: surfaceView,
            contents: contents,
            surface: surface,
            request: request,
            state: state
        )
    }
}

struct GhosttyNewTabEvent {
    let surfaceView: SurfaceView?
    let inheritedConfig: ghostty_surface_config_s?

    static func from(_ notification: Notification) -> Self? {
        return GhosttyNewTabEvent(
            surfaceView: notification.object as? SurfaceView,
            inheritedConfig: notification.userInfo?["inherited_config"] as? ghostty_surface_config_s
        )
    }
}

struct CalyxIPCLaunchWorkflowEvent {
    let roleNames: [String]
    let autoStart: Bool
    let sessionName: String
    let initialTask: String
    let runtime: AgentRuntimeConfiguration

    static func from(_ notification: Notification) -> Self? {
        guard let roleNames = notification.userInfo?["roleNames"] as? [String],
              !roleNames.isEmpty
        else { return nil }
        return CalyxIPCLaunchWorkflowEvent(
            roleNames: roleNames,
            autoStart: (notification.userInfo?["autoStart"] as? Bool) ?? false,
            sessionName: (notification.userInfo?["sessionName"] as? String) ?? "",
            initialTask: (notification.userInfo?["initialTask"] as? String) ?? "",
            runtime: AgentRuntimeConfiguration.from(userInfo: notification.userInfo)
        )
    }
}
