import XCTest
@testable import Automation

#if canImport(CoreImage)
import CoreImage
import CoreGraphics

/// Tests for `FrameTransform` — the pure CoreImage crop+scale used by
/// the recording renderer. We only assert behavior we can verify
/// without producing actual pixels: the fast path (scale == 1.0) and
/// the inline `clamp` helper. Pixel-level rendering correctness
/// belongs in the recording-snapshot golden suite, not here.
final class FrameTransformTests: XCTestCase {
    // MARK: Fast path (scale == 1)

    func testScaleOfOneReturnsInputUnchanged() {
        // The fast path is hot — every recorded frame outside an
        // active zoom region hits it. Identity in == identity out.
        let input = CIImage(color: CIColor.red).cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 50)
        )
        let result = FrameTransform.transformedFrame(
            input,
            scale: 1.0,
            focusX: 50,
            focusY: 25,
            frameSize: CGSize(width: 100, height: 50)
        )
        XCTAssertTrue(result === input)
    }

    func testScaleVeryCloseToOneAlsoUsesFastPath() {
        // The fast-path predicate is `abs(scale - 1.0) < 1e-6`.
        // Confirm a value inside the tolerance returns the same
        // CIImage instance — important because CIContext.render of a
        // pass-through is more expensive than detecting it upfront.
        let input = CIImage(color: CIColor.green).cropped(
            to: CGRect(x: 0, y: 0, width: 32, height: 32)
        )
        let result = FrameTransform.transformedFrame(
            input,
            scale: 1.0 + 1e-7,
            focusX: 16,
            focusY: 16,
            frameSize: CGSize(width: 32, height: 32)
        )
        XCTAssertTrue(result === input)
    }

    // MARK: clamp helper

    func testClampPassesThroughInRange() {
        XCTAssertEqual(
            FrameTransform.clamp(5, min: 0, max: 10), 5, accuracy: 1e-9
        )
    }

    func testClampPinsBelowMin() {
        XCTAssertEqual(
            FrameTransform.clamp(-5, min: 0, max: 10), 0, accuracy: 1e-9
        )
    }

    func testClampPinsAboveMax() {
        XCTAssertEqual(
            FrameTransform.clamp(15, min: 0, max: 10), 10, accuracy: 1e-9
        )
    }

    func testClampWithDegenerateRangeFallsBackToLowerBound() {
        // hi < lo can occur when the crop is bigger than the frame
        // for scale < 1; the docstring says "fall back to lo" so the
        // caller doesn't see NaN.
        XCTAssertEqual(
            FrameTransform.clamp(5, min: 10, max: 0), 10, accuracy: 1e-9
        )
    }
}

#endif
