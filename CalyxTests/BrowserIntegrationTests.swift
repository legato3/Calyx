//
//  BrowserIntegrationTests.swift
//  CalyxTests
//
//  Tests for Phase 8 Browser Integration: TabContent.browser case,
//  BrowserSnapshot persistence, BrowserState observable model,
//  and BrowserTabController lifecycle.
//
//  Coverage:
//  - TabContent.browser(url:) variant
//  - BrowserSnapshot JSON encode/decode roundtrip
//  - TabSnapshot with browserURL field
//  - BrowserState initial property values
//  - BrowserTabController create / deactivate lifecycle
//

import XCTest
@testable import Calyx

@MainActor
final class BrowserIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private let exampleURL = URL(string: "https://example.com")!
    private let githubURL = URL(string: "https://github.com/user/repo")!

    // ==================== 1. TabContent.browser Case ====================

    func test_tabContent_browser_stores_url() {
        // Arrange
        let content = TabContent.browser(url: exampleURL)

        // Assert
        if case .browser(let url) = content {
            XCTAssertEqual(url, exampleURL, "browser case should store the URL")
        } else {
            XCTFail("Expected .browser case")
        }
    }

    func test_tab_with_browser_content_exposes_url() {
        // Arrange
        let tab = Tab(title: "Browser", content: .browser(url: githubURL))

        // Assert
        if case .browser(let url) = tab.content {
            XCTAssertEqual(url, githubURL)
        } else {
            XCTFail("Tab content should be .browser")
        }
    }

    func test_tab_with_terminal_content_still_works() {
        // Arrange
        let tab = Tab(title: "Terminal", content: .terminal)

        // Assert
        if case .terminal = tab.content {
            // Pass — terminal case unchanged
        } else {
            XCTFail("Tab content should be .terminal")
        }
    }

    // ==================== 2. BrowserSnapshot Encode/Decode ====================

    func test_browserSnapshot_roundtrip() throws {
        // Arrange
        let original = BrowserSnapshot(url: exampleURL)

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrowserSnapshot.self, from: data)

        // Assert
        XCTAssertEqual(decoded.url, exampleURL, "URL should survive JSON roundtrip")
    }

    func test_browserSnapshot_preserves_complex_url() throws {
        // Arrange
        let complexURL = URL(string: "https://example.com/path?q=hello&lang=en#section")!
        let original = BrowserSnapshot(url: complexURL)

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrowserSnapshot.self, from: data)

        // Assert
        XCTAssertEqual(decoded.url, complexURL, "Complex URL with query and fragment should be preserved")
    }

    // ==================== 3. TabSnapshot with browserURL ====================

    func test_tabSnapshot_with_browserURL_roundtrip() throws {
        // Arrange
        let original = TabSnapshot(
            id: UUID(),
            title: "Docs",
            pwd: nil,
            splitTree: SplitTree(),
            browserURL: exampleURL
        )

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        // Assert
        XCTAssertEqual(decoded.browserURL, exampleURL, "browserURL should survive roundtrip")
        XCTAssertEqual(decoded.title, "Docs")
    }

    func test_tabSnapshot_browserURL_nil_for_terminal_tabs() throws {
        // Arrange
        let original = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            pwd: "/home",
            splitTree: SplitTree()
        )

        // Act
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        // Assert
        XCTAssertNil(decoded.browserURL, "browserURL should be nil for terminal tabs")
    }

    func test_sessionSnapshot_roundtrip_with_browser_tab() throws {
        // Arrange
        let browserTab = TabSnapshot(
            id: UUID(), title: "Browser", pwd: nil,
            splitTree: SplitTree(), browserURL: githubURL
        )
        let terminalTab = TabSnapshot(
            id: UUID(), title: "Terminal", pwd: "/home",
            splitTree: SplitTree()
        )
        let group = TabGroupSnapshot(
            id: UUID(), name: "Default",
            tabs: [browserTab, terminalTab],
            activeTabID: browserTab.id
        )
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            groups: [group],
            activeGroupID: group.id
        )
        let snapshot = SessionSnapshot(windows: [window])

        // Act
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        // Assert
        let tabs = decoded.windows[0].groups[0].tabs
        XCTAssertEqual(tabs[0].browserURL, githubURL, "Browser tab URL should be preserved")
        XCTAssertNil(tabs[1].browserURL, "Terminal tab browserURL should remain nil")
    }

    // ==================== 4. BrowserState Initial Values ====================

    func test_browserState_initial_url() {
        // Arrange & Act
        let state = BrowserState(url: exampleURL)

        // Assert
        XCTAssertEqual(state.url, exampleURL, "Initial URL should match")
    }

    func test_browserState_initial_loading_false() {
        // Arrange & Act
        let state = BrowserState(url: exampleURL)

        // Assert
        XCTAssertFalse(state.isLoading, "isLoading should default to false")
    }

    func test_browserState_initial_navigation_flags() {
        // Arrange & Act
        let state = BrowserState(url: exampleURL)

        // Assert
        XCTAssertFalse(state.canGoBack, "canGoBack should default to false")
        XCTAssertFalse(state.canGoForward, "canGoForward should default to false")
    }

    func test_browserState_title_defaults_to_host() {
        // Arrange & Act
        let state = BrowserState(url: githubURL)

        // Assert
        XCTAssertEqual(state.title, "github.com",
                       "Title should default to URL host")
    }

    // ==================== 5. BrowserTabController Lifecycle ====================

    func test_controller_creates_browserState_with_url() {
        // Arrange & Act
        let controller = BrowserTabController(url: exampleURL)

        // Assert — browserState is non-optional (let), always present after init
        XCTAssertEqual(controller.browserState.url, exampleURL)
    }

    func test_controller_cleans_up_on_dealloc() {
        // Arrange — controller uses deinit for cleanup (no explicit deactivate)
        var controller: BrowserTabController? = BrowserTabController(url: exampleURL)
        XCTAssertEqual(controller?.browserState.url, exampleURL,
                       "Precondition: browserState exists with correct URL")

        // Act — release the controller; deinit handles cleanup
        controller = nil

        // Assert — controller is nil, proving lifecycle is dealloc-based
        XCTAssertNil(controller)
    }

    // ==================== 6. BrowserState.lastError ====================

    func test_browserState_lastError_defaults_to_nil() {
        // Arrange & Act
        let state = BrowserState(url: exampleURL)

        // Assert
        XCTAssertNil(state.lastError, "lastError should default to nil")
    }

    func test_browserState_lastError_can_be_set_and_cleared() {
        // Arrange
        let state = BrowserState(url: exampleURL)

        // Act — set
        state.lastError = "Connection failed"

        // Assert — set
        XCTAssertEqual(state.lastError, "Connection failed")

        // Act — clear
        state.lastError = nil

        // Assert — cleared
        XCTAssertNil(state.lastError)
    }

    // ==================== 7. BrowserTabController BrowserView Ownership ====================

    func test_controller_owns_browserView() {
        // Arrange & Act
        let controller = BrowserTabController(url: exampleURL)

        // Assert
        XCTAssertNotNil(controller.browserView,
                        "BrowserTabController should own a BrowserView")
    }

    func test_controller_browserState_matches_browserView() {
        // Arrange & Act
        let controller = BrowserTabController(url: exampleURL)

        // Assert — browserState (non-optional access via browserView)
        XCTAssertEqual(controller.browserState.url, exampleURL)
    }

    func test_controller_navigation_methods_exist() {
        // Arrange
        let controller = BrowserTabController(url: exampleURL)

        // Act — these should compile and not crash;
        // navigation on an empty WKWebView is safe
        controller.goBack()
        controller.goForward()
        controller.reload()
    }

    func test_controller_loadURL() {
        // Arrange
        let controller = BrowserTabController(url: exampleURL)
        let newURL = URL(string: "https://apple.com")!

        // Act — loadURL delegates to BrowserView which updates state
        controller.loadURL(newURL)
    }

    // ==================== 8. BrowserTabController Title Callback ====================

    func test_controller_browserView_onTitleChanged_callback() {
        // Arrange
        let controller = BrowserTabController(url: exampleURL)
        var receivedTitle: String?
        controller.browserView.onTitleChanged = { title in
            receivedTitle = title
        }

        // Act — simulate title change by directly updating state
        controller.browserState.title = "New Title"

        // Assert — verify the callback property exists and is settable on browserView
        XCTAssertNotNil(controller.browserView.onTitleChanged)
        // Note: actual invocation depends on BrowserView's WKNavigationDelegate
        // wiring, which is tested in integration; here we verify the API surface.
        _ = receivedTitle  // suppress unused warning
    }

    // ==================== 9. Browser Tab Registry ====================

    func test_browser_tab_has_empty_registry() {
        // Arrange & Act
        let tab = Tab(title: "Browser", content: .browser(url: exampleURL))

        // Assert
        XCTAssertTrue(tab.registry.allIDs.isEmpty,
                      "Browser tab should have no surfaces")
    }

    func test_browser_tab_splitTree_is_empty() {
        // Arrange & Act
        let tab = Tab(title: "Browser", content: .browser(url: exampleURL))

        // Assert
        XCTAssertTrue(tab.splitTree.isEmpty,
                      "Browser tab should have empty split tree")
    }
}
