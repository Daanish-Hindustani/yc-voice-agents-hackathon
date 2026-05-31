import AppKit
import Automation
import Foundation
import os

private let log = Logger(subsystem: "com.cacty", category: "agent")

/// Single-task agent loop. Runs the Gemini ↔ Engine round-trip
/// until the model emits a text-only response (the task is done)
/// or hits a configured step cap.
///
/// One `Worker` per task — Cacty's supervisor (Phase 1) holds a
/// fixed-size pool of these and assigns each in-flight task to
/// one. The worker is `nonisolated` against actor reentrancy
/// concerns: it only mutates its own `contents` history, and
/// downstream calls into `Engine` and `GeminiClient` are
/// serialized through their own actor executors.
///
/// The loop pattern:
///
/// 1. Build initial `contents` with the user prompt + the full
///    `ToolSchema.allEngineTools()` declaration set.
/// 2. POST to Gemini via `GeminiClient.generateResponse`.
/// 3. If the response has function calls, dispatch each via
///    `Engine`, wrap the result as a `FunctionResponse`, append
///    a `function`-role `Content` to history, and loop.
/// 4. If the response is text-only, return the joined text.
/// 5. If the loop hits `maxSteps`, throw `.maxStepsExceeded`.
///
/// Tool failures (engine throwing, missing args) are caught and
/// surfaced back to Gemini as an `error` object inside the
/// `FunctionResponse` — the loop continues so the model can try
/// a different approach. Only programmer errors and
/// authorization failures propagate out as Worker errors.
public actor Worker {
    /// Persistent steering shipped as Gemini `systemInstruction` on
    /// every step. Addresses observed failure modes where the model
    /// asks the user for tool-resolvable facts (bundle IDs, pids,
    /// window IDs) instead of calling `list_apps` / `list_windows`.
    /// Build the system instruction for a single Gemini turn.
    /// Inlines the current local date, weekday, and timezone so the
    /// model can resolve relative references like "tomorrow" or
    /// "next Friday" without asking. Without this, Gemini's
    /// training cutoff date is the only anchor it has — observed
    /// failure: voice command "schedule for tomorrow at 7pm" with
    /// today = 2026-05-17 produced an event on the wrong day.
    static func makeSystemInstruction(now: Date = Date()) -> Content {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateLine = formatter.string(from: now)
        let tz = TimeZone.current.identifier
        let prelude = """
        Current local date: \(dateLine). Timezone: \(tz). Use this when \
        the user mentions relative times like "today", "tomorrow", \
        "tonight", "next Monday", or "in two hours" — convert to an \
        absolute date before typing it into any UI field. When a target \
        UI (e.g. Google Calendar's date input) accepts only a specific \
        format, format the absolute date to match that field's expected \
        format (e.g. "May 18, 2026"), not the relative phrase.

        """
        return Content(role: "user", parts: [Part(text: prelude + Self.systemInstructionBody)])
    }

    /// Static rule body. The dynamic prelude (current date, tz) is
    /// prepended per-turn by `makeSystemInstruction(now:)`.
    static let systemInstructionBody: String = """
        You are Cacty's macOS automation agent. You drive native Mac apps in \
        the background while the user keeps working. Follow these rules \
        without exception:

        1. NEVER ask the user for facts you can resolve with a tool. \
           Specifically: bundle identifiers, process IDs (pids), and \
           window IDs are ALL resolvable. Use `list_apps` to find a \
           target app's `bundle_id` and `pid` from its display name. \
           Use `list_windows(pid)` to find a window's `window_id`. If \
           the user says "read slack activity," you call \
           `list_apps`, find Slack's pid and bundle, call \
           `launch_app(bundleId: <found>)`, then `list_windows` and \
           `get_window_state` against the result. You never ask \
           "what is Slack's bundle ID."

        1a. Freshly-opened windows take 1–3 s to finish loading \
            and start producing live capture frames. If the first \
            `get_window_state` after `launch_app` returns an empty \
            or blank screenshot, do NOT report failure to the user \
            — call `get_window_state` again (and again, up to four \
            times total) before concluding the window is broken. \
            The AX tree may also be sparse on first read for web \
            content; a second snapshot 1 s later typically returns \
            the populated tree. Treat "blank capture once" as a \
            timing artifact, not a failure.

        2. For ANY target app you intend to capture, always call \
           `launch_app(bundleId)` first — even when `list_apps` shows \
           the app is already running. This is idempotent and is the \
           only way to guarantee capturable pixels for previously- \
           hidden or minimized apps.

        3. After `launch_app`, call `list_windows` to pick a window, \
           then `get_window_state(captureMode: "som")` to read \
           message text, canvas pixels, and other content that may \
           not surface in the AX tree.

        4. Background contract: your actions must not steal focus from \
           the user's current frontmost app. The engine enforces this \
           for tool calls — you don't need to take special steps, but \
           you also must not request the user activate a target app.

        5. Be concise. The user is voice-driven; they want the answer, \
           not a recap of which tools you called.

        6. Electron chat apps (Discord, Slack, MS Teams): the message \
           input is a Slate.js / Draft.js / Lexical rich-text editor. \
           `type_text` (AX `kAXSelectedText` write) RETURNS SUCCESS \
           but silently no-ops — the editor manages its own state and \
           ignores AX writes. ALWAYS use this chain for those targets: \
           `click(elementIndex of input)` → \
           `type_text_chars(pid, text)` → \
           `press_key(pid, keys: ["return"])`. Never call `type_text` \
           on a Discord / Slack / Teams message field. If a post-state \
           snapshot shows the input is still empty after type_text \
           returned "ok," that confirms the silent-discard bug — \
           switch to `type_text_chars` and retry.

        7. Browser reads (Chrome, Brave, Edge): always prefer the \
           `page` tool for reading content — no tab switching, no \
           focus steal. The `enable_javascript_apple_events` action \
           is DESTRUCTIVE: it QUITS the entire browser process \
           (closing every window the user has open) to patch a \
           Preferences file on disk, then relaunches. Treat it as \
           a one-time install-time setup, not a runtime fix. \
           Specifically: \
           (a) If `page(execute_javascript)` succeeded at ANY point \
               in the current task, the flag is already enabled — \
               NEVER call `enable_javascript_apple_events` again in \
               the same task. The supervisor will refuse it. \
           (b) If `page(execute_javascript)` fails with "Allow \
               JavaScript from Apple Events is not enabled" AND no \
               prior page call has succeeded in this task, escalate \
               to the user via `ask_user` rather than calling the \
               enable action mid-task. Quitting Chrome to fix this \
               costs the user every open tab they have; that is not \
               a decision the agent makes unilaterally. \
           (c) Do NOT call `enable_javascript_apple_events` \
               speculatively, defensively, or "just to be safe." \
               It is only ever the right answer when (b)'s \
               conditions are met.

        8. Element indices are SCOPED TO THE MOST RECENT \
           `get_window_state` snapshot of a particular (pid, \
           windowId). They are NOT stable across snapshots — the \
           same logical UI element (e.g. Discord's message input) \
           usually moves to a different index every time you \
           re-snapshot. After ANY `get_window_state` call (including \
           the automatic post-state snapshot embedded in your tool \
           result), you MUST read fresh indices from that new \
           snapshot's `tree_markdown` before using them. NEVER reuse \
           an index from a previous turn. If a tool returns "ok" but \
           the post-state shows the action didn't land (e.g. the \
           message input is still empty), do NOT retry with the \
           same element_index — read the new snapshot's tree, find \
           the correct element again, and use the freshly-resolved \
           index. Stale-index retries are the #1 source of looped \
           failures; reading fresh is the only reliable recovery.

        9. When the voice command is genuinely ambiguous in a way no \
           tool can resolve — "send the email to John" with two \
           Johns in the user's recent contacts, "schedule it for \
           next week" without a day, a destructive choice with two \
           safe paths — call `ask_user(question, choices?)`. The \
           user sees a panel and replies; you get their answer back \
           as the tool result. Use 2–4 short `choices` whenever the \
           answer space is discrete. If the user replies \
           `{"reply_type": "skipped"}`, either abort with a clear \
           one-sentence explanation or proceed with your best \
           guess and SAY SO in your final response. Do NOT call \
           `ask_user` for anything resolvable via `list_apps` / \
           `list_windows` / `get_window_state` / `page` — rule 1 \
           still applies.

        10a. Browser SPA buttons that open a popover, dropdown, \
             listbox, date picker, or time picker (Google Calendar's \
             start/end time fields, Google Calendar's date field, \
             Gmail's "Send" arrow chevron, Google Docs font-size \
             box, etc.) often silently no-op on `click` with \
             `element_index` even though the call returns "ok" — \
             AXPress fires but the React/Vue handler only listens \
             for real mouse events. ALWAYS use `click(x, y)` with \
             the element's pixel coordinates for these widgets, \
             NOT `click(element_index)`. \
             Interactive lines in the `get_window_state(captureMode: \
             "som")` tree carry `rect=[x, y, w, h]` in the SAME \
             scaled-image-pixel coordinate space `click(x, y)` \
             accepts. Compute the click point as \
             `(x + w/2, y + h/2)` and pass it to `click` directly — \
             do NOT eyeball coordinates off the screenshot. \
             Elements that don't carry a rect (containers without \
             on-screen geometry, etc.) are not pixel-clickable. \
             After every such click, immediately call \
             `get_window_state(captureMode: "som")` and confirm \
             the expected popover / listbox / picker appeared in \
             the new snapshot before proceeding. If it didn't \
             appear, the click missed — do NOT type into the \
             unopened field and do NOT assume the change took \
             effect. Re-issue the pixel click slightly off-center, \
             or try a different addressable element from the fresh \
             snapshot. Reporting "the time was set" without first \
             verifying the picker opened is a hallucination — \
             rule 0 of background automation is: trust post-state, \
             never trust "ok".

        11. Google Calendar (calendar.google.com) — full skill in \
            `docs/agent-skills/google-calendar.md`. To create an \
            event: \
            (a) `launch_app("com.google.Chrome")` then \
                `page(execute_javascript, "window.location.href = \
                'https://calendar.google.com'")`. Do not use the \
                omnibox. \
            (b) Click the red "Create" button in the top-left of \
                the left rail, then click "Event" in the dropdown. \
                Faster alternative: click an empty cell in the \
                grid at the desired time — the panel pre-fills \
                that date and a 1-hour slot. \
            (c) Type the title into the title input at the top of \
                the panel. \
            (d) For the Start date, Start time, End date, and End \
                time buttons: use `click(x, y)` with the SOM tree's \
                `rect=[x, y, w, h]` center — `click(x + w/2, y + \
                h/2)` — NOT `click(element_index)`. These are \
                React widgets that ignore AXPress: element-index \
                clicks return "ok" but the picker popover never \
                opens. After each click, re-snapshot and verify \
                the picker is in the new tree before typing the \
                value into it. \
            (e) Write dates as `<MonthName> <D>, <YYYY>` \
                (e.g. `May 18, 2026`). Calendar does not parse \
                relative phrases like "tomorrow" in the input \
                field — resolve relative dates from rule 0's \
                current-date prelude first. \
            (f) Write times as `7:00pm` or `7 PM`. \
            (g) Click "Save". After saving, re-snapshot and \
                confirm the event panel has dismissed and the \
                grid is back. Only then report success — `ok` from \
                a tool call is not evidence the event was created. \
            For other operations (read, edit, delete, navigate, \
            invite guests), follow the procedures in the skill \
            doc. The grid already shows event titles, so reading \
            "what do I have today" rarely requires opening events.

        10. Native macOS menu-bar items (the File / Edit / View / \
            Window row at the top of the screen — role \
            `AXMenuBarItem` / `AXMenuBar`) are background-unsafe \
            to click: doing so requires foregrounding the target \
            app, and the engine refuses such clicks. ALWAYS drive \
            menu-bar actions with `hotkey` against the target pid \
            instead. For Apple Calendar: \
            `hotkey(pid, keys: ["cmd", "n"])` for New Event, \
            `hotkey(pid, keys: ["cmd", "f"])` for Find. For any \
            standard macOS verb (Save, Open, Print, Close, etc.) \
            use the well-known ⌘-shortcut. Only fall back to \
            clicking in-window UI when no keyboard equivalent \
            exists. If a click is refused with role \
            `AXMenuBarItem`, the recovery is ALWAYS to retry as a \
            `hotkey` — never report the task as impossible.
        """

    public enum WorkerError: Error, CustomStringConvertible, Sendable {
        case maxStepsExceeded(stepCount: Int)
        case noCandidates
        case invalidArguments(toolName: String, reason: String)
        case unsupportedTool(name: String)
        case resultEncodingFailed(toolName: String, reason: String)
        case geminiFailed(GeminiClient.GeminiError)

        public var description: String {
            switch self {
            case .maxStepsExceeded(let n):
                return "Worker hit max step count (\(n)) without a final response."
            case .noCandidates:
                return "Gemini returned an empty candidate list — model declined."
            case .invalidArguments(let tool, let reason):
                return "Tool `\(tool)` invocation has invalid arguments: \(reason)"
            case .unsupportedTool(let name):
                return "Tool `\(name)` is not implemented by the worker dispatch."
            case .resultEncodingFailed(let tool, let reason):
                return "Tool `\(tool)` succeeded but its result couldn't be encoded for Gemini: \(reason)"
            case .geminiFailed(let error):
                return "Gemini call failed: \(error)"
            }
        }
    }

    /// Default per-turn step ceiling. The supervisor's planner can
    /// override at construction; runaway loops are capped at this
    /// to bound cost in the absence of Q12-deferred token budgets.
    public static let defaultMaxSteps = 30

    private let client: GeminiClient
    private let engine: Engine
    private let model: String
    private let maxSteps: Int

    /// Gate consulted before every tool dispatch classified as
    /// `Sensitivity.requiresApproval`. Defaults to
    /// `AlwaysApproveGate` so unit tests and the standalone Agent
    /// target keep working without an App-side coordinator wired
    /// in. Production: AgentSupervisor injects an
    /// `ApprovalCoordinator` that drives the bottom-center
    /// approval panel.
    private let approvalGate: any ApprovalGate

    /// Gate consulted when the model calls `ask_user`. Same
    /// shape and rationale as `approvalGate`; default
    /// `AlwaysSkipClarificationGate` keeps unit tests
    /// non-blocking.
    private let clarificationGate: any ClarificationGate

    /// Optional callback fired on each tool dispatch that
    /// carries a `(pid, windowId)` target. Used by the
    /// supervisor to expose "what is this agent currently
    /// looking at" to UI surfaces (the hover popover in
    /// particular). `nil` for standalone Agent-target tests.
    public typealias FocusReporter = @Sendable (Int32, Int) async -> Void
    private let focusReporter: FocusReporter?

    /// Ordered list of tool names dispatched during the most
    /// recent (or in-progress) `run`. Read-only from outside;
    /// the dispatch loop appends as it goes. Cleared at the
    /// start of each `run` call so tests can assert the
    /// sequence without coupling to prior runs.
    ///
    /// Used by integration tests to verify that the model
    /// actually exercised multi-step paths (e.g., a test that
    /// requires `get_window_state` before `click_element` will
    /// assert both names appear in this array). Production
    /// callers can ignore it.
    public private(set) var dispatchedToolNames: [String] = []

    /// Count of post-action snapshots taken automatically by
    /// `verify-via-snapshot` (see `verifyAfterAction` flag below).
    /// Increments once per state-changing tool dispatch when
    /// verification is enabled. Used by integration tests to
    /// confirm the verification pass actually fired.
    public private(set) var verificationSnapshotCount: Int = 0

    /// When true (default), every state-changing tool dispatch
    /// (`click_element`, `type_text`) is followed automatically
    /// by a `get_window_state` snapshot whose result is embedded
    /// inside the tool's `function_response` payload as
    /// `post_state`. The model sees both the tool's result AND
    /// the new AX tree on the same turn, without having to ask
    /// for the snapshot itself.
    ///
    /// **This is the structural defense against Gemini's
    /// hallucination tendency** discovered in PR #16: under
    /// politely-worded prompts, the model emitted text claiming a
    /// click had landed without ever invoking `click_element`.
    /// With verify-via-snapshot on, the model can no longer
    /// claim something happened that didn't happen — its next
    /// turn always sees the actual post-action tree, so any
    /// claim that contradicts the observed state is
    /// pattern-matchable by the model itself.
    ///
    /// Set to `false` for tests that want to exercise the raw
    /// dispatch loop without the auto-verify.
    private let verifyAfterAction: Bool

    public init(
        client: GeminiClient,
        engine: Engine,
        model: String,
        maxSteps: Int = Worker.defaultMaxSteps,
        verifyAfterAction: Bool = true,
        approvalGate: any ApprovalGate = AlwaysApproveGate(),
        clarificationGate: any ClarificationGate = AlwaysSkipClarificationGate(),
        focusReporter: FocusReporter? = nil
    ) {
        self.client = client
        self.engine = engine
        self.model = model
        self.maxSteps = maxSteps
        self.verifyAfterAction = verifyAfterAction
        self.approvalGate = approvalGate
        self.clarificationGate = clarificationGate
        self.focusReporter = focusReporter
    }

    /// Run one task to completion. Returns the model's final
    /// text, or throws on cap / decline / programmer-error
    /// failures. Tool failures during the loop are NOT thrown —
    /// they're sent back to Gemini as error objects so the model
    /// can recover.
    public func run(prompt: String) async throws -> String {
        // Reset dispatch trace for this run. Tests assert against
        // this array; staleness from a prior run would mask the
        // current run's behavior.
        dispatchedToolNames = []
        verificationSnapshotCount = 0

        var contents: [Content] = [
            Content(role: "user", parts: [Part(text: prompt)])
        ]
        let tools = [Tool(functionDeclarations: ToolSchema.allEngineTools())]
        let systemInstruction = Self.makeSystemInstruction()

        for _ in 0..<maxSteps {
            try Task.checkCancellation()

            let request = GeminiRequest(
                contents: contents,
                tools: tools,
                systemInstruction: systemInstruction
            )
            let response: GeminiResponse
            do {
                response = try await client.generateResponse(
                    model: model, request: request
                )
            } catch {
                throw WorkerError.geminiFailed(error)
            }

            guard let candidate = response.candidates.first else {
                throw WorkerError.noCandidates
            }

            // Append the model's turn to history regardless of what
            // it contained — Gemini's conversation contract requires
            // the model's content to appear before any function
            // response we send back.
            contents.append(candidate.content)

            // Pull out function calls. Empty list means model
            // produced text only and we're done.
            let calls = candidate.content.parts.compactMap(\.functionCall)
            if calls.isEmpty {
                let text = candidate.content.parts
                    .compactMap(\.text).joined(separator: "\n")
                return text
            }

            // Dispatch each call and assemble the response Content.
            // Gemini's wire format puts every function response
            // from one turn under a single role: "function" Content
            // with one `Part` per response.
            //
            // Any screenshot bytes a tool wants the model to *see*
            // (rather than just describe in JSON) are returned as
            // attached images and posted in a follow-up user-role
            // turn with `inline_data` Parts — the model only OCRs
            // images delivered through that channel, not base64
            // strings buried in a function response payload.
            var responseParts: [Part] = []
            var attachedImages: [AttachedImage] = []
            for call in calls {
                let outcome = await dispatch(call)
                responseParts.append(Part(functionResponse: outcome.response))
                attachedImages.append(contentsOf: outcome.attachedImages)
            }
            contents.append(
                Content(role: "function", parts: responseParts)
            )
            if !attachedImages.isEmpty {
                contents.append(
                    Content(
                        role: "user",
                        parts: attachedImagesToParts(attachedImages)
                    )
                )
            }

        }

        throw WorkerError.maxStepsExceeded(stepCount: maxSteps)
    }

    // MARK: - Dispatch

    /// Result bundle from a single tool dispatch: the
    /// `FunctionResponse` Gemini's protocol requires plus any
    /// binary attachments (currently screenshots) that the model
    /// needs to receive as `inline_data` Parts in a follow-up
    /// user-role turn.
    private struct DispatchOutcome {
        let response: FunctionResponse
        let attachedImages: [AttachedImage]
    }

    /// Image attached to the conversation after a tool call so
    /// the model actually sees the pixels. `caption` becomes the
    /// text Part that precedes the image so the model knows what
    /// it's looking at.
    private struct AttachedImage {
        let caption: String
        let mimeType: String
        /// Base64-encoded image bytes.
        let base64: String
    }

    /// Route a single FunctionCall to the matching engine method
    /// and shape the result as a FunctionResponse. Errors during
    /// dispatch are caught and folded into the response payload —
    /// this is the agent-loop pattern: the model sees its own
    /// tool failure and can recover.
    private func dispatch(_ call: FunctionCall) async -> DispatchOutcome {
        // Record the dispatch BEFORE attempting it so tests can
        // see the call was issued even when the underlying
        // engine method throws.
        dispatchedToolNames.append(call.name)
        Self.trace("→ \(call.name)(\(Self.formatArgs(call.args)))")

        // `ask_user` is the only tool that doesn't touch the
        // engine — it routes straight to the clarification gate
        // and returns the user's reply as the tool result. Short-
        // circuit here so it never visits the approval gate (a
        // clarifying question can't itself be sensitive) and
        // never triggers verify-via-snapshot (nothing changed on
        // the screen).
        if call.name == "ask_user" {
            return await dispatchAskUser(call)
        }

        // Hard-denial gate. Forbidden chords (⌘Q, ⌘W, ⌘⇧W, ⌘L,
        // ⌘Tab, ⌘`) are refused outright with a structured error
        // so the model can pick a different path. Distinct from
        // the approval flow below — there is no user prompt, no
        // way to override; the supervisor will not destroy the
        // user's windows / apps / browser session on the model's
        // initiative. The reason text is the denial message from
        // `SensitivityEngine.forbiddenHotkeyPatterns` and is
        // verbose enough for the model to learn the correct
        // alternative without re-trying.
        if let denyReason = SensitivityEngine.denyReason(
            toolName: call.name, args: call.args
        ) {
            Self.trace("← \(call.name) REFUSED: \(denyReason)")
            return DispatchOutcome(
                response: FunctionResponse(
                    name: call.name,
                    response: .object([
                        "error": .string("supervisor_refused: \(denyReason)")
                    ])
                ),
                attachedImages: []
            )
        }

        // Approval gate runs before any engine work — and before
        // the focus reporter, so a denied tool doesn't leak its
        // target into the hover preview. Denied calls never touch
        // Automation/. The denial reason is shipped back to the
        // model as a normal `error` payload so the loop continues
        // and the model can pick a different path (or end the
        // task with a "user blocked the action" explanation).
        let sensitivity = SensitivityEngine.classify(
            toolName: call.name, args: call.args
        )
        if case .requiresApproval(let reason, let summary, let scopeKey) = sensitivity {
            let decision = await approvalGate.requestApproval(
                toolName: call.name,
                summary: summary,
                reason: reason,
                scopeKey: scopeKey
            )
            if case .denied(let denyReason) = decision {
                Self.trace("← \(call.name) DENIED: \(denyReason)")
                return DispatchOutcome(
                    response: FunctionResponse(
                        name: call.name,
                        response: .object([
                            "error": .string("user_denied: \(denyReason)")
                        ])
                    ),
                    attachedImages: []
                )
            }
        }

        // Report current focus to whoever's watching (the hover
        // popover via the supervisor). We report whenever a
        // dispatch carries both `pid` and `windowId` — that's
        // every tool that actually touches a specific window
        // (`click`, `type_text*`, `get_window_state`, etc.).
        // Tools without those args (`list_apps`, `screenshot`
        // global) don't update the focus — last-known target
        // stays sticky, which is what the user wants from a
        // hover-preview ("show me what the agent is doing").
        //
        // Uses `lookupArg` to accept both camelCase and snake_case
        // — Gemini emits `window_id` intermittently.
        if let reporter = focusReporter,
           let pidInt = lookupArg(call.args, "pid")?.intValue,
           let windowId = lookupArg(call.args, "windowId")?.intValue,
           let pid = Int32(exactly: pidInt)
        {
            await reporter(pid, windowId)
        }

        do {
            let (result, images) = try await dispatchOrThrow(call)
            Self.trace("← \(call.name) ok")
            return DispatchOutcome(
                response: FunctionResponse(name: call.name, response: result),
                attachedImages: images
            )
        } catch {
            Self.trace("← \(call.name) ERROR: \(String(describing: error))")
            return DispatchOutcome(
                response: FunctionResponse(
                    name: call.name,
                    response: .object([
                        "error": .string(String(describing: error))
                    ])
                ),
                attachedImages: []
            )
        }
    }

    /// Render attached images as the parts of a user-role turn.
    /// Each image is preceded by a text Part naming what it
    /// depicts so the model can correlate it with the matching
    /// tool result.
    private func attachedImagesToParts(_ images: [AttachedImage]) -> [Part] {
        var parts: [Part] = []
        for image in images {
            parts.append(Part(text: image.caption))
            parts.append(
                Part(
                    inlineData: InlineData(
                        mimeType: image.mimeType,
                        data: image.base64
                    )
                )
            )
        }
        return parts
    }

    /// Dispatch path for the Cacty-specific `ask_user` tool. The
    /// tool never touches `Automation/`; it routes to the
    /// clarification gate (which the App wires to the bottom-
    /// center panel) and ships the user's reply back to the model
    /// as a structured `reply_type`-tagged object. Missing
    /// arguments or a cancelled reply land as `error` payloads so
    /// the model can decide whether to abort or retry.
    private func dispatchAskUser(_ call: FunctionCall) async -> DispatchOutcome {
        guard let question = call.args["question"]?.stringValue,
              !question.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            Self.trace("← ask_user invalid: missing question")
            return DispatchOutcome(
                response: FunctionResponse(
                    name: call.name,
                    response: .object([
                        "error": .string("missing required `question` arg")
                    ])
                ),
                attachedImages: []
            )
        }
        let choices = (call.args["choices"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
        let request = ClarificationRequest(
            question: question, choices: choices
        )
        let reply = await clarificationGate.askUser(request)
        Self.trace("← ask_user \(reply)")
        return DispatchOutcome(
            response: FunctionResponse(
                name: call.name, response: Self.encodeReply(reply)
            ),
            attachedImages: []
        )
    }

    /// Tagged-union JSON encoding for `ClarificationReply` that
    /// matches the schema documented on `ToolSchema.askUser()`.
    /// Kept here (not on the gate type) because the encoding is
    /// part of the Worker↔Gemini wire contract; the gate is
    /// transport-agnostic.
    private static func encodeReply(_ reply: ClarificationReply) -> JSONValue {
        switch reply {
        case .selected(let index, let text):
            return .object([
                "reply_type": .string("selected"),
                "index": .int(index),
                "text": .string(text),
            ])
        case .freeform(let text):
            return .object([
                "reply_type": .string("freeform"),
                "text": .string(text),
            ])
        case .skipped:
            return .object(["reply_type": .string("skipped")])
        case .cancelled:
            // Model never receives this in normal flow — the
            // worker loop's `try Task.checkCancellation()` exits
            // before we'd ship another turn. Encoded for
            // completeness in case a future code path bypasses
            // the loop guard.
            return .object([
                "reply_type": .string("skipped"),
                "error": .string("cancelled"),
            ])
        }
    }

    /// One-line stderr trace for every tool call the agent
    /// dispatches. Keeps the format tight so the terminal stays
    /// readable across a multi-turn task. Truncated at 500 chars
    /// per line so a large screenshot arg doesn't wallpaper the
    /// log.
    private static func trace(_ message: String) {
        let trimmed = message.count > 500
            ? String(message.prefix(500)) + "…"
            : message
        log.debug("\(trimmed, privacy: .public)")
    }

    /// Compact arg renderer for traces. Drops obvious noise
    /// (screenshot bytes, long text fields are truncated) so the
    /// terminal stays scannable.
    private static func formatArgs(_ args: [String: JSONValue]) -> String {
        return args
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(formatValue($0.value))" }
            .joined(separator: ", ")
    }

    private static func formatValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s):
            let escaped = s.replacingOccurrences(of: "\n", with: "\\n")
            return s.count > 80
                ? "\"\(escaped.prefix(80))…\""
                : "\"\(escaped)\""
        case .int(let n): return String(n)
        case .double(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array(let arr): return "[\(arr.count) items]"
        case .object(let obj): return "{\(obj.count) keys}"
        }
    }

    private func dispatchOrThrow(
        _ call: FunctionCall
    ) async throws -> (JSONValue, [AttachedImage]) {
        // IMPORTANT: every branch returns a `.object(...)` value.
        // Gemini's FunctionResponse.response field is typed as
        // `google.protobuf.Struct` which only accepts top-level
        // JSON objects — arrays and scalars are rejected at the
        // API edge with "Proto field is not repeating, cannot
        // start list." So array-returning tools (list_apps,
        // list_windows) wrap their result under a named key,
        // and Void-returning tools wrap a synthetic
        // `{"result": "ok"}`. Object-returning tools pass through
        // directly via `encodeAsJSON`.
        //
        // Tools that want the model to see binary content (images)
        // return them in the second tuple slot; the run loop then
        // appends them to a follow-up user-role turn as
        // `inline_data` Parts. The base64 string is stripped from
        // the function response payload before send to avoid
        // doubling the token cost.
        switch call.name {
        case "list_apps":
            let apps = try Worker.encodeAsJSON(engine.listApps())
            return (.object(["apps": apps]), [])

        case "list_windows":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windows = engine.listWindows(forPid: pid)
            return (.object(["windows": try Worker.encodeAsJSON(windows)]), [])

        case "launch_app":
            let bundleId = try requireString(call.args, "bundleId", in: call.name)
            let info = try await engine.launchApp(bundleId: bundleId)
            return (try Worker.encodeAsJSON(info), [])

        case "get_window_state":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = try requireInt(call.args, "windowId", in: call.name)
            let captureMode = try optionalCaptureMode(
                call.args, "captureMode", in: call.name
            ) ?? .som
            let snapshot = try await engine.getWindowState(
                pid: pid, windowId: windowId, captureMode: captureMode
            )
            return try splitSnapshotForWire(
                snapshot, pid: pid, windowId: windowId
            )

        case "click":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowIdOpt = optionalInt(call.args, "windowId")
            let elementIndexOpt = optionalInt(call.args, "elementIndex")
            let xOpt = optionalDouble(call.args, "x")
            let yOpt = optionalDouble(call.args, "y")
            let modifiers = optionalStringArray(call.args, "modifier") ?? []
            let count = optionalInt(call.args, "count") ?? 1
            try await engine.click(
                pid: pid,
                windowId: windowIdOpt,
                elementIndex: elementIndexOpt,
                x: xOpt, y: yOpt,
                modifiers: modifiers,
                count: count
            )
            // Post-state snapshot — prefer the explicit windowId; if
            // the model used the pixel path without windowId, pick
            // the pid's frontmost window.
            let snapshotWindow = windowIdOpt
                ?? engine.listWindows(forPid: pid).first?.id
            if let snapshotWindow {
                return (
                    await wrapWithPostStateSnapshot(
                        base: ["result": .string("ok")],
                        pid: pid, windowId: snapshotWindow
                    ),
                    []
                )
            }
            return (.object(["result": .string("ok")]), [])

        case "type_text_chars":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let text = try requireString(call.args, "text", in: call.name)
            try await engine.type(pid: pid, text: text)
            // For type_text we don't have a window_id in args (the
            // engine routes by pid), so the post-state snapshot
            // requires resolving a window. Pick the first window of
            // the pid; if none, skip the snapshot. Skipping is
            // acceptable here — the next model turn will likely
            // call get_window_state explicitly, which is the
            // existing pattern; we just don't get the auto-verify
            // bonus for that one call.
            let firstWindow = engine.listWindows(forPid: pid).first
            if let firstWindow {
                return (
                    await wrapWithPostStateSnapshot(
                        base: ["result": .string("ok")],
                        pid: pid, windowId: firstWindow.id
                    ),
                    []
                )
            }
            return (.object(["result": .string("ok")]), [])

        case "type_text":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = try requireInt(call.args, "windowId", in: call.name)
            let elementIndex = try requireInt(call.args, "elementIndex", in: call.name)
            let text = try requireString(call.args, "text", in: call.name)
            try await engine.setElementValue(
                pid: pid, windowId: windowId,
                elementIndex: elementIndex, text: text
            )
            return (
                await wrapWithPostStateSnapshot(
                    base: ["result": .string("ok")],
                    pid: pid, windowId: windowId
                ),
                []
            )

        case "page":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = try requireInt(call.args, "windowId", in: call.name)
            let action = try requireString(call.args, "action", in: call.name)
            let javascript = optionalString(call.args, "javascript")
            let cssSelector = optionalString(call.args, "cssSelector")
            let attributes = optionalStringArray(call.args, "attributes") ?? []
            let bundleId = optionalString(call.args, "bundleId")
            let userConfirmed = optionalBool(
                call.args, "userHasConfirmedEnabling"
            ) ?? false
            let result = try await engine.page(
                pid: pid, windowId: windowId, action: action,
                javascript: javascript, cssSelector: cssSelector,
                attributes: attributes, bundleId: bundleId,
                userHasConfirmedEnabling: userConfirmed
            )
            return (.object(["result": .string(result)]), [])

        case "press_key":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let keys = try requireStringArray(call.args, "keys", in: call.name)
            // Optional element_index + window_id pre-focus path
            // (cua's PressKeyTool with element_index).
            let windowIdOpt: Int? = (lookupArg(call.args, "windowId")?.intValue)
                ?? (lookupArg(call.args, "windowId")?.stringValue.flatMap { Int($0) })
            let elementIndexOpt: Int? = (lookupArg(call.args, "elementIndex")?.intValue)
                ?? (lookupArg(call.args, "elementIndex")?.stringValue.flatMap { Int($0) })
            try await engine.pressKey(
                pid: pid, keys: keys,
                windowId: windowIdOpt, elementIndex: elementIndexOpt
            )
            // Snapshot the press-target window (or first window if
            // none specified) so the model sees post-keypress state.
            let firstWindow = engine.listWindows(forPid: pid).first
            if let firstWindow {
                return (
                    await wrapWithPostStateSnapshot(
                        base: ["result": .string("ok")],
                        pid: pid, windowId: firstWindow.id
                    ),
                    []
                )
            }
            return (.object(["result": .string("ok")]), [])

        // MARK: - cua tool ports (Phase 3)

        case "right_click":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = optionalInt(call.args, "windowId")
            let elementIndex = optionalInt(call.args, "elementIndex")
            let x = optionalDouble(call.args, "x")
            let y = optionalDouble(call.args, "y")
            let modifiers = optionalStringArray(call.args, "modifier") ?? []
            try await engine.rightClick(
                pid: pid, windowId: windowId, elementIndex: elementIndex,
                x: x, y: y, modifiers: modifiers
            )
            return (.object(["result": .string("ok")]), [])

        case "double_click":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = optionalInt(call.args, "windowId")
            let elementIndex = optionalInt(call.args, "elementIndex")
            let x = optionalDouble(call.args, "x")
            let y = optionalDouble(call.args, "y")
            let modifiers = optionalStringArray(call.args, "modifier") ?? []
            try await engine.doubleClick(
                pid: pid, windowId: windowId, elementIndex: elementIndex,
                x: x, y: y, modifiers: modifiers
            )
            return (.object(["result": .string("ok")]), [])

        case "drag":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = optionalInt(call.args, "windowId")
            guard let fromX = optionalDouble(call.args, "fromX"),
                  let fromY = optionalDouble(call.args, "fromY"),
                  let toX = optionalDouble(call.args, "toX"),
                  let toY = optionalDouble(call.args, "toY")
            else {
                throw WorkerError.invalidArguments(
                    toolName: call.name,
                    reason: "drag requires fromX, fromY, toX, toY."
                )
            }
            let durationMs = optionalInt(call.args, "durationMs") ?? 500
            let steps = optionalInt(call.args, "steps") ?? 20
            let modifiers = optionalStringArray(call.args, "modifier") ?? []
            try await engine.drag(
                pid: pid, windowId: windowId,
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                durationMs: durationMs, steps: steps, modifiers: modifiers
            )
            return (.object(["result": .string("ok")]), [])

        case "scroll":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let direction = try requireString(call.args, "direction", in: call.name)
            let amount = optionalInt(call.args, "amount") ?? 3
            let by = optionalString(call.args, "by") ?? "line"
            let windowId = optionalInt(call.args, "windowId")
            let elementIndex = optionalInt(call.args, "elementIndex")
            try await engine.scroll(
                pid: pid, direction: direction, amount: amount, by: by,
                windowId: windowId, elementIndex: elementIndex
            )
            return (.object(["result": .string("ok")]), [])

        case "hotkey":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let keys = try requireStringArray(call.args, "keys", in: call.name)
            try await engine.hotkey(pid: pid, keys: keys)
            return (.object(["result": .string("ok")]), [])

        case "move_cursor":
            let x = try requireInt(call.args, "x", in: call.name)
            let y = try requireInt(call.args, "y", in: call.name)
            engine.moveCursor(x: x, y: y)
            return (.object(["result": .string("ok")]), [])

        case "zoom":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            guard let x1 = optionalDouble(call.args, "x1"),
                  let y1 = optionalDouble(call.args, "y1"),
                  let x2 = optionalDouble(call.args, "x2"),
                  let y2 = optionalDouble(call.args, "y2")
            else {
                throw WorkerError.invalidArguments(
                    toolName: call.name,
                    reason: "zoom requires x1, y1, x2, y2."
                )
            }
            let shot = try await engine.zoom(
                pid: pid, x1: x1, y1: y1, x2: x2, y2: y2
            )
            return (
                .object([
                    "width": .double(Double(shot.width)),
                    "height": .double(Double(shot.height)),
                    "scale_factor": .double(Double(shot.scaleFactor)),
                    "png_base64": .string(
                        shot.imageData.base64EncodedString()
                    ),
                ]),
                []
            )

        case "get_cursor_position":
            let point = engine.getCursorPosition()
            return (
                .object([
                    "x": .double(Double(point.x)),
                    "y": .double(Double(point.y)),
                ]),
                []
            )

        case "get_screen_size":
            let size = try engine.getScreenSize()
            return (
                .object([
                    "width": .double(Double(size.width)),
                    "height": .double(Double(size.height)),
                    "scale_factor": .double(Double(size.scaleFactor)),
                ]),
                []
            )

        case "get_accessibility_tree":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = try requireInt(call.args, "windowId", in: call.name)
            let tree = try await engine.getAccessibilityTree(
                pid: pid, windowId: windowId
            )
            return (.object(["tree_markdown": .string(tree)]), [])

        case "screenshot":
            let pid = try requireInt32(call.args, "pid", in: call.name)
            let windowId = optionalInt(call.args, "windowId")
            let maxDim = optionalInt(call.args, "maxImageDimension") ?? 1600
            let shot = try await engine.screenshot(
                pid: pid, windowId: windowId, maxImageDimension: maxDim
            )
            return (
                .object([
                    "width": .double(Double(shot.width)),
                    "height": .double(Double(shot.height)),
                    "scale_factor": .double(Double(shot.scaleFactor)),
                    "png_base64": .string(
                        shot.imageData.base64EncodedString()
                    ),
                ]),
                []
            )

        case "check_permissions":
            let perms = await engine.checkPermissions()
            return (
                .object([
                    "accessibility": .bool(perms.accessibility),
                    "screen_recording": .bool(perms.screenRecording),
                ]),
                []
            )

        case "set_recording":
            guard let enabled = optionalBool(call.args, "enabled") else {
                throw WorkerError.invalidArguments(
                    toolName: call.name,
                    reason: "set_recording requires `enabled: Bool`."
                )
            }
            let outputDir = optionalString(call.args, "outputDir")
            let videoExperimental =
                optionalBool(call.args, "videoExperimental") ?? false
            try await engine.setRecording(
                enabled: enabled,
                outputDir: outputDir,
                videoExperimental: videoExperimental
            )
            return (.object(["result": .string("ok")]), [])

        case "get_recording_state":
            let state = await engine.getRecordingState()
            var payload: [String: JSONValue] = [
                "enabled": .bool(state.enabled),
                "next_turn": .int(state.nextTurn),
                "video_experimental": .bool(state.videoExperimental),
            ]
            if let url = state.outputDirectory {
                payload["output_directory"] = .string(url.path)
            } else {
                payload["output_directory"] = .null
            }
            return (.object(payload), [])

        case "replay_trajectory":
            let path = try requireString(call.args, "path", in: call.name)
            try await engine.replayTrajectory(path: path)
            return (.object(["result": .string("ok")]), [])

        case "get_agent_cursor_state":
            let enabled = await MainActor.run { engine.getAgentCursorState() }
            return (.object(["enabled": .bool(enabled)]), [])

        case "set_agent_cursor_enabled":
            guard let enabled = optionalBool(call.args, "enabled") else {
                throw WorkerError.invalidArguments(
                    toolName: call.name,
                    reason: "set_agent_cursor_enabled requires `enabled: Bool`."
                )
            }
            await MainActor.run { engine.setAgentCursorEnabled(enabled) }
            return (.object(["result": .string("ok")]), [])

        case "set_agent_cursor_motion":
            let glide = optionalDouble(call.args, "glideDurationSeconds")
            let idle = optionalDouble(call.args, "idleHideDelaySeconds")
            await MainActor.run {
                engine.setAgentCursorMotion(
                    glideDurationSeconds: glide,
                    idleHideDelaySeconds: idle
                )
            }
            return (.object(["result": .string("ok")]), [])

        case "get_config":
            let config = await engine.getConfig()
            let data = try Worker.encodeAsJSON(config)
            return (.object(["config": data]), [])

        case "set_config":
            let configJson = try requireString(call.args, "configJson", in: call.name)
            guard let bytes = configJson.data(using: .utf8) else {
                throw WorkerError.invalidArguments(
                    toolName: call.name, reason: "configJson is not UTF-8."
                )
            }
            do {
                let config = try ConfigStore.makeDecoder().decode(
                    CuaDriverConfig.self, from: bytes
                )
                try await engine.setConfig(config)
            } catch let e as Engine.EngineError {
                throw e
            } catch {
                throw WorkerError.invalidArguments(
                    toolName: call.name,
                    reason: "configJson decode failed: \(error)"
                )
            }
            return (.object(["result": .string("ok")]), [])

        default:
            throw WorkerError.unsupportedTool(name: call.name)
        }
    }

    // Optional-arg helpers reused by the new cua-mirror tool cases.
    private func optionalInt(
        _ args: [String: JSONValue], _ key: String
    ) -> Int? {
        let raw = lookupArg(args, key)
        if let v = raw?.intValue { return v }
        if let d = raw?.doubleValue, let v = Int(exactly: d) { return v }
        if let s = raw?.stringValue, let v = Int(s) { return v }
        return nil
    }

    private func optionalDouble(
        _ args: [String: JSONValue], _ key: String
    ) -> Double? {
        let raw = lookupArg(args, key)
        if let d = raw?.doubleValue { return d }
        if let i = raw?.intValue { return Double(i) }
        if let s = raw?.stringValue, let d = Double(s) { return d }
        return nil
    }

    /// Pull the screenshot off a `get_window_state` snapshot for
    /// inline-image delivery and return:
    /// - a function-response payload that keeps the dimensions /
    ///   scale factor but replaces `screenshot_png_b64` with a
    ///   marker telling the model the actual image is attached
    ///   as an inline-data Part in the next user turn, and
    /// - the image itself bundled with a caption identifying
    ///   which `(pid, window_id)` it depicts.
    ///
    /// When the snapshot has no screenshot (capture failure, or
    /// `captureMode: .ax`), returns the snapshot unchanged and an
    /// empty attachment list.
    private func splitSnapshotForWire(
        _ snapshot: AppStateSnapshot,
        pid: Int32,
        windowId: Int
    ) throws -> (JSONValue, [AttachedImage]) {
        guard let base64 = snapshot.screenshotPngBase64 else {
            return (try Worker.encodeAsJSON(snapshot), [])
        }
        // Re-encode the snapshot with the heavy base64 stripped.
        let lightweight = AppStateSnapshot(
            pid: snapshot.pid,
            bundleId: snapshot.bundleId,
            name: snapshot.name,
            treeMarkdown: snapshot.treeMarkdown,
            elementCount: snapshot.elementCount,
            turnId: snapshot.turnId,
            screenshotPngBase64: nil,
            screenshotWidth: snapshot.screenshotWidth,
            screenshotHeight: snapshot.screenshotHeight,
            screenshotScaleFactor: snapshot.screenshotScaleFactor,
            screenshotOriginalWidth: snapshot.screenshotOriginalWidth,
            screenshotOriginalHeight: snapshot.screenshotOriginalHeight
        )
        var payload = (try Worker.encodeAsJSON(lightweight)).objectValue ?? [:]
        payload["screenshot_attached_as"] = .string(
            "inline_data PNG in the following user turn"
        )
        let caption =
            "Screenshot for get_window_state(pid=\(pid), "
            + "window_id=\(windowId)). Use this image to read "
            + "content that does not appear in the AX tree "
            + "(Slack/Discord/Electron messages, canvas/WebGL, etc.)."
        return (
            .object(payload),
            [AttachedImage(caption: caption, mimeType: "image/png", base64: base64)]
        )
    }

    // MARK: - Argument extraction helpers

    /// Look up `key` in `args`, accepting both the canonical camelCase key
    /// declared by the tool schema and the snake_case variant Gemini
    /// sometimes emits regardless of the declared parameter name. Returns
    /// the first hit, or nil if neither key is present.
    private func lookupArg(
        _ args: [String: JSONValue], _ key: String
    ) -> JSONValue? {
        if let direct = args[key] { return direct }
        let snake = Worker.camelToSnake(key)
        if snake != key, let alt = args[snake] { return alt }
        return nil
    }

    private static func camelToSnake(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(ch.lowercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private func requireString(
        _ args: [String: JSONValue], _ key: String, in tool: String
    ) throws -> String {
        guard let value = lookupArg(args, key)?.stringValue else {
            throw WorkerError.invalidArguments(
                toolName: tool, reason: "missing or non-string `\(key)`"
            )
        }
        return value
    }

    private func requireStringArray(
        _ args: [String: JSONValue], _ key: String, in tool: String
    ) throws -> [String] {
        guard let raw = lookupArg(args, key)?.arrayValue else {
            throw WorkerError.invalidArguments(
                toolName: tool, reason: "missing or non-array `\(key)`"
            )
        }
        let strings = raw.compactMap { $0.stringValue }
        guard strings.count == raw.count, !strings.isEmpty else {
            throw WorkerError.invalidArguments(
                toolName: tool,
                reason: "`\(key)` must be a non-empty array of strings"
            )
        }
        return strings
    }

    private func requireInt(
        _ args: [String: JSONValue], _ key: String, in tool: String
    ) throws -> Int {
        let raw = lookupArg(args, key)
        // Accept int, double-with-no-fractional-part, and numeric strings
        // ("20906"). Gemini occasionally stringifies large window ids and
        // emits doubles for fields it treats as numeric without enforcing
        // integrality. Reject anything that loses precision.
        if let v = raw?.intValue { return v }
        if let d = raw?.doubleValue, let v = Int(exactly: d) { return v }
        if let s = raw?.stringValue, let v = Int(s) { return v }
        throw WorkerError.invalidArguments(
            toolName: tool, reason: "missing or non-integer `\(key)`"
        )
    }

    /// Optional string arg — `nil` when absent or not a string.
    private func optionalString(
        _ args: [String: JSONValue], _ key: String
    ) -> String? {
        lookupArg(args, key)?.stringValue
    }

    /// Optional boolean arg — `nil` when absent or not a bool.
    private func optionalBool(
        _ args: [String: JSONValue], _ key: String
    ) -> Bool? {
        lookupArg(args, key)?.boolValue
    }

    /// Optional `[String]` arg — `nil` when absent. Filters non-string
    /// entries silently to match Gemini's lax array typing.
    private func optionalStringArray(
        _ args: [String: JSONValue], _ key: String
    ) -> [String]? {
        guard let raw = lookupArg(args, key)?.arrayValue else { return nil }
        return raw.compactMap { $0.stringValue }
    }

    /// Parse an optional `CaptureMode` arg. Returns `nil` when the
    /// key is absent so the caller can apply its own default. Throws
    /// `invalidArguments` when present but not a recognized value.
    private func optionalCaptureMode(
        _ args: [String: JSONValue], _ key: String, in tool: String
    ) throws -> CaptureMode? {
        guard let raw = lookupArg(args, key)?.stringValue else { return nil }
        switch raw {
        case "som": return .som
        case "ax": return .ax
        case "vision", "screenshot": return .vision
        default:
            throw WorkerError.invalidArguments(
                toolName: tool,
                reason: "`\(key)` must be one of: som, ax, vision"
            )
        }
    }

    private func requireInt32(
        _ args: [String: JSONValue], _ key: String, in tool: String
    ) throws -> Int32 {
        let value = try requireInt(args, key, in: tool)
        guard let cast = Int32(exactly: value) else {
            throw WorkerError.invalidArguments(
                toolName: tool,
                reason: "`\(key)` value \(value) is out of Int32 range"
            )
        }
        return cast
    }

    // MARK: - Result encoding

    /// Encode any `Codable` engine result as a `JSONValue` for
    /// inclusion in a FunctionResponse. Round-tripping through
    /// `JSONEncoder` + `JSONDecoder` is the simplest path that
    /// preserves whatever snake_case mapping the engine type
    /// declared via its CodingKeys.
    static func encodeAsJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw WorkerError.resultEncodingFailed(
                toolName: "(unknown)", reason: String(describing: error)
            )
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw WorkerError.resultEncodingFailed(
                toolName: "(unknown)", reason: String(describing: error)
            )
        }
    }

    // MARK: - Verify-via-snapshot

    /// Append a post-action AX snapshot to a tool's response payload
    /// when `verifyAfterAction` is enabled. The model sees:
    ///
    /// ```json
    /// {
    ///   "result": "ok",
    ///   "post_state": { /* tree_markdown, element_count, ... */ }
    /// }
    /// ```
    ///
    /// rather than just `{"result": "ok"}` — so it can confirm the
    /// click/type actually changed the AX tree, not hallucinate a
    /// success outcome from text alone.
    ///
    /// Snapshot failure during verification is non-fatal: we wrap
    /// the underlying error inside `post_state.error` and return
    /// the response anyway. The tool's main effect (the click /
    /// type) succeeded; the verify pass is best-effort observability.
    ///
    /// When `verifyAfterAction` is `false`, this method returns
    /// `.object(base)` unchanged — the existing pre-PR-1.1 contract.
    private func wrapWithPostStateSnapshot(
        base: [String: JSONValue],
        pid: Int32,
        windowId: Int
    ) async -> JSONValue {
        guard verifyAfterAction else {
            return .object(base)
        }
        verificationSnapshotCount += 1
        var enriched = base
        do {
            // Verification snapshots use `.ax` so the post-action
            // response stays small — the model just needs to see
            // tree changes, not pay for a fresh PNG every step.
            let snapshot = try await engine.getWindowState(
                pid: pid, windowId: windowId, captureMode: .ax
            )
            let snapshotJSON = (try? Worker.encodeAsJSON(snapshot)) ?? .null
            enriched["post_state"] = snapshotJSON
        } catch {
            enriched["post_state"] = .object([
                "error": .string(String(describing: error)),
                "note": .string(
                    "post-action verification snapshot failed; the action itself "
                    + "may still have landed — re-snapshot explicitly to confirm"
                )
            ])
        }
        return .object(enriched)
    }
}
