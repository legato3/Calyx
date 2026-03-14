// GlassThemeTests.swift
// CalyxTests
//
// Tests for GlassTheme.chromeTintOpacity(for:) which maps a glass opacity
// value (0.0–1.0) to a chrome tint opacity via 0.20 + (clamped * 0.80).
//
// Coverage:
// - Zero input → minimum tint (0.20)
// - Default input (0.7) → 0.76
// - Maximum input (1.0) → 1.00
// - Negative input clamped to 0.0 → 0.20
// - Above-one input clamped to 1.0 → 1.00

import Testing
@testable import Calyx

@Suite("GlassTheme chromeTintOpacity Tests")
struct GlassThemeTests {

    // MARK: - Happy Path

    @Test("chromeTintOpacity returns 0.20 for zero input")
    func chromeTintOpacity_atZero() {
        let result = GlassTheme.chromeTintOpacity(for: 0.0)
        #expect(result == 0.20)
    }

    @Test("chromeTintOpacity returns 0.76 for default (0.7)")
    func chromeTintOpacity_atDefault() {
        let result = GlassTheme.chromeTintOpacity(for: 0.7)
        #expect(abs(result - 0.76) < 0.01)
    }

    @Test("chromeTintOpacity returns 1.00 for max (1.0)")
    func chromeTintOpacity_atMax() {
        let result = GlassTheme.chromeTintOpacity(for: 1.0)
        #expect(result == 1.00)
    }

    // MARK: - Clamping

    @Test("chromeTintOpacity clamps negative input to 0.20")
    func chromeTintOpacity_clampNegative() {
        let result = GlassTheme.chromeTintOpacity(for: -0.5)
        #expect(result == 0.20)
    }

    @Test("chromeTintOpacity clamps above-one input to 1.00")
    func chromeTintOpacity_clampAboveOne() {
        let result = GlassTheme.chromeTintOpacity(for: 1.5)
        #expect(result == 1.00)
    }
}
