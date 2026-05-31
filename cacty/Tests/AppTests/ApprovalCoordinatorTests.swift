import XCTest
@testable import Agent
@testable import App

/// State-machine tests for the approval queue. Covers:
///
/// - Approve/deny resolves the matching pending request.
/// - Worker call suspends until UI resolves.
/// - Cancellation resolves pending request as denied.
/// - Double-resolve is a no-op (race between user click and
///   cancellation handler).
@MainActor
final class ApprovalCoordinatorTests: XCTestCase {
    // MARK: - Approve / deny basics

    func testApproveResolvesContinuationAndDrainsQueue() async {
        let coordinator = ApprovalCoordinator()

        let task = Task {
            await coordinator.requestApproval(
                toolName: "hotkey",
                summary: "Send via ⌘ Return",
                reason: "send_hotkey", scopeKey: nil
            )
        }

        // Wait until the request lands in the queue. The hop from
        // worker → MainActor isn't synchronous; spinning a few
        // times keeps the test deterministic without an
        // unbounded sleep.
        try? await waitForPending(coordinator, count: 1)

        XCTAssertEqual(coordinator.pending.count, 1)
        let id = coordinator.pending[0].id
        coordinator.approve(id)

        let decision = await task.value
        XCTAssertEqual(decision, .approved)
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    func testDenyPropagatesReasonToWorker() async {
        let coordinator = ApprovalCoordinator()

        let task = Task {
            await coordinator.requestApproval(
                toolName: "press_key",
                summary: "Press Return",
                reason: "bare_return", scopeKey: nil
            )
        }
        try? await waitForPending(coordinator, count: 1)

        let id = coordinator.pending[0].id
        coordinator.deny(id, reason: "wait, let me check the draft")

        let decision = await task.value
        XCTAssertEqual(
            decision,
            .denied(reason: "wait, let me check the draft")
        )
    }

    func testDenyWithEmptyReasonFallsBackToDefault() async {
        let coordinator = ApprovalCoordinator()
        let task = Task {
            await coordinator.requestApproval(
                toolName: "set_config", summary: "Change config", reason: "set_config", scopeKey: nil
            )
        }
        try? await waitForPending(coordinator, count: 1)
        coordinator.deny(coordinator.pending[0].id, reason: "   ")
        let decision = await task.value
        XCTAssertEqual(decision, .denied(reason: "user_denied"))
    }

    // MARK: - Cancellation

    func testCancellationResolvesPendingAsDenied() async {
        let coordinator = ApprovalCoordinator()

        let task = Task {
            await coordinator.requestApproval(
                toolName: "hotkey",
                summary: "Send",
                reason: "send_hotkey", scopeKey: nil
            )
        }
        try? await waitForPending(coordinator, count: 1)

        task.cancel()
        let decision = await task.value
        XCTAssertEqual(decision, .denied(reason: "cancelled"))

        // Queue should be drained — the cancelled request must
        // not linger in the UI.
        try? await waitForPending(coordinator, count: 0)
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    // MARK: - FIFO + multi-pending

    func testTwoPendingRequestsResolvedIndependently() async {
        let coordinator = ApprovalCoordinator()

        let firstTask = Task {
            await coordinator.requestApproval(
                toolName: "hotkey", summary: "Send 1", reason: "send_hotkey", scopeKey: nil
            )
        }
        try? await waitForPending(coordinator, count: 1)

        let secondTask = Task {
            await coordinator.requestApproval(
                toolName: "set_config", summary: "Config", reason: "set_config", scopeKey: nil
            )
        }
        try? await waitForPending(coordinator, count: 2)

        // Resolve in reverse order; both tasks should still get
        // their own decisions.
        let firstId = coordinator.pending[0].id
        let secondId = coordinator.pending[1].id
        coordinator.deny(secondId, reason: "no")
        coordinator.approve(firstId)

        let secondDecision = await secondTask.value
        let firstDecision = await firstTask.value
        XCTAssertEqual(secondDecision, .denied(reason: "no"))
        XCTAssertEqual(firstDecision, .approved)
    }

    // MARK: - Double-resolve race

    func testDoubleResolveIsNoOp() async {
        let coordinator = ApprovalCoordinator()
        let task = Task {
            await coordinator.requestApproval(
                toolName: "hotkey", summary: "Send", reason: "send_hotkey", scopeKey: nil
            )
        }
        try? await waitForPending(coordinator, count: 1)

        let id = coordinator.pending[0].id
        coordinator.approve(id)
        // Second resolve must not crash (would double-resume the
        // CheckedContinuation otherwise).
        coordinator.approve(id)
        coordinator.deny(id)

        let decision = await task.value
        XCTAssertEqual(decision, .approved)
    }

    // MARK: - Helpers

    /// Spin briefly until `pending.count == count`, with a timeout.
    /// Used because the worker→MainActor hop is async; without
    /// this we'd race the assertion against the enqueue.
    private func waitForPending(
        _ coordinator: ApprovalCoordinator,
        count: Int,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.pending.count != count {
            if Date() > deadline {
                throw NSError(
                    domain: "ApprovalCoordinatorTests",
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
