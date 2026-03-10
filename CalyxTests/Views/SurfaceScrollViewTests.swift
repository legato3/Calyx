// SurfaceScrollViewTests.swift
// CalyxTests
//
// Tests for SurfaceScrollView's pure helper methods: validation, coordinate
// conversion, row clamping, and document-height calculation. These are static
// functions that can be exercised without a live ghostty surface.

import Testing
@testable import Calyx
import AppKit

@MainActor
@Suite("SurfaceScrollView Tests")
struct SurfaceScrollViewTests {

    // MARK: - Validation

    @Test("validatedScrollbar returns nil for zero total")
    func validatedScrollbarZeroTotal() {
        let result = SurfaceScrollView.validatedScrollbar(total: 0, offset: 0, len: 0)
        #expect(result == nil)
    }

    @Test("validatedScrollbar clamps len to total")
    func validatedScrollbarClampsLen() {
        let result = SurfaceScrollView.validatedScrollbar(total: 100, offset: 0, len: 200)
        #expect(result != nil)
        #expect(result!.len == 100)
    }

    @Test("validatedScrollbar clamps offset to total-len")
    func validatedScrollbarClampsOffset() {
        let result = SurfaceScrollView.validatedScrollbar(total: 100, offset: 90, len: 20)
        #expect(result != nil)
        #expect(result!.offset == 80)  // total - len
    }

    @Test("validatedScrollbar passes valid values through")
    func validatedScrollbarValid() {
        let result = SurfaceScrollView.validatedScrollbar(total: 1000, offset: 50, len: 24)
        #expect(result != nil)
        #expect(result!.total == 1000)
        #expect(result!.offset == 50)
        #expect(result!.len == 24)
    }

    @Test("validatedScrollbar with max UInt64 values does not crash")
    func validatedScrollbarMaxValues() {
        let result = SurfaceScrollView.validatedScrollbar(total: UInt64.max, offset: UInt64.max, len: UInt64.max)
        #expect(result != nil)
        // Should clamp without overflow
        #expect(result!.total > 0)
    }

    // MARK: - Document Height

    @Test("documentHeight calculates correctly for normal values")
    func documentHeightNormal() {
        // total=100, len=24, cellHeight=16, contentHeight=384 (24*16)
        let height = SurfaceScrollView.documentHeight(total: 100, len: 24, cellHeight: 16, contentHeight: 384)
        // gridHeight = 100 * 16 = 1600, padding = 384 - 24*16 = 0, result = 1600
        #expect(height == 1600)
    }

    @Test("documentHeight with padding")
    func documentHeightWithPadding() {
        // contentHeight has extra padding beyond grid
        let height = SurfaceScrollView.documentHeight(total: 100, len: 24, cellHeight: 16, contentHeight: 400)
        // gridHeight = 1600, padding = 400 - 384 = 16, result = 1616
        #expect(height == 1616)
    }

    @Test("documentHeight is capped at maxDocumentHeight")
    func documentHeightCapped() {
        let height = SurfaceScrollView.documentHeight(total: Int.max / 2, len: 24, cellHeight: 16, contentHeight: 384)
        #expect(height <= SurfaceScrollView.maxDocumentHeight)
    }

    @Test("documentHeight with zero cellHeight returns contentHeight")
    func documentHeightZeroCellHeight() {
        let height = SurfaceScrollView.documentHeight(total: 100, len: 24, cellHeight: 0, contentHeight: 384)
        // gridHeight = 0, padding = 384 - 0 = 384, result = 384
        #expect(height == 384)
    }

    // MARK: - Coordinate Conversion: Core → UI

    @Test("offsetToScrollY converts core offset to AppKit Y coordinate")
    func offsetToScrollY() {
        // offset=50 rows from top, cellHeight=16
        let y = SurfaceScrollView.offsetToScrollY(offset: 50, cellHeight: 16)
        #expect(y == 800)  // 50 * 16
    }

    @Test("offsetToScrollY with zero offset returns zero")
    func offsetToScrollYZero() {
        let y = SurfaceScrollView.offsetToScrollY(offset: 0, cellHeight: 16)
        #expect(y == 0)
    }

    // MARK: - Coordinate Conversion: UI → Core

    @Test("scrollYToRow converts AppKit Y to row number")
    func scrollYToRow() {
        let row = SurfaceScrollView.scrollYToRow(scrollY: 800, cellHeight: 16)
        #expect(row == 50)
    }

    @Test("scrollYToRow rounds to nearest row")
    func scrollYToRowRounding() {
        // 808 / 16 = 50.5 → should round to 50 (floor)
        let row = SurfaceScrollView.scrollYToRow(scrollY: 808, cellHeight: 16)
        #expect(row == 50)
    }

    @Test("scrollYToRow with zero cellHeight returns 0")
    func scrollYToRowZeroCellHeight() {
        let row = SurfaceScrollView.scrollYToRow(scrollY: 800, cellHeight: 0)
        #expect(row == 0)
    }

    @Test("scrollYToRow with negative scrollY returns 0")
    func scrollYToRowNegative() {
        let row = SurfaceScrollView.scrollYToRow(scrollY: -100, cellHeight: 16)
        #expect(row == 0)
    }

    // MARK: - Row Clamping

    @Test("clampRow clamps to valid range")
    func clampRow() {
        #expect(SurfaceScrollView.clampRow(50, total: 100, len: 24) == 50)
        #expect(SurfaceScrollView.clampRow(-1, total: 100, len: 24) == 0)
        #expect(SurfaceScrollView.clampRow(100, total: 100, len: 24) == 76)  // total - len
        #expect(SurfaceScrollView.clampRow(0, total: 100, len: 24) == 0)
    }

    @Test("clampRow with len >= total returns 0")
    func clampRowLenGETotal() {
        #expect(SurfaceScrollView.clampRow(50, total: 24, len: 24) == 0)
        #expect(SurfaceScrollView.clampRow(50, total: 24, len: 100) == 0)
    }

    // MARK: - ScrollbarMode Config

    @Test("ScrollbarMode raw values")
    func scrollbarModeRawValues() {
        #expect(GhosttyConfigManager.ScrollbarMode.system.rawValue == "system")
        #expect(GhosttyConfigManager.ScrollbarMode.never.rawValue == "never")
    }
}
