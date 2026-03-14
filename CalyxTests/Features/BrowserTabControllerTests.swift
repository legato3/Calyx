//
//  BrowserTabControllerTests.swift
//  CalyxTests
//
//  Tests for BrowserTabController scriptable-browser extensions.
//
//  Coverage:
//  - snapshotGeneration initial value
//  - incrementSnapshotGeneration single and multiple increments
//  - Creation with correct URL
//  - onNavigationCommit callback default and assignment
//

import XCTest
@testable import Calyx

@MainActor
final class BrowserTabControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(url: URL = URL(string: "https://example.com")!) -> BrowserTabController {
        BrowserTabController(url: url)
    }

    // MARK: - snapshotGeneration

    func test_should_have_snapshotGeneration_initially_zero() {
        let sut = makeSUT()
        XCTAssertEqual(sut.snapshotGeneration, 0,
                       "snapshotGeneration should start at 0")
    }

    func test_should_increment_snapshotGeneration_by_one() {
        let sut = makeSUT()
        sut.incrementSnapshotGeneration()
        XCTAssertEqual(sut.snapshotGeneration, 1,
                       "snapshotGeneration should be 1 after single increment")
    }

    func test_should_increment_snapshotGeneration_multiple_times() {
        let sut = makeSUT()
        sut.incrementSnapshotGeneration()
        sut.incrementSnapshotGeneration()
        sut.incrementSnapshotGeneration()
        XCTAssertEqual(sut.snapshotGeneration, 3,
                       "snapshotGeneration should be 3 after three increments")
    }

    // MARK: - Creation

    func test_should_create_with_correct_url() {
        let url = URL(string: "https://developer.apple.com")!
        let sut = makeSUT(url: url)
        XCTAssertEqual(sut.browserState.url, url,
                       "BrowserTabController should store the provided URL in browserState")
    }

    // MARK: - onNavigationCommit

    func test_should_have_onNavigationCommit_nil_by_default() {
        let sut = makeSUT()
        XCTAssertNil(sut.onNavigationCommit,
                     "onNavigationCommit should be nil by default")
    }

    func test_should_allow_setting_onNavigationCommit_callback() {
        let sut = makeSUT()
        var callbackInvoked = false
        sut.onNavigationCommit = { callbackInvoked = true }

        XCTAssertNotNil(sut.onNavigationCommit,
                        "onNavigationCommit should be non-nil after assignment")

        sut.onNavigationCommit?()
        XCTAssertTrue(callbackInvoked,
                      "onNavigationCommit callback should be invocable after assignment")
    }
}
