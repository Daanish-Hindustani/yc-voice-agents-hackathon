import XCTest
@testable import Automation

#if canImport(CoreGraphics)
import CoreGraphics

/// Pure-math tests for `CubicBezier` — sampling at parametric t,
/// tangent direction, and `cgPath` shape. No graphics calls; just the
/// formulas.
final class CubicBezierTests: XCTestCase {
    private let tolerance: CGFloat = 1e-9

    // MARK: point(at:)

    func testPointAtZeroReturnsStart() {
        let curve = CubicBezier(
            start: CGPoint(x: 10, y: 20),
            control1: CGPoint(x: 30, y: 40),
            control2: CGPoint(x: 50, y: 60),
            end: CGPoint(x: 70, y: 80)
        )
        let p = curve.point(at: 0)
        XCTAssertEqual(p.x, 10, accuracy: tolerance)
        XCTAssertEqual(p.y, 20, accuracy: tolerance)
    }

    func testPointAtOneReturnsEnd() {
        let curve = CubicBezier(
            start: CGPoint(x: 10, y: 20),
            control1: CGPoint(x: 30, y: 40),
            control2: CGPoint(x: 50, y: 60),
            end: CGPoint(x: 70, y: 80)
        )
        let p = curve.point(at: 1)
        XCTAssertEqual(p.x, 70, accuracy: tolerance)
        XCTAssertEqual(p.y, 80, accuracy: tolerance)
    }

    func testStraightLineMidpointIsAverageOfStartAndEnd() {
        // Degenerate "linear" cubic: control points sit on the
        // start-end line, evenly spaced. At t=0.5 the curve passes
        // through the midpoint of start and end.
        let curve = CubicBezier(
            start: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: 10, y: 0),
            control2: CGPoint(x: 20, y: 0),
            end: CGPoint(x: 30, y: 0)
        )
        let p = curve.point(at: 0.5)
        XCTAssertEqual(p.x, 15, accuracy: 1e-6)
        XCTAssertEqual(p.y, 0, accuracy: 1e-6)
    }

    // MARK: tangentRadians(at:)

    func testTangentOfHorizontalStraightLineIsZeroRadians() {
        // All points on the x-axis going right -> tangent is +x
        // direction -> atan2(0, +) == 0.
        let curve = CubicBezier(
            start: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: 1, y: 0),
            control2: CGPoint(x: 2, y: 0),
            end: CGPoint(x: 3, y: 0)
        )
        XCTAssertEqual(curve.tangentRadians(at: 0.5), 0, accuracy: 1e-9)
    }

    func testTangentOfVerticalStraightLineIsHalfPi() {
        // All points on the y-axis going down (positive y) -> tangent
        // direction (0, +) -> atan2(+, 0) == pi/2.
        let curve = CubicBezier(
            start: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: 0, y: 1),
            control2: CGPoint(x: 0, y: 2),
            end: CGPoint(x: 0, y: 3)
        )
        XCTAssertEqual(
            curve.tangentRadians(at: 0.5), .pi / 2, accuracy: 1e-9
        )
    }

    // MARK: cgPath

    func testCGPathStartsAtStartPoint() {
        let curve = CubicBezier(
            start: CGPoint(x: 5, y: 7),
            control1: CGPoint(x: 1, y: 2),
            control2: CGPoint(x: 3, y: 4),
            end: CGPoint(x: 9, y: 11)
        )
        // Walk the path and assert the first element is moveTo(start).
        var first: CGPoint? = nil
        curve.cgPath.applyWithBlock { elementPtr in
            if first != nil { return }
            let element = elementPtr.pointee
            if element.type == .moveToPoint {
                first = element.points[0]
            }
        }
        XCTAssertEqual(first?.x, 5)
        XCTAssertEqual(first?.y, 7)
    }
}

#endif
