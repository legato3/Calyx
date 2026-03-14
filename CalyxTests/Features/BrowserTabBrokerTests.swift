//
//  BrowserTabBrokerTests.swift
//  CalyxTests
//
//  Tests for BrowserTabBroker: app-level resolver for browser tabs across windows.
//
//  Coverage:
//  - resolveTab returns nil when appDelegate is nil
//  - resolveTab(nil) returns nil when no key window exists
//  - resolveTab with unknown UUID returns nil
//  - listTabs returns empty when appDelegate is nil
//  - listTabs returns empty when no browser tabs exist
//  - createTab returns nil when appDelegate is nil
//

import XCTest
@testable import Calyx

@MainActor
final class BrowserTabBrokerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT() -> BrowserTabBroker {
        BrowserTabBroker()
    }

    // ==================== resolveTab ====================

    func test_should_return_nil_when_resolveTab_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()
        XCTAssertNil(sut.appDelegate, "Precondition: appDelegate should be nil")

        // When: resolveTab with a specific UUID
        let result = sut.resolveTab(UUID())

        // Then: returns nil because there are no windows to search
        XCTAssertNil(result, "resolveTab should return nil when appDelegate is nil")
    }

    func test_should_return_nil_when_resolveTab_nil_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()

        // When: resolveTab(nil) — requesting active browser tab in key window
        let result = sut.resolveTab(nil)

        // Then: returns nil because there is no key window
        XCTAssertNil(result, "resolveTab(nil) should return nil when appDelegate is nil")
    }

    func test_should_return_nil_when_resolveTab_with_unknown_uuid() {
        // Given: broker with no appDelegate
        let sut = makeSUT()
        let unknownID = UUID()

        // When: resolveTab with an ID that doesn't match any tab
        let result = sut.resolveTab(unknownID)

        // Then: returns nil
        XCTAssertNil(result, "resolveTab should return nil for unknown tab ID")
    }

    // ==================== listTabs ====================

    func test_should_return_empty_when_listTabs_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()

        // When: listing all browser tabs
        let result = sut.listTabs()

        // Then: returns empty array because there are no windows
        XCTAssertTrue(result.isEmpty, "listTabs should return empty when appDelegate is nil")
    }

    // ==================== createTab ====================

    func test_should_return_nil_when_createTab_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()
        let url = URL(string: "https://example.com")!

        // When: attempting to create a browser tab
        let result = sut.createTab(url: url)

        // Then: returns nil because there is no key window to create it in
        XCTAssertNil(result, "createTab should return nil when appDelegate is nil")
    }

    // ==================== Initial State ====================

    func test_should_have_nil_appDelegate_after_init() {
        // Given & When: fresh broker
        let sut = makeSUT()

        // Then: appDelegate is nil by default (weak reference, not set)
        XCTAssertNil(sut.appDelegate,
                     "BrowserTabBroker should have nil appDelegate after initialization")
    }
}
