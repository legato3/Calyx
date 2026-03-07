import XCTest
@testable import Calyx

final class NotificationSanitizerTests: XCTestCase {

    func test_strips_bidi_overrides() {
        let input = "Hello\u{202A}World\u{202E}!"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "HelloWorld!")
    }

    func test_strips_bidi_isolates() {
        let input = "\u{2066}test\u{2069}"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "test")
    }

    func test_strips_control_chars_but_keeps_newline_and_tab() {
        let input = "Hello\tWorld\nLine2\u{01}\u{02}\u{7F}"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello\tWorld\nLine2")
    }

    func test_strips_c1_control_chars() {
        let input = "test\u{80}\u{9F}end"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "testend")
    }

    func test_strips_zero_width_chars() {
        let input = "Hello\u{200B}World\u{FEFF}!"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "HelloWorld!")
    }

    func test_nfc_normalization() {
        // é composed (U+00E9) vs decomposed (e + U+0301)
        let decomposed = "e\u{0301}"
        let result = NotificationSanitizer.sanitize(decomposed)
        XCTAssertEqual(result, "\u{00E9}")
    }

    func test_truncation_at_256_grapheme_clusters() {
        let long = String(repeating: "a", count: 300)
        let result = NotificationSanitizer.sanitize(long)
        XCTAssertEqual(result.count, 256)
    }

    func test_newline_collapsing() {
        let input = "Hello\n\n\nWorld"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello\nWorld")
    }

    func test_strips_leading_trailing_newlines() {
        let input = "\n\nHello\n\n"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Hello")
    }

    func test_plain_text_unchanged() {
        let input = "Normal notification text"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, input)
    }

    func test_empty_string() {
        let result = NotificationSanitizer.sanitize("")
        XCTAssertEqual(result, "")
    }

    func test_emoji_preserved() {
        let input = "Build complete 🎉"
        let result = NotificationSanitizer.sanitize(input)
        XCTAssertEqual(result, "Build complete 🎉")
    }
}
