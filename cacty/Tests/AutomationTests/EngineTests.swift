import XCTest
@testable import Automation

/// Tests for the public `Engine` facade. Covers the read-only methods
/// that don't require AX / Screen Recording / Input Monitoring grants —
/// those belong in the future `BackgroundInvariantTests` integration
/// target, not here.
final class EngineTests: XCTestCase {
    func testEngineInstantiates() {
        // The actor must be constructible via its public init —
        // the AgentSupervisor will hold one as a stored property.
        _ = Engine()
    }

    // MARK: - version

    func testVersionMatchesCoreVersion() {
        // `version` is `nonisolated` — no `await` needed.
        let engine = Engine()
        XCTAssertEqual(engine.version, CuaDriverCore.version)
    }

    // MARK: - listApps

    func testListAppsReturnsAtLeastOneRunningApp() {
        // The test runner itself is a running app, so the result
        // must include at least one entry. We don't assert the
        // specific contents — that would couple the test to the
        // test runner's bundle id.
        let engine = Engine()
        let apps = engine.listApps()
        XCTAssertFalse(apps.isEmpty)
        XCTAssertTrue(apps.contains(where: { $0.running }))
    }

    func testListAppsEntriesHaveStableSchema() {
        // Lock the public shape: every record has a non-empty name
        // and a valid pid (0 is allowed for installed-not-running
        // apps; > 0 for running ones).
        let engine = Engine()
        let apps = engine.listApps()
        for app in apps {
            XCTAssertFalse(app.name.isEmpty, "App with empty name: \(app)")
            if app.running {
                XCTAssertGreaterThan(app.pid, 0, "Running app has pid 0: \(app)")
            }
        }
    }

    // MARK: - listWindows

    func testListWindowsForLaunchdReturnsEmpty() {
        // Pid 1 is launchd — by macOS design it never owns UI
        // windows. The engine should return an empty array. Tests
        // the "no windows is a normal state" contract for any pid
        // that owns no windows.
        let engine = Engine()
        let windows = engine.listWindows(forPid: 1)
        XCTAssertTrue(windows.isEmpty)
    }

    func testListWindowsFiltersByPid() {
        // Cross-check: the union of windows across all running pids
        // must be a subset of `allWindows()`. Validates the filter
        // is exclusive — no window leaks into another pid's result,
        // and the facade does not fabricate window ids that don't
        // appear in the raw enumerator.
        let engine = Engine()
        let allRunning = engine.listApps().filter { $0.running }
        var union: Set<Int> = []
        for app in allRunning {
            let windows = engine.listWindows(forPid: app.pid)
            for window in windows {
                XCTAssertEqual(
                    window.pid, app.pid,
                    "listWindows(forPid: \(app.pid)) returned window owned by pid \(window.pid)"
                )
                union.insert(window.id)
            }
        }
        let everything = Set(WindowEnumerator.allWindows().map { $0.id })
        XCTAssertTrue(
            union.isSubset(of: everything),
            "filtered pid windows escaped allWindows()"
        )
    }

    // MARK: - permissions

    func testPermissionsReturnsConcreteStatus() async {
        // The probe always returns a status — even when both grants
        // are denied. We don't assert true/false because that
        // depends on the developer's machine state. The contract is
        // "this never blocks indefinitely and never throws."
        let engine = Engine()
        let status = await engine.permissions()
        // Both fields are Bool — accessing them confirms the type.
        _ = status.accessibility
        _ = status.screenRecording
    }

    // MARK: - launchApp (unit tier — error path only)
    //
    // The success path of `launchApp` actually launches a real Mac
    // app and is therefore an integration test, gated by
    // `CACTY_INTEGRATION_TESTS=1`. See `EngineIntegrationTests.swift`
    // for that suite. The error path is unit-testable here because
    // the `locate()` step fails synchronously without any
    // LaunchServices call.

    func testLaunchAppForUnknownBundleIdThrowsEngineError() async {
        let engine = Engine()
        // Pick a bundle id that cannot resolve — LaunchServices
        // returns notFound before any process is created.
        let fakeBundleId = "com.cacty.test.definitely-does-not-exist"
        // `launchApp` is `throws(EngineError)`, so the catch type is
        // statically known — no `as` cast or "unexpected error" branch
        // needed.
        do {
            _ = try await engine.launchApp(bundleId: fakeBundleId)
            XCTFail("Expected throw for unknown bundle id")
        } catch let .appLaunchFailed(reason) {
            // The wrapped reason should mention the bundle id so
            // the supervisor can render a useful message. We don't
            // pin the exact text — that's an upstream
            // implementation detail.
            XCTAssertTrue(
                reason.lowercased().contains("not found")
                    || reason.lowercased().contains("could not locate"),
                "Reason should describe a not-found failure; got: \(reason)"
            )
        } catch {
            XCTFail("Expected .appLaunchFailed, got \(error)")
        }
    }

    func testEngineErrorEquatable() {
        // Lock the Equatable conformance so future cases stay
        // pattern-matchable. This is the typed-throws contract.
        XCTAssertEqual(
            Engine.EngineError.appLaunchFailed(reason: "x"),
            Engine.EngineError.appLaunchFailed(reason: "x")
        )
        XCTAssertNotEqual(
            Engine.EngineError.appLaunchFailed(reason: "x"),
            Engine.EngineError.appLaunchFailed(reason: "y")
        )
        XCTAssertNotEqual(
            Engine.EngineError.appLaunchFailed(reason: "x"),
            Engine.EngineError.windowNotOwnedByPid(
                windowId: 1, ownerPid: 1, requestedPid: 2
            )
        )
    }

    // MARK: - getWindowState (input-validation tier — error path only)
    //
    // The success path of `getWindowState` walks a real AX tree and
    // requires Accessibility permission. That belongs in
    // `EngineIntegrationTests`. The two cases here cover the
    // input-validation contract that fails synchronously before any
    // AX call — guaranteed to work without permissions.

    func testGetWindowStateRejectsNegativeWindowId() async {
        let engine = Engine()
        do {
            _ = try await engine.getWindowState(pid: 1234, windowId: -1)
            XCTFail("Expected throw for negative windowId")
        } catch let .invalidWindowId(value) {
            XCTAssertEqual(value, -1)
        } catch {
            XCTFail("Expected .invalidWindowId, got \(error)")
        }
    }

    func testGetWindowStateRejectsWindowIdLargerThanUInt32Max() async {
        let engine = Engine()
        let tooBig = Int(UInt32.max) + 1
        do {
            _ = try await engine.getWindowState(pid: 1234, windowId: tooBig)
            XCTFail("Expected throw for windowId > UInt32.max")
        } catch let .invalidWindowId(value) {
            XCTAssertEqual(value, tooBig)
        } catch {
            XCTFail("Expected .invalidWindowId, got \(error)")
        }
    }

    func testGetWindowStateAcceptsWindowIdAtUInt32Max() async {
        // Boundary: UInt32.max is a valid CGWindowID. Validation
        // shouldn't reject it. The call will fail downstream
        // (no real window has this id, AX walk will throw), but
        // the failure mode must be `.windowStateFailed` from the
        // engine layer, not `.invalidWindowId` from input
        // validation. This test pins which side of the boundary
        // owns the rejection.
        let engine = Engine()
        do {
            _ = try await engine.getWindowState(
                pid: 1234, windowId: Int(UInt32.max)
            )
            XCTFail("Expected throw — pid 1234 won't have UInt32.max as a window")
        } catch .invalidWindowId {
            XCTFail(".invalidWindowId fired for a value that does fit UInt32")
        } catch let error as Engine.EngineError {
            // Any non-validation EngineError case is acceptable —
            // the failure path depends on whether the test runner
            // has AX granted (notAuthorized) or not (some other
            // path). The point of this test is "validation
            // passed, downstream rejected." Catch with an explicit
            // `as` cast so a future relaxation of the typed-throws
            // contract (untyped `throws`) wouldn't silently let a
            // non-EngineError sneak past the assertion.
            _ = error
        }
    }

    // MARK: - clickElement (input-validation tier — error path only)
    //
    // The success path of `clickElement` requires Accessibility
    // permission AND a prior `getWindowState` call that wrote to the
    // cache; that belongs in `EngineIntegrationTests`. The two cases
    // below cover validation that fails synchronously — guaranteed to
    // work without permissions.

    func testClickElementRejectsNegativeWindowId() async {
        let engine = Engine()
        do {
            try await engine.clickElement(pid: 1234, windowId: -1, elementIndex: 0)
            XCTFail("Expected throw for negative windowId")
        } catch let .invalidWindowId(value) {
            XCTAssertEqual(value, -1)
        } catch {
            XCTFail("Expected .invalidWindowId, got \(error)")
        }
    }

    func testClickElementWithoutPriorSnapshotThrowsElementNotFound() async {
        // Cache miss path: a fresh Engine has never seen
        // `(pid: 1234, windowId: 1)`, so `lookup` throws and the
        // engine surfaces it as `.elementNotFound` with the
        // requested coordinates. Pins the cache-keying contract
        // (callers MUST snapshot first) without needing AX
        // permission or a real window. The structured case lets
        // the supervisor distinguish "need to re-snapshot" from
        // "element refused the action" — they have different
        // recovery strategies.
        let engine = Engine()
        do {
            try await engine.clickElement(
                pid: 1234, windowId: 1, elementIndex: 0
            )
            XCTFail("Expected throw — no snapshot has been taken for this pid/windowId")
        } catch let .elementNotFound(pid, windowId, elementIndex) {
            XCTAssertEqual(pid, 1234)
            XCTAssertEqual(windowId, 1)
            XCTAssertEqual(elementIndex, 0)
        } catch {
            XCTFail("Expected .elementNotFound, got \(error)")
        }
    }

    // MARK: - type (input-validation tier — error path only)
    //
    // The success path of `type` posts CGEvents to a real pid; that
    // belongs in `EngineIntegrationTests`. The empty-text fast path
    // is unit-testable here because it returns before any event
    // dispatch — guaranteed to work without permissions.

    // MARK: - screenshot (input-validation tier — error path only)

    func testScreenshotRejectsNegativeWindowId() async {
        let engine = Engine()
        do {
            _ = try await engine.screenshot(pid: 1234, windowId: -1)
            XCTFail("Expected throw for negative windowId")
        } catch let .invalidWindowId(value) {
            XCTAssertEqual(value, -1)
        } catch {
            XCTFail("Expected .invalidWindowId, got \(error)")
        }
    }

    // MARK: - captureStream

    func testCaptureStreamWithInvalidWindowIdEndsImmediately() async {
        // Out-of-UInt32 windowId should produce an empty stream
        // (no frames, terminates cleanly). Doesn't throw — the
        // contract for AsyncStream is "finish silently when there's
        // nothing to produce" so consumers can use a plain `for
        // await` loop without a try/catch envelope.
        let engine = Engine()
        let stream = engine.captureStream(
            pid: 1234, windowId: -1, fps: 5
        )
        var frameCount = 0
        for await _ in stream {
            frameCount += 1
            if frameCount > 0 { break }
        }
        XCTAssertEqual(frameCount, 0)
    }

    func testTypeWithEmptyTextIsNoOpAndDoesNotThrow() async throws {
        // The engine's contract for empty input: no events, no
        // throw. The supervisor's planner can produce a degenerate
        // empty-string result (e.g., a Gemini turn with no
        // recognized characters) and shouldn't have to special-case
        // it.
        //
        // Pid 1 (launchd) would cause a real type call to fail, so
        // passing it here exercises that the empty guard fires
        // BEFORE we touch the keyboard subsystem. The timing
        // assertion below pins this structurally — even one real
        // character would take ~30ms (per-char pacing in
        // `KeyboardInput.typeCharacters`), so a return under 50ms
        // proves no characters were dispatched. Without this
        // structural check, a future refactor that drops the
        // empty-text guard could silently pass for the wrong
        // reason (typing zero chars is also a no-op at the
        // keyboard layer, but takes longer due to thread hop).
        let engine = Engine()
        let start = Date()
        try await engine.type(pid: 1, text: "")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 0.05,
            "Empty text should fast-path before the keyboard subsystem; "
                + "took \(Int(elapsed * 1000))ms"
        )
    }
}
