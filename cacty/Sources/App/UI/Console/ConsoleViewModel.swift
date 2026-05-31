import Foundation
import Observation

/// Observable model behind the Console window.
///
/// Polls `supervisor.taskSummaries()` at a slow cadence (1 Hz)
/// — the Console is a foreground inspection tool, not a live
/// stream; humans don't perceive sub-second status changes in a
/// table view. The dot strip's 500ms cadence is more responsive
/// for the in-corner UI where movement is small and frequent.
@Observable
@MainActor
final class ConsoleViewModel {
    private(set) var summaries: [AgentSupervisor.TaskSummary] = []

    private let supervisor: AgentSupervisor
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(
        supervisor: AgentSupervisor,
        pollInterval: Duration = .seconds(1)
    ) {
        self.supervisor = supervisor
        self.pollInterval = pollInterval
    }

    func start() {
        if pollTask != nil { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Single refresh pass. Exposed for tests so they can drive
    /// the view model deterministically without waiting for the
    /// poll cadence.
    func refresh() async {
        let next = await supervisor.taskSummaries()
        if next != summaries { summaries = next }
    }

    /// Fire-and-forget cancel for a task. Mirrors
    /// `TaskDotsViewModel.cancelDot` — the supervisor cancel is
    /// cooperative, the next poll picks up the new status.
    func cancel(_ id: AgentSupervisor.TaskID) {
        Task { await supervisor.cancelTask(id) }
    }
}
