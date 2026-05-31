import Agent
import Automation
import Foundation
import os

private let log = Logger(subsystem: "com.cacty", category: "supervisor")

/// Task-lifecycle orchestrator for the Cacty app.
///
/// The supervisor sits between the user-facing surfaces (Fn-PTT,
/// menu-bar, future dot UI / approval bar / clarification panel)
/// and the agent layer (`Worker` from PR #15 + verify-via-snapshot
/// from PR #21). Its responsibilities for Phase 1 PR 1.3:
///
/// - Hold the shared `Engine`, `GeminiClient`, model id, and a
///   small pool of `Worker`s (size 1 to start; PR 1.6 expands to
///   match the parallel-tasks contract from PLAN.md when the
///   floating-dot UI can display multiple).
/// - Start a task from a prompt, returning a `TaskID` the caller
///   uses to poll status, cancel, or eventually wire into UI.
/// - Track each task's state through its lifecycle:
///   `running → succeeded / failed / cancelled`.
///
/// What's deliberately NOT in this PR:
///
/// - Approval flow (PR 1.8 / 1.9)
/// - Clarification panel hookup (PR 1.10)
/// - Window-lock conflict detection (PR 1.7-adjacent)
/// - Sensitivity rules (PR 1.9)
///
/// Those layer on top once the basic task-lifecycle plumbing
/// here is solid. The current shape — start, cancel, status —
/// is the minimum viable surface for a "single worker, full
/// Gemini loop" demo per PLAN.md § Phase 1.
public actor AgentSupervisor {
    /// Stable identifier for a task. UUIDs are overkill for a
    /// single-process supervisor, but they're zero-config and
    /// trivially `Sendable`; revisit if we ever need ordered ids.
    public typealias TaskID = UUID

    public enum TaskStatus: Sendable, Equatable {
        /// Task is currently being driven by a worker. The
        /// `startedAt` timestamp lets UI surfaces show "running
        /// for 12s" without the supervisor having to push events.
        case running(startedAt: Date)

        /// The worker loop terminated cleanly with the model's
        /// final text response.
        case succeeded(text: String)

        /// The worker loop threw. `reason` is the underlying
        /// error captured as `String(describing:)` so the type
        /// stays `Sendable + Equatable` (we don't carry
        /// `any Error` because that breaks both contracts).
        case failed(reason: String)

        /// The task was cancelled by the supervisor — typically
        /// because the user clicked the "End task" button or
        /// quit the app mid-task.
        case cancelled
    }

    private struct Record {
        let id: TaskID
        let task: Task<String, any Error>
        let prompt: String
        let startedAt: Date
        var status: TaskStatus
    }

    /// Read-only snapshot of a task suitable for the Console UI.
    /// Pulled into its own struct (not just exposing `Record`)
    /// so the supervisor's internal handle (`Task<String, any
    /// Error>`) doesn't leak across the actor boundary — that
    /// type is not `Sendable` in a useful way.
    public struct TaskSummary: Sendable, Equatable, Identifiable {
        public let id: TaskID
        public let prompt: String
        public let startedAt: Date
        public let status: TaskStatus
    }

    /// Sticky "what is this task looking at right now" target,
    /// updated whenever a worker dispatches a tool with both
    /// `pid` and `windowId` args. The hover-popover reads this
    /// to know which window to live-capture for a given task.
    public struct Focus: Sendable, Equatable {
        public let pid: Int32
        public let windowId: Int
    }

    private let client: GeminiClient
    private let engine: Engine
    /// Exposed so UI surfaces (hover popover, future console)
    /// can call `engine.captureStream(...)` against the same
    /// engine the workers use. Read-only — task lifecycle is
    /// owned by the supervisor.
    public nonisolated let publicEngine: Engine
    private let model: String
    private let approvalGate: any ApprovalGate
    private let clarificationGate: any ClarificationGate
    private var records: [TaskID: Record] = [:]
    private var focusByTask: [TaskID: Focus] = [:]
    /// Count of tasks currently in `.running` state. Used to flip
    /// the agent-cursor overlay on the moment the first task
    /// starts and off when the last terminates — the model no
    /// longer has to remember to call `set_agent_cursor_enabled`
    /// for users to see clicks happening on screen.
    private var runningCount: Int = 0

    public init(
        client: GeminiClient,
        engine: Engine,
        model: String,
        approvalGate: any ApprovalGate = AlwaysApproveGate(),
        clarificationGate: any ClarificationGate = AlwaysSkipClarificationGate()
    ) {
        self.client = client
        self.engine = engine
        self.publicEngine = engine
        self.model = model
        self.approvalGate = approvalGate
        self.clarificationGate = clarificationGate
    }

    /// Start a task from a user prompt. Returns immediately with
    /// a `TaskID`; the worker runs asynchronously in the
    /// background. Poll `status(of:)` or — once Phase 1 has UI
    /// surfaces wired — receive events via the future status
    /// stream (not in this PR; UI surfaces in 1.6+ will use
    /// polling as a first cut).
    ///
    /// `verifyAfterAction` defaults on (the Phase 1 hallucination
    /// defense from PR 1.1); production callers leave it alone.
    /// Tests can pass `false` to exercise the raw dispatch path.
    @discardableResult
    public func startTask(
        prompt: String,
        verifyAfterAction: Bool = true
    ) -> TaskID {
        let id = TaskID()
        // Capture id once so the focus reporter doesn't have to
        // know which task it belongs to — closures the worker
        // calls into already carry the binding.
        let capturedID = id
        let focusReporter: Worker.FocusReporter = { [weak self] pid, windowId in
            await self?.recordFocus(
                id: capturedID,
                focus: Focus(pid: pid, windowId: windowId)
            )
        }

        let worker = Worker(
            client: client,
            engine: engine,
            model: model,
            verifyAfterAction: verifyAfterAction,
            approvalGate: approvalGate,
            clarificationGate: clarificationGate,
            focusReporter: focusReporter
        )

        // The actual run is wrapped in a Swift `Task` so the
        // worker's loop runs in the background and `startTask`
        // returns immediately. The supervisor learns about
        // termination via the completion handler below; it does
        // NOT await the task here because that would defeat the
        // whole point of running tasks concurrently with the UI.
        let workerTask = Task<String, any Error> {
            try await worker.run(prompt: prompt)
        }

        let startedAt = Date()
        let record = Record(
            id: id,
            task: workerTask,
            prompt: prompt,
            startedAt: startedAt,
            status: .running(startedAt: startedAt)
        )
        records[id] = record
        incrementRunning()

        // Watcher: when the worker terminates, fold its outcome
        // into the supervisor's status map. `Task.detached`
        // (not the inherited-isolation `Task {}`) is load-bearing
        // here — inheriting the supervisor's isolation would
        // block the actor's executor for the WHOLE worker run,
        // blocking concurrent startTask / cancelTask / status
        // calls. Detached runs off-actor; the `await
        // recordFinalStatus` then correctly hops back to the
        // actor to mutate the records map.
        //
        // The captured `self` is the actor itself. Actors aren't
        // WeakReferenceable in Swift 6; the supervisor lives for
        // the app's lifetime so retaining it from a child Task
        // is acceptable.
        Task.detached { [self] in
            let final: TaskStatus
            do {
                let text = try await workerTask.value
                final = .succeeded(text: text)
            } catch is CancellationError {
                final = .cancelled
            } catch {
                final = .failed(reason: String(describing: error))
            }
            // Mirror terminal states into the unified Logger so
            // debugging doesn't require clicking through the menu UI.
            // Truncate body so a 50KB Gemini error doesn't wallpaper
            // the log stream.
            let payload = "\(final)"
            let truncated = payload.count > 4000
                ? String(payload.prefix(4000)) + "…"
                : payload
            log.info("task \(id, privacy: .public): \(truncated, privacy: .public)")
            await self.recordFinalStatus(id: id, status: final)
        }

        return id
    }

    /// Cancel a running task. No-op if the task already
    /// terminated or the id is unknown. Cancellation is
    /// cooperative — the worker's loop checks
    /// `Task.checkCancellation()` between turns, so a cancel
    /// issued mid-Gemini-call may not interrupt until the next
    /// turn boundary. That's acceptable for the supervisor's
    /// "End task" button UX; the alternative (force-killing a
    /// turn) leaves the conversation in a half-state.
    public func cancelTask(_ id: TaskID) {
        records[id]?.task.cancel()
    }

    /// Current status for a task. Returns `nil` if the id
    /// doesn't match any task the supervisor knows about (the
    /// caller passed a stale id, or the supervisor was
    /// re-initialized).
    public func status(of id: TaskID) -> TaskStatus? {
        records[id]?.status
    }

    /// Every task the supervisor knows about, in undefined
    /// order. Used by the dot-strip view model for its
    /// reconciliation pass; the Console UI uses
    /// `taskSummaries()` instead because it needs richer per-task
    /// state (prompt, start time) that the dot strip ignores.
    public func allTaskIDs() -> [TaskID] {
        return Array(records.keys)
    }

    /// Console-shaped snapshot of every known task, sorted by
    /// `startedAt` descending (newest first) so the UI can
    /// render top-to-bottom without re-sorting on every poll.
    public func taskSummaries() -> [TaskSummary] {
        records.values
            .map {
                TaskSummary(
                    id: $0.id,
                    prompt: $0.prompt,
                    startedAt: $0.startedAt,
                    status: $0.status
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Drop a task's record entirely. Used by tests and (Phase
    /// 4+) any retention-policy code that prunes old completed
    /// tasks. The associated Swift Task is cancelled first if
    /// still running, on the assumption that "forget about this
    /// task" implies "and stop it if it's still going."
    public func forgetTask(_ id: TaskID) {
        if let record = records[id], case .running = record.status {
            decrementRunning()
        }
        records[id]?.task.cancel()
        records.removeValue(forKey: id)
        focusByTask.removeValue(forKey: id)
    }

    /// Most recently reported `(pid, windowId)` for a task —
    /// `nil` if the task has not yet dispatched a tool with both
    /// args (e.g. it's still in the first Gemini round-trip, or
    /// has only made global queries like `list_apps`).
    public func currentFocus(of id: TaskID) -> Focus? {
        focusByTask[id]
    }

    // MARK: - Internal

    private func recordFinalStatus(id: TaskID, status: TaskStatus) {
        guard let record = records[id] else { return }
        let wasRunning: Bool = {
            if case .running = record.status { return true }
            return false
        }()
        records[id]?.status = status
        if wasRunning {
            decrementRunning()
        }
    }

    private func incrementRunning() {
        runningCount += 1
        if runningCount == 1 {
            let engine = self.engine
            Task { @MainActor in
                engine.setAgentCursorEnabled(true)
            }
        }
    }

    private func decrementRunning() {
        runningCount = max(0, runningCount - 1)
        if runningCount == 0 {
            let engine = self.engine
            Task { @MainActor in
                engine.setAgentCursorEnabled(false)
            }
        }
    }

    private func recordFocus(id: TaskID, focus: Focus) {
        focusByTask[id] = focus
    }
}
