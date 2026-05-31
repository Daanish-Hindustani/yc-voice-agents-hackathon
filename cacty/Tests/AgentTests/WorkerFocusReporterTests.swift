import XCTest
@testable import Agent

/// Unit tests for the `Worker.FocusReporter` plumbing without
/// spinning up Gemini or the engine.
///
/// We can't drive a full `Worker.run()` loop without a real
/// Gemini client, but the reporter is invoked from
/// `dispatch(_:)` which is private — so this test exercises the
/// reporter signature directly to lock in:
///   - the closure type is `Sendable`
///   - it accepts `(Int32, Int)` and returns `Void async`
///   - calling it from outside an actor compiles and runs
///
/// The integration that the reporter fires on every tool dispatch
/// with `pid`+`windowId` args is verified by reading the
/// dispatch-loop code (`Worker.dispatch`, 15 lines, single
/// conditional). Full integration coverage requires a Gemini
/// mock which is deferred to the Phase 1 fixture-based mock work.
final class WorkerFocusReporterTests: XCTestCase {
    func testReporterTypeSignatureCompiles() async {
        actor Spy {
            var calls: [(Int32, Int)] = []
            func record(_ pid: Int32, _ wid: Int) { calls.append((pid, wid)) }
        }
        let spy = Spy()
        let reporter: Worker.FocusReporter = { pid, wid in
            await spy.record(pid, wid)
        }
        await reporter(35855, 30961)
        await reporter(1234, 42)

        let calls = await spy.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, 35855)
        XCTAssertEqual(calls[0].1, 30961)
        XCTAssertEqual(calls[1].0, 1234)
        XCTAssertEqual(calls[1].1, 42)
    }
}
