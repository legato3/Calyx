//
//  BrowserAutomationTests.swift
//  CalyxTests
//
//  Tests for BrowserAutomation (JS codegen) and BrowserAutomationError.
//
//  Coverage:
//  - BrowserAutomationError enum cases and LocalizedError conformance
//  - BrowserAutomation.wrap() IIFE structure
//  - BrowserAutomation.snapshot() accessibility tree JS generation
//  - BrowserAutomation.click/fill/type/press/select/check/uncheck JS generation
//  - BrowserAutomation.getText/getHTML JS generation
//  - BrowserAutomation.eval arbitrary JS wrapping
//  - BrowserAutomation.wait() Promise-based JS generation
//  - BrowserAutomation.clearRefs() ref cleanup JS
//  - BrowserAutomation.resolveSelector() @e1 ref resolution
//  - BrowserAutomation.parseResponse() JSON parsing
//  - Selector escaping with special characters
//

import XCTest
@testable import Calyx

// MARK: - BrowserAutomationError Tests

final class BrowserAutomationErrorTests: XCTestCase {

    // ==================== Error Case Existence ====================

    func test_scriptingDisabled_case_exists() {
        let error = BrowserAutomationError.scriptingDisabled
        XCTAssertNotNil(error)
    }

    func test_tabNotFound_case_stores_uuid() {
        let id = UUID()
        let error = BrowserAutomationError.tabNotFound(id)
        if case .tabNotFound(let storedID) = error {
            XCTAssertEqual(storedID, id)
        } else {
            XCTFail("Expected .tabNotFound case")
        }
    }

    func test_noActiveBrowserTab_case_exists() {
        let error = BrowserAutomationError.noActiveBrowserTab
        XCTAssertNotNil(error)
    }

    func test_evaluationFailed_case_stores_message() {
        let error = BrowserAutomationError.evaluationFailed("ReferenceError: x is not defined")
        if case .evaluationFailed(let msg) = error {
            XCTAssertEqual(msg, "ReferenceError: x is not defined")
        } else {
            XCTFail("Expected .evaluationFailed case")
        }
    }

    func test_invalidResponse_case_exists() {
        let error = BrowserAutomationError.invalidResponse
        XCTAssertNotNil(error)
    }

    func test_restrictedPage_case_stores_url() {
        let error = BrowserAutomationError.restrictedPage("https://accounts.google.com")
        if case .restrictedPage(let url) = error {
            XCTAssertEqual(url, "https://accounts.google.com")
        } else {
            XCTFail("Expected .restrictedPage case")
        }
    }

    func test_screenshotFailed_case_exists() {
        let error = BrowserAutomationError.screenshotFailed
        XCTAssertNotNil(error)
    }

    func test_timeout_case_exists() {
        let error = BrowserAutomationError.timeout
        XCTAssertNotNil(error)
    }

    // ==================== Error Protocol Conformance ====================

    func test_conforms_to_Error_protocol() {
        let error: Error = BrowserAutomationError.scriptingDisabled
        XCTAssertNotNil(error)
    }

    func test_conforms_to_LocalizedError_protocol() {
        let error: LocalizedError = BrowserAutomationError.scriptingDisabled
        XCTAssertNotNil(error.errorDescription)
    }

    // ==================== LocalizedError Descriptions ====================

    func test_scriptingDisabled_has_description() {
        let error = BrowserAutomationError.scriptingDisabled
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty, "scriptingDisabled should have a non-empty error description")
    }

    func test_tabNotFound_description_contains_uuid() {
        let id = UUID()
        let error = BrowserAutomationError.tabNotFound(id)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains(id.uuidString),
                      "tabNotFound description should contain the UUID string")
    }

    func test_evaluationFailed_description_contains_message() {
        let error = BrowserAutomationError.evaluationFailed("some JS error")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("some JS error"),
                      "evaluationFailed description should contain the error message")
    }

    func test_restrictedPage_description_contains_url() {
        let error = BrowserAutomationError.restrictedPage("https://login.example.com")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("https://login.example.com"),
                      "restrictedPage description should contain the URL")
    }

    func test_noActiveBrowserTab_has_description() {
        let error = BrowserAutomationError.noActiveBrowserTab
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty)
    }

    func test_invalidResponse_has_description() {
        let error = BrowserAutomationError.invalidResponse
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty)
    }

    func test_screenshotFailed_has_description() {
        let error = BrowserAutomationError.screenshotFailed
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty)
    }

    func test_timeout_has_description() {
        let error = BrowserAutomationError.timeout
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty)
    }

    // ==================== Equatable-like Distinctness ====================

    func test_all_cases_produce_distinct_descriptions() {
        let id = UUID()
        let errors: [BrowserAutomationError] = [
            .scriptingDisabled,
            .tabNotFound(id),
            .noActiveBrowserTab,
            .evaluationFailed("msg"),
            .invalidResponse,
            .restrictedPage("url"),
            .screenshotFailed,
            .timeout,
        ]
        let descriptions = errors.compactMap { $0.errorDescription }
        XCTAssertEqual(descriptions.count, errors.count,
                       "Every error case should have a description")
        let unique = Set(descriptions)
        XCTAssertEqual(unique.count, descriptions.count,
                       "All error descriptions should be distinct")
    }
}

// MARK: - BrowserAutomation Tests

final class BrowserAutomationTests: XCTestCase {

    // ==================== resolveSelector ====================

    func test_resolveSelector_converts_at_ref_to_data_attribute() {
        let result = BrowserAutomation.resolveSelector("@e1")
        XCTAssertEqual(result, "[data-calyx-ref=\"e1\"]")
    }

    func test_resolveSelector_converts_at_ref_with_larger_number() {
        let result = BrowserAutomation.resolveSelector("@e42")
        XCTAssertEqual(result, "[data-calyx-ref=\"e42\"]")
    }

    func test_resolveSelector_passes_through_css_selector() {
        let result = BrowserAutomation.resolveSelector("#my-button")
        XCTAssertEqual(result, "#my-button")
    }

    func test_resolveSelector_passes_through_class_selector() {
        let result = BrowserAutomation.resolveSelector(".submit-btn")
        XCTAssertEqual(result, ".submit-btn")
    }

    func test_resolveSelector_passes_through_attribute_selector() {
        let result = BrowserAutomation.resolveSelector("[name=\"email\"]")
        XCTAssertEqual(result, "[name=\"email\"]")
    }

    func test_resolveSelector_passes_through_tag_selector() {
        let result = BrowserAutomation.resolveSelector("input")
        XCTAssertEqual(result, "input")
    }

    // ==================== wrap() ====================

    func test_wrap_produces_iife() {
        let js = BrowserAutomation.wrap("42")
        XCTAssertTrue(js.contains("(() =>"), "Should start with IIFE arrow")
        XCTAssertTrue(js.contains("})()"), "Should end with IIFE invocation")
    }

    func test_wrap_includes_try_catch() {
        let js = BrowserAutomation.wrap("42")
        XCTAssertTrue(js.contains("try"), "Should contain try block")
        XCTAssertTrue(js.contains("catch"), "Should contain catch block")
    }

    func test_wrap_returns_json_stringify_with_ok_true() {
        let js = BrowserAutomation.wrap("42")
        XCTAssertTrue(js.contains("JSON.stringify"), "Should stringify result")
        XCTAssertTrue(js.contains("ok: true") || js.contains("\"ok\": true") || js.contains("ok:true"),
                      "Should include ok: true in success path")
    }

    func test_wrap_includes_pageURL() {
        let js = BrowserAutomation.wrap("42")
        XCTAssertTrue(js.contains("pageURL"), "Should include pageURL field")
        XCTAssertTrue(js.contains("location.href"), "Should use location.href for pageURL")
    }

    func test_wrap_catch_returns_error_json() {
        let js = BrowserAutomation.wrap("42")
        XCTAssertTrue(js.contains("ok: false") || js.contains("\"ok\": false") || js.contains("ok:false"),
                      "Catch block should return ok: false")
    }

    func test_wrap_includes_body() {
        let body = "document.title"
        let js = BrowserAutomation.wrap(body)
        XCTAssertTrue(js.contains(body), "Wrapped JS should contain the body code")
    }

    // ==================== snapshot() ====================

    func test_snapshot_returns_wrapped_js() {
        let js = BrowserAutomation.snapshot()
        XCTAssertTrue(js.contains("(() =>"), "snapshot should produce IIFE")
        XCTAssertTrue(js.contains("})()"), "snapshot should end with IIFE invocation")
    }

    func test_snapshot_stamps_data_calyx_ref() {
        let js = BrowserAutomation.snapshot()
        XCTAssertTrue(js.contains("data-calyx-ref"),
                      "snapshot JS should stamp data-calyx-ref attributes")
    }

    func test_snapshot_uses_default_max_depth() {
        let js = BrowserAutomation.snapshot()
        // Default maxDepth is 12
        XCTAssertTrue(js.contains("12"),
                      "snapshot JS should reference default maxDepth of 12")
    }

    func test_snapshot_uses_custom_max_depth() {
        let js = BrowserAutomation.snapshot(maxDepth: 5)
        XCTAssertTrue(js.contains("5"),
                      "snapshot JS should reference custom maxDepth of 5")
    }

    func test_snapshot_uses_default_max_elements() {
        let js = BrowserAutomation.snapshot()
        XCTAssertTrue(js.contains("500"),
                      "snapshot JS should reference default maxElements of 500")
    }

    func test_snapshot_uses_custom_max_elements() {
        let js = BrowserAutomation.snapshot(maxElements: 100)
        XCTAssertTrue(js.contains("100"),
                      "snapshot JS should reference custom maxElements of 100")
    }

    func test_snapshot_uses_default_max_text_length() {
        let js = BrowserAutomation.snapshot()
        XCTAssertTrue(js.contains("80"),
                      "snapshot JS should reference default maxTextLength of 80")
    }

    func test_snapshot_includes_json_stringify() {
        let js = BrowserAutomation.snapshot()
        XCTAssertTrue(js.contains("JSON.stringify"),
                      "snapshot should return JSON-stringified result")
    }

    // ==================== click() ====================

    func test_click_with_css_selector() {
        let js = BrowserAutomation.click(selector: "#submit")
        XCTAssertTrue(js.contains("#submit"), "click JS should contain the selector")
        XCTAssertTrue(js.contains(".click()"), "click JS should invoke .click()")
    }

    func test_click_with_ref_selector() {
        let js = BrowserAutomation.click(selector: "@e3")
        XCTAssertTrue(js.contains("data-calyx-ref"),
                      "click with @ref should resolve to data-calyx-ref selector")
        XCTAssertFalse(js.contains("@e3"),
                       "click JS should NOT contain the raw @e3 ref")
    }

    func test_click_wrapped_in_iife() {
        let js = BrowserAutomation.click(selector: "button")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== fill() ====================

    func test_fill_contains_selector_and_value() {
        let js = BrowserAutomation.fill(selector: "#email", value: "test@example.com")
        XCTAssertTrue(js.contains("#email"), "fill JS should contain the selector")
        XCTAssertTrue(js.contains("test@example.com"), "fill JS should contain the value")
    }

    func test_fill_dispatches_input_event() {
        let js = BrowserAutomation.fill(selector: "#name", value: "Alice")
        XCTAssertTrue(js.contains("input") || js.contains("Input"),
                      "fill JS should dispatch input event")
    }

    func test_fill_dispatches_change_event() {
        let js = BrowserAutomation.fill(selector: "#name", value: "Alice")
        XCTAssertTrue(js.contains("change") || js.contains("Change"),
                      "fill JS should dispatch change event")
    }

    func test_fill_with_ref_selector() {
        let js = BrowserAutomation.fill(selector: "@e5", value: "hello")
        XCTAssertTrue(js.contains("data-calyx-ref"),
                      "fill with @ref should resolve selector")
    }

    func test_fill_escapes_quotes_in_value() {
        let js = BrowserAutomation.fill(selector: "#field", value: "it's a \"test\"")
        // The JS should not break — the value should be properly escaped
        XCTAssertTrue(js.contains("(() =>"), "fill JS should still be valid IIFE")
    }

    // ==================== type() ====================

    func test_type_contains_text() {
        let js = BrowserAutomation.type(text: "Hello World")
        XCTAssertTrue(js.contains("Hello World"), "type JS should contain the text")
    }

    func test_type_uses_keyboard_event() {
        let js = BrowserAutomation.type(text: "abc")
        XCTAssertTrue(js.contains("KeyboardEvent") || js.contains("keydown") || js.contains("keypress"),
                      "type JS should dispatch keyboard events")
    }

    func test_type_wrapped_in_iife() {
        let js = BrowserAutomation.type(text: "x")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== press() ====================

    func test_press_contains_key() {
        let js = BrowserAutomation.press(key: "Enter")
        XCTAssertTrue(js.contains("Enter"), "press JS should contain the key name")
    }

    func test_press_dispatches_keyboard_events() {
        let js = BrowserAutomation.press(key: "Tab")
        XCTAssertTrue(js.contains("KeyboardEvent") || js.contains("keydown"),
                      "press JS should dispatch keyboard events")
    }

    func test_press_wrapped_in_iife() {
        let js = BrowserAutomation.press(key: "Escape")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== select() ====================

    func test_select_contains_selector_and_value() {
        let js = BrowserAutomation.select(selector: "#country", value: "US")
        XCTAssertTrue(js.contains("#country"), "select JS should contain the selector")
        XCTAssertTrue(js.contains("US"), "select JS should contain the value")
    }

    func test_select_with_ref_selector() {
        let js = BrowserAutomation.select(selector: "@e7", value: "option1")
        XCTAssertTrue(js.contains("data-calyx-ref"),
                      "select with @ref should resolve selector")
    }

    func test_select_wrapped_in_iife() {
        let js = BrowserAutomation.select(selector: "select", value: "a")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== check() ====================

    func test_check_contains_selector() {
        let js = BrowserAutomation.check(selector: "#agree")
        XCTAssertTrue(js.contains("#agree"), "check JS should contain the selector")
    }

    func test_check_sets_checked_true() {
        let js = BrowserAutomation.check(selector: "#terms")
        XCTAssertTrue(js.contains("true") || js.contains("checked"),
                      "check JS should set checkbox to checked")
    }

    func test_check_wrapped_in_iife() {
        let js = BrowserAutomation.check(selector: "input")
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== uncheck() ====================

    func test_uncheck_contains_selector() {
        let js = BrowserAutomation.uncheck(selector: "#agree")
        XCTAssertTrue(js.contains("#agree"), "uncheck JS should contain the selector")
    }

    func test_uncheck_sets_checked_false() {
        let js = BrowserAutomation.uncheck(selector: "#terms")
        XCTAssertTrue(js.contains("false") || js.contains("checked"),
                      "uncheck JS should set checkbox to unchecked")
    }

    func test_uncheck_wrapped_in_iife() {
        let js = BrowserAutomation.uncheck(selector: "input")
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== getText() ====================

    func test_getText_contains_selector() {
        let js = BrowserAutomation.getText(selector: "#message")
        XCTAssertTrue(js.contains("#message"), "getText JS should contain the selector")
    }

    func test_getText_uses_innerText() {
        let js = BrowserAutomation.getText(selector: "p")
        XCTAssertTrue(js.contains("innerText") || js.contains("textContent"),
                      "getText JS should read innerText or textContent")
    }

    func test_getText_wrapped_in_iife() {
        let js = BrowserAutomation.getText(selector: "span")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    func test_getText_with_ref_selector() {
        let js = BrowserAutomation.getText(selector: "@e10")
        XCTAssertTrue(js.contains("data-calyx-ref"),
                      "getText with @ref should resolve selector")
    }

    // ==================== getHTML() ====================

    func test_getHTML_contains_selector() {
        let js = BrowserAutomation.getHTML(selector: "#content")
        XCTAssertTrue(js.contains("#content"), "getHTML JS should contain the selector")
    }

    func test_getHTML_uses_outerHTML() {
        let js = BrowserAutomation.getHTML(selector: "div")
        XCTAssertTrue(js.contains("outerHTML"),
                      "getHTML JS should read outerHTML")
    }

    func test_getHTML_includes_truncation_logic() {
        let js = BrowserAutomation.getHTML(selector: "div")
        // Default maxLength is 512000
        XCTAssertTrue(js.contains("512000") || js.contains("substring") || js.contains("slice"),
                      "getHTML JS should include truncation logic with default maxLength")
    }

    func test_getHTML_uses_custom_maxLength() {
        let js = BrowserAutomation.getHTML(selector: "div", maxLength: 1024)
        XCTAssertTrue(js.contains("1024"),
                      "getHTML JS should reference custom maxLength of 1024")
    }

    func test_getHTML_wrapped_in_iife() {
        let js = BrowserAutomation.getHTML(selector: "div")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== eval() ====================

    func test_eval_wraps_arbitrary_code() {
        let js = BrowserAutomation.eval(code: "document.title")
        XCTAssertTrue(js.contains("document.title"),
                      "eval JS should contain the user code")
    }

    func test_eval_wrapped_in_iife() {
        let js = BrowserAutomation.eval(code: "1+1")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    func test_eval_includes_try_catch() {
        let js = BrowserAutomation.eval(code: "throw new Error('fail')")
        XCTAssertTrue(js.contains("try"))
        XCTAssertTrue(js.contains("catch"))
    }

    // ==================== wait() ====================

    func test_wait_with_selector_returns_promise() {
        let js = BrowserAutomation.wait(selector: "#loaded", text: nil, url: nil, timeout: 5000)
        XCTAssertTrue(js.contains("Promise") || js.contains("promise"),
                      "wait JS should use Promise")
    }

    func test_wait_with_selector_contains_selector() {
        let js = BrowserAutomation.wait(selector: "#loaded", text: nil, url: nil, timeout: 5000)
        XCTAssertTrue(js.contains("#loaded"), "wait JS should contain the selector")
    }

    func test_wait_with_text_contains_text() {
        let js = BrowserAutomation.wait(selector: nil, text: "Success", url: nil, timeout: 3000)
        XCTAssertTrue(js.contains("Success"), "wait JS should contain the text to wait for")
    }

    func test_wait_with_url_contains_url() {
        let js = BrowserAutomation.wait(selector: nil, text: nil, url: "https://done.com", timeout: 3000)
        XCTAssertTrue(js.contains("https://done.com"), "wait JS should contain the URL to wait for")
    }

    func test_wait_contains_timeout_value() {
        let js = BrowserAutomation.wait(selector: "div", text: nil, url: nil, timeout: 7500)
        XCTAssertTrue(js.contains("7500"), "wait JS should contain the timeout value")
    }

    func test_wait_uses_mutation_observer_or_settimeout() {
        let js = BrowserAutomation.wait(selector: ".result", text: nil, url: nil, timeout: 5000)
        XCTAssertTrue(js.contains("MutationObserver") || js.contains("setTimeout") || js.contains("setInterval"),
                      "wait JS should use MutationObserver or setTimeout for polling")
    }

    func test_wait_wrapped_in_iife() {
        let js = BrowserAutomation.wait(selector: "div", text: nil, url: nil, timeout: 1000)
        XCTAssertTrue(js.contains("(() =>") || js.contains("(async () =>"),
                      "wait JS should be wrapped in IIFE (possibly async)")
    }

    // ==================== clearRefs() ====================

    func test_clearRefs_removes_data_calyx_ref() {
        let js = BrowserAutomation.clearRefs()
        XCTAssertTrue(js.contains("data-calyx-ref"),
                      "clearRefs JS should reference data-calyx-ref attributes")
    }

    func test_clearRefs_uses_removeAttribute_or_querySelectorAll() {
        let js = BrowserAutomation.clearRefs()
        XCTAssertTrue(js.contains("removeAttribute") || js.contains("querySelectorAll"),
                      "clearRefs JS should query and remove ref attributes")
    }

    func test_clearRefs_wrapped_in_iife() {
        let js = BrowserAutomation.clearRefs()
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== parseResponse() ====================

    func test_parseResponse_ok_true_with_value() {
        let json = """
        {"ok":true,"value":"Hello","error":null,"pageURL":"https://example.com"}
        """
        let response = BrowserAutomation.parseResponse(json)
        XCTAssertTrue(response.ok, "ok should be true")
        XCTAssertEqual(response.value, "Hello")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.pageURL, "https://example.com")
    }

    func test_parseResponse_ok_false_with_error() {
        let json = """
        {"ok":false,"value":null,"error":"ReferenceError: x is not defined","pageURL":"https://example.com"}
        """
        let response = BrowserAutomation.parseResponse(json)
        XCTAssertFalse(response.ok, "ok should be false")
        XCTAssertNil(response.value)
        XCTAssertEqual(response.error, "ReferenceError: x is not defined")
        XCTAssertEqual(response.pageURL, "https://example.com")
    }

    func test_parseResponse_malformed_json_returns_error_response() {
        let json = "not valid json {{"
        let response = BrowserAutomation.parseResponse(json)
        XCTAssertFalse(response.ok, "Malformed JSON should return ok=false")
        XCTAssertNotNil(response.error, "Malformed JSON should populate error")
    }

    func test_parseResponse_empty_string_returns_error_response() {
        let response = BrowserAutomation.parseResponse("")
        XCTAssertFalse(response.ok, "Empty string should return ok=false")
        XCTAssertNotNil(response.error, "Empty string should populate error")
    }

    func test_parseResponse_null_value_parsed_as_nil() {
        let json = """
        {"ok":true,"value":null,"error":null,"pageURL":null}
        """
        let response = BrowserAutomation.parseResponse(json)
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.value)
        XCTAssertNil(response.error)
        XCTAssertNil(response.pageURL)
    }

    func test_parseResponse_value_with_special_characters() {
        let json = """
        {"ok":true,"value":"<div class=\\"test\\">Hello &amp; World</div>","error":null,"pageURL":"https://example.com/path?q=1&r=2"}
        """
        let response = BrowserAutomation.parseResponse(json)
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.value)
    }

    // ==================== BrowserAutomationResponse Struct ====================

    func test_response_struct_has_required_fields() {
        let response = BrowserAutomationResponse(
            ok: true,
            value: "test",
            error: nil,
            pageURL: "https://example.com"
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.value, "test")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.pageURL, "https://example.com")
    }

    func test_response_struct_all_nil_optionals() {
        let response = BrowserAutomationResponse(
            ok: false,
            value: nil,
            error: nil,
            pageURL: nil
        )
        XCTAssertFalse(response.ok)
        XCTAssertNil(response.value)
        XCTAssertNil(response.error)
        XCTAssertNil(response.pageURL)
    }

    // ==================== Selector Escaping ====================

    func test_click_selector_with_single_quotes() {
        let js = BrowserAutomation.click(selector: "[data-value='hello']")
        XCTAssertTrue(js.contains("(() =>"), "Should produce valid IIFE despite single quotes in selector")
    }

    func test_click_selector_with_double_quotes() {
        let js = BrowserAutomation.click(selector: "[data-value=\"hello\"]")
        XCTAssertTrue(js.contains("(() =>"), "Should produce valid IIFE despite double quotes in selector")
    }

    func test_fill_value_with_backslashes() {
        let js = BrowserAutomation.fill(selector: "#path", value: "C:\\Users\\test")
        XCTAssertTrue(js.contains("(() =>"), "Should produce valid IIFE despite backslashes in value")
    }

    func test_fill_value_with_newlines() {
        let js = BrowserAutomation.fill(selector: "#textarea", value: "line1\nline2")
        XCTAssertTrue(js.contains("(() =>"), "Should produce valid IIFE despite newlines in value")
    }

    // ==================== getAttribute() ====================

    func test_getAttribute_contains_selector_and_attribute() {
        let js = BrowserAutomation.getAttribute(selector: "#link", attribute: "href")
        XCTAssertTrue(js.contains("#link"))
        XCTAssertTrue(js.contains("href"))
    }

    func test_getAttribute_throws_when_element_not_found() {
        let js = BrowserAutomation.getAttribute(selector: "#missing", attribute: "id")
        XCTAssertTrue(js.contains("Element not found"))
    }

    func test_getAttribute_returns_null_for_missing_attribute() {
        let js = BrowserAutomation.getAttribute(selector: "a", attribute: "data-x")
        // getAttribute returns "null" string when attr is missing (not an error)
        XCTAssertTrue(js.contains("getAttribute"))
    }

    func test_getAttribute_with_ref_selector() {
        let js = BrowserAutomation.getAttribute(selector: "@e1", attribute: "class")
        XCTAssertTrue(js.contains("data-calyx-ref"))
    }

    func test_getAttribute_wrapped_in_iife() {
        let js = BrowserAutomation.getAttribute(selector: "a", attribute: "href")
        XCTAssertTrue(js.contains("(() =>"))
        XCTAssertTrue(js.contains("})()"))
    }

    // ==================== getLinks() ====================

    func test_getLinks_queries_anchor_elements() {
        let js = BrowserAutomation.getLinks()
        XCTAssertTrue(js.contains("a[href]") || js.contains("querySelectorAll"))
    }

    func test_getLinks_uses_default_max_items() {
        let js = BrowserAutomation.getLinks()
        XCTAssertTrue(js.contains("100"))
    }

    func test_getLinks_uses_custom_max_items() {
        let js = BrowserAutomation.getLinks(maxItems: 50)
        XCTAssertTrue(js.contains("50"))
    }

    func test_getLinks_truncates_text() {
        let js = BrowserAutomation.getLinks()
        XCTAssertTrue(js.contains("200"))
    }

    func test_getLinks_wrapped_in_iife() {
        let js = BrowserAutomation.getLinks()
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== getInputs() ====================

    func test_getInputs_queries_form_elements() {
        let js = BrowserAutomation.getInputs()
        XCTAssertTrue(js.contains("input") && js.contains("select") && js.contains("textarea"))
    }

    func test_getInputs_uses_default_max_items() {
        let js = BrowserAutomation.getInputs()
        XCTAssertTrue(js.contains("100"))
    }

    func test_getInputs_uses_custom_max_items() {
        let js = BrowserAutomation.getInputs(maxItems: 25)
        XCTAssertTrue(js.contains("25"))
    }

    func test_getInputs_truncates_values() {
        let js = BrowserAutomation.getInputs()
        XCTAssertTrue(js.contains("200"))
    }

    func test_getInputs_wrapped_in_iife() {
        let js = BrowserAutomation.getInputs()
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== isVisible() ====================

    func test_isVisible_contains_selector() {
        let js = BrowserAutomation.isVisible(selector: "#el")
        XCTAssertTrue(js.contains("#el"))
    }

    func test_isVisible_returns_false_for_not_found() {
        let js = BrowserAutomation.isVisible(selector: "#missing")
        // isVisible should return "false" for not-found (not error)
        XCTAssertTrue(js.contains("false"))
    }

    func test_isVisible_checks_visibility() {
        let js = BrowserAutomation.isVisible(selector: "div")
        XCTAssertTrue(js.contains("checkVisibility") || js.contains("display") || js.contains("visibility"))
    }

    func test_isVisible_wrapped_in_iife() {
        let js = BrowserAutomation.isVisible(selector: "div")
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== hover() ====================

    func test_hover_contains_selector() {
        let js = BrowserAutomation.hover(selector: "#link")
        XCTAssertTrue(js.contains("#link"))
    }

    func test_hover_dispatches_pointer_events() {
        let js = BrowserAutomation.hover(selector: "a")
        XCTAssertTrue(js.contains("pointerover") || js.contains("PointerEvent"))
        XCTAssertTrue(js.contains("pointerenter") || js.contains("PointerEvent"))
    }

    func test_hover_dispatches_mouse_events() {
        let js = BrowserAutomation.hover(selector: "a")
        XCTAssertTrue(js.contains("mouseover") || js.contains("MouseEvent"))
        XCTAssertTrue(js.contains("mouseenter") || js.contains("MouseEvent"))
    }

    func test_hover_wrapped_in_iife() {
        let js = BrowserAutomation.hover(selector: "a")
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== scroll() ====================

    func test_scroll_contains_direction() {
        let js = BrowserAutomation.scroll(direction: "down", amount: 500)
        XCTAssertTrue(js.contains("scrollBy"))
    }

    func test_scroll_uses_amount() {
        let js = BrowserAutomation.scroll(direction: "down", amount: 300)
        XCTAssertTrue(js.contains("300"))
    }

    func test_scroll_with_selector() {
        let js = BrowserAutomation.scroll(direction: "down", amount: 500, selector: "#scrollbox")
        XCTAssertTrue(js.contains("#scrollbox"))
    }

    func test_scroll_without_selector_targets_window() {
        let js = BrowserAutomation.scroll(direction: "up", amount: 100)
        XCTAssertTrue(js.contains("window") || js.contains("scrollBy"))
    }

    func test_scroll_wrapped_in_iife() {
        let js = BrowserAutomation.scroll(direction: "down", amount: 500)
        XCTAssertTrue(js.contains("(() =>"))
    }

    // ==================== Cross-Method Consistency ====================

    func test_all_action_methods_produce_iife() {
        let methods: [(String, String)] = [
            ("click", BrowserAutomation.click(selector: "a")),
            ("fill", BrowserAutomation.fill(selector: "input", value: "x")),
            ("type", BrowserAutomation.type(text: "x")),
            ("press", BrowserAutomation.press(key: "Enter")),
            ("select", BrowserAutomation.select(selector: "select", value: "a")),
            ("check", BrowserAutomation.check(selector: "input")),
            ("uncheck", BrowserAutomation.uncheck(selector: "input")),
            ("getText", BrowserAutomation.getText(selector: "p")),
            ("getHTML", BrowserAutomation.getHTML(selector: "div")),
            ("eval", BrowserAutomation.eval(code: "1")),
            ("clearRefs", BrowserAutomation.clearRefs()),
            ("snapshot", BrowserAutomation.snapshot()),
            ("getAttribute", BrowserAutomation.getAttribute(selector: "a", attribute: "href")),
            ("getLinks", BrowserAutomation.getLinks()),
            ("getInputs", BrowserAutomation.getInputs()),
            ("isVisible", BrowserAutomation.isVisible(selector: "div")),
            ("hover", BrowserAutomation.hover(selector: "a")),
            ("scroll", BrowserAutomation.scroll(direction: "down", amount: 500)),
        ]
        for (name, js) in methods {
            XCTAssertTrue(js.contains("(() =>") || js.contains("(async () =>"),
                          "\(name) should produce IIFE")
        }
    }

    func test_all_action_methods_include_json_stringify() {
        let methods: [(String, String)] = [
            ("click", BrowserAutomation.click(selector: "a")),
            ("fill", BrowserAutomation.fill(selector: "input", value: "x")),
            ("getText", BrowserAutomation.getText(selector: "p")),
            ("getHTML", BrowserAutomation.getHTML(selector: "div")),
            ("eval", BrowserAutomation.eval(code: "1")),
            ("snapshot", BrowserAutomation.snapshot()),
            ("clearRefs", BrowserAutomation.clearRefs()),
            ("getAttribute", BrowserAutomation.getAttribute(selector: "a", attribute: "href")),
            ("getLinks", BrowserAutomation.getLinks()),
            ("getInputs", BrowserAutomation.getInputs()),
            ("isVisible", BrowserAutomation.isVisible(selector: "div")),
            ("hover", BrowserAutomation.hover(selector: "a")),
            ("scroll", BrowserAutomation.scroll(direction: "down", amount: 500)),
        ]
        for (name, js) in methods {
            XCTAssertTrue(js.contains("JSON.stringify"),
                          "\(name) should include JSON.stringify for normalized response")
        }
    }
}
