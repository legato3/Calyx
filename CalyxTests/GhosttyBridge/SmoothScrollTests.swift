// SmoothScrollTests.swift
// CalyxTests
//
// Tests for SurfaceView smooth pixel scrolling helpers:
//   - computeSmoothScrollOffset (mirrors ghostty Surface.zig:3423-3435)
//   - clampSmoothScrollAtBoundary

import Testing
@testable import Calyx

@MainActor
@Suite("SurfaceView Smooth Scroll Tests")
struct SmoothScrollTests {

    // MARK: - computeSmoothScrollOffset: small delta (< cellHeight)

    @Test("Small delta below cellHeight returns correct accumulator and pixelOffset")
    func smallDeltaBelowCellHeight() {
        let result = SurfaceView.computeSmoothScrollOffset(
            currentAccumulator: 0,
            rawDeltaY: 5,
            precisionMultiplier: 1,
            cellHeight: 20
        )
        #expect(result.accumulator == 5)
        #expect(result.pixelOffset == 5)
    }

    // MARK: - computeSmoothScrollOffset: exactly cellHeight

    @Test("Delta exactly equal to cellHeight returns zero remainder")
    func exactlyCellHeightReturnsZeroRemainder() {
        let result = SurfaceView.computeSmoothScrollOffset(
            currentAccumulator: 0,
            rawDeltaY: 20,
            precisionMultiplier: 1,
            cellHeight: 20
        )
        #expect(result.accumulator == 0)
        #expect(result.pixelOffset == 0)
    }

    // MARK: - computeSmoothScrollOffset: 1.5x cellHeight

    @Test("Delta of 1.5x cellHeight returns 0.5x cellHeight remainder")
    func oneAndHalfCellHeightRemainder() {
        let result = SurfaceView.computeSmoothScrollOffset(
            currentAccumulator: 0,
            rawDeltaY: 30,
            precisionMultiplier: 1,
            cellHeight: 20
        )
        #expect(result.accumulator == 10)
        #expect(result.pixelOffset == 10)
    }

    // MARK: - computeSmoothScrollOffset: direction reversal

    @Test("Direction reversal reduces accumulator magnitude")
    func directionReversalReducesAccumulator() {
        // Start with positive accumulator of 15, then scroll negative by 10
        let result = SurfaceView.computeSmoothScrollOffset(
            currentAccumulator: 15,
            rawDeltaY: -10,
            precisionMultiplier: 1,
            cellHeight: 20
        )
        #expect(result.accumulator == 5)
        #expect(result.pixelOffset == 5)
    }

    // MARK: - computeSmoothScrollOffset: zero cellHeight

    @Test("Zero cellHeight returns zero state to avoid division by zero")
    func zeroCellHeightReturnsZeroState() {
        let result = SurfaceView.computeSmoothScrollOffset(
            currentAccumulator: 10,
            rawDeltaY: 5,
            precisionMultiplier: 1,
            cellHeight: 0
        )
        #expect(result.accumulator == 0)
        #expect(result.pixelOffset == 0)
    }

    // MARK: - computeSmoothScrollOffset: 2x multiplier

    @Test("Precision multiplier of 2 doubles the effective delta")
    func twoXMultiplierDoublesEffectiveDelta() {
        let result = SurfaceView.computeSmoothScrollOffset(
            currentAccumulator: 0,
            rawDeltaY: 5,
            precisionMultiplier: 2,
            cellHeight: 20
        )
        #expect(result.accumulator == 10)
        #expect(result.pixelOffset == 10)
    }

    // MARK: - clampSmoothScrollAtBoundary: clamp at top

    @Test("Positive accumulator is clamped to zero when at top boundary")
    func clampsAtTopBoundary() {
        let result = SurfaceView.clampSmoothScrollAtBoundary(
            accumulator: 15,
            isAtTop: true,
            isAtBottom: false
        )
        #expect(result == 0)
    }

    // MARK: - clampSmoothScrollAtBoundary: clamp at bottom

    @Test("Negative accumulator is clamped to zero when at bottom boundary")
    func clampsAtBottomBoundary() {
        let result = SurfaceView.clampSmoothScrollAtBoundary(
            accumulator: -10,
            isAtTop: false,
            isAtBottom: true
        )
        #expect(result == 0)
    }

    // MARK: - clampSmoothScrollAtBoundary: no clamp when not at boundary

    @Test("Accumulator passes through unchanged when not at any boundary")
    func noClampWhenNotAtBoundary() {
        let result = SurfaceView.clampSmoothScrollAtBoundary(
            accumulator: 15,
            isAtTop: false,
            isAtBottom: false
        )
        #expect(result == 15)
    }

    // MARK: - discreteScrollEaseOut

    @Test("Ease-out at progress 0 returns 0")
    func easeOutAtZero() {
        let result = SurfaceView.discreteScrollEaseOut(progress: 0)
        #expect(result == 0)
    }

    @Test("Ease-out at progress 1 returns 1")
    func easeOutAtOne() {
        let result = SurfaceView.discreteScrollEaseOut(progress: 1)
        #expect(result == 1)
    }

    @Test("Ease-out at progress 0.5 returns 0.75 (quadratic)")
    func easeOutAtHalf() {
        let result = SurfaceView.discreteScrollEaseOut(progress: 0.5)
        #expect(result == 0.75)
    }

    @Test("Ease-out clamps negative progress to 0")
    func easeOutClampsNegative() {
        let result = SurfaceView.discreteScrollEaseOut(progress: -0.5)
        #expect(result == 0)
    }

    @Test("Ease-out clamps progress above 1 to 1")
    func easeOutClampsAboveOne() {
        let result = SurfaceView.discreteScrollEaseOut(progress: 2.0)
        #expect(result == 1)
    }
}
