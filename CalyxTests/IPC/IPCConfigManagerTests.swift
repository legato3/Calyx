import XCTest
@testable import Calyx

final class IPCConfigManagerTests: XCTestCase {

    // MARK: - IPCConfigResult.anySucceeded

    func test_anySucceeded_bothSuccess() {
        let result = IPCConfigResult(claudeCode: .success, codex: .success)
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_oneSuccess() {
        let result = IPCConfigResult(claudeCode: .success, codex: .skipped(reason: "not installed"))
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_otherSuccess() {
        let result = IPCConfigResult(claudeCode: .skipped(reason: "not installed"), codex: .success)
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_noneSuccess() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed")
        )
        XCTAssertFalse(result.anySucceeded)
    }

    func test_anySucceeded_failedAndSkipped() {
        let error = NSError(domain: "test", code: 1)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .skipped(reason: "not installed")
        )
        XCTAssertFalse(result.anySucceeded)
    }

    // MARK: - ConfigStatus pattern matching

    func test_configStatus_success() {
        let status: ConfigStatus = .success
        if case .success = status {
            // pass
        } else {
            XCTFail("Expected .success")
        }
    }

    func test_configStatus_skipped() {
        let status: ConfigStatus = .skipped(reason: "not installed")
        if case .skipped(let reason) = status {
            XCTAssertEqual(reason, "not installed")
        } else {
            XCTFail("Expected .skipped")
        }
    }

    func test_configStatus_failed() {
        let error = NSError(domain: "test", code: 42)
        let status: ConfigStatus = .failed(error)
        if case .failed(let err) = status {
            XCTAssertEqual((err as NSError).code, 42)
        } else {
            XCTFail("Expected .failed")
        }
    }
}
