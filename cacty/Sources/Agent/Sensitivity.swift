import Foundation

/// Verdict from the sensitivity classifier — what does Cacty's
/// supervisor need to do before this tool call actually executes?
///
/// The classifier is a pure function over `(toolName, args)`; it
/// does not know about the user's history, allowlist preferences,
/// or trajectory context. Those layers (Phase 4's editable
/// allowlists in Settings) wrap this verdict and may downgrade
/// `.requiresApproval` to `.safe` when the user has previously
/// approved the same combination.
public enum Sensitivity: Sendable, Equatable {
    /// Dispatch immediately. No approval bar, no prompt.
    case safe

    /// Block dispatch until the user approves. `summary` is the
    /// one-line plain-English description shown on the approval
    /// bar; `reason` is the rule name that fired (used for
    /// telemetry and for the user to know *why* it was flagged).
    /// `scopeKey`, when non-nil, lets the coordinator short-circuit
    /// future requests with the same key — e.g.
    /// `"page_execute_javascript:com.google.Chrome"` becomes a
    /// per-app one-time approval that stays approved for the
    /// remainder of the app session.
    case requiresApproval(reason: String, summary: String, scopeKey: String?)
}

/// Phase 1's sensitivity rules. Deliberately small — the surface
/// here is "external email, purchases, settings writes" per
/// `plan.md` § Phase 1. Phase 4 will replace the hard-coded list
/// with editable allowlists/denylists in Settings.
///
/// Design notes:
///
/// - Pure function. No actor, no I/O. Easy to unit-test exhaustively.
/// - Conservative defaults. When in doubt, classify as
///   `requiresApproval` — the user can always click approve. A
///   missed approval (sending an email without asking) is a
///   product failure; a false-positive approval is friction.
/// - Tool-name + args only. We do not introspect the AX tree or
///   the running app — the classifier can't tell a "Send" button
///   from a "Save Draft" button by element index. That's a
///   future Phase-4 enhancement once the tree-text is plumbed
///   into the dispatch context.
public enum SensitivityEngine {
    /// Hotkey combinations commonly bound to "send" / "submit"
    /// actions across Mail.app, Messages, Slack, Discord, Gmail,
    /// etc. The model uses these to commit a composed message;
    /// gating them gives the user a chance to read the draft
    /// before it ships.
    ///
    /// Stored as lowercased, comma-joined modifier+key strings,
    /// pre-sorted alphabetically so they match the output of
    /// `normalizeHotkey` directly. Order is canonicalized via
    /// sort, so `["cmd", "return"]` and `["return", "cmd"]` both
    /// hit. The token order in each entry is the *sorted* order,
    /// not the human-spoken order: `cmd,d,shift` represents ⌘⇧D,
    /// not `cmd,shift,d`.
    static let sendHotkeyPatterns: Set<String> = [
        "cmd,return",            // ⌘ Return
        "cmd,return,shift",      // ⌘ ⇧ Return
        "cmd,enter",             // ⌘ Enter
        "cmd,enter,shift",       // ⌘ ⇧ Enter
        "cmd,d,shift",           // ⌘ ⇧ D — Apple Mail "Send"
    ]

    /// Hotkey patterns that the supervisor refuses outright — no
    /// approval prompt, just a structured error returned to the
    /// model. These chords either destroy state the user owns
    /// (windows, app processes, active session) or trigger
    /// foregrounding behavior that breaks the background contract.
    /// Stored in the same canonicalized + sorted form as
    /// `sendHotkeyPatterns` so `normalizeHotkey` output matches
    /// directly.
    ///
    /// Each entry maps to a one-line user-facing reason that
    /// surfaces back to the model so it can pick a different path.
    static let forbiddenHotkeyPatterns: [String: String] = [
        // Window / app destruction — these were observed wiping
        // the user's Chrome session mid-task. The model is never
        // allowed to close the user's windows or quit a running
        // app on its own initiative.
        "cmd,q":          "Refusing ⌘Q — quits the target app entirely, destroying every window the user has open in it. There is no legitimate reason an automation task needs to quit an app; if the goal involves restarting it, ask the user.",
        "cmd,w":          "Refusing ⌘W — closes the current tab. Cacty's agent browser window is intentionally single-tab; closing it would terminate the active session. Use the back button or `page` navigation instead.",
        "cmd,shift,w":    "Refusing ⌘⇧W — closes the current window. The user owns the window lifecycle; do not close windows the model didn't create.",
        // Foregrounding / cross-app navigation — these break the
        // background contract and have been on the denylist since
        // Phase 0 (only previously documented in CLAUDE.md, never
        // enforced in code).
        "cmd,l":          "Refusing ⌘L — focuses the browser omnibox, which requires foregrounding the target. Use `page(action: \"execute_javascript\", javascript: \"window.location.href = '...'\")` to navigate without focus theft.",
        "cmd,tab":        "Refusing ⌘Tab — opens the macOS app switcher, foregrounds an arbitrary app, and is visible to the user as a focus jump. Background-contract violation.",
        "cmd,`":          "Refusing ⌘` — cycles windows within the frontmost app. Visible focus change that the user did not initiate.",
    ]

    /// `page` tool subactions that modify the host system and
    /// therefore need user approval.
    ///
    /// Mirrors the four-action surface cua's `PageTool` actually
    /// exposes: `enable_javascript_apple_events`,
    /// `execute_javascript`, `get_text`, `query_dom`. Only
    /// `enable_javascript_apple_events` is gated by default — that
    /// action quits the browser, edits its Preferences JSON on
    /// disk, and relaunches. `execute_javascript`, `get_text`, and
    /// `query_dom` stay `.safe`: they're read/JS-eval against the
    /// user's existing browser session and don't modify host state.
    ///
    /// `enable_javascript_apple_events` is special-cased below: the
    /// Worker's system prompt rule 7 treats the user's voice
    /// command as consent and sets `userHasConfirmedEnabling:
    /// true`. The classifier respects that flag — if it's set, the
    /// call is safe; otherwise it requires approval here.
    static let sensitivePageActions: Set<String> = [
        "enable_javascript_apple_events",
    ]

    /// If `(toolName, args)` matches a hard-denial rule, return the
    /// one-line reason that should be surfaced to the model
    /// instead of dispatching to the engine. Today the only
    /// rules live in ``forbiddenHotkeyPatterns`` and apply to the
    /// `hotkey` and single-chord `press_key` tools — `press_key`
    /// is included so a model can't smuggle a forbidden chord
    /// past the gate by routing through the wrong tool.
    /// Returns `nil` when no rule fires.
    public static func denyReason(
        toolName: String, args: [String: JSONValue]
    ) -> String? {
        switch toolName {
        case "hotkey":
            return normalizeHotkey(args: args)
                .flatMap { forbiddenHotkeyPatterns[$0] }
        case "press_key":
            return normalizeHotkey(args: args)
                .flatMap { forbiddenHotkeyPatterns[$0] }
        default:
            return nil
        }
    }

    /// Classify a single tool call.
    public static func classify(
        toolName: String, args: [String: JSONValue]
    ) -> Sensitivity {
        switch toolName {
        case "hotkey":
            return classifyHotkey(args: args)
        case "press_key":
            return classifyPressKey(args: args)
        case "page":
            return classifyPage(args: args)
        case "set_config":
            return .requiresApproval(
                reason: "set_config",
                summary: "Change Cacty engine configuration.",
                scopeKey: nil
            )
        case "set_recording":
            return .requiresApproval(
                reason: "set_recording",
                summary: "Toggle trajectory recording.",
                scopeKey: nil
            )
        case "replay_trajectory":
            return .requiresApproval(
                reason: "replay_trajectory",
                summary: "Replay a saved trajectory of past actions.",
                scopeKey: nil
            )
        default:
            return .safe
        }
    }

    // MARK: - Per-tool classifiers

    private static func classifyHotkey(
        args: [String: JSONValue]
    ) -> Sensitivity {
        guard let normalized = normalizeHotkey(args: args) else {
            return .safe
        }
        if sendHotkeyPatterns.contains(normalized) {
            return .requiresApproval(
                reason: "send_hotkey",
                summary: "Send a message or email via \(displayHotkey(normalized)).",
                scopeKey: nil
            )
        }
        return .safe
    }

    /// `press_key` with `["return"]` (or `["enter"]`) is the
    /// canonical "commit the focused field" chord. We treat it as
    /// approval-worthy when no modifiers are present — modifier
    /// chords route through `hotkey`. The conservative bias here
    /// matches the rule's purpose: a bare Return after typing a
    /// message body almost always ships the message.
    ///
    /// Tradeoff: this will also flag Returns that just dismiss a
    /// dialog or move to a new line in a multi-line composer. The
    /// user can click "Approve" — friction is acceptable for
    /// Phase 1 while we don't have AX-aware context. Phase 4 will
    /// look at the focused element role to disambiguate.
    private static func classifyPressKey(
        args: [String: JSONValue]
    ) -> Sensitivity {
        guard let keys = args["keys"]?.arrayValue else { return .safe }
        let strings = keys.compactMap(\.stringValue).map { $0.lowercased() }
        if strings.count == 1, strings.first == "return" || strings.first == "enter" {
            return .requiresApproval(
                reason: "bare_return",
                summary: "Press Return to commit the focused field.",
                scopeKey: nil
            )
        }
        return .safe
    }

    private static func classifyPage(
        args: [String: JSONValue]
    ) -> Sensitivity {
        guard let action = args["action"]?.stringValue?.lowercased() else {
            return .safe
        }
        if !sensitivePageActions.contains(action) { return .safe }

        // The enable-AppleEvents action is special: the model has
        // a documented path to set `userHasConfirmedEnabling:
        // true` after a voice command authorizes the browser
        // read. Respect that flag — re-asking after voice-as-
        // consent is friction the Phase 1 prompt explicitly
        // calls out (Worker.systemInstructionContent rule 7).
        if action == "enable_javascript_apple_events",
           args["userHasConfirmedEnabling"]?.boolValue == true
        {
            return .safe
        }

        // Per-app one-time approval: scope the verdict to the
        // (action, bundleId) pair so the coordinator can auto-
        // approve subsequent JS execution against the same browser
        // for the rest of the session. The first call still
        // prompts so the user can authorize Cacty to drive that
        // specific browser; further calls within the session skip
        // the friction.
        let bundleId = args["bundleId"]?.stringValue
            ?? args["bundle_id"]?.stringValue
        let scopeKey = bundleId.map { "page_\(action):\($0)" }
        let appLabel = bundleId.map { " in \($0)" } ?? ""
        return .requiresApproval(
            reason: "page_\(action)",
            summary: "Browser action: \(action)\(appLabel).",
            scopeKey: scopeKey
        )
    }

    // MARK: - Helpers

    /// Convert a `hotkey` call's args into a lowercased, sorted,
    /// comma-joined chord string for matching. Modifier aliases
    /// are canonicalized so `["ctrl", "return"]` and
    /// `["control", "return"]` produce the same key.
    static func normalizeHotkey(
        args: [String: JSONValue]
    ) -> String? {
        guard let keys = args["keys"]?.arrayValue else { return nil }
        let names = keys
            .compactMap(\.stringValue)
            .map { canonicalModifier($0.lowercased()) }
        if names.isEmpty { return nil }
        return names.sorted().joined(separator: ",")
    }

    /// Collapse modifier aliases to one canonical token. Keeps the
    /// patterns set small (one entry per chord) and the
    /// classifier robust to Gemini's choice of synonym.
    private static func canonicalModifier(_ token: String) -> String {
        switch token {
        case "control": return "ctrl"
        case "option", "opt", "alt": return "alt"
        case "command": return "cmd"
        default: return token
        }
    }

    /// User-facing pretty-print of a normalized chord string.
    /// `"cmd,return"` → `"⌘ Return"`.
    private static func displayHotkey(_ normalized: String) -> String {
        normalized
            .split(separator: ",")
            .map { part -> String in
                switch part {
                case "cmd": return "⌘"
                case "shift": return "⇧"
                case "alt", "opt", "option": return "⌥"
                case "ctrl", "control": return "⌃"
                case "return": return "Return"
                case "enter": return "Enter"
                default: return String(part).capitalized
                }
            }
            .joined(separator: " ")
    }
}
