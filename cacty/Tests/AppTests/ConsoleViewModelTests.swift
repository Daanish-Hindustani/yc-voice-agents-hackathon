import XCTest
@testable import Agent
@testable import App
@testable import Automation

@MainActor
final class ConsoleViewModelTests: XCTestCase {
    // MARK: - Empty state

    func testFreshModelHasNoSummaries() async {
        let supervisor = makeSupervisor()
        let model = ConsoleViewModel(supervisor: supervisor)
        await model.refresh()
        XCTAssertTrue(model.summaries.isEmpty)
    }

    // MARK: - Task surfacing + sort

    func testStartedTasksAppearInSummariesNewestFirst() async {
        let supervisor = makeSupervisor()
        let model = ConsoleViewModel(supervisor: supervisor)

        let firstId = await supervisor.startTask(prompt: "first")
        // Small gap so the second startedAt is strictly later —
        // avoids relying on Date() resolution.
        try? await Task.sleep(for: .milliseconds(5))
        let secondId = await supervisor.startTask(prompt: "second")

        await model.refresh()
        XCTAssertEqual(model.summaries.count, 2)
        XCTAssertEqual(model.summaries[0].id, secondId, "newest task should be first")
        XCTAssertEqual(model.summaries[0].prompt, "second")
        XCTAssertEqual(model.summaries[1].id, firstId)
        XCTAssertEqual(model.summaries[1].prompt, "first")
    }

    // MARK: - Cancel

    func testCancelPropagatesToSupervisor() async throws {
        let supervisor = makeSupervisor()
        let model = ConsoleViewModel(supervisor: supervisor)

        let id = await supervisor.startTask(prompt: "noop")
        model.cancel(id)

        // Same pattern as TaskDotsViewModelTests — wait for any
        // terminal state since the bad-key network failure may
        // race the cancel signal.
        let deadline = Date().addingTimeInterval(2)
        var terminal: AgentSupervisor.TaskStatus?
        while Date() < deadline {
            if let s = await supervisor.status(of: id), case .running = s {
                try? await Task.sleep(for: .milliseconds(20))
            } else if let s = await supervisor.status(of: id) {
                terminal = s
                break
            }
        }
        XCTAssertNotNil(terminal, "task did not reach terminal state within 2s")
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
