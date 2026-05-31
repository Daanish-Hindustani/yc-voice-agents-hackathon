import XCTest
import AppKit
@testable import Agent
@testable import Automation

/// End-to-end integration test for the agent loop. Hits the **real
/// Gemini API** AND drives **real macOS apps** through the engine.
///
/// **Costs money** (small Gemini token charges per run) and
/// requires a working API key. Three layers of gating:
///
/// - `CACTY_INTEGRATION_TESTS=1` enables the integration tier
/// - `GEMINI_API_KEY=<key>` provides API credentials
/// - `AXIsProcessTrusted()` must be true for AX-using tools
///
/// Run manually:
///
/// ```bash
/// CACTY_INTEGRATION_TESTS=1 GEMINI_API_KEY=… \
///     swift test --filter WorkerIntegrationTests
/// ```
///
/// **Phase 0 vertical slice:** the test below is the closed-loop
/// validation for Phase 0 — Gemini emits a `launch_app` call,
/// Worker dispatches it via `Engine`, the response goes back to
/// Gemini, Gemini emits a final text confirmation, the loop
/// terminates. Assert: Calculator is now running, hidden, and
/// the loop's text response is non-empty. When this passes,
/// every Phase 0 unknown is dead and Phase 1 vertical slice can
/// start.
final class WorkerIntegrationTests: XCTestCase {
    private let fixtureBundleId = "com.apple.calculator"

    private var model: String {
        ProcessInfo.processInfo.environment["GEMINI_MODEL"]
            ?? "gemini-3.1-pro-preview"
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CACTY_INTEGRATION_TESTS"] == "1"
        else {
            throw XCTSkip(
                "Integration tests skipped — set CACTY_INTEGRATION_TESTS=1 to enable."
            )
        }
        terminateFixtureIfRunning()
    }

    override func tearDownWithError() throws {
        terminateFixtureIfRunning()
    }

    // MARK: - Phase 0 closed-loop test

    func testWorkerDrivesGeminiToOpenCalculator() async throws {
        // Triple-gated: env var (skip), API key (skip), AX
        // (skip). Without all three the test cleanly skips
        // rather than failing.
        let apiKey = try requireApiKey()

        let client = GeminiClient(apiKey: apiKey)
        let engine = Engine()
        let worker = Worker(client: client, engine: engine, model: model)

        // Capture frontmost BEFORE the whole loop so the
        // background-safety assertion at the end covers every
        // Gemini turn + every engine dispatch.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let prompt = """
            The user asked you to open the macOS Calculator app. \
            Use the launch_app tool with the appropriate bundle id. \
            Reply with a one-sentence confirmation when done.
            """
        let finalText = try await worker.run(prompt: prompt)

        XCTAssertFalse(
            finalText.isEmpty,
            "Worker returned no final text — the loop didn't terminate cleanly. "
                + "This shouldn't happen unless Gemini hit max steps without "
                + "producing a text-only candidate."
        )

        // Calculator should now be running, hidden, and not
        // frontmost. The engine's launchApp post-hide retry is
        // what makes this assertion possible.
        let calculator = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == fixtureBundleId
        }
        let unwrappedCalc = try XCTUnwrap(
            calculator,
            "Calculator never started — Worker → Engine dispatch path is broken."
        )
        // Poll briefly for hide() to settle (same pattern as
        // EngineIntegrationTests).
        let hideDeadline = Date().addingTimeInterval(2.0)
        while Date() < hideDeadline && !unwrappedCalc.isHidden {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(
            unwrappedCalc.isHidden,
            "Calculator started but isn't hidden — the launchApp post-hide path "
                + "regressed."
        )

        // Background safety: frontmost unchanged across the
        // entire Worker loop.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(
            frontmostBefore, frontmostAfter,
            "Frontmost changed during the agent loop — "
                + "background contract violated by some step in the dispatch chain."
        )
        XCTAssertNotEqual(
            frontmostAfter, fixtureBundleId,
            "Calculator became frontmost — focus was stolen."
        )
    }

    // MARK: - Multi-step AX-tree validation (Phase 0 closer)

    func testWorkerDrivesGeminiThroughMultiStepCalculatorTask() async throws {
        // PHASE 0 AX-TREE VALIDATION.
        //
        // The `testWorkerDrivesGeminiToOpenCalculator` test above
        // proves Gemini can call ONE tool (`launch_app`). It does
        // NOT prove Gemini can read an AX tree we hand it via
        // `get_window_state` and emit valid `element_index`
        // clicks against it. That second proof is the actual
        // Phase 0 unknown — "Gemini reliability on real Mac AX
        // trees" per PLAN.md § Phase 0 risks.
        //
        // This test forces a multi-step plan: launch → snapshot →
        // click → confirm. The dispatch-trace assertion at the end
        // verifies every required tool was actually invoked.
        //
        // **Hallucination finding (Phase 1 supervisor concern):**
        // an earlier draft of this prompt was politely-worded
        // ("use launch_app... use click_element..."). Gemini
        // executed launch + list_windows + get_window_state, then
        // emitted text claiming the click had landed — without
        // ever invoking `click_element`. The dispatch trace
        // exposed the hallucination. Phase 1's supervisor must
        // implement the verify-via-snapshot pattern from
        // `docs/agent-skills/driving-mac-apps.md` (re-snapshot
        // after every click and confirm visual change) to defend
        // against this. The current imperative prompt below is a
        // workaround for the test; production should not rely on
        // prompt directness alone.
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "Accessibility permission not granted to the test runner — "
                + "AX-tree multi-step test requires it."
        )
        let apiKey = try requireApiKey()

        let client = GeminiClient(apiKey: apiKey)
        let engine = Engine()
        // Slightly higher cap for the multi-step task; the model
        // may need extra turns to explore the tree.
        let worker = Worker(
            client: client, engine: engine, model: model, maxSteps: 16
        )

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let prompt = """
            CRITICAL: You MUST execute every step by calling the actual \
            tool. Do NOT describe a plan and stop. Do NOT claim a click \
            happened unless you literally invoked the click_element \
            function. The system will detect uncalled tools.

            Task: open the macOS Calculator and click the digit button \
            labeled "7".

            Required tool sequence — execute each one as a real function \
            call, in order:

              1. launch_app(bundleId: "com.apple.calculator")
              2. list_windows(pid: <pid from step 1>)
              3. get_window_state(pid: <pid>, windowId: <id from step 2>)
              4. Read the returned tree_markdown. Find the line for the \
                 AXButton whose AXTitle is "7" and note its element_index.
              5. click_element(pid: <pid>, windowId: <id>, \
                 elementIndex: <index from step 4>)

            Step 5 is mandatory. After step 5 lands, reply with a one- \
            sentence confirmation. If the tree from step 3 has fewer than \
            10 elements (Calculator may still be loading), call \
            get_window_state again before attempting step 5.
            """

        let finalText = try await worker.run(prompt: prompt)

        // Loop terminated cleanly (didn't hit max steps).
        XCTAssertFalse(
            finalText.isEmpty,
            "Worker returned no text — multi-step loop didn't terminate."
        )

        // The actual AX-tree validation: assert Gemini exercised
        // every step the prompt required. If the dispatch trace
        // is missing get_window_state or click_element, the model
        // skipped the AX path (e.g., it might have stopped at
        // launch_app and replied with text). Both failure modes
        // mean Phase 0's AX-tree unknown is NOT cleared.
        let trace = await worker.dispatchedToolNames
        XCTAssertTrue(
            trace.contains("launch_app"),
            "Trace missing launch_app — model never started the app. Trace: \(trace)"
        )
        XCTAssertTrue(
            trace.contains("get_window_state"),
            "Trace missing get_window_state — model never inspected the AX "
                + "tree, so the tree-comprehension unknown is NOT validated. "
                + "Trace: \(trace)"
        )
        XCTAssertTrue(
            trace.contains("click_element"),
            "Trace missing click_element — model didn't follow through on "
                + "the AX tree it received. Trace: \(trace)"
        )

        // Verify-via-snapshot (PR 1.1) MUST have fired at least
        // once during the multi-step task. A click_element
        // dispatch with verification enabled increments
        // verificationSnapshotCount. If this is zero, the
        // hallucination defense is silently disabled — bigger
        // problem than any single test failure.
        let verifyCount = await worker.verificationSnapshotCount
        XCTAssertGreaterThan(
            verifyCount, 0,
            "verificationSnapshotCount is 0 after a multi-step task that "
                + "dispatched click_element. The post-action verify pass "
                + "didn't fire — Phase 1's structural defense against "
                + "hallucination is silently disabled. Trace: \(trace)"
        )

        // Calculator should be running and hidden.
        let calculator = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == fixtureBundleId
        }
        let unwrappedCalc = try XCTUnwrap(calculator)
        let hideDeadline = Date().addingTimeInterval(2.0)
        while Date() < hideDeadline && !unwrappedCalc.isHidden {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(unwrappedCalc.isHidden)

        // Background safety across a multi-turn loop.
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(
            frontmostBefore, frontmostAfter,
            "Frontmost changed during multi-step agent loop — "
                + "background contract held for the single-step launch test "
                + "but regressed under longer conversations."
        )
        XCTAssertNotEqual(frontmostAfter, fixtureBundleId)
    }

    // MARK: - Helpers

    private func requireApiKey() throws -> String {
        guard
            let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
            !key.isEmpty
        else {
            throw XCTSkip(
                "GEMINI_API_KEY not set — cannot run real-API integration tests."
            )
        }
        return key
    }

    private func terminateFixtureIfRunning() {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == fixtureBundleId {
            app.terminate()
        }
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
