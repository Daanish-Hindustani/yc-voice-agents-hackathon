import Foundation

/// Type-safe builders for the `FunctionDeclaration` values the
/// supervisor sends to Gemini. Each method on `ToolSchema`
/// produces a single declaration mirroring one of `Automation.Engine`'s
/// public methods, with the OpenAPI-flavored parameter schema
/// hand-written from the engine's call-site shape.
///
/// Convention: tool names use snake_case (`launch_app`,
/// `click_element`) per Gemini's tool-calling style and the
/// patterns established in `docs/agent-skills/driving-mac-apps.md`.
/// The supervisor's dispatch layer maps these names back to
/// `Engine` Swift methods (camelCase) when handling each
/// `FunctionCall`.
///
/// Use `allEngineTools()` to wire the whole surface in one call;
/// the supervisor's `Worker` constructs `Tool(functionDeclarations:
/// ToolSchema.allEngineTools())` at task start and never lists tools
/// individually.
public enum ToolSchema {
    /// Every engine-mirroring tool, in a stable order. The order
    /// is part of the wire shape Gemini sees — keeping it stable
    /// across releases makes it easier to compare model behaviour
    /// across runs (the model's internal tool-selection logic is
    /// known to weight order in practice).
    public static func allEngineTools() -> [FunctionDeclaration] {
        return [
            listApps(),
            listWindows(),
            launchApp(),
            getWindowState(),
            clickElement(),
            typeText(),
            setElementValue(),
            pressKey(),
            page(),
            rightClick(),
            doubleClick(),
            drag(),
            scroll(),
            hotkey(),
            moveCursor(),
            zoom(),
            getCursorPosition(),
            getScreenSize(),
            getAccessibilityTree(),
            screenshot(),
            checkPermissions(),
            setRecording(),
            getRecordingState(),
            replayTrajectory(),
            getAgentCursorState(),
            setAgentCursorEnabled(),
            setAgentCursorMotion(),
            getConfig(),
            setConfig(),
            askUser(),
        ]
    }

    // MARK: - Clarification

    /// Declaration for the Cacty-specific `ask_user` tool. Routes
    /// through `ClarificationGate` to the bottom-center panel; the
    /// user's reply is shipped back to the model as the tool's
    /// `FunctionResponse`. This is the model's only path to
    /// disambiguate without guessing — Cacty's voice-PTT UX has no
    /// in-flight text channel, so the model must explicitly call
    /// `ask_user` when it would otherwise fall back to assumption.
    ///
    /// Not in cua. Cacty-specific because cua's MCP-CLI consumers
    /// can interleave clarifying text with the model; Cacty's
    /// release-Fn-and-watch-it-go flow can't.
    public static func askUser() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "ask_user",
            description: """
                Ask the user a clarifying question via Cacty's \
                bottom-center panel. Use this when:

                - The original voice command is ambiguous in a way no \
                tool call can resolve (e.g. "send the email to John" \
                when `list_apps`/contacts can't distinguish which John).
                - You need a value that only the user knows (a meeting \
                time they haven't committed to a calendar yet, the body \
                text for a message you can't infer).
                - A destructive choice has more than one safe path and \
                you'd rather the user pick than guess.

                Do NOT use `ask_user` for facts you can resolve with a \
                tool (bundle ids, pids, window ids, current Calendar \
                events, currently-open browser tabs). Reread system \
                prompt rule 1 — `list_apps` / `list_windows` / `page` / \
                `get_window_state` come first.

                Provide 2–4 `choices` whenever the answer space is \
                discrete (e.g. "Which Slack workspace?" → \
                ["Personal", "Acme", "Skip"]). Leave `choices` empty \
                only when the answer must be free-form text. The panel \
                always shows a Skip control regardless — `choices` is \
                the bounded happy path.

                The tool returns one of:
                - `{"reply_type": "selected", "index": <int>, "text": <choice string>}`
                - `{"reply_type": "freeform", "text": "<user typed>"}`
                - `{"reply_type": "skipped"}`

                A `skipped` reply means the user declined to answer — \
                decide whether to abort the task with a clear \
                explanation or proceed with your best guess (and say so).
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "question": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "One sentence in plain English. Address the user "
                                + "directly (\"Which …?\"), no preamble like "
                                + "\"I need to clarify.\""
                        )
                    ]),
                    "choices": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "2–4 short discrete options, or empty for "
                                + "free-form answer only. Each option is a "
                                + "user-visible string; do not include \"Skip\""
                                + "as a choice — the panel renders a Skip "
                                + "control separately."
                        )
                    ]),
                ]),
                "required": .array([.string("question")])
            ])
        )
    }

    // MARK: - Inventory

    /// Declaration for `Engine.listApps()`.
    public static func listApps() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "list_apps",
            description: """
                List every macOS app the system knows about: running processes \
                plus installed `.app` bundles. Each entry carries a `pid` \
                (0 if the app is installed but not running), `bundleId`, \
                `name`, `running`, and `active` (true only for the user's \
                frontmost app). Use this to find the pid of an already- \
                running app or to check whether a target needs `launch_app` \
                first. Pure read; no side effects.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    /// Declaration for `Engine.listWindows(forPid:)`.
    public static func listWindows() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "list_windows",
            description: """
                List every window owned by `pid`, including off-screen, \
                minimized, and hidden windows (a launched app's windows are \
                hidden by default and still drivable via AX). Each entry \
                carries `id` (the CGWindowID — pass this back as `windowId` \
                in subsequent calls), `bounds`, `name`, `isOnScreen`. Use \
                this after `launch_app` to find the `windowId` to pass to \
                `get_window_state`. Pure read; no side effects.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Target process id (from `list_apps` or `launch_app`)."
                        )
                    ])
                ]),
                "required": .array([.string("pid")])
            ])
        )
    }

    // MARK: - Launch

    /// Declaration for `Engine.launchApp(bundleId:)`. The first
    /// tool we exposed is also the simplest — a single required
    /// string argument and a high-signal description so Gemini
    /// can disambiguate it from the model's general "open an app"
    /// chat-mode reflex.
    public static func launchApp() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "launch_app",
            description: """
                Launch a native macOS app without stealing focus from \
                whatever the user is currently using. The launched app may \
                be visible on screen (it is not hidden or minimized) but it \
                will not become the frontmost app — the user's existing \
                frontmost stays active. Idempotent for already-running \
                apps: if the target is already running, returns its existing \
                process info. If the target is already running but hidden \
                (Cmd+H), it is unhidden so its windows are composited and \
                `get_window_state` screenshots return real pixels instead \
                of a black frame; focus is then returned to whatever the \
                user was using. ALWAYS call this before the first \
                `get_window_state` on a target, even when `list_apps` shows \
                the app is already running — this is the only way to \
                guarantee capturable pixels for a previously-hidden app. \
                Provide the macOS bundle identifier (e.g., \
                "com.apple.calculator", "com.apple.Mail", "com.google.Chrome").
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "bundleId": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "The macOS bundle identifier of the app to launch."
                        )
                    ])
                ]),
                "required": .array([.string("bundleId")])
            ])
        )
    }

    // MARK: - Snapshot

    /// Declaration for `Engine.getWindowState(pid:windowId:captureMode:)`.
    public static func getWindowState() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_window_state",
            description: """
                Snapshot a specific window and return a Markdown-rendered \
                AX tree (with numeric `element_index`es on every actionable \
                element) plus, by default, a base64-encoded PNG of the \
                window. Element indices are cache-keyed on `(pid, \
                window_id)` and only valid until the next \
                `get_window_state` call against the same window — call \
                this immediately before any `click_element` action. \
                Pure read; no side effects, no focus change.

                When `capture_mode` includes a screenshot, the image \
                is delivered as an inline-image attachment in the \
                user turn that immediately follows this tool's \
                response — `screenshot_attached_as` in the function \
                response confirms it landed. Read that image to see \
                non-AX-exposed content: Slack/Discord/Electron \
                message text, canvas/WebGL pixels, custom-rendered \
                views, anything else the AX tree omits. Image pixel \
                coordinates relate to AX point coordinates by \
                `point = pixel / screenshot_scale_factor`.

                IMPORTANT — black-screenshot avoidance: macOS does \
                not composite the windows of a Cmd+H-hidden app, so \
                capturing such an app returns a fully black PNG. \
                ALWAYS call `launch_app(bundleId)` for your target \
                app BEFORE the first `get_window_state` against it, \
                even when `list_apps` shows the app is already \
                running. `launch_app` is idempotent for running \
                apps and, when the app is hidden, unhides it (its \
                windows become composited) without leaving it \
                frontmost. Skipping this step on a hidden app \
                wastes a turn on a black screenshot.

                `capture_mode`:
                  - `som` (default): tree + screenshot. Best when you \
                    need to read on-screen text that may not be in the \
                    AX tree (Slack/Discord messages, etc.).
                  - `ax`: tree only, no screenshot. Cheaper payload — \
                    use when you only need element indices and the \
                    target's content already surfaces in the AX tree.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Target process id.")
                    ]),
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Window id from `list_windows`."
                        )
                    ]),
                    "captureMode": .object([
                        "type": .string("STRING"),
                        "enum": .array([
                            .string("som"), .string("ax")
                        ]),
                        "description": .string(
                            "Optional. `som` (default) returns tree + "
                            + "PNG; `ax` returns tree only."
                        )
                    ])
                ]),
                "required": .array([
                    .string("pid"), .string("windowId")
                ])
            ])
        )
    }

    // MARK: - Action

    /// Declaration for the cua `click` tool. Backed by
    /// `Engine.click(pid:windowId:elementIndex:x:y:modifiers:count:)`.
    public static func clickElement() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "click",
            description: """
                Left-click against a target pid. Two addressing modes:

                - `elementIndex` + `windowId` (from the last \
                `get_window_state` snapshot of that window) — performs \
                an AX action on the cached element. Pure AX RPC, works \
                on backgrounded / hidden windows, no cursor move or \
                focus steal. PREFERRED whenever an element_index is \
                available.

                - `x`, `y` window-local screenshot pixels (same space \
                as the PNG `get_window_state` returns) — synthesizes \
                mouse events via CGEvent / SkyLight and delivers to \
                the pid. AX never consulted on this path. Driver \
                rescales image-pixel → screen-point internally using \
                the last capture's resize ratio. `count: 2` posts a \
                stamped double-click; `modifier` holds \
                cmd/shift/option/ctrl during the click.

                Exactly one of `elementIndex` or (`x` AND `y`) must \
                be provided.

                FORBIDDEN: do NOT click system menu-bar items (role = \
                AXMenuBarItem). Those clicks force the target app to \
                the foreground, violating the background guarantee, \
                and the engine will refuse them with `action_refused`. \
                Use `press_key` for keyboard shortcuts instead.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Target process id.")
                    ]),
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Window id from the matching `get_window_state` "
                                + "call. Required with `elementIndex`."
                        )
                    ]),
                    "elementIndex": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Index from the snapshot's `tree_markdown`. "
                                + "Mutually exclusive with x/y."
                        )
                    ]),
                    "x": .object([
                        "type": .string("NUMBER"),
                        "description": .string(
                            "Window-local pixel X (PNG space). Pair with y."
                        )
                    ]),
                    "y": .object([
                        "type": .string("NUMBER"),
                        "description": .string(
                            "Window-local pixel Y (PNG space). Pair with x."
                        )
                    ]),
                    "modifier": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "Modifier keys held during the click "
                                + "(cmd/shift/option/ctrl). Pixel path only."
                        )
                    ]),
                    "count": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "1 (single), 2 (double), 3 (triple). "
                                + "Pixel path only. Default 1."
                        )
                    ]),
                ]),
                "required": .array([.string("pid")])
            ])
        )
    }

    /// Declaration for the cua `type_text_chars` tool — backed by
    /// `Engine.type(pid:text:)`. Cacty's previous tool name `type_text`
    /// was reassigned to the AX-write primitive (cua-aligned) and the
    /// raw-CGEvent variant moved here.
    public static func typeText() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "type_text_chars",
            description: """
                Type `text` one character at a time, delivered directly to \
                the target pid's event queue via `CGEvent.postToPid`. Each \
                character is posted as a synthesized key-down/key-up pair \
                whose Unicode payload is set via \
                `CGEventKeyboardSetUnicodeString`, bypassing virtual-key \
                mapping so accents, symbols, and emoji transmit verbatim.

                REQUIRED PATH FOR DISCORD, SLACK, MS TEAMS, and any \
                other Electron app whose message input is a rich-text \
                editor (Slate.js, Draft.js, Lexical, ProseMirror). \
                Those inputs silently no-op `type_text` (AX) writes — \
                you'll see `type_text` return success but the field \
                stays empty. Synthesized keystrokes via this tool DO \
                land because the renderer treats them as real input. \
                Standard chain for sending a Discord/Slack message: \
                (1) `click` the message input to focus it, \
                (2) `type_text_chars(pid, text)` to insert the body, \
                (3) `press_key(pid, keys: ["return"])` to send. \
                For Cocoa text fields (Mail compose, Notes, Spotlight, \
                Safari address bar), prefer `type_text` — that path \
                is more reliable on AX-aware native inputs.

                The target does NOT need to be frontmost; keyboard \
                focus within the target pid determines where \
                characters land, so focus the receiving element first \
                (e.g. via `click` on the input).
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Target process id.")
                    ]),
                    "text": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "Literal characters to type. ASCII supported; "
                                + "Unicode requiring an IME is best-effort."
                        )
                    ])
                ]),
                "required": .array([
                    .string("pid"), .string("text")
                ])
            ])
        )
    }

    /// Declaration for the cua `type_text` tool — AX
    /// `kAXSelectedText` write. Backed by `Engine.setElementValue`.
    public static func setElementValue() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "type_text",
            description: """
                Insert `text` into the target pid via \
                `AXSetAttribute(kAXSelectedText)`. Works for standard \
                Cocoa text fields and text views (Mail compose, Notes, \
                TextEdit, Spotlight, Safari address bar, native \
                NSTextField search boxes).

                DO NOT USE FOR ELECTRON CHAT APPS (Discord, Slack, \
                MS Teams) OR ANY SLATE.JS / DRAFT.JS / LEXICAL / \
                PROSEMIRROR EDITOR. These apps report \
                `kAXSelectedText` writes as succeeded but silently \
                discard them — the rich-text editor manages its own \
                state and ignores AX writes. You will see "ok" come \
                back from this tool and a follow-up snapshot will \
                show the input is still empty. Use \
                `type_text_chars` instead for those targets: click \
                the input first (so the renderer focuses it), then \
                `type_text_chars(pid, text)` synthesizes real key \
                events that Slate / Draft / Lexical / ProseMirror \
                accept. Hard rule for Discord: ALWAYS use the \
                click → type_text_chars → press_key(["return"]) \
                sequence; `type_text` will silently no-op every \
                time.

                Requires `element_index` + `window_id` from the last \
                `get_window_state` snapshot of that window; the \
                element is focused before the write. Targeting a \
                non-text element returns `action_refused`; targeting \
                a stale index returns `element_not_found`.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Target process id.")
                    ]),
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Window id from the matching `get_window_state` call."
                        )
                    ]),
                    "elementIndex": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Index of the text element from `tree_markdown`."
                        )
                    ]),
                    "text": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "Replacement contents for the text field."
                        )
                    ])
                ]),
                "required": .array([
                    .string("pid"), .string("windowId"),
                    .string("elementIndex"), .string("text")
                ])
            ])
        )
    }

    /// Declaration for `Engine.pressKey(pid:keys:)`.
    public static func pressKey() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "press_key",
            description: """
                Press a single key (or modifier+key combo) into the target \
                pid. Background-safe: pid-scoped CGEvent post, identical \
                routing to `type_text`, no focus steal, no cursor movement.

                USE THIS TO SUBMIT MESSAGES, FORMS, AND COMMANDS. After \
                you put text into a Slack/Discord/iMessage/Mail message \
                box with `set_element_value`, call `press_key(keys: \
                ["return"])` to actually send it. `type_text` with "\\n" \
                or "\\r" does NOT submit messages in Electron / web apps \
                — those characters reach the input as literal characters \
                and the message just sits there. Return must be a real \
                key event, which is what this tool produces.

                Other common uses:
                  - keys: ["return"]            → submit / commit / Enter
                  - keys: ["escape"]            → cancel modal / dismiss
                  - keys: ["tab"]               → advance focus
                  - keys: ["cmd", "f"]          → in-app search
                  - keys: ["cmd", "k"]          → quick switcher / palette
                  - keys: ["cmd", "return"]     → send (Slack/Discord force-send)
                  - keys: ["cmd", "shift", "k"] → channel switcher (Slack)
                  - keys: ["down"] / ["up"]     → list navigation

                Modifier auto-classification: cmd / command / shift / \
                option / alt / ctrl / control / fn are recognized as \
                modifiers; the remaining key is the keycap. If multiple \
                non-modifier keys are passed, only the last is pressed \
                (use one call per discrete key).

                FORBIDDEN combos (refused at the engine layer): cmd+l \
                (omnibox focus, foregrounds Chrome), cmd+tab (app \
                switcher), cmd+` (window cycle). Use AX-tree navigation \
                or the URL-attached `launch_app` form instead.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Target process id.")
                    ]),
                    "keys": .object([
                        "type": .string("ARRAY"),
                        "items": .object([
                            "type": .string("STRING")
                        ]),
                        "description": .string(
                            "Key names. Modifiers (cmd, shift, option, "
                                + "ctrl, fn) are auto-classified; the "
                                + "remaining entry is the keycap "
                                + "(return, escape, tab, space, "
                                + "up/down/left/right, a-z, 0-9, f1-f12)."
                        )
                    ]),
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Optional. CGWindowID for the window whose "
                                + "get_window_state produced the "
                                + "elementIndex. Required when "
                                + "elementIndex is used."
                        )
                    ]),
                    "elementIndex": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Optional. Element index from the last "
                                + "get_window_state for the same (pid, "
                                + "windowId). When present, the element "
                                + "is focused via "
                                + "AXSetAttribute(kAXFocused, true) "
                                + "before the key is posted. Canonical "
                                + "path for 'type into this exact field "
                                + "→ press Return on it.'"
                        )
                    ])
                ]),
                "required": .array([
                    .string("pid"), .string("keys")
                ])
            ])
        )
    }

    /// Declaration for `Engine.page(...)`. Faithful port of cua's
    /// `PageTool` tool description.
    public static func page() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "page",
            description: """
                Browser page primitives — execute JavaScript, extract page \
                text, or query DOM elements via CSS selector. \
                PREFERRED PATH for reading Chrome / Safari / Brave / Edge \
                content: the browser does NOT need to be frontmost, NO tab \
                switching, NO focus steal. Use this instead of \
                `get_window_state` + `click_element` on a tab bar when you \
                want data from a known browser tab.

                Three read/exec actions:

                • `execute_javascript` — run arbitrary JS in the active tab \
                and return the result. Wrap in an IIFE with try-catch for \
                safety. Don't use for elements already indexed by \
                `get_window_state` — prefer `click_element` / \
                `set_element_value` there.

                • `get_text` — returns `document.body.innerText`. Faster \
                than walking the AX tree for plain-text content (prices, \
                article body, table values) that the AX tree drops or \
                truncates.

                • `query_dom` — runs `querySelectorAll(css_selector)` and \
                returns each match's tag, innerText, and any requested \
                attributes as JSON. Useful for structured data (table \
                rows, link hrefs, data-* attributes) that the AX tree \
                flattens.

                One setup action:

                • `enable_javascript_apple_events` — enable 'Allow \
                JavaScript from Apple Events' in Chrome / Brave / Edge. \
                Quits the browser, patches each profile's Preferences \
                JSON, then relaunches. Requires \
                `userHasConfirmedEnabling=true` — you MUST ask the user \
                for explicit permission before calling this action.

                Supported browsers: Chrome (com.google.Chrome), Brave \
                (com.brave.Browser), Edge (com.microsoft.edgemac), Safari \
                (com.apple.Safari). For Electron apps (Slack, Discord, \
                VS Code) JS is routed via CDP automatically when the app \
                was launched with `electron_debugging_port`. For \
                Tauri / WKWebView apps `get_text` / `query_dom` fall back \
                to AX-tree reads.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Browser process id."),
                    ]),
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "CGWindowID of the target browser window."
                        ),
                    ]),
                    "action": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "One of: execute_javascript, get_text, "
                                + "query_dom, enable_javascript_apple_events."
                        ),
                    ]),
                    "javascript": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "JS to execute (action=execute_javascript "
                                + "only). Should return a serialisable "
                                + "value. Wrap in IIFE: `(() => { … })()`."
                        ),
                    ]),
                    "cssSelector": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "CSS selector (action=query_dom only). Passed "
                                + "to querySelectorAll — standard CSS syntax."
                        ),
                    ]),
                    "attributes": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "Element attributes to include per match "
                                + "(action=query_dom only). E.g. "
                                + "[\"href\", \"src\", \"data-id\"]. "
                                + "tag and innerText are always included."
                        ),
                    ]),
                    "bundleId": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "Browser bundle id "
                                + "(action=enable_javascript_apple_events "
                                + "only). E.g. com.google.Chrome."
                        ),
                    ]),
                    "userHasConfirmedEnabling": .object([
                        "type": .string("BOOLEAN"),
                        "description": .string(
                            "Must be true "
                                + "(action=enable_javascript_apple_events "
                                + "only). Set only after the user has "
                                + "explicitly said yes."
                        ),
                    ]),
                ]),
                "required": .array([
                    .string("pid"), .string("windowId"), .string("action"),
                ]),
            ])
        )
    }

    // MARK: - cua tool ports (Phase 3)

    private static let pidProp: JSONValue = .object([
        "type": .string("INTEGER"),
        "description": .string("Target process id.")
    ])

    private static let windowIdProp: JSONValue = .object([
        "type": .string("INTEGER"),
        "description": .string(
            "CGWindowID for the window whose get_window_state produced "
                + "the elementIndex. Required when elementIndex is used."
        )
    ])

    private static let elementIndexProp: JSONValue = .object([
        "type": .string("INTEGER"),
        "description": .string(
            "Element index from the last get_window_state for the same "
                + "(pid, windowId)."
        )
    ])

    public static func rightClick() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "right_click",
            description: """
                Right-click against a target pid. Two addressing modes: \
                element_index + windowId (AXShowMenu, AX RPC, no focus \
                steal), or x + y window-local screenshot pixels \
                (synthesized CGEvent right-mouse pair). Modifier keys \
                apply only to the pixel path.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "windowId": windowIdProp,
                    "elementIndex": elementIndexProp,
                    "x": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Window-local pixel X.")
                    ]),
                    "y": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Window-local pixel Y.")
                    ]),
                    "modifier": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "Modifier keys (cmd/shift/option/ctrl) held "
                                + "during the click. Pixel path only."
                        )
                    ]),
                ]),
                "required": .array([.string("pid")]),
            ])
        )
    }

    public static func doubleClick() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "double_click",
            description: """
                Double-click against a target pid. element_index + \
                windowId tries AXOpen first, falls back to a stamped \
                pixel double-click at the element's center. x + y pixel \
                path synthesizes two CGEvent down/up pairs via the \
                primer-gated auth-signed recipe. Required for \
                Chromium-rendered double-click handlers.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "windowId": windowIdProp,
                    "elementIndex": elementIndexProp,
                    "x": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Window-local pixel X.")
                    ]),
                    "y": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Window-local pixel Y.")
                    ]),
                    "modifier": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "Modifier keys held during the gesture. "
                                + "Pixel path only."
                        )
                    ]),
                ]),
                "required": .array([.string("pid")]),
            ])
        )
    }

    public static func drag() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "drag",
            description: """
                Press-drag-release gesture from (fromX, fromY) to (toX, \
                toY) in window-local screenshot pixels. Pixel-only — \
                macOS AX has no semantic drag action. Use for \
                marquee/lasso selection, drag-and-drop, slider scrub, \
                handle resize. durationMs (default 500) and steps \
                (default 20) shape the path. Frontmost target: real HID \
                cursor moves. Backgrounded target: cursor-neutral pid \
                routing.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Optional CGWindowID. When omitted, "
                                + "frontmost window of pid is used."
                        )
                    ]),
                    "fromX": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Drag-start X (pixels).")
                    ]),
                    "fromY": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Drag-start Y (pixels).")
                    ]),
                    "toX": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Drag-end X (pixels).")
                    ]),
                    "toY": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Drag-end Y (pixels).")
                    ]),
                    "durationMs": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Wall-clock budget between mouseDown and "
                                + "mouseUp. Default 500."
                        )
                    ]),
                    "steps": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Interpolated mouseDragged events. Default 20."
                        )
                    ]),
                    "modifier": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "Modifier keys held throughout the gesture."
                        )
                    ]),
                ]),
                "required": .array([
                    .string("pid"),
                    .string("fromX"), .string("fromY"),
                    .string("toX"), .string("toY"),
                ]),
            ])
        )
    }

    public static func scroll() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "scroll",
            description: """
                Scroll the target pid's focused region via synthesized \
                keystrokes (PageUp/Down for 'page', arrow keys for \
                'line'). Wheel events are silently dropped by Chromium \
                via the per-pid path — keystrokes don't have that \
                problem. Optional elementIndex + windowId pre-focuses \
                a scrollable element.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "direction": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "One of: up, down, left, right."
                        )
                    ]),
                    "amount": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Keystroke repetitions (1-50). Default 3."
                        )
                    ]),
                    "by": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "Granularity: 'line' or 'page'. Default line."
                        )
                    ]),
                    "windowId": windowIdProp,
                    "elementIndex": elementIndexProp,
                ]),
                "required": .array([.string("pid"), .string("direction")]),
            ])
        )
    }

    public static func hotkey() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "hotkey",
            description: """
                Press a chord combo on target pid. E.g. ["cmd","c"] for \
                Copy, ["cmd","shift","4"] for screenshot. Posted via \
                CGEvent.postToPid — target doesn't need to be frontmost. \
                Functionally overlaps with press_key's array form; this \
                tool exists for cua-parity.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "keys": .object([
                        "type": .string("ARRAY"),
                        "items": .object(["type": .string("STRING")]),
                        "description": .string(
                            "Modifier(s) + one non-modifier key. "
                                + "E.g. ['cmd','c']."
                        )
                    ]),
                ]),
                "required": .array([.string("pid"), .string("keys")]),
            ])
        )
    }

    public static func moveCursor() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "move_cursor",
            description: """
                Instantly move the system cursor to (x, y) in screen \
                points via CGWarpMouseCursorPosition. No drag, no click, \
                no CGEvent.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "x": .object([
                        "type": .string("INTEGER"),
                        "description": .string("X in screen points.")
                    ]),
                    "y": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Y in screen points.")
                    ]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        )
    }

    public static func zoom() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "zoom",
            description: """
                Zoom into a rectangular region of a window screenshot at \
                native resolution. Use when get_window_state returned a \
                resized image and you need to read small text or icons. \
                Coordinates in resized-image pixel space.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "x1": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Left edge of region.")
                    ]),
                    "y1": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Top edge of region.")
                    ]),
                    "x2": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Right edge of region.")
                    ]),
                    "y2": .object([
                        "type": .string("NUMBER"),
                        "description": .string("Bottom edge of region.")
                    ]),
                ]),
                "required": .array([
                    .string("pid"),
                    .string("x1"), .string("y1"),
                    .string("x2"), .string("y2"),
                ]),
            ])
        )
    }

    public static func getCursorPosition() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_cursor_position",
            description:
                "Return the current mouse cursor position in screen points "
                + "(origin top-left).",
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    public static func getScreenSize() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_screen_size",
            description: """
                Return the logical size of the main display in points \
                plus its backing scale factor. Retina displays have \
                scale_factor 2.0.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    public static func getAccessibilityTree() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_accessibility_tree",
            description: """
                Return the AX tree markdown for (pid, windowId). \
                Convenience over get_window_state(captureMode: ax) — \
                same data, no screenshot.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string("CGWindowID.")
                    ]),
                ]),
                "required": .array([.string("pid"), .string("windowId")]),
            ])
        )
    }

    public static func screenshot() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "screenshot",
            description: """
                Standalone PNG screenshot of a window. When windowId is \
                omitted, picks the pid's frontmost on-screen window. \
                Used by vision-only workflows that don't need an AX walk.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": pidProp,
                    "windowId": .object([
                        "type": .string("INTEGER"),
                        "description": .string("Optional CGWindowID.")
                    ]),
                    "maxImageDimension": .object([
                        "type": .string("INTEGER"),
                        "description": .string(
                            "Clamp longest edge to this many pixels. "
                                + "0 = native resolution. Default 1600."
                        )
                    ]),
                ]),
                "required": .array([.string("pid")]),
            ])
        )
    }

    public static func checkPermissions() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "check_permissions",
            description: """
                Probe macOS TCC grants (Accessibility, Screen Recording). \
                Returns a boolean per permission.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    public static func setRecording() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "set_recording",
            description: """
                Enable or disable trajectory recording. When enabled \
                with no `outputDir`, the driver picks \
                `~/Library/Application Support/Cacty/recordings/<ISO-8601>`. \
                `videoExperimental` opts into the screen-capture + \
                cursor-sampler pipeline alongside the trajectory \
                JSONL (heavier; off by default).
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "enabled": .object([
                        "type": .string("BOOLEAN"),
                        "description": .string(
                            "True to start recording, false to stop."
                        )
                    ]),
                    "outputDir": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "Optional path for the recording session "
                                + "directory. Tilde-expanded. When "
                                + "omitted, an ISO-8601-stamped dir is "
                                + "created under Application Support."
                        )
                    ]),
                    "videoExperimental": .object([
                        "type": .string("BOOLEAN"),
                        "description": .string(
                            "When true, also arm video capture + "
                                + "cursor sampling. Default false."
                        )
                    ]),
                ]),
                "required": .array([.string("enabled")]),
            ])
        )
    }

    public static func getRecordingState() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_recording_state",
            description: """
                Return current trajectory-recording state \
                (enabled / configured output dir / turn count).
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    public static func replayTrajectory() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "replay_trajectory",
            description: """
                DO NOT CALL — this tool always returns an unsupported \
                error in Cacty. Action-replay (re-driving recorded \
                tool calls against a live session) is not implemented \
                in Cacty's `Recording` pipeline; only video rendering \
                via `RecordingRenderer.render(from:to:)` exists. \
                Schema kept for cua parity; the engine surfaces a \
                structured error pointing callers at the rendering \
                alternative. If the user asks to "replay" a recording, \
                tell them Cacty can render the video but cannot \
                re-execute the actions.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "path": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "Filesystem path to the trajectory dir."
                        )
                    ]),
                ]),
                "required": .array([.string("path")]),
            ])
        )
    }

    public static func getAgentCursorState() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_agent_cursor_state",
            description: """
                Return whether the agent-cursor overlay is currently \
                enabled. (Visual indicator only — separate from the \
                system cursor.)
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    public static func setAgentCursorEnabled() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "set_agent_cursor_enabled",
            description: """
                Show or hide the agent-cursor overlay (visual indicator \
                only — does not move the real system cursor).
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "enabled": .object([
                        "type": .string("BOOLEAN"),
                        "description": .string("True to show, false to hide.")
                    ]),
                ]),
                "required": .array([.string("enabled")]),
            ])
        )
    }

    public static func setAgentCursorMotion() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "set_agent_cursor_motion",
            description: """
                Configure agent-cursor motion timings — glide duration \
                and idle-hide delay. (Style / shape is configured at \
                build time and not driven from this tool.)
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "glideDurationSeconds": .object([
                        "type": .string("NUMBER"),
                        "description": .string(
                            "Seconds for the cursor to glide to its "
                                + "target position. E.g. 0.75."
                        )
                    ]),
                    "idleHideDelaySeconds": .object([
                        "type": .string("NUMBER"),
                        "description": .string(
                            "Seconds after the last action before the "
                                + "overlay auto-hides. E.g. 8.0."
                        )
                    ]),
                ]),
            ])
        )
    }

    public static func getConfig() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "get_config",
            description: """
                Return the persisted driver config (capture mode, \
                telemetry/auto-update toggles, agent-cursor sub-config).
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([:]),
            ])
        )
    }

    public static func setConfig() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "set_config",
            description: """
                Update the persisted driver config. Accepts a JSON \
                serialization of the full CuaDriverConfig struct.
                """,
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "configJson": .object([
                        "type": .string("STRING"),
                        "description": .string(
                            "JSON-encoded CuaDriverConfig. See "
                                + "get_config for the canonical shape."
                        )
                    ]),
                ]),
                "required": .array([.string("configJson")]),
            ])
        )
    }
}
