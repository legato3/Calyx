//
//  BrowserToolHandlerTests.swift
//  CalyxTests
//
//  Tests for BrowserToolHandler: MCP tool dispatch layer for browser scripting.
//
//  Coverage:
//  - isRestrictedForEval static method (auth URL detection)
//  - handleTool when scripting is disabled
//  - handleTool with unknown tool name
//  - handleTool browser_list with no tabs (nil appDelegate)
//  - BrowserToolResult struct construction
//

import XCTest
@testable import Calyx

@MainActor
final class BrowserToolHandlerTests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "browserScriptingEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "browserScriptingEnabled")
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSUT() -> BrowserToolHandler {
        let broker = BrowserTabBroker()
        return BrowserToolHandler(broker: broker)
    }

    // ==================== isRestrictedForEval ====================

    func test_should_return_true_when_url_contains_login_path() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/login"),
            "/login path should be restricted"
        )
    }

    func test_should_return_true_when_url_contains_auth_callback_path() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/auth/callback"),
            "/auth/callback path should be restricted"
        )
    }

    func test_should_return_true_when_url_contains_oauth_authorize_path() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/oauth/authorize"),
            "/oauth/authorize path should be restricted"
        )
    }

    func test_should_return_true_when_url_contains_signin_path() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/signin"),
            "/signin path should be restricted"
        )
    }

    func test_should_return_false_when_url_is_root_path() {
        XCTAssertFalse(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/"),
            "/ root path should not be restricted"
        )
    }

    func test_should_return_false_when_url_is_dashboard_path() {
        XCTAssertFalse(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/dashboard"),
            "/dashboard path should not be restricted"
        )
    }

    func test_should_return_true_when_url_contains_LOGIN_uppercase() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/LOGIN"),
            "/LOGIN (uppercase) should be restricted (case-insensitive)"
        )
    }

    func test_should_return_false_when_url_is_settings_path() {
        XCTAssertFalse(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/settings"),
            "/settings path should not be restricted"
        )
    }

    func test_should_return_true_when_url_contains_mixed_case_OAuth() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/OAuth/redirect"),
            "/OAuth (mixed case) should be restricted (case-insensitive)"
        )
    }

    func test_should_return_true_when_url_contains_SignIn_mixed_case() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/SignIn"),
            "/SignIn (mixed case) should be restricted (case-insensitive)"
        )
    }

    func test_should_return_true_when_url_contains_auth_in_middle_of_path() {
        XCTAssertTrue(
            BrowserToolHandler.isRestrictedForEval(url: "https://accounts.google.com/o/oauth2/auth"),
            "URL with /auth in deep path should be restricted"
        )
    }

    func test_should_return_false_when_url_has_no_restricted_segment() {
        XCTAssertFalse(
            BrowserToolHandler.isRestrictedForEval(url: "https://example.com/api/users"),
            "/api/users path should not be restricted"
        )
    }

    // ==================== handleTool: scripting disabled ====================

    func test_should_return_error_when_scripting_disabled_for_browser_open() async {
        // Given: scripting is explicitly disabled
        UserDefaults.standard.set(false, forKey: "browserScriptingEnabled")
        let sut = makeSUT()

        // When: any tool is called
        let result = await sut.handleTool(name: "browser_open", arguments: ["url": "https://example.com"])

        // Then: returns error indicating scripting is not enabled
        XCTAssertTrue(result.isError, "Should return error when scripting is disabled")
        XCTAssertTrue(
            result.text.lowercased().contains("not enabled") || result.text.lowercased().contains("disabled"),
            "Error text should indicate scripting is not enabled, got: \(result.text)"
        )
    }

    func test_should_return_error_when_scripting_disabled_for_browser_snapshot() async {
        // Given: scripting key not set (defaults to false)
        let sut = makeSUT()

        // When: snapshot tool is called
        let result = await sut.handleTool(name: "browser_snapshot", arguments: nil)

        // Then: returns error
        XCTAssertTrue(result.isError, "Should return error when scripting key is unset (defaults to false)")
    }

    func test_should_return_error_when_scripting_disabled_for_browser_eval() async {
        // Given: scripting is disabled
        UserDefaults.standard.set(false, forKey: "browserScriptingEnabled")
        let sut = makeSUT()

        // When: eval tool is called
        let result = await sut.handleTool(name: "browser_eval", arguments: ["code": "1+1"])

        // Then: returns error
        XCTAssertTrue(result.isError, "Should return error when scripting is disabled for eval")
    }

    // ==================== handleTool: unknown tool ====================

    func test_should_return_error_when_unknown_tool_name() async {
        // Given: scripting is enabled
        UserDefaults.standard.set(true, forKey: "browserScriptingEnabled")
        let sut = makeSUT()

        // When: unknown tool name is used
        let result = await sut.handleTool(name: "browser_nonexistent", arguments: nil)

        // Then: returns error mentioning unknown tool
        XCTAssertTrue(result.isError, "Should return error for unknown tool")
        XCTAssertTrue(
            result.text.lowercased().contains("unknown"),
            "Error text should mention 'unknown', got: \(result.text)"
        )
    }

    func test_should_return_error_when_completely_invalid_tool_name() async {
        // Given: scripting is enabled
        UserDefaults.standard.set(true, forKey: "browserScriptingEnabled")
        let sut = makeSUT()

        // When: completely invalid tool name
        let result = await sut.handleTool(name: "not_a_browser_tool", arguments: nil)

        // Then: returns error
        XCTAssertTrue(result.isError, "Should return error for non-browser tool name")
    }

    // ==================== handleTool: browser_list with no tabs ====================

    func test_should_return_empty_list_when_browser_list_with_no_app_delegate() async {
        // Given: scripting is enabled, broker has no appDelegate
        UserDefaults.standard.set(true, forKey: "browserScriptingEnabled")
        let sut = makeSUT()

        // When: browser_list is called
        let result = await sut.handleTool(name: "browser_list", arguments: nil)

        // Then: returns a result (not an error) with empty list representation
        XCTAssertFalse(result.isError, "browser_list with no tabs should not be an error")
    }

    // ==================== BrowserToolResult ====================

    func test_should_create_BrowserToolResult_with_text_and_isError_false() {
        let result = BrowserToolResult(text: "success", isError: false)
        XCTAssertEqual(result.text, "success")
        XCTAssertFalse(result.isError)
    }

    func test_should_create_BrowserToolResult_with_text_and_isError_true() {
        let result = BrowserToolResult(text: "something went wrong", isError: true)
        XCTAssertEqual(result.text, "something went wrong")
        XCTAssertTrue(result.isError)
    }

    func test_should_create_BrowserToolResult_with_empty_text() {
        let result = BrowserToolResult(text: "", isError: false)
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.isError)
    }

    func test_should_create_BrowserToolResult_with_multiline_text() {
        let multiline = "line1\nline2\nline3"
        let result = BrowserToolResult(text: multiline, isError: false)
        XCTAssertEqual(result.text, multiline)
    }

    // ==================== isScriptingEnabled property ====================

    func test_should_return_false_when_browserScriptingEnabled_not_set() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isScriptingEnabled,
                       "isScriptingEnabled should be false when UserDefaults key is not set")
    }

    func test_should_return_true_when_browserScriptingEnabled_is_true() {
        UserDefaults.standard.set(true, forKey: "browserScriptingEnabled")
        let sut = makeSUT()
        XCTAssertTrue(sut.isScriptingEnabled,
                      "isScriptingEnabled should be true when UserDefaults key is true")
    }

    func test_should_return_false_when_browserScriptingEnabled_is_false() {
        UserDefaults.standard.set(false, forKey: "browserScriptingEnabled")
        let sut = makeSUT()
        XCTAssertFalse(sut.isScriptingEnabled,
                       "isScriptingEnabled should be false when UserDefaults key is false")
    }

    // ==================== init ====================

    func test_should_store_broker_reference() {
        let broker = BrowserTabBroker()
        let sut = BrowserToolHandler(broker: broker)
        XCTAssertTrue(sut.broker === broker,
                      "BrowserToolHandler should store the provided broker reference")
    }
}
