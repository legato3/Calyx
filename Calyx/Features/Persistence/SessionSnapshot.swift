// SessionSnapshot.swift
// Calyx
//
// Codable DTOs for session persistence. Off-main-thread safe.

import Foundation

struct SessionSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let windows: [WindowSnapshot]

    init(schemaVersion: Int = Self.currentSchemaVersion, windows: [WindowSnapshot] = []) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

struct WindowSnapshot: Codable, Equatable {
    let id: UUID
    let frame: CGRect
    let groups: [TabGroupSnapshot]
    let activeGroupID: UUID?

    init(id: UUID = UUID(), frame: CGRect = .zero, groups: [TabGroupSnapshot] = [], activeGroupID: UUID? = nil) {
        self.id = id
        self.frame = frame
        self.groups = groups
        self.activeGroupID = activeGroupID
    }

    func clampedToScreen(screenFrame: CGRect) -> WindowSnapshot {
        var f = frame
        if f.origin.x < screenFrame.origin.x { f.origin.x = screenFrame.origin.x }
        if f.origin.y < screenFrame.origin.y { f.origin.y = screenFrame.origin.y }
        if f.maxX > screenFrame.maxX { f.origin.x = screenFrame.maxX - f.width }
        if f.maxY > screenFrame.maxY { f.origin.y = screenFrame.maxY - f.height }
        f.size.width = max(f.size.width, 400)
        f.size.height = max(f.size.height, 300)
        return WindowSnapshot(id: id, frame: f, groups: groups, activeGroupID: activeGroupID)
    }
}

struct TabGroupSnapshot: Codable, Equatable {
    let id: UUID
    let name: String
    let color: String?
    let tabs: [TabSnapshot]
    let activeTabID: UUID?

    init(id: UUID = UUID(), name: String = "Default", color: String? = nil, tabs: [TabSnapshot] = [], activeTabID: UUID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

struct TabSnapshot: Codable, Equatable {
    let id: UUID
    let title: String
    let pwd: String?
    let splitTree: SplitTree
    let browserURL: URL?

    init(id: UUID = UUID(), title: String = "Terminal", pwd: String? = nil, splitTree: SplitTree = SplitTree(), browserURL: URL? = nil) {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.splitTree = splitTree
        self.browserURL = browserURL
    }
}

// MARK: - Conversion to/from Runtime Models

extension AppSession {
    func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            windows: windows.map { $0.snapshot() }
        )
    }
}

extension WindowSession {
    func snapshot() -> WindowSnapshot {
        WindowSnapshot(
            id: id,
            frame: .zero, // Frame is set by the caller from NSWindow
            groups: groups.map { $0.snapshot() },
            activeGroupID: activeGroupID
        )
    }
}

extension TabGroup {
    func snapshot() -> TabGroupSnapshot {
        TabGroupSnapshot(
            id: id,
            name: name,
            color: color.rawValue,
            tabs: tabs.map { $0.snapshot() },
            activeTabID: activeTabID
        )
    }
}

extension Tab {
    func snapshot() -> TabSnapshot {
        let url: URL? = switch content {
        case .terminal: nil
        case .browser(url: let url): url
        }
        return TabSnapshot(
            id: id,
            title: title,
            pwd: pwd,
            splitTree: splitTree,
            browserURL: url
        )
    }

    convenience init(snapshot: TabSnapshot) {
        let content: TabContent = if let url = snapshot.browserURL {
            .browser(url: url)
        } else {
            .terminal
        }
        self.init(
            id: snapshot.id,
            title: snapshot.title,
            pwd: snapshot.pwd,
            splitTree: snapshot.splitTree,
            content: content
        )
    }
}
