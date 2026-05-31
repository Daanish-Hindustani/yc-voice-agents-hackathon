import XCTest
@testable import Automation

#if canImport(CoreGraphics)
import CoreGraphics

/// Tests for `CursorMotionPath` Bezier construction. We only assert
/// pure geometric properties of the produced curve — the
/// `CAKeyframeAnimation` and `CASpringAnimation` builders are not
/// covered here because they wrap Apple framework objects and adding
/// values to them would test Apple's behavior, not ours.
final class CursorMotionPathTests: XCTestCase {
    private let tolerance: CGFloat = 1e-6

    // MARK: Endpoint preservation

    func testBezierStartAndEndMatchInputPoints() {
        // The Bezier start and end must always be the requested
        // points, regardless of options. The control points move; the
        // anchors do not.
        let from = CGPoint(x: 100, y: 200)
        let to = CGPoint(x: 400, y: 50)
        let path = CursorMotionPath(from: from, to: to)
        XCTAssertEqual(path.bezier.start, from)
        XCTAssertEqual(path.bezier.end, to)
    }

    // MARK: Straight-line case (arcSize = 0)

    func testZeroArcSizeKeepsControlsOnTheStartEndLine() {
        // arcSize = 0 means perpendicular deflection is zero, so the
        // control points sit exactly on the straight line from start
        // to end. The curve is still a cubic bezier (parametrically),
        // but geometrically it's the line segment.
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 100, y: 100)
        let opts = CursorMotionPath.Options(
            startHandle: 0.3, endHandle: 0.3, arcSize: 0,
            arcFlow: 0, spring: 0.72
        )
        let path = CursorMotionPath(from: from, to: to, options: opts)

        // Control1 sits 30% along the line: (30, 30).
        XCTAssertEqual(path.bezier.control1.x, 30, accuracy: tolerance)
        XCTAssertEqual(path.bezier.control1.y, 30, accuracy: tolerance)
        // Control2 sits 30% from the end: (70, 70).
        XCTAssertEqual(path.bezier.control2.x, 70, accuracy: tolerance)
        XCTAssertEqual(path.bezier.control2.y, 70, accuracy: tolerance)
    }

    // MARK: Coincident endpoints

    func testCoincidentStartAndEndProducesDegenerateBezier() {
        // When from == to we hit the `length = max(hypot(...), 1)`
        // floor that prevents division-by-zero; the curve collapses
        // to (almost) a point. Regression check: this must not crash
        // and must produce control points at or very near the shared
        // anchor.
        let p = CGPoint(x: 200, y: 200)
        let path = CursorMotionPath(from: p, to: p)
        // Distance from anchor to control1 should be small —
        // bounded by 1 unit length (the floor) times arcSize, so
        // ~0.25 pixels with default arcSize.
        let dx1 = path.bezier.control1.x - p.x
        let dy1 = path.bezier.control1.y - p.y
        XCTAssertLessThan(hypot(dx1, dy1), 1.0)
    }

    // MARK: Default-options sanity

    func testDefaultOptionsDeflectControlsOffTheStraightLine() {
        // Pin the actual geometry: for a left-to-right horizontal
        // line at y=100, the source's perpendicular is (0, +1) — so
        // the control points are deflected to y > 100 with a
        // non-zero arcSize. This is documenting the real direction,
        // not the in-source comment which describes the *intended*
        // visual side; the renderer's flipped coordinate space sorts
        // out "above" vs "below" downstream.
        let from = CGPoint(x: 0, y: 100)
        let to = CGPoint(x: 100, y: 100)
        let path = CursorMotionPath(from: from, to: to)
        XCTAssertNotEqual(path.bezier.control1.y, 100)
        XCTAssertNotEqual(path.bezier.control2.y, 100)
        // Both control x's still ride the line — only y deflects.
        XCTAssertEqual(path.bezier.control1.x, 30, accuracy: tolerance)
        XCTAssertEqual(path.bezier.control2.x, 70, accuracy: tolerance)
    }

    // MARK: Options round-trip

    func testOptionsAreStoredOnPath() {
        let opts = CursorMotionPath.Options(
            startHandle: 0.5, endHandle: 0.4, arcSize: 0.3,
            arcFlow: 0.1, spring: 0.6
        )
        let path = CursorMotionPath(
            from: .zero, to: CGPoint(x: 10, y: 0), options: opts
        )
        XCTAssertEqual(path.options, opts)
    }
}

#endif
