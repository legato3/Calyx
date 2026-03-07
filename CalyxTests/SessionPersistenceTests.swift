import XCTest
@testable import Calyx

final class SessionPersistenceTests: XCTestCase {

    func test_encode_decode_roundtrip() throws {
        let tab1 = TabSnapshot(id: UUID(), title: "Tab 1", pwd: "/home", splitTree: SplitTree(leafID: UUID()))
        let tab2 = TabSnapshot(id: UUID(), title: "Tab 2", pwd: nil, splitTree: SplitTree())
        let group = TabGroupSnapshot(id: UUID(), name: "Default", tabs: [tab1, tab2], activeTabID: tab1.id)
        let window = WindowSnapshot(id: UUID(), frame: CGRect(x: 100, y: 100, width: 800, height: 600), groups: [group], activeGroupID: group.id)
        let snapshot = SessionSnapshot(windows: [window])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, SessionSnapshot.currentSchemaVersion)
        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].groups.count, 1)
        XCTAssertEqual(decoded.windows[0].groups[0].tabs.count, 2)
        XCTAssertEqual(decoded.windows[0].groups[0].tabs[0].title, "Tab 1")
        XCTAssertEqual(decoded.windows[0].groups[0].tabs[0].pwd, "/home")
        XCTAssertEqual(decoded.windows[0].groups[0].tabs[1].pwd, nil)
    }

    func test_corrupt_json_fails_gracefully() {
        let corrupt = Data("not json".utf8)
        let result = try? JSONDecoder().decode(SessionSnapshot.self, from: corrupt)
        XCTAssertNil(result, "Corrupt JSON should fail to decode")
    }

    func test_schema_version_preserved() throws {
        let snapshot = SessionSnapshot(schemaVersion: 42, windows: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 42)
    }

    func test_empty_snapshot_roundtrip() throws {
        let snapshot = SessionSnapshot(windows: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 0)
    }

    func test_window_frame_clamped_to_screen() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: -100, y: -50, width: 800, height: 600),
            groups: [],
            activeGroupID: nil
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = window.clampedToScreen(screenFrame: screen)

        XCTAssertGreaterThanOrEqual(clamped.frame.origin.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.frame.origin.y, 0)
    }

    func test_window_frame_min_size() {
        let window = WindowSnapshot(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = window.clampedToScreen(screenFrame: screen)

        XCTAssertGreaterThanOrEqual(clamped.frame.width, 400)
        XCTAssertGreaterThanOrEqual(clamped.frame.height, 300)
    }

    func test_snapshot_equality() {
        let id = UUID()
        let a = SessionSnapshot(windows: [WindowSnapshot(id: id)])
        let b = SessionSnapshot(windows: [WindowSnapshot(id: id)])
        XCTAssertEqual(a, b)
    }
}
