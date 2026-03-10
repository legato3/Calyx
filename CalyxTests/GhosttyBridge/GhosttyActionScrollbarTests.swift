// GhosttyActionScrollbarTests.swift
// CalyxTests
//
// Tests for the ScrollbarState struct on GhosttySurfaceController.
// Verifies storage, zero-value behavior, and large-value safety.

import Testing
@testable import Calyx

@MainActor
@Suite("GhosttyAction Scrollbar Tests")
struct GhosttyActionScrollbarTests {

    @Test("ScrollbarState stores values correctly")
    func scrollbarStateStoresValues() {
        let state = GhosttySurfaceController.ScrollbarState(total: 1000, offset: 50, len: 24)
        #expect(state.total == 1000)
        #expect(state.offset == 50)
        #expect(state.len == 24)
    }

    @Test("ScrollbarState with zero total")
    func scrollbarStateZeroTotal() {
        let state = GhosttySurfaceController.ScrollbarState(total: 0, offset: 0, len: 0)
        #expect(state.total == 0)
    }

    @Test("ScrollbarState with large values does not overflow")
    func scrollbarStateLargeValues() {
        let state = GhosttySurfaceController.ScrollbarState(total: UInt64.max, offset: UInt64.max - 1, len: 1)
        #expect(state.total == UInt64.max)
        #expect(state.offset == UInt64.max - 1)
        #expect(state.len == 1)
    }
}
