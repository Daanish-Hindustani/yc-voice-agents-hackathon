import Agent
import Automation
import AppKit
import Foundation
import Observation

/// Wires the PTT input layer (Fn-key + speech) to the agent
/// orchestrator (AgentSupervisor). Phase 1 PR 1.5 — the moment
/// "hold Fn → speak → agent runs the task in the background"
/// becomes one continuous wire, not three separate pieces.
///
/// Observable so SwiftUI surfaces can render the live PTT state
/// without polling: while Fn is held, `liveTranscript` updates
/// per partial recognition; on release, `lastStartedTaskId`
/// changes to the new task's id and the menu surface can update
/// its label.
///
/// The coordinator owns: the engine, the Gemini client, the
/// supervisor, the Fn-key handler, the speech recognizer. The
/// `CactyApp` SwiftUI scene holds a single `AppCoordinator` and
/// reads its observable state.
@Observable
@MainActor
final class AppCoordinator {
    /// Aggregated PTT + agent state for the menu UI. Single
    /// enum so the SwiftUI binding has one Equatable thing to
    /// switch over.
    enum State: Equatable {
        /// Default state. Nothing is recording, no task is in
        /// flight.
        case idle

        /// User is holding Fn; we're capturing audio and
        /// streaming partial transcripts.
        case recording(partial: String)

        /// Audio capture ended; waiting on the recognizer's
        /// final result before dispatching to the supervisor.
        case transcribing

        /// Supervisor has accepted a task; the worker is
        /// running.
        case running(taskId: AgentSupervisor.TaskID, prompt: String)

        /// A task just finished (or failed / was cancelled).
        /// UI surfaces "last task: <prompt>" briefly before
        /// reverting to `.idle`.
        case settling(text: String)

        /// Permission denied or some setup-level failure that
        /// blocks PTT entirely. The menu surface shows the
        /// message; user has to fix it in System Settings and
        /// relaunch.
        case blocked(reason: String)
    }

    private(set) var state: State = .idle

    /// Most recent finalized transcript. The PR 1.6 dot UI
    /// shows this on hover.
    private(set) var lastFinalTranscript: String = ""

    /// Most recent supervisor task id. Tests and future console
    /// can correlate against `AgentSupervisor.status(of:)`.
    private(set) var lastStartedTaskId: AgentSupervisor.TaskID?

    /// Exposed so UI surfaces (e.g. the floating dot strip) can
    /// build their own view models against the same supervisor
    /// the coordinator drives. Read-only — task lifecycle stays
    /// owned by the coordinator.
    let supervisor: AgentSupervisor

    /// Same shape as `supervisor`: held here so the app shell can
    /// hand it to the `ApprovalBarPanel` without reaching into
    /// supervisor internals. The supervisor and the coordinator
    /// share one `ApprovalCoordinator` instance — that's the gate
    /// the worker queries and the queue the UI renders.
    let approvalCoordinator: ApprovalCoordinator

    /// Same shape as `approvalCoordinator` for the `ask_user`
    /// tool's clarification flow.
    let clarificationCoordinator: ClarificationCoordinator

    /// Shared "what is the user currently hovering" state for
    /// the live-preview panel. Written by `DotItemView` hover
    /// callbacks; observed by `LivePreviewPanel`'s polling
    /// refresh loop. Single instance per app.
    let livePreviewState: LivePreviewState

    private let fnHandler: FnKeyHandler
    private let recognizer: SpeechRecognizer

    init(
        supervisor: AgentSupervisor,
        approvalCoordinator: ApprovalCoordinator = ApprovalCoordinator(),
        clarificationCoordinator: ClarificationCoordinator = ClarificationCoordinator(),
        livePreviewState: LivePreviewState = LivePreviewState(),
        fnHandler: FnKeyHandler = FnKeyHandler(),
        recognizer: SpeechRecognizer = SpeechRecognizer()
    ) {
        self.supervisor = supervisor
        self.approvalCoordinator = approvalCoordinator
        self.clarificationCoordinator = clarificationCoordinator
        self.livePreviewState = livePreviewState
        self.fnHandler = fnHandler
        self.recognizer = recognizer

        wireFnHandler()
        wireRecognizer()
    }

    /// Bring the coordinator online: request mic + speech
    /// authorization, install the Fn event tap. Should be
    /// called once at app launch (`CactyApp.onAppear` /
    /// equivalent). Routes any setup failure into the
    /// `.blocked` state so the UI can surface it.
    func start() async {
        // Speech + mic auth first — these can prompt the user.
        // Doing this before installing the Fn tap means a user
        // who clicks "Don't allow" on the prompts gets a clear
        // blocked-state message instead of "tap installed but
        // nothing happens when I press Fn."
        switch await recognizer.requestAuthorization() {
        case .success:
            break
        case .failure(let err):
            state = .blocked(reason: err.description)
            return
        }

        switch fnHandler.start() {
        case .success:
            state = .idle
        case .failure(let err):
            state = .blocked(reason: err.description)
        }
    }

    /// Tear everything down. Used by app quit and tests.
    func stop() {
        fnHandler.stop()
        recognizer.stopRecording()
    }

    /// Submit a typed prompt directly to the supervisor, bypassing
    /// Fn-PTT + speech entirely. Used by the menu-bar text-input
    /// surface so testers can drive the agent without holding Fn
    /// or speaking. State transitions match the speech path:
    /// `.running → .settling → .idle`.
    func submitTextPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        if case .blocked = state { return }
        lastFinalTranscript = trimmed
        Task { @MainActor in
            let id = await self.supervisor.startTask(prompt: trimmed)
            self.lastStartedTaskId = id
            self.state = .running(taskId: id, prompt: trimmed)
            self.watchTask(id, prompt: trimmed)
        }
    }

    // MARK: - Wiring

    private func wireFnHandler() {
        fnHandler.onPress = { [weak self] in
            guard let self else { return }
            // Always attempt to start — even from .blocked.
            // Bailing out of .blocked silently means a user who
            // recovers the permission state (granted mic in
            // System Settings, installed a dictation model) has
            // no way to retry. `startRecording()` will fail
            // again with the same error if the conditions still
            // hold, which surfaces the actual problem.
            state = .recording(partial: "")
            switch recognizer.startRecording() {
            case .success:
                break
            case .failure(let err):
                state = .settling(text: "Speech failed: \(err.description)")
                scheduleSettle()
            }
        }
        fnHandler.onRelease = { [weak self] in
            guard let self else { return }
            // Only finalize a recording — if Fn was tapped while
            // we were elsewhere in the state machine, do nothing.
            guard case .recording = state else { return }
            state = .transcribing
            recognizer.stopRecording()
            // The final transcript arrives async in onFinal —
            // see wireRecognizer below.
        }
    }

    private func wireRecognizer() {
        recognizer.onPartial = { [weak self] partial in
            guard let self else { return }
            if case .recording = state {
                state = .recording(partial: partial)
            }
        }
        recognizer.onFinal = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                lastFinalTranscript = text
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    state = .idle
                    return
                }
                // Hand the transcript to the supervisor.
                // `await` requires a Task here; the supervisor
                // call is fast (just records the task) but we
                // can't block the main actor.
                Task { @MainActor in
                    let id = await self.supervisor.startTask(prompt: trimmed)
                    self.lastStartedTaskId = id
                    self.state = .running(taskId: id, prompt: trimmed)
                    self.watchTask(id, prompt: trimmed)
                }
            case .failure(let err):
                state = .settling(
                    text: "Speech failed: \(err.description)"
                )
                // Auto-return to .idle so the user can retry by
                // pressing Fn again. Without this, the state
                // stays in `.settling` permanently, masking the
                // next press as "nothing happens."
                scheduleSettle()
            }
        }
    }

    private func watchTask(
        _ id: AgentSupervisor.TaskID, prompt: String
    ) {
        // Poll for terminal status. Fine for PR 1.5 (we don't
        // have many tasks in flight); PR 1.6's dot UI will
        // switch to an AsyncStream for richer updates.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(120) // 2-minute cap
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let status = await self.supervisor.status(of: id)
                switch status {
                case .running, .none:
                    continue
                case .succeeded(let text):
                    self.state = .settling(
                        text: text.isEmpty ? "Task complete." : text
                    )
                    self.scheduleSettle()
                    return
                case .failed(let reason):
                    self.state = .settling(text: "Failed: \(reason)")
                    self.scheduleSettle()
                    return
                case .cancelled:
                    self.state = .settling(text: "Task cancelled.")
                    self.scheduleSettle()
                    return
                }
            }
            // Hit the polling deadline — surface as "still
            // running" rather than artificially terminate.
            // Real cancel goes through supervisor.cancelTask.
        }
    }

    private func scheduleSettle() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
            guard let self else { return }
            if case .settling = self.state {
                self.state = .idle
            }
        }
    }
}
