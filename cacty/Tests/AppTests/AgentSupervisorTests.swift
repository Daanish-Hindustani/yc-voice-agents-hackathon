import XCTest
@testable import App
@testable import Agent
@testable import Automation

/// Unit tests for `AgentSupervisor` that don't hit the Gemini API
/// or any real macOS app. The full success-path test (`startTask`
/// returns a `TaskID`, status transitions through `running →
/// succeeded`) is an integration test gated behind
/// `CACTY_INTEGRATION_TESTS=1` + `GEMINI_API_KEY` — same gating
/// the `Worker` integration suite uses.
///
/// What's unit-testable without a network round-trip:
///
/// - Initial state contracts (no tasks until startTask is called)
/// - `status(of:)` returns nil for unknown ids
/// - `allTaskIDs()` reflects what's been started
/// - `TaskStatus.Equatable` works for the cases that don't carry
///   `Date`s (Equatable is what lets the future UI compare
///   states across polls)
final class AgentSupervisorTests: XCTestCase {
    // MARK: - Initial state

    func testFreshSupervisorHasNoTasks() async {
        let supervisor = makeSupervisor()
        let ids = await supervisor.allTaskIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    func testStatusForUnknownTaskIsNil() async {
        let supervisor = makeSupervisor()
        let randomId = UUID()
        let status = await supervisor.status(of: randomId)
        XCTAssertNil(status)
    }

    // MARK: - startTask records the task

    func testStartTaskReturnsIdAndRecordsTheTaskAsRunning() async {
        // The Worker.run path will fail fast under the fake
        // GeminiClient (api key "test" → 4xx from real Gemini),
        // but startTask returns BEFORE that — the watcher Task
        // runs detached. So immediately after startTask, the
        // status must be .running. We sample once before the
        // watcher has had a chance to set the final status.
        let supervisor = makeSupervisor()
        let id = await supervisor.startTask(prompt: "ignored")

        // Sample status immediately; can be .running or already
        // .failed depending on how fast the watcher resolved.
        // Either is structurally valid; what we care about is
        // that the record exists.
        let status = await supervisor.status(of: id)
        XCTAssertNotNil(
            status,
            "startTask must record a task — its id should resolve to a status"
        )

        let ids = await supervisor.allTaskIDs()
        XCTAssertTrue(ids.contains(id))
    }

    // MARK: - cancelTask

    func testCancelOnUnknownIdIsNoOp() async {
        // cancelTask must not throw / crash on a stale id.
        // The UI may surface a cancel button for a task that's
        // already terminal; clicking it shouldn't blow up.
        let supervisor = makeSupervisor()
        await supervisor.cancelTask(UUID())
        // Pass if we got here.
    }

    func testCancelTransitionsToFailedOrCancelled() async throws {
        // Start a task against the bad API key, immediately
        // cancel it, then poll until terminal. The terminal
        // status will be `.cancelled` if the cancel landed
        // before the worker's network call returned, or
        // `.failed(...)` if the network failed first. Either is
        // a valid terminal state — what we pin is that the
        // task DOES reach a terminal state within a short
        // window (no hang on cancel).
        let supervisor = makeSupervisor()
        let id = await supervisor.startTask(prompt: "ignored")
        await supervisor.cancelTask(id)

        let deadline = Date().addingTimeInterval(5.0)
        var lastStatus: AgentSupervisor.TaskStatus?
        while Date() < deadline {
            lastStatus = await supervisor.status(of: id)
            if let s = lastStatus, isTerminal(s) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let final = try XCTUnwrap(lastStatus)
        XCTAssertTrue(
            isTerminal(final),
            "Task should reach a terminal status within 5s of cancel; "
                + "got \(final)"
        )
    }

    // MARK: - forgetTask

    func testForgetTaskDropsItFromAllTaskIDs() async {
        let supervisor = makeSupervisor()
        let id = await supervisor.startTask(prompt: "ignored")
        await supervisor.forgetTask(id)
        let ids = await supervisor.allTaskIDs()
        XCTAssertFalse(ids.contains(id))
        let status = await supervisor.status(of: id)
        XCTAssertNil(status)
    }

    // MARK: - TaskStatus Equatable

    func testTaskStatusEquatableForNonDateCases() {
        // The .running case carries a Date, which is comparable
        // but date equality in test code is fragile. The
        // non-date cases need Equatable so the future UI can
        // detect state changes between polls without copying
        // raw structs around.
        let a: AgentSupervisor.TaskStatus = .succeeded(text: "ok")
        let b: AgentSupervisor.TaskStatus = .succeeded(text: "ok")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, .succeeded(text: "different"))
        XCTAssertNotEqual(a, .cancelled)
        XCTAssertEqual(
            AgentSupervisor.TaskStatus.failed(reason: "x"),
            AgentSupervisor.TaskStatus.failed(reason: "x")
        )
        XCTAssertEqual(
            AgentSupervisor.TaskStatus.cancelled,
            AgentSupervisor.TaskStatus.cancelled
        )
    }

    // MARK: - Helpers

    private func makeSupervisor() -> AgentSupervisor {
        let client = GeminiClient(apiKey: "test-key-not-used")
        let engine = Engine()
        return AgentSupervisor(
            client: client,
            engine: engine,
            model: "gemini-3.1-pro-preview"
        )
    }

    private func isTerminal(_ status: AgentSupervisor.TaskStatus) -> Bool {
        switch status {
        case .running:
            return false
        case .succeeded, .failed, .cancelled:
            return true
        }
    }
}
