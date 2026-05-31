import Automation
import Foundation
import Observation
import SwiftUI

/// Observable model behind the top-right floating dots.
///
/// Each in-flight (or recently-finished) supervisor task is
/// represented by one `Dot`. The view diffs by `id` so SwiftUI
/// animates new dots in, status changes recolor in place, and
/// removed dots fade out cleanly.
///
/// Polling — not pushing — is the right shape for PR 1.6:
/// `AgentSupervisor` is an actor without an event stream today,
/// and adding one is exactly the kind of "scope expansion" the
/// project rules warn against. PR 1.7's live-video popover will
/// already drive the supervisor toward streaming; we'll
/// consolidate then.
@Observable
@MainActor
final class TaskDotsViewModel {
    struct Dot: Identifiable, Equatable {
        let id: AgentSupervisor.TaskID
        let status: AgentSupervisor.TaskStatus
    }

    private(set) var dots: [Dot] = []

    private let supervisor: AgentSupervisor
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// Shared with the app-level `LivePreviewPanel`. `nil` when
    /// the view model is constructed standalone (e.g. tests
    /// that don't exercise the hover-preview surface).
    private let livePreviewState: LivePreviewState?

    /// Recently-terminated tasks linger this long before being
    /// dropped from the dot strip — gives the user a moment to
    /// see the success / fail color change.
    private let lingerSeconds: TimeInterval

    private var terminatedAt: [AgentSupervisor.TaskID: Date] = [:]

    /// Cancellation handle for the in-flight hover-preview resolve.
    /// `beginHoverPreview` enqueues a Task that asks the supervisor
    /// for the focus; `endHoverPreview` must cancel that Task to
    /// avoid a stale `show(focus)` landing after the user already
    /// moused off (which would flash the preview with no dot
    /// hovered).
    private var hoverResolveTask: Task<Void, Never>?

    init(
        supervisor: AgentSupervisor,
        livePreviewState: LivePreviewState? = nil,
        pollInterval: Duration = .milliseconds(500),
        lingerSeconds: TimeInterval = 4
    ) {
        self.supervisor = supervisor
        self.livePreviewState = livePreviewState
        self.pollInterval = pollInterval
        self.lingerSeconds = lingerSeconds
    }

    func start() {
        if pollTask != nil { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(500))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Fire-and-forget cancel for the dot the user clicked the X
    /// on. The supervisor's cancel is cooperative — the worker's
    /// loop exits at the next tool-boundary `checkCancellation`,
    /// at which point the dot recolors via the next `refresh()`
    /// tick. UI doesn't await the result; the polling loop
    /// observes the state change.
    ///
    /// Per `plan.md` § PTT: cancel paths accept mouse only,
    /// never Fn. There is intentionally no keyboard shortcut.
    func cancelDot(_ id: AgentSupervisor.TaskID) {
        Task { await supervisor.cancelTask(id) }
    }

    /// The shared engine UI surfaces (hover popover) need so
    /// they can subscribe to `engine.captureStream(...)` against
    /// the same engine the workers drive. Pulled from the
    /// supervisor's `publicEngine` at access time so the view
    /// model doesn't have to hold a second copy.
    var engine: Engine { supervisor.publicEngine }

    /// Latest `(pid, windowId)` target reported by the worker
    /// for `id`. `nil` if the task hasn't dispatched a
    /// window-targeted tool yet. The hover popover uses this to
    /// decide whether to subscribe (skip the stream until a
    /// target exists rather than waste capture cycles on a
    /// "best guess" frontmost window).
    func currentFocus(of id: AgentSupervisor.TaskID) async -> AgentSupervisor.Focus? {
        await supervisor.currentFocus(of: id)
    }

    /// Hover entered a running dot — resolve its focus and ask
    /// the shared preview state to display it. No-op when no
    /// preview state was injected (tests).
    func beginHoverPreview(_ id: AgentSupervisor.TaskID) {
        guard let livePreviewState else { return }
        hoverResolveTask?.cancel()
        hoverResolveTask = Task { @MainActor in
            let focus = await self.supervisor.currentFocus(of: id)
            // Hover ended (or another begin superseded us) while
            // we were on the supervisor actor — drop the result
            // rather than racing past `hide()`.
            if Task.isCancelled { return }
            guard let focus else {
                // Worker hasn't dispatched a window-targeted
                // tool yet — keep preview hidden rather than
                // flashing a "waiting…" panel.
                livePreviewState.hide()
                return
            }
            livePreviewState.show(focus)
        }
    }

    /// Hover ended — drop the preview if this dot was the one
    /// being shown. We don't bother tracking per-dot ownership
    /// here: any hover-end hides. If the user is sweeping across
    /// dots, the next `beginHoverPreview` re-shows within a
    /// frame, so the user perceives a smooth handoff.
    func endHoverPreview() {
        hoverResolveTask?.cancel()
        hoverResolveTask = nil
        livePreviewState?.hide()
    }

    /// Single refresh pass: pull current task ids from the
    /// supervisor, look up each status, and reconcile the local
    /// `dots` array. Public so tests can drive it deterministically
    /// without waiting on the poll loop.
    func refresh() async {
        let ids = await supervisor.allTaskIDs()
        var next: [Dot] = []
        let now = Date()
        for id in ids {
            guard let status = await supervisor.status(of: id) else { continue }
            switch status {
            case .running:
                terminatedAt[id] = nil
                next.append(Dot(id: id, status: status))
            case .succeeded, .failed, .cancelled:
                let terminatedTime = terminatedAt[id] ?? now
                terminatedAt[id] = terminatedTime
                if now.timeIntervalSince(terminatedTime) < lingerSeconds {
                    next.append(Dot(id: id, status: status))
                }
            }
        }
        if dots != next { dots = next }
    }
}

extension AgentSupervisor.TaskStatus {
    /// Color used for the dot representing this status. Kept
    /// here rather than inside the view so the model can be
    /// unit-tested without spinning up SwiftUI.
    var dotColor: Color {
        switch self {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}
