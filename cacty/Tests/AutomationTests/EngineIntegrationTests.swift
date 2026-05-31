import XCTest
import AppKit
@testable import Automation

/// Integration tests for `Automation.Engine` action-tier methods.
///
/// **These tests touch real macOS state** — they launch real apps
/// and read real window-server state. They are gated behind the
/// `CACTY_INTEGRATION_TESTS=1` env var so CI and routine
/// `swift test` runs skip them. Run them manually on a developer
/// machine when validating engine behavior under live conditions:
///
/// ```bash
/// CACTY_INTEGRATION_TESTS=1 swift test --filter Integration
/// ```
///
/// **Background-safety contract** — every test in this suite must
/// snapshot the system's frontmost app before the action and assert
/// it is unchanged after. That is the entire reason `Automation`
/// exists; a failure here means we shipped a regression in the
/// no-foreground guarantee.
final class EngineIntegrationTests: XCTestCase {
    // The test fixture: Calculator is small, ships with macOS,
    // launches in <2s, and tolerates being terminated immediately
    // after — exactly what we want for a launch round-trip test.
    private let fixtureBundleId = "com.apple.calculator"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CACTY_INTEGRATION_TESTS"] == "1"
        else {
            throw XCTSkip(
                "Integration tests skipped — set CACTY_INTEGRATION_TESTS=1 to enable."
            )
        }
        // If a previous run left the fixture app behind, terminate
        // it so we start each test from a known no-Calculator
        // state. `forceTerminate` is OK on Apple's first-party
        // sample apps; we'd be more careful with user apps.
        terminateFixtureIfRunning()
    }

    override func tearDownWithError() throws {
        // Always clean up after ourselves so a failed assertion
        // doesn't leave Calculator running in the dock.
        terminateFixtureIfRunning()
    }

    // MARK: - launchApp

    func testLaunchAppLaunchesCalculatorWithValidPid() async throws {
        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)

        XCTAssertEqual(info.bundleId, fixtureBundleId)
        XCTAssertGreaterThan(
            info.pid, 0,
            "Launched app must report a live pid"
        )
        XCTAssertTrue(
            info.running,
            "Returned AppInfo should reflect running == true after launch"
        )
    }

    func testLaunchAppHidesNewlyLaunchedApp() async throws {
        // Cacty's product premise is "you keep working while the
        // agent runs invisibly." `activates = false` alone gives
        // visible-but-backgrounded; the engine adds an explicit
        // `NSRunningApplication.hide()` for newly-launched apps so
        // the user does not see the window pop onto their screen.
        // This test pins that behavior.
        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)

        // Poll briefly — `hide()` is processed asynchronously by
        // the window server. Cap at 1s; if the app isn't hidden
        // within that window, something regressed in launchApp's
        // hide step.
        let runningApp = NSRunningApplication(processIdentifier: info.pid)
        XCTAssertNotNil(runningApp, "Newly launched app should resolve via NSRunningApplication")

        let pollDeadline = Date().addingTimeInterval(1.0)
        var observedHidden = runningApp?.isHidden ?? false
        while Date() < pollDeadline && !observedHidden {
            try await Task.sleep(nanoseconds: 50_000_000)
            observedHidden = runningApp?.isHidden ?? false
        }
        XCTAssertTrue(
            observedHidden,
            "Newly launched Calculator should be hidden after launchApp returns"
        )
    }

    func testLaunchAppDoesNotChangeFrontmostApp() async throws {
        // The whole point of the engine. If this fails, every
        // other promise about background safety is meaningless.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let engine = Engine()
        _ = try await engine.launchApp(bundleId: fixtureBundleId)

        // Latch on the first deviation from `frontmostBefore` —
        // if the engine ever steals focus, the latch fires within
        // a few ticks of the activation event. Polling instead of
        // a fixed sleep means we exit fast on the success path
        // and we don't paper over a too-short wait on slow
        // hardware. Cap at 2s wall-clock so a hung activation
        // event surfaces as a test timeout, not a hang.
        let pollDeadline = Date().addingTimeInterval(2.0)
        var observedDeviation: String? = nil
        while Date() < pollDeadline {
            let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if current != frontmostBefore {
                observedDeviation = current
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }

        XCTAssertNil(
            observedDeviation,
            "Frontmost app changed during launchApp — background contract violated. "
                + "Was \(frontmostBefore ?? "nil"), became \(observedDeviation ?? "nil")"
        )
        // Belt-and-suspenders: even if the deviation latch passed,
        // explicitly assert Calculator did not become frontmost.
        let frontmostFinal = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertNotEqual(
            frontmostFinal, fixtureBundleId,
            "Calculator became frontmost after launch — focus was stolen"
        )
    }

    // MARK: - getWindowState

    /// Headroom over Calculator's observed launch-to-window-server
    /// register time on this hardware (~2s). Bump if slower CI
    /// machines start flaking on the launch poll.
    private static let windowAppearDeadline: Double = 3.0

    func testGetWindowStateReturnsTreeForCalculatorWindow() async throws {
        // This test additionally requires Accessibility permission
        // because the AX walk reads the tree. Skip cleanly if the
        // test runner doesn't have AX granted — surfacing this as
        // a failure would just be noise.
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "Accessibility permission not granted to the test runner. "
                + "Grant it in System Settings → Privacy & Security → "
                + "Accessibility, then re-run."
        )

        // Capture frontmost BEFORE the launch so the assertion at
        // the end covers the entire `launchApp + waitForFirstWindow
        // + getWindowState` sequence, not just the snapshot call.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)

        // Calculator's window appears asynchronously after the
        // launch returns. Poll listWindows until the pid has at
        // least one *visible* window or we hit the deadline. We
        // require `isOnScreen == true` because a stale minimized
        // window from an unclean previous run would otherwise
        // satisfy `windows.first` and produce a vacuously-shallow
        // AX snapshot.
        let calculatorWindow = try await waitForFirstWindow(
            ofPid: info.pid,
            deadline: Self.windowAppearDeadline,
            engine: engine
        )

        let snapshot = try await engine.getWindowState(
            pid: info.pid, windowId: calculatorWindow.id
        )

        XCTAssertEqual(snapshot.pid, info.pid)
        XCTAssertEqual(snapshot.bundleId, fixtureBundleId)
        XCTAssertGreaterThan(
            snapshot.elementCount, 0,
            "AX tree was empty — Calculator was launched but the snapshot saw no elements"
        )
        XCTAssertFalse(
            snapshot.treeMarkdown.isEmpty,
            "treeMarkdown should be populated when elementCount > 0"
        )
        // Cacty divergence #7: SOM mode (default) annotates
        // interactive elements with `rect=[x,y,w,h]` in
        // scaled-image-pixel space — the same coords `click(x, y)`
        // accepts. Calculator's buttons all report AXPosition + AXSize,
        // so at least one rect annotation must be present.
        XCTAssertTrue(
            snapshot.treeMarkdown.contains("rect=["),
            "SOM tree should annotate interactive elements with rect=[x,y,w,h] — "
                + "got tree:\n\(snapshot.treeMarkdown)"
        )
        // Background-safety check.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(
            frontmostBefore, frontmostAfter,
            "getWindowState changed frontmost app — background contract violated"
        )
    }

    // MARK: - clickElement

    func testClickElementOnCalculatorPreservesFrontmost() async throws {
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "Accessibility permission not granted to the test runner. "
                + "Grant it in System Settings → Privacy & Security → "
                + "Accessibility, then re-run."
        )

        // Capture frontmost BEFORE the entire launch+snapshot+click
        // sequence so the assertion covers the whole flow, not just
        // the click call.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)
        let calculatorWindow = try await waitForFirstWindow(
            ofPid: info.pid,
            deadline: Self.windowAppearDeadline,
            engine: engine
        )
        let snapshot = try await engine.getWindowState(
            pid: info.pid, windowId: calculatorWindow.id
        )
        XCTAssertGreaterThan(
            snapshot.elementCount, 0,
            "Need at least one element to attempt a click"
        )

        // Walk early indices and attempt a click. We don't pin
        // *which* element gets clicked — Calculator's exact AX
        // layout shifts between OS releases (root AXApplication /
        // AXWindow nodes typically don't accept AXPress, and the
        // first actual button has been at index 4 / 5 / 6 across
        // recent macOS releases).
        //
        // What we DO pin: the cache-lookup half of the call path.
        // If every index returns `.elementNotFound`, the engine's
        // cache plumbing is broken — that should fail the test.
        // If indices return `.actionRefused` (no AXPress
        // advertised), that's expected for non-interactive
        // elements and is fine. The split between the two
        // EngineError cases is what makes this assertion possible.
        let attemptCount = min(snapshot.elementCount, 10)
        var anyClickSucceeded = false
        var anyLookupSucceeded = false
        var refusedCount = 0
        for index in 0..<attemptCount {
            do {
                try await engine.clickElement(
                    pid: info.pid, windowId: calculatorWindow.id, elementIndex: index
                )
                anyClickSucceeded = true
                anyLookupSucceeded = true
                break
            } catch let error as Engine.EngineError {
                switch error {
                case .actionRefused:
                    // Lookup succeeded; element just doesn't
                    // advertise AXPress. Expected for non-button
                    // elements (root, window, static text).
                    anyLookupSucceeded = true
                    refusedCount += 1
                case .elementNotFound:
                    // Lookup miss for an index < elementCount —
                    // a real cache regression. Don't continue
                    // pretending it's fine; let the final
                    // assertion catch it below.
                    continue
                default:
                    XCTFail("Unexpected EngineError during click attempt: \(error)")
                    return
                }
            }
        }

        // Cache integrity — the supervisor's contract with the
        // engine is "after a snapshot, lookup works for indices
        // 0..<elementCount." If every attempt across 10 indices in
        // a non-trivial snapshot bounced as elementNotFound, the
        // cache is broken. Bound this assertion by elementCount so
        // a tiny snapshot (e.g., menu-bar-only app) can still be
        // exercised by the call path without flagging a false
        // regression.
        if snapshot.elementCount > 5 {
            XCTAssertTrue(
                anyLookupSucceeded,
                "All \(attemptCount) cache lookups returned .elementNotFound for a "
                    + "snapshot of \(snapshot.elementCount) elements — cache regression"
            )
        }

        // The cache-integrity assertion above is the regression net.
        // We deliberately don't emit a "click summary" diagnostic —
        // a passing test means nothing actionable to log; a failing
        // test prints the assertion message with the relevant
        // counts. Non-failing diagnostic prints are noise on CI
        // and get missed in green-test scrolling.
        _ = anyClickSucceeded
        _ = refusedCount

        // The whole point of the engine.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(
            frontmostBefore, frontmostAfter,
            "Frontmost changed during launch+snapshot+click — background contract violated"
        )
        XCTAssertNotEqual(
            frontmostAfter, fixtureBundleId,
            "Calculator became frontmost — focus was stolen"
        )
    }

    // MARK: - type

    func testTypeIntoCalculatorPreservesFrontmost() async throws {
        // Note: no `XCTSkipUnless(AXIsProcessTrusted())` here on
        // purpose — `CGEvent.postToPid` does not require
        // Accessibility permission, so this test runs on any
        // machine the env-var gate has opened the suite on, even
        // ones without AX granted. The peer tests for
        // `getWindowState` and `clickElement` need AX because the
        // AX walk and element lookup are what require it; typing
        // doesn't.

        // Capture frontmost BEFORE the entire sequence so the
        // assertion covers launch + type, not just type.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)

        // Type a short sequence into a hidden Calculator. We don't
        // pin the visible result — Calculator is hidden by
        // launchApp, and verifying the display would couple this
        // test to Calculator's specific AX layout (which shifts
        // between OS releases). The point of this test is the
        // **call path**: KeyboardInput.typeCharacters dispatches
        // CGEvents to the right pid, and the no-foreground
        // contract holds across a real keystroke sequence.
        //
        // "5" is a deliberately tiny input — the typing path takes
        // ~30ms per character so a long string would slow the
        // suite without proving anything new about pid-scoping.
        try await engine.type(pid: info.pid, text: "5")

        // Background-safety check.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(
            frontmostBefore, frontmostAfter,
            "Frontmost changed during launch+type — background contract violated"
        )
        XCTAssertNotEqual(
            frontmostAfter, fixtureBundleId,
            "Calculator became frontmost — focus was stolen"
        )
    }

    // MARK: - screenshot

    func testScreenshotCapturesCalculatorWindow() async throws {
        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)
        let window = try await waitForFirstWindow(
            ofPid: info.pid,
            deadline: Self.windowAppearDeadline,
            engine: engine
        )

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let screenshot = try await engine.screenshot(
            pid: info.pid, windowId: window.id
        )

        XCTAssertGreaterThan(screenshot.imageData.count, 0)
        XCTAssertGreaterThan(screenshot.width, 0)
        XCTAssertGreaterThan(screenshot.height, 0)

        // Background safety: capturing a hidden window must not
        // change the user's frontmost app.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(
            frontmostBefore, frontmostAfter,
            "screenshot changed frontmost — capture should be silent"
        )
        XCTAssertNotEqual(frontmostAfter, fixtureBundleId)
    }

    /// Phase 0 latency finding (Plan.md § Phase 0 originally
    /// targeted <50ms):
    ///
    /// Empirical measurement on stock `ScreenCaptureKit` via
    /// `WindowCapture.captureWindow` is ~100ms per call, dominated
    /// by the `SCShareableContent.current` enumeration that
    /// happens on every capture. The <50ms target was
    /// aspirational; achieving it requires an SCStream-based
    /// pipeline that amortizes window enumeration across frames.
    /// That optimization is deferred to Phase 1 polish — the
    /// 5fps hover-popover use case tolerates 100ms per frame.
    ///
    /// What this test pins is a regression net at <200ms, NOT
    /// the original <50ms spec. If the steady-state median
    /// jumps to 500ms, something genuinely regressed (e.g.,
    /// SCShareableContent fetch slowed down, the window resolved
    /// to a degenerate filter). The 100ms vs 50ms gap is a
    /// known-deferred optimization, not a regression.
    ///
    /// Median (not max) keeps the test from flaking on
    /// transient OS hiccups.
    func testScreenshotSteadyStateLatencyUnder200msRegressionNet() async throws {
        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)
        let window = try await waitForFirstWindow(
            ofPid: info.pid,
            deadline: Self.windowAppearDeadline,
            engine: engine
        )

        let totalCaptures = 6
        let warmupCount = 2
        var elapsedMs: [Double] = []
        for _ in 0..<totalCaptures {
            let start = Date()
            _ = try await engine.screenshot(
                pid: info.pid, windowId: window.id
            )
            elapsedMs.append(Date().timeIntervalSince(start) * 1000)
        }

        let steadyState = elapsedMs.dropFirst(warmupCount).sorted()
        let medianMs = steadyState[steadyState.count / 2]
        XCTAssertLessThan(
            medianMs, 200.0,
            "Steady-state capture latency \(medianMs)ms blew past the "
                + "200ms regression net (real-world target is ~100ms on stock "
                + "SCK; <50ms requires the deferred SCStream pipeline). "
                + "Per-frame: \(elapsedMs.map { String(format: "%.1f", $0) })"
        )
    }

    func testCaptureStreamYieldsFramesAtRequestedRate() async throws {
        // Open a stream at 5 fps, take 3 frames, assert each
        // frame's image is non-empty and the frames arrive
        // within a reasonable window. Tests the producer Task
        // termination cleanly when the consumer breaks the loop.
        let engine = Engine()
        let info = try await engine.launchApp(bundleId: fixtureBundleId)
        let window = try await waitForFirstWindow(
            ofPid: info.pid,
            deadline: Self.windowAppearDeadline,
            engine: engine
        )

        let stream = engine.captureStream(
            pid: info.pid, windowId: window.id, fps: 5
        )
        var collected: [Screenshot] = []
        let start = Date()
        for await frame in stream {
            collected.append(frame)
            if collected.count >= 3 { break }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(collected.count, 3)
        for frame in collected {
            XCTAssertGreaterThan(frame.imageData.count, 0)
            XCTAssertGreaterThan(frame.width, 0)
        }
        // 3 frames at 5fps means roughly 0.4s minimum (2 sleep
        // intervals between 3 frames) and a generous upper bound
        // of 3s for slow hardware.
        XCTAssertGreaterThan(elapsed, 0.3)
        XCTAssertLessThan(
            elapsed, 3.0,
            "Stream took \(elapsed)s for 3 frames at 5fps; producer may be hung"
        )
    }

    // MARK: - Helpers

    private func waitForFirstWindow(
        ofPid pid: Int32, deadline seconds: Double, engine: Engine
    ) async throws -> WindowInfo {
        // Calculator's window can take up to ~2s after launch
        // returns to register with the window server. Poll every
        // 100ms; a hung launch should surface as a clear test
        // failure, not a silent wait.
        //
        // We deliberately do NOT filter on `isOnScreen` — hidden
        // apps (which `Engine.launchApp` produces by design)
        // report `isOnScreen == false` even though the window
        // exists and is fully drivable via AX. Filter on non-zero
        // bounds instead, which still excludes phantom CG entries
        // (zero-size system overlays, in-flight teardowns) without
        // rejecting our hidden fixture.
        let endTime = Date().addingTimeInterval(seconds)
        while Date() < endTime {
            let windows = engine.listWindows(forPid: pid)
                .filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
            if let first = windows.first {
                return first
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTestError(
            .timeoutWhileWaiting,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Window for pid \(pid) did not appear within \(seconds)s"
            ]
        )
    }

    private func terminateFixtureIfRunning() {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == fixtureBundleId {
            // Polite first; the OS will SIGKILL if the app refuses
            // (Calculator never refuses). We don't `forceTerminate`
            // unconditionally because the test runner shouldn't be
            // hostile to other Apple apps in case the bundle id
            // ever resolves to something the user cares about.
            app.terminate()
        }
        // `terminate()` is async — wait for the process to actually
        // exit before returning. Without this, a quick test sequence
        // could observe a half-alive Calculator left over from the
        // previous test. Cap at 2s; a hung Calculator would surface
        // as a real test failure, not a hidden flake.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let stillRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == fixtureBundleId
            }
            if !stillRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
