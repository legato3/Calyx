// NotificationSanitizer.swift
// Calyx
//
// Sanitizes notification text for security.

import Foundation

enum NotificationSanitizer {

    static func sanitize(_ text: String) -> String {
        var result = text

        // Strip bidi overrides: U+202A-202E, U+2066-2069
        result = result.replacing(/[\u{202A}-\u{202E}\u{2066}-\u{2069}]/, with: "")

        // Strip C0/C1 control chars except \n (0x0A) and \t (0x09)
        result = result.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A { return true }
            if v <= 0x1F { return false }
            if v == 0x7F { return false }
            if v >= 0x80 && v <= 0x9F { return false }
            return true
        }.map { String($0) }.joined()

        // Strip zero-width chars: U+200B-200F, U+FEFF
        result = result.replacing(/[\u{200B}-\u{200F}\u{FEFF}]/, with: "")

        // Normalize newlines: collapse multiple \n to single, strip leading/trailing
        result = result.replacing(/\n{2,}/, with: "\n")
        result = result.trimmingCharacters(in: .newlines)

        // Unicode NFC normalization
        result = result.precomposedStringWithCanonicalMapping

        // Truncate to 256 grapheme clusters
        if result.count > 256 {
            result = String(result.prefix(256))
        }

        return result
    }
}
