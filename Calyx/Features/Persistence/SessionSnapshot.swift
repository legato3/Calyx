// SessionSnapshot.swift
// Calyx
//
// Codable DTOs for session persistence. Off-main-thread safe.

import Foundation

struct SessionSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 4

    let schemaVersion: Int
    let windows: [WindowSnapshot]
    /// Named workspace tag. `nil` for the auto-save slot; set when saving as a named workspace.
    var workspaceName: String?

    init(schemaVersion: Int = Self.currentSchemaVersion,
         windows: [WindowSnapshot] = [],
         workspaceName: String? = nil) {
        self.schemaVersion = schemaVersion
        self.windows = windows
        self.workspaceName = workspaceName
    }
}

extension SessionSnapshot {
    /// Stepwise migration pipeline. Add a new step here when bumping currentSchemaVersion.
    static func migrate(_ snapshot: SessionSnapshot) -> SessionSnapshot {
        var current = snapshot
        if current.schemaVersion < 2 { current = migrateV1ToV2(current) }
        if current.schemaVersion < 3 { current = migrateV2ToV3(current) }
        if current.schemaVersion < 4 { current = migrateV3ToV4(current) }
        return SessionSnapshot(schemaVersion: currentSchemaVersion, windows: current.windows)
    }

    // v1 → v2: no structural changes; optional field defaults handled by Decodable.
    private static func migrateV1ToV2(_ s: SessionSnapshot) -> SessionSnapshot {
        SessionSnapshot(schemaVersion: 2, windows: s.windows)
    }

    // v2 → v3: no structural changes; optional field defaults handled by Decodable.
    private static func migrateV2ToV3(_ s: SessionSnapshot) -> SessionSnapshot {
        SessionSnapshot(schemaVersion: 3, windows: s.windows)
    }

    // v3 → v4: no structural changes; optional field defaults handled by Decodable.
    private static func migrateV3ToV4(_ s: SessionSnapshot) -> SessionSnapshot {
        SessionSnapshot(schemaVersion: 4, windows: s.windows)
    }
}

struct WindowSnapshot: Codable, Equatable {
    let id: UUID
    let frame: CGRect
    let groups: [TabGroupSnapshot]
    let activeGroupID: UUID?
    let showSidebar: Bool
    let sidebarWidth: CGFloat

    private enum CodingKeys: String, CodingKey {
        case id, frame, groups, activeGroupID, showSidebar, sidebarWidth
    }

    init(id: UUID = UUID(), frame: CGRect = .zero, groups: [TabGroupSnapshot] = [], activeGroupID: UUID? = nil, showSidebar: Bool = true, sidebarWidth: CGFloat = SidebarLayout.defaultWidth) {
        self.id = id
        self.frame = frame
        self.groups = groups
        self.activeGroupID = activeGroupID
        self.showSidebar = showSidebar
        self.sidebarWidth = sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = try container.decode(CGRect.self, forKey: .frame)
        groups = try container.decode([TabGroupSnapshot].self, forKey: .groups)
        activeGroupID = try container.decodeIfPresent(UUID.self, forKey: .activeGroupID)
        showSidebar = try container.decodeIfPresent(Bool.self, forKey: .showSidebar) ?? true
        let rawWidth = try container.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? SidebarLayout.defaultWidth
        sidebarWidth = SidebarLayout.clampWidth(rawWidth)
    }

    func clampedToScreen(screenFrame: CGRect) -> WindowSnapshot {
        // If frame doesn't intersect screen at all, center it
        if !screenFrame.intersects(frame) {
            let w = max(frame.width, 400)
            let h = max(frame.height, 300)
            let centered = CGRect(
                x: screenFrame.midX - w / 2,
                y: screenFrame.midY - h / 2,
                width: w, height: h
            )
            return WindowSnapshot(id: id, frame: centered, groups: groups, activeGroupID: activeGroupID, showSidebar: showSidebar, sidebarWidth: sidebarWidth)
        }

        var f = frame
        // Enforce minimum size first so clamping uses correct dimensions
        f.size.width = max(f.size.width, 400)
        f.size.height = max(f.size.height, 300)
        if f.origin.x < screenFrame.origin.x { f.origin.x = screenFrame.origin.x }
        if f.origin.y < screenFrame.origin.y { f.origin.y = screenFrame.origin.y }
        if f.maxX > screenFrame.maxX { f.origin.x = screenFrame.maxX - f.width }
        if f.maxY > screenFrame.maxY { f.origin.y = screenFrame.maxY - f.height }
        return WindowSnapshot(id: id, frame: f, groups: groups, activeGroupID: activeGroupID, showSidebar: showSidebar, sidebarWidth: sidebarWidth)
    }
}

struct TabGroupSnapshot: Codable, Equatable {
    let id: UUID
    let name: String
    let color: String?
    let tabs: [TabSnapshot]
    let activeTabID: UUID?
    let isCollapsed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, color, tabs, activeTabID, isCollapsed
    }

    init(id: UUID = UUID(), name: String = "Default", color: String? = nil, tabs: [TabSnapshot] = [], activeTabID: UUID? = nil, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.isCollapsed = isCollapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        tabs = try container.decode([TabSnapshot].self, forKey: .tabs)
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
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
            activeGroupID: activeGroupID,
            showSidebar: showSidebar,
            sidebarWidth: sidebarWidth
        )
    }
}

extension TabGroup {
    func snapshot() -> TabGroupSnapshot {
        TabGroupSnapshot(
            id: id,
            name: name,
            color: color.rawValue,
            tabs: tabs.compactMap { $0.snapshot() },
            activeTabID: activeTabID,
            isCollapsed: isCollapsed
        )
    }
}

extension Tab {
    func snapshot() -> TabSnapshot? {
        switch content {
        case .diff:
            return nil  // Diff tabs are not persisted
        case .terminal:
            return TabSnapshot(id: id, title: title, pwd: pwd, splitTree: splitTree, browserURL: nil)
        case .browser(let url):
            return TabSnapshot(id: id, title: title, pwd: pwd, splitTree: splitTree, browserURL: url)
        }
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

extension TabGroup {
    convenience init(snapshot: TabGroupSnapshot) {
        let tabs = snapshot.tabs.map { Tab(snapshot: $0) }
        let color = TabGroupColor(rawValue: snapshot.color ?? "blue") ?? .blue
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            color: color,
            isCollapsed: snapshot.isCollapsed,
            tabs: tabs,
            activeTabID: snapshot.activeTabID
        )
    }
}

extension WindowSession {
    convenience init(snapshot: WindowSnapshot) {
        let groups = snapshot.groups.map { TabGroup(snapshot: $0) }
        self.init(
            id: snapshot.id,
            groups: groups,
            activeGroupID: snapshot.activeGroupID,
            showSidebar: snapshot.showSidebar,
            sidebarWidth: snapshot.sidebarWidth
        )
    }
}
