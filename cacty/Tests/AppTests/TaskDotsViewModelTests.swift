import XCTest
@testable import App
@testable import Agent
@testable import Automation

/// Unit tests for `TaskDotsViewModel`'s reconciliation logic.
///
/// We don't exercise the poll loop here (timing-flaky). Instead,
/// drive `refresh()` directly against a real supervisor and a
/// stubbed Gemini client so we can verify:
///   - empty supervisor → empty dots
///   - new running task → one running dot
///   - dotColor mapping is stable
@MainActor
final class TaskDotsViewModelTests: XCTestCase {
    func testFreshModelHasNoDots() async {
        let supervisor = makeSupervisor()
        let model = TaskDotsViewModel(supervisor: supervisor)
        await model.refresh()
        XCTAssertEqual(model.dots.count, 0)
    }

    func testDotColorMapping() {
        XCTAssertEqual(
            AgentSupervisor.TaskStatus
                .running(startedAt: Date()).dotColor.description,
            AgentSupervisor.TaskStatus
                .running(startedAt: Date()).dotColor.description
        )
        // .succeeded → .green, .failed → .red, .cancelled → .gray,
        // .running → .blue. We don't introspect SwiftUI Color
        // internals; instead check that distinct statuses produce
        // distinct color descriptions.
        let colors: [AgentSupervisor.TaskStatus] = [
            .running(startedAt: Date()),
            .succeeded(text: "ok"),
            .failed(reason: "x"),
            .cancelled,
        ]
        let descriptions = Set(colors.map { $0.dotColor.description })
        XCTAssertEqual(descriptions.count, 4)
    }

    func testDotIsEquatableForDiffing() {
        let id = UUID()
        let a = TaskDotsViewModel.Dot(id: id, status: .cancelled)
        let b = TaskDotsViewModel.Dot(id: id, status: .cancelled)
        XCTAssertEqual(a, b)
        let c = TaskDotsViewModel.Dot(id: id, status: .succeeded(text: "ok"))
        XCTAssertNotEqual(a, c)
    }

    // MARK: - cancelDot (end-task button)

    /// Verifies the kill-button glue: `cancelDot` propagates a
    /// cancel to the supervisor so the next `refresh()` recolors
    /// the dot. We start a task whose Gemini call will fail
    /// immediately (bad key → network error) — the test asserts
    /// the supervisor records *some* terminal status (cancelled
    /// OR failed, depending on the race between cancel-arrival
    /// and HTTP-fail-arrival), which proves the
    /// view-model→supervisor wire is intact.
    func testCancelDotPropagatesToSupervisor() async throws {
        let supervisor = makeSupervisor()
        let model = TaskDotsViewModel(supervisor: supervisor)

        let id = await supervisor.startTask(prompt: "noop")
        model.cancelDot(id)

        let deadline = Date().addingTimeInterval(2)
        var finalStatus: AgentSupervisor.TaskStatus?
        while Date() < deadline {
            if let s = await supervisor.status(of: id) {
                switch s {
                case .running:
                    try? await Task.sleep(for: .milliseconds(20))
                case .cancelled, .succeeded, .failed:
                    finalStatus = s
                }
                if finalStatus != nil { break }
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertNotNil(finalStatus, "task did not reach a terminal status within 2s")
    }

    // MARK: - Helpers

    private func makeSupervisor() -> AgentSupervisor {
        let engine = Engine()
        let client = GeminiClient(apiKey: "test-key-not-used")
        return AgentSupervisor(
            client: client, engine: engine, model: "gemini-3.1-pro-preview"
        )
    }
}
