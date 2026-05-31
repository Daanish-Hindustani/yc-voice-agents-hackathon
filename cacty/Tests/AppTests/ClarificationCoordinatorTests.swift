import XCTest
@testable import Agent
@testable import App

@MainActor
final class ClarificationCoordinatorTests: XCTestCase {
    // MARK: - Selected choice

    func testSelectChoiceResolvesWithMatchingText() async {
        let coordinator = ClarificationCoordinator()
        let task = Task {
            await coordinator.askUser(
                ClarificationRequest(
                    question: "Which workspace?",
                    choices: ["Personal", "Acme"]
                )
            )
        }
        try? await waitForPending(coordinator, count: 1)

        let id = coordinator.pending[0].id
        coordinator.selectChoice(id, index: 1)

        let reply = await task.value
        XCTAssertEqual(reply, .selected(index: 1, text: "Acme"))
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    func testSelectChoiceOutOfBoundsIgnored() async {
        let coordinator = ClarificationCoordinator()
        let task = Task {
            await coordinator.askUser(
                ClarificationRequest(question: "X?", choices: ["A", "B"])
            )
        }
        try? await waitForPending(coordinator, count: 1)
        let id = coordinator.pending[0].id

        // Out of bounds — should not resolve the continuation.
        coordinator.selectChoice(id, index: 99)
        XCTAssertEqual(coordinator.pending.count, 1, "out-of-bounds select must not pop")

        // Valid resolution still works.
        coordinator.selectChoice(id, index: 0)
        let reply = await task.value
        XCTAssertEqual(reply, .selected(index: 0, text: "A"))
    }

    // MARK: - Free-form

    func testFreeformAnswerResolvesWithTrimmedText() async {
        let coordinator = ClarificationCoordinator()
        let task = Task {
            await coordinator.askUser(
                ClarificationRequest(question: "Subject?")
            )
        }
        try? await waitForPending(coordinator, count: 1)
        coordinator.submitFreeform(
            coordinator.pending[0].id,
            text: "   Lunch tomorrow  \n"
        )
        let reply = await task.value
        XCTAssertEqual(reply, .freeform(text: "Lunch tomorrow"))
    }

    func testFreeformEmptyTreatedAsSkip() async {
        let coordinator = ClarificationCoordinator()
        let task = Task {
            await coordinator.askUser(
                ClarificationRequest(question: "X?")
            )
        }
        try? await waitForPending(coordinator, count: 1)
        coordinator.submitFreeform(coordinator.pending[0].id, text: "    ")
        let reply = await task.value
        XCTAssertEqual(reply, .skipped)
    }

    // MARK: - Explicit skip

    func testSkipResolvesAsSkipped() async {
        let coordinator = ClarificationCoordinator()
        let task = Task {
            await coordinator.askUser(
                ClarificationRequest(question: "X?", choices: ["A"])
            )
        }
        try? await waitForPending(coordinator, count: 1)
        coordinator.skip(coordinator.pending[0].id)
        let reply = await task.value
        XCTAssertEqual(reply, .skipped)
    }

    // MARK: - Cancellation

    func testCancellationResolvesAsCancelled() async {
        let coordinator = ClarificationCoordinator()
        let task = Task {
            await coordinator.askUser(
                ClarificationRequest(question: "X?")
            )
        }
        try? await waitForPending(coordinator, count: 1)

        task.cancel()
        let reply = await task.value
        XCTAssertEqual(reply, .cancelled)

        try? await waitForPending(coordinator, count: 0)
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    // MARK: - Helpers

    private func waitForPending(
        _ coordinator: ClarificationCoordinator,
        count: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.pending.count != count {
            if Date() > deadline {
                throw NSError(
                    domain: "ClarificationCoordinatorTests",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "expected pending.count == \(count) within \(timeout)s, got \(coordinator.pending.count)"
                    ]
                )
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
