# CLAUDE.md

Guidance for Claude Code (and other coding agents) working in this repository.

## What this project is

A native macOS menu-bar app: a voice-driven, multi-agent computer-use product. The user holds **Fn**, speaks a task, releases. The transcript goes to Gemini 3 Pro along with a set of automation tools. Gemini drives real Mac apps in the background while the user keeps working. Multiple agents run in parallel, each shown as a small floating dot in the top-right of the screen.

The full product specification is in `plan.md` — read it before making non-trivial changes. This file is for working conventions and constraints.

## The background contract — read this first

**Cacty's `Sources/Automation/` mirrors `cua-driver/` with four documented divergences.** Tool names, descriptions, behavior, and focus-management code all match cua exactly except where listed below. Cacty adds product layers (`Sources/App/`, `Sources/Agent/`, UI, Memory, PTT, Speech, Gemini integration) on top — none of which exist in cua. See `cua-driver/Sources/CuaDriverServer/Tools/*.swift` for the canonical tool reference.

**Cacty-specific extensions on top of cua.** Every divergence below was made to address a concrete UX failure Cacty's voice-PTT model can't tolerate but cua's MCP-CLI users do tolerate. Re-evaluate each one before extending it; never add a ninth divergence without explicit caller justification + a docstring at the divergence site pointing back here.

1. **Space-aware preventer skip** — `Sources/Automation/Focus/SystemFocusStealPreventer.swift` (`Entry.targetIsOnAnotherSpace` cache + `handleActivation` early-return). cua unconditionally calls `restoreTo.activate(options: [])` from its activation observer, which triggers a Mission Control Space-switch animation ("entire Mac blinks") when `restoreTo` is in a fullscreen Space and the target is in a regular Space (or vice versa) — empirically observed when a user voice-commands "type into Discord" while fullscreen on another app. Cacty caches a cross-Space verdict at `add` time (via `SpaceMigrator.status(forPid:)`) and skips the demote entirely when the target is off-Space. Safe because an off-Space target is invisible to the user anyway — there is nothing to undo.

2. **`forcePidRoute` flag on `MouseInput.click` / `rightClick` / `drag`** — `Sources/Automation/Input/MouseInput.swift`, plumbed through `Engine.click` / `rightClick` / `doubleClick` / `drag` via `Engine.shouldForcePidRoute(forPid:)`. cua's routing decision is `isActive`-only: when the target is frontmost, post via the HID tap. That breaks when Cacty has caused the target to be frontmost on its *own* Space (typical after a background launch + AX-write reflex activation) while the user is on a different Space — HID-tap delivery lands on the user's visible Space, not the target's. Cacty checks `SpaceMigrator` and forces pid-routed delivery when off-Space. Real cursor stays put, click lands on the right pid.

3. **Voice-as-consent for `page(action: enable_javascript_apple_events)`** — `Sources/Agent/Worker.swift` (system-prompt rule 7). cua's `PageTool` description says *"you MUST ask the user for explicit permission before calling this action"* (the action quits Chrome, patches Preferences JSON, relaunches). cua's MCP-CLI model has the LLM caller ask the human via UI; Cacty's voice-PTT flow can't carry a yes/no across a Fn-press boundary cheaply. The system prompt instructs the model to treat the user's original voice command as consent and set `userHasConfirmedEnabling: true` on the first call without re-asking. The engine-layer gate still requires the flag to be true — silent-prefs-write protection is preserved; only the asking-twice friction is removed.

4. **Discord / Slate.js typing rule** — `Sources/Agent/Worker.swift` (system-prompt rule 6). cua's `WEB_APPS.md` says *"if [type_text] silently drops, fall back to click + type_text_chars."* — meaning the model is expected to detect the silent-drop via post-state observation and retry. Gemini hallucinates success on the silent-drop case (the agent claimed Discord messages were sent that weren't). Cacty's prompt rule preemptively forbids `type_text` on Slate.js / Draft.js / Lexical / ProseMirror editors (Discord, Slack, MS Teams), forcing the click → `type_text_chars` → `press_key` chain. More aggressive than cua's policy; documented because the failure mode it prevents is silent.

5. **Extended launch suppression window** — `Sources/Automation/PublicAPI.swift` (`launchSuppressionWindowNs = 5_000_000_000`, polling demote at `launchPollIntervalNs = 100_000_000`). cua uses a fixed 500 ms blocking suppression hold plus a one-shot belt-and-braces demote. Empirically insufficient for slow-booting Electron apps (Slack, Discord, Teams, VS Code, Spotify) that fire multiple `NSApp.activate(ignoringOtherApps:)` calls across a 2–5 s cold boot — any activation after cua's 500 ms window closes leaves the target stuck frontmost. Cacty keeps the `SystemFocusStealPreventer` armed for 5 s and polls `NSWorkspace.shared.frontmostApplication` every 100 ms, re-demoting via `priorFrontmost.activate(options: [])` on each tick where the target is frontmost. Safe: no `hide()` calls (preserves the no-unhide design at `AppLauncher.swift:142–150`), no Space-switch (target stays in its own Space, just not frontmost). Trade-off: every `launch_app` blocks ~5 s before returning, which is within the existing LaunchServices + AX-tree-wait envelope for cold launches.

6. **Green agent-cursor palette + auto-enable** — `Sources/Automation/Cursor/AgentCursorView.swift` (focus-rect fill/stroke/glow + arrow gradient + bloom halo) and `Sources/App/Supervisor/AgentSupervisor.swift` (`runningCount` toggle). cua paints the on-screen agent-cursor overlay in ice-blue/cyan and only enables it when the LLM calls `set_agent_cursor_enabled`. Cacty repaints it green so users can trivially distinguish the agent's cursor from their own (matches the brand), and `AgentSupervisor` auto-enables the overlay while any task is `.running` (and disables when the last one terminates) so users see clicks/moves happening without the model having to remember the tool. Pure cosmetic + lifecycle divergence — the animation, motion-path, focus-rect, and click-press behavior remain identical to cua, and the cursor wiring inside `Engine.click` / `clickElement` / `rightClick` / `doubleClick` / `drag` is a verbatim port of the same calls in cua's `ClickTool` / `RightClickTool` / `DoubleClickTool` / `DragTool` (Cacty replaced cua's Tool layer with `Engine.*` methods, so the wiring had to live there instead).

7. **SOM-tree bounding-rect annotations** — `Sources/Automation/AppState/AppState.swift` (`AppStateEngine.RectTransform` typealias + optional `imagePixelTransform` parameter on `snapshot` and `renderTree`) and `Sources/Automation/PublicAPI.swift` (`getWindowState` SOM path captures screenshot first, then builds `makeImagePixelTransform` from the recorded `ImageScaleRegistry.Scale` + `WindowEnumerator` bounds, then walks AX with the transform). cua emits the AX tree with role / title / value / identifier / help / actions per element but no per-element geometry. Its model derives pixel coordinates from the screenshot visually. Gemini can't — observed on Google Calendar: when rule 10a / 11d forced the model onto the pixel path for React date/time pickers, every click was eyeballed and missed (`(50,100)`, `(95,125)`, `(121.5,128)` strings of misses without a popover ever opening). Cacty appends `rect=[x, y, w, h]` (rounded integers, scaled-image-pixel space — same coordinate space `click(x, y)` accepts) to each interactive element in SOM mode. Inverse of `windowLocalToScreen` (`PublicAPI.swift:2058-2096`). Skipped for `.ax` (no screenshot, so rects in scaled-image-pixel space would be meaningless) and elements without `AXPosition`+`AXSize`. System-prompt rules 10a and 11d in `Worker.swift` direct the model to read `(x + w/2, y + h/2)` straight off the rect rather than eyeball the screenshot.

8. **Chromium anti-throttle launch flags** — `Sources/Automation/PublicAPI.swift` (`chromiumAntiThrottleFlags`, `chromiumBundleIds`, `isChromiumBundle`, and the injection block in `launchApp`). When Cacty launches a Chromium-family browser (Chrome, Brave, Edge, Arc, Vivaldi, Opera + channel variants), the launch arguments are augmented with `--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling`. cua doesn't do this — its model interacts with the browser via the same window Cacty's `LivePopoverView` captures, but cua never tries to render that capture to a user-visible UI surface while the window is backgrounded. Cacty's hover-popover shows the agent's live view of the page; without the flags, Chromium pauses compositing of the Blink content layer for occluded / non-focused windows and SCK captures a stale IOSurface → the popover renders the AppKit-native tab strip but a black content region until the user manually foregrounds Chrome. Documented limitation: LaunchServices reuses an already-running browser instance and silently drops the flags, so the fix is only effective on a cold launch from Cacty. Safari (`com.apple.Safari`) is intentionally excluded — different engine, different occlusion policy, rejects Chromium CLI flags.

Beyond these eight, Cacty also stays cua-shaped: tool names match, parameter shapes match, `MouseInput` / `KeyboardInput` are bit-for-bit identical, `SystemFocusStealPreventer` differs only in the early-return + cache (1). Any other observable difference is a bug.

**Cacty's background contract is "visible-but-not-frontmost."** Launched / driven apps may have their windows briefly visible on the user's screen (Slack appearing in its previous on-screen position is acceptable) but must not steal sustained *frontmost / focus* from whatever the user is currently using.

Specifically, the agent must never:
- Steal **frontmost** from whatever the user has active (a sub-frame flash during a launch is acceptable; sustained frontmost is not)
- Leak keystrokes to any pid other than the target
- Trigger Dock bounces or system sounds

What it MAY do, given cua's reactive-suppression model:
- Briefly raise a window to z-order top before the focus-steal preventer reverts it (~1–2 frames; this is an inter-frame flash, not a sustained activation)
- Move the cursor via `move_cursor` (cua-mirrored tool — `CGWarpMouseCursorPosition`). The earlier no-cursor-movement rule was relaxed to match cua's tool surface 1:1.
- Switch the active Space when an off-Space target self-activates. Cacty's Space-aware preventer skip (`SystemFocusStealPreventer`) detects this and demotes without invoking `.activate()` on `restoreTo`, avoiding the Mission Control flash. cua does not suppress this — Cacty's voice-PTT UX requires the extension.
- Compose its own UI panels (Cacty's surfaces stay above without activating the agent app — see UI section)

If a task cannot be completed without breaking this contract, the agent escalates to the user rather than violating it.

**History note.** An earlier off-screen-window-parking experiment (`WindowParking.swift`, deleted 2026-05-13) was reverted in favor of cua's "visible-but-not-frontmost" model. Cacty's 5 s suppression hold, pre-emptive AX-enablement assertion, and Cmd+H unhide extensions were also reverted on 2026-05-14 to mirror cua exactly — the trade-off is that Slack and Chromium apps can briefly pop foreground when read, matching cua's baseline behavior. The Space-aware preventer skip was reverted alongside the others on 2026-05-14, then **restored later the same day** when the whole-screen Mission Control flash from cross-Space activations turned out to break message-typing entirely (CGEvents queued during Space transitions are silently dropped by Cocoa, not just visually disruptive). The 5 s suppression hold was also **restored later in 2026-05** as divergence (5) — a cleaner shape than the prior pound-`hide()` approach from commit `2acf296` — after the cua-parity revert reintroduced the Slack-pops-to-foreground regression on cold launches.

## Implement exactly what is asked — nothing more, nothing less

This is the second-most-important rule in this file. Coding agents have a tendency to "improve" requests by adding scope, refactoring nearby code, swapping libraries, or making things "more robust." **Don't.**

### The rules

1. **Do exactly what was requested.** If the request is "add a button that cancels the task," add a button that cancels the task. Don't also restructure the surrounding view, rename variables you think are unclear, or extract helpers.

2. **No unrequested refactors.** If you notice code nearby that looks improvable, leave it alone or surface it in a separate PR with the user's approval. Mid-task refactors hide what actually changed and break review.

3. **No silent dependency additions.** Don't add a new package, library, or framework without asking. This includes "small" utilities. Every dependency is a long-term liability.

4. **No silent scope expansion.** If the requested change requires touching more than what was asked (e.g. a schema migration to support the new field), stop and confirm before doing it.

5. **No "while I'm here" changes.** Fixing typos, reformatting code, updating comments unrelated to the task — none of these belong in the same PR as the requested change.

6. **Match the existing style.** Don't introduce a new pattern (functional vs. imperative, different naming convention, different error-handling style) just because you prefer it. Match what's already in the file.

7. **Ask when ambiguous.** If a request can be reasonably interpreted two ways, ask which one. Do not guess and proceed. Do not implement both. A clarifying question is cheaper than the wrong implementation.

8. **Don't add features the user didn't ask for.** If the user asks for a settings toggle, don't also add export/import for those settings. If they ask for a kill button, don't also add a confirmation dialog "for safety" unless they asked.

9. **Don't remove things you weren't asked to remove.** If old code looks dead, ask first. It might be load-bearing in ways that aren't obvious (see `Automation/` — half of it looks like ceremony but isn't).

10. **Stop and report when blocked.** If the requested change isn't possible as specified, stop and explain why. Don't pivot to a different approach without confirming.

### When you think the user is wrong

You may push back. State the concern clearly, give a concrete reason, and propose an alternative. Then **wait for the user's decision**. Don't pre-emptively implement what you think is the better approach.

Good: "This will conflict with the window-locking logic in `AgentSupervisor`. We could either (a) extend the lock to cover this case, or (b) bypass the lock for read-only actions. Which do you prefer?"

Bad: silently picking (b) because it's faster to implement.

### Surface assumptions explicitly

When implementing, if you're making a non-obvious decision — even one that seems reasonable — call it out in the PR description or in a comment. The user should be able to tell, from your output, which choices you made and why. Hidden decisions become surprise bugs.

### When asked for a plan, deliver a plan, not an implementation

If the request is "how should I do X" or "plan the change for X," respond with a plan and stop. Don't write the code. Don't start "just sketching" the implementation. Wait for explicit approval before coding.

## Architecture at a glance

```
Swift app (Cacty.app) — single process, no sidecar
├── App/                    SwiftUI, menu bar, PTT, UI surfaces
├── Automation/             Vendored + cleaned cua-driver engine
│                           (AX clicks, SkyLight pixel clicks,
│                            scoped keyboard, per-window capture)
└── Agent/                  Gemini client, worker pool, tool schema, memory context
```

The agent runs in-process as Swift actors drawn from a warm pool. There is no
Python and no IPC across processes — the supervisor talks directly to
`Automation/` via async function calls. Crash isolation is per-task error
containment inside actors, not OS-level process boundaries.

Read `plan.md` § Architecture and § Implementation Guide for the full picture.

## Working in `Automation/`

This module was copied from `trycua/cua` (MIT, attribution in `THIRD_PARTY_LICENSES.md`) with the MCP server, CLI, daemon scaffolding, and external-client glue removed. What's left is the engine.

**Cacty's `Sources/Automation/` is a faithful mirror of `cua-driver/`.** Behavior, tool descriptions, and focus-management code all match cua exactly. When iterating on launch / focus / capture paths, **port from cua verbatim**. The upstream reference stays vendored at `cua-driver/` for diffing. Diverging from cua without explicit caller justification is a review-blocking issue — and the divergence must be documented as a regression risk in the relevant module's docstring.

**Do not delete or refactor without understanding:**
- The auth-signed SkyLight recipe in `SkyLight/` — half of it isn't in any public Apple header
- The focus-restore guard — catches Chrome's internal activation paths
- `_AXObserverAddNotificationAndCheckRemote` plumbing — keeps Electron AX trees alive when occluded
- The `(pid, window_id)` AX state cache — element indices are cache-keyed; dropping invalidates clicks
- The AppKit run-loop attachment — capture and event paths require a real run loop

**Tool surface (mirrors cua's `ToolRegistry`):**

`list_apps`, `list_windows`, `launch_app`, `get_window_state`, `click` (element_index AX action / pixel-coord CGEvent), `type_text` (AX `kAXSelectedText` write), `type_text_chars` (raw CGEvent chars), `press_key` (bare or with element_index pre-focus), `page` (browser JS / DOM via Apple Events / CDP / WKWebView), `right_click`, `double_click`, `drag`, `scroll`, `hotkey`, `move_cursor`, `zoom`, `get_cursor_position`, `get_screen_size`, `get_accessibility_tree`, `screenshot`, `check_permissions`, `set_recording`, `get_recording_state`, `replay_trajectory`, `get_agent_cursor_state`, `set_agent_cursor_enabled`, `set_agent_cursor_motion`, `get_config`, `set_config`.

For each tool's description, parameters, and edge cases: read the matching `cua-driver/Sources/CuaDriverServer/Tools/<Name>Tool.swift`. Cacty's `ToolSchema.swift` mirrors those descriptions; Cacty's `Engine.*` methods mirror the invoke bodies; `Worker.swift` dispatches by the same tool name.

**Always prefer `click` with `element_index` over `click` with `x`/`y` pixels.** Pixel clicks are the fallback for canvas, WebGL, and non-AX surfaces only.

**Forbidden hotkeys** (denied at supervisor layer, not just in the model prompt):
- `⌘L` (omnibox focus → triggers app activation)
- `⌘Tab` (app switcher)
- `⌘\`` (window cycle)

If you need to add a new automation primitive, it must:
1. Document which low-level path it uses
2. Declare `foreground_safe: Bool` in its `ActionResult`
3. Have a corresponding entry in the background invariant test suite

## Working in `Agent/` (Swift)

The Agent module runs Gemini 3 Pro and orchestrates tool calls. It owns:
- The Gemini conversation per task (`URLSession` HTTP client, no third-party SDK)
- Memory context retrieval (direct calls into `App/Memory/`)
- Trajectory writing
- The `ask_user` clarification mechanism (a Gemini tool)

It does **not** own:
- Any direct system access. The agent cannot click, type, or capture screens —
  those calls always go through `Automation/`.
- Approval decisions. Those go through `App/Supervisor/SensitivityEngine`.
- Memory writes. The agent proposes; the supervisor writes.

When adding a new Gemini tool, update `Agent/ToolSchema.swift` *and* the
corresponding handler in `App/Supervisor/`. Worker actors run inside a warm
pool — fixed size at startup (default 4), reused across tasks. Each worker
holds one in-flight Gemini conversation; finished workers are reset and
returned to the pool.

Tool descriptions in `Agent/ToolSchema.swift` are the model's reality model.
Be precise:
- State whether the tool is background-safe
- State preference order vs. similar tools (`click` with element_index over `click` with x/y pixels)
- Document forbidden inputs (denylisted hotkeys)
- Use cua's parameter semantics verbatim (`pid`, `window_id`, `element_index`)

## Working in `App/` (Swift)

### `Supervisor/`
The `AgentSupervisor` actor is the heart of the app. Every tool call from a worker flows through it. New approval rules, window-locking logic, and conflict detection live here.

### `UI/`
Four UI surfaces, all need `NSPanel` configured for floating + all-Spaces + non-activating:

```swift
panel.styleMask = [.nonactivatingPanel, .borderless]
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
panel.level = .statusBar
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
```

If a UI surface activates the app or steals focus when shown, **that is itself a background-guarantee violation**. The product's own UI must obey the same rules as the agent.

- `TaskDots/` — top-right floating dots, hover for live video popover
- `ApprovalBar/` — bottom-center, Claude-Code-style approve/deny
- `ClarificationPanel/` — multi-choice + free-response, ≥2 options or skip options
- `Console/` — full task list, memory inspector, trajectory replay

### `PTT/` and Fn-key handling
The Fn key is captured via `CGEventTap` on `.flagsChanged`. Apple reserves Fn for system dictation by default — onboarding must guide the user to disable it in System Settings → Keyboard. Fn is the **only** trigger; there is no fallback hotkey.

**Fn always means "start a new task PTT,"** regardless of what overlays are
on screen. Approvals and clarifications respond only to mouse clicks and
Enter — never to Fn or voice. This keeps the state machine trivial: one
input route per UI surface, no ambiguity.

Speech-to-text uses `SpeechAnalyzer` (macOS 26+). On-device only.

### `Memory/`
SQLite via GRDB.swift. Embeddings via Apple's `NLContextualEmbedding`
(NaturalLanguage framework, built-in, no bundled model weight). Three
tables: `preferences`, `routines`, `episodes`, plus `clarification_history`
for the 2nd-repeat promotion rule.

Memory promotion rules:
- Explicit "remember that..." → confidence 0.95
- Same clarification answered same way 2nd time → confidence 0.7
- Correction → write negative + positive examples

Never auto-promote on first occurrence. Asking once is curiosity; asking the same thing twice is annoying.

## Be truthful about what you've completed

This rule is the result of a real pattern: in the conversation that built this engine, the agent claimed "Phase 0 complete" three separate times before it actually was. Each time the claim was technically defensible (code shipped, tests passed for what was tested) and substantively wrong (multiple spec deliverables untouched, risks unverified). The rule below exists so that pattern doesn't repeat.

### "Done" means observed outcome, not shipped code

There is a hierarchy of completion claims and they are NOT interchangeable:

1. **Code written** — exists in a working tree.
2. **Code merged** — exists on `dev` / `main`.
3. **Code run** — at least one execution has been observed.
4. **Outcome verified** — the thing the code was supposed to prove has been observably proven.

When the user asks "is X complete," answer at level 4. If the answer at level 4 is no, say so explicitly — don't slide back to level 1 or 2 and pretend it's the same thing.

### Spec deliverables: every one, or none

When closing out a phase, gate, or milestone, audit against **every line item in the spec**, not the ones you happen to remember. If there are four deliverables and you've done three, the answer is "three of four; here's what's missing," not "complete." This is true even if the missing item feels minor or you have a plausible reason to defer it. Spec deviations get **named and justified**, never quietly elided.

If a target was missed (e.g. "<50ms latency" measured at 100ms), say "missed by 2x, here's why, here's the path to actually hit it" — don't relax the test threshold and then claim completion.

### Distinguish code from validation

For risks named in the spec ("does Fn-key capture work on this Mac?"), shipping the spike code is not the same as killing the risk. The risk is killed when someone runs the spike and observes the expected behavior. Until then, the risk is "implemented but unverified" — and you say exactly that.

This matters because the failure modes you're trying to discover (Fn key reserved by macOS, model hallucinates, capture exceeds latency budget) only surface at runtime. The whole point of a spike is the run.

### When you've over-claimed, acknowledge it specifically

If the user catches you over-claiming, do not respond with hedged repackaging of the same claim. The right response is:

- Name what was over-claimed
- State what's actually true
- State what's missing
- Propose a concrete next step

"You're right, I overstated. Phase 0 is missing X and Y. I can do X next, then we re-evaluate." That's the shape. Not "well, the agent layer is substantially complete."

### Tracking unverified items

When a deliverable is implemented but unverified, log it explicitly in the conversation **and in the PR description**, not buried in commit text. The user shouldn't have to read your commits to know what's still pending.

When you write a PR description that closes out a phase or milestone, include a "still unverified" or "pending user-side run" section if anything fits there. If nothing fits there and you're claiming completion, double-check that's true.

### Why this rule exists at this length

The temptation to over-claim is built into how this work feels: each PR ships something real, the tests pass, the code is correct, and saying "done" is satisfying. But "done" is a claim about the world, not about the diff. Phase 0 risks are about "does this work in production?" The diff alone never answers that.

When in doubt, under-claim and let the user push you to claim more.

## Coding conventions

### Swift
- Swift 6.0+, async/await throughout
- Targets macOS 26+ (no back-deployment). Use new framework APIs freely (`SpeechAnalyzer`, `NLContextualEmbedding`).
- Actors for shared mutable state (`AgentSupervisor`, `MemoryStore`, worker actors)
- `Sendable` conformance on all types crossing actor boundaries
- No `@MainActor` on automation code paths — they run on dedicated queues with explicit run loops
- Errors via typed `throws`, not `Result`
- No third-party SDK for Gemini — `URLSession` + `Codable` request/response types

### Agent boundary types
Worker actors talk to the supervisor and to `Automation/` via Swift types
(no JSON-RPC, no Python). Breaking changes to those types still require
care:
1. Update both producer and consumer in the same PR
2. Add migration handling for any persisted trajectory format change
3. Note the schema version in the PR description

## Code quality

This is a consumer product targeting paying users. Code quality is not aesthetic — it's product quality. The bar:

### Naming
- Names describe **what**, not **how**. `pendingApprovalQueue`, not `approvalArray`.
- No abbreviations except universally understood ones (`pid`, `id`, `url`, `ax`).
- Booleans read as predicates: `isStreamingFrames`, `requiresApproval`, `hasPendingClarification`.
- Functions describe their effect: `cancelTaskAndDrainInput()`, not `handleTask()`.
- Match the domain: this codebase says `worker`, `task`, `agent`, `dot`, `supervisor`. Don't introduce synonyms.

### Functions
- One thing per function. If you can't describe what it does in one sentence, split it.
- Maximum ~50 lines. Longer functions need a strong reason.
- Maximum 4 parameters. More than that → take a struct.
- Pure where possible. Side effects belong at the boundary (Supervisor, IPC, UI), not deep in helpers.

### Error handling
- Typed `throws` everywhere. Never `throws` without a typed error.
- Errors are descriptive: include the pid, window_id, task_id, action, and what was attempted.
- Failures in `Automation/` always return structured `ActionResult` with `success: false` and a reason — never throw silently up the stack and lose context.
- User-facing errors (Console window, approval bar) are written for humans, not stack traces.

### Concurrency
- Actors for shared mutable state. No `DispatchQueue.async` for state ownership.
- One worker actor per task, drawn from a fixed-size warm pool.
- Cancellation is cooperative and explicit — `CancellationError` propagates up, no zombies.
- Long-running operations check for cancellation between steps.

### Magic numbers and strings
- Constants live in a config file or named `static let` at the top of the relevant module.
- Tuneables (timeouts, fps, retry counts) go in `App/Config/Tuning.swift` so they can be adjusted without code archaeology.
- No `5`, `60`, `"com.apple.mail"` scattered through method bodies.

### Avoid premature abstraction
- Two callers ≠ extract a helper. Three is the threshold.
- Don't add protocols, generics, or layers "in case we need them later." We probably won't.
- The codebase is small enough that "find usages" is fast — keep things concrete.

## Testing

This product runs untrusted-ish AI output against the user's machine. Tests are not optional.

### What must be tested

**Always:**
- Every `Automation/` primitive (correctness + background invariants)
- Every Gemini boundary type (`Codable` round-trip; HTTP request/response shapes)
- Every sensitivity rule (does it correctly trigger approval for the right cases?)
- Every memory promotion rule (explicit, 2nd-repeat, correction)
- Fn-key handling (start-task path is the only path; no overlay-dependent transitions)

**Frequently:**
- The full agent loop with a mocked `GeminiClient` (deterministic trajectory replay)
- Approval bar queueing under load (multiple concurrent approvals)
- Window-lock conflict detection
- Worker-actor failure isolation (a worker error does not take down peers or the supervisor)

**End-to-end (slower, run on PR):**
- Background invariant suite (cursor, frontmost, Space, no leaked keystrokes)
- A small set of canonical tasks ("create a calendar event," "draft an email") that must continue to work

### Test conventions

- Tests live next to the code in their target's `Tests/` directory: `Foo.swift` → `FooTests.swift`.
- One assertion concept per test. A test named `test_clickElement_returnsErrorWhenWindowMissing` should test exactly that.
- Test names describe the scenario: `test_<unit>_<condition>_<expectedOutcome>`.
- Fixtures and mocks in `Tests/Support/`, never inline duplicated across files.
- No sleeping in tests. Use proper async waits with timeouts.
- Tests must be deterministic. Flaky tests get fixed or deleted, not retried.

### When you change code

- **Modifying behavior** → update or add tests in the same PR. No "tests in a follow-up."
- **Fixing a bug** → add a regression test that fails before your fix and passes after. Otherwise the bug comes back.
- **Refactoring** → existing tests must still pass without modification. If you're changing tests, you're changing behavior.
- **Adding an `Automation/` primitive** → background invariant test is required, no exceptions.

### What not to test

- SwiftUI rendering (visual review handles this).
- Apple framework behavior (don't test that `NSWorkspace.frontmostApplication` returns an app — test your code's reaction to it).
- Mocking that just verifies the mock was called with the right args without testing real behavior.

### Background invariant tests (the most important suite)

Tests in `Tests/BackgroundInvariantTests/` assert that running an agent task does not perturb the user's environment:
- Cursor position unchanged before/after a task (`CGEventGetUnflippedLocation`)
- Frontmost app unchanged (`NSWorkspace.shared.frontmostApplication`)
- Active Space unchanged
- TextEdit-typing-during-task content matches expected (no leaked keystrokes)

These run on every PR. A failure blocks merge. Adding any new `Automation/` primitive requires a corresponding entry in this suite.

### Gemini boundary tests

Every Gemini request/response type round-trips through `Codable` in
`Tests/AgentBoundaryTests/`, and the HTTP transport is exercised against a
recorded-fixture mock. The wire format is the contract with the model
provider; if you can't decode a real response, you can't ship the change.

## Comments and inline documentation

Comments are for **why**, not what. The code says what; comments say why it's that way when the why isn't obvious from the code.

### When to comment

- **Non-obvious decisions:** "Using `SLEventPostToPid` instead of `CGEventPost` because the latter would route through the global HID stream and steal focus." Future maintainers will not figure this out from code alone.
- **Apple framework gotchas:** "ScreenCaptureKit's default `SCStreamConfiguration` causes window activation on macOS 14.0–14.2; explicit `excludesCurrentProcessAudio = true` and window-list filtering avoids it."
- **Wire-format coupling:** "This struct's JSON encoding is consumed by Gemini's function-calling pipeline. Keep field order stable; renames need a fixture update."
- **Workarounds:** "Retry once on first call — Electron AX trees populate lazily. See plan.md § Appendix."
- **Invariants:** "Caller must hold the window lock for `(pid, windowId)` before calling this. Asserted at runtime."

### When not to comment

- Restating code: `// increment counter` above `counter += 1`. Delete.
- Stale comments: if the code changed and the comment didn't, delete the comment.
- "TODO" without a ticket reference and an owner. Either fix it now, file an issue, or remove it.
- Header comments listing the file's contents. The code lists the file's contents.

### Doc comments on public APIs

Every public method on `Automation.Engine` (in `Sources/Automation/PublicAPI.swift`) and every public actor method in `App/Supervisor/` gets a doc comment with:

```swift
/// One-sentence summary of what it does.
///
/// Longer description if needed, including which low-level path is used and
/// any background-safety notes. This is required for `Automation/` methods.
///
/// - Parameter pid: Target process ID.
/// - Parameter windowId: Target window ID from `listWindows`.
/// - Returns: `ActionResult` with `foreground_safe` set based on path used.
/// - Throws: `AutomationError.windowNotFound` if the window has been closed.
public func clickElement(pid: Int32, windowId: Int, elementIndex: Int) async throws -> ActionResult
```

Internal helpers don't need this. Public API does.

### Tool-schema descriptions

Gemini's tool schema descriptions in `Agent/ToolSchema.swift` are a special case — they're "comments" the model reads. Be precise:
- State whether the tool is background-safe in plain language
- State the preference order vs. similar tools
- Document forbidden inputs (denylisted hotkeys)
- Use cua's parameter semantics verbatim

Bad descriptions = bad agent. This file is load-bearing for product quality.

## Documentation

Three docs at the repo root, each with a clear purpose:

- **`plan.md`** — the product spec. What is being built, why, and the phased plan. Updated when the product direction changes.
- **`CLAUDE.md`** — this file. Working conventions for coding agents. Updated when conventions change.
- **`THIRD_PARTY_LICENSES.md`** — MIT attribution for cua-derived code. Updated only when third-party code is added or removed.

### Module-level READMEs

Each top-level directory (`App/`, `Automation/`, `Agent/`) has a `README.md` describing:
- What lives in this directory
- The public API surface (classes, functions, agent boundary types)
- Any constraints specific to this module (e.g. `Automation/README.md` enumerates the kept-vs-cut decisions and the background-safety paths)

### When you change the product

- Behavior change visible to the user → update `plan.md`
- New convention, dependency rule, or constraint → update `CLAUDE.md`
- Module structure change → update that module's `README.md`
- Breaking change to a Gemini boundary type → update the matching `Codable` types and the recorded-fixture tests

Docs that drift are worse than no docs. If you're not going to maintain a doc, delete it.

### Architecture decision records (ADRs)

For significant decisions ("why Gemini 3 Pro and not Sonnet 4.6," "why a warm pool of in-process actors rather than per-task processes"), write a short ADR in `docs/adr/NNN-title.md`. Format: Context, Decision, Consequences. Two paragraphs each is plenty. The point is future-you remembering why.

## What NOT to do

- Don't add new dependencies for Gemini access. `URLSession` + `Codable` is the contract; no Google SDKs, no third-party HTTP clients.
- Don't introduce new dependencies into `Automation/`. It should compile against macOS frameworks only.
- Don't modify `Automation/SkyLight/` without testing on the actual fallback paths (canvas apps, Chromium content). The recipe is fragile.
- Don't add new hotkeys to the denylist by silently editing — these are part of the safety contract.
- Don't add a tool to `Agent/ToolSchema.swift` without a matching supervisor handler and an updated description. The model's understanding of the tools must reflect reality.
- Don't add Fn-key behavior to approval or clarification surfaces. Fn always means "start a new task" — approvals/clarifications are mouse + Enter only.
- Don't write to memory without going through the promotion rules. Bypassing them fills the DB with noise.
- Don't `@MainActor`-ify `Automation/` code. It needs its own run loop on dedicated queues.
- Don't use `ScreenCaptureKit` defaults that imply window activation. Always use the explicit-window-ID path.
- Don't create UI panels without the floating + all-Spaces + non-activating configuration. Anything else breaks the product's own background guarantee.

## Key files to know

| File | Purpose |
|---|---|
| `plan.md` | Full product spec — start here |
| `THIRD_PARTY_LICENSES.md` | Attribution for any vendored third-party code |
| `docs/agent-skills/driving-mac-apps.md` | No-foreground contract + tool preference rules + forbidden hotkeys — load-bearing source for the Gemini system prompt |
| `docs/agent-skills/web-app-quirks.md` | Browser / Electron / WebView quirks the agent needs to handle |
| `docs/agent-skills/trajectory-format.md` | On-disk turn-folder format produced by `Sources/Automation/Recording/` |
| `App/Supervisor/AgentSupervisor.swift` | Core orchestration actor |
| `App/Supervisor/SensitivityEngine.swift` | What requires approval |
| `App/PTT/FnKeyHandler.swift` | Fn-key tap (start-task only) |
| `Sources/Automation/PublicAPI.swift` | The `Automation.Engine` actor — supervisor-facing API for agent actions |
| `Agent/WorkerPool.swift` | Warm pool of worker actors |
| `Agent/Worker.swift` | Single-task Gemini loop |
| `Agent/GeminiClient.swift` | URLSession HTTP client for Gemini |
| `Agent/ToolSchema.swift` | Gemini function declarations (descriptions sourced from `docs/agent-skills/`) |

## When you're stuck

- Ambiguity about backgrounding → ask, don't guess. Wrong choice here ships a broken product.
- Cua-engine code looks like ceremony → it almost certainly isn't. Ask before deleting.
- Adding a new model capability → update tool schema, supervisor handler, agent boundary types, and tests *together* in one PR.
- Onboarding/permissions issue → check that the user has granted Microphone, Speech Recognition, Accessibility, Screen Recording, and Input Monitoring. All five are required.

## Build and run

See `Scripts/build.sh` for the full Developer ID signing + notarization
pipeline. The app ships **outside the Mac App Store** — Developer ID signed
and notarized, no MAS sandbox, full system access via the granted
permissions above.

For local dev:

```bash
swift build                                          # engine + agent compile
swift test                                           # unit tests
xcodebuild -scheme Cacty -configuration Debug        # full app
open build/Debug/Cacty.app
```

No Python runtime, no `uv sync`, no embedded interpreter. One language, one toolchain.
