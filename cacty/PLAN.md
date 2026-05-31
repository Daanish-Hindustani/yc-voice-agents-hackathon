# Voice-Driven Multi-Agent Mac Computer-Use App — Build Plan

> **Note — 2026-05-14.** The tool surface in this document predates the
> cua-mirror revert. Tool names below (`click_element`, `click_pixel`,
> `set_element_value`) have been renamed to their cua equivalents
> (`click`, `type_text`). The product / phases / architecture are
> still correct; only the tool-name listings are out of date. See
> `CLAUDE.md` § "Tool surface" for the authoritative list, and
> `cua-driver/Sources/CuaDriverServer/Tools/*.swift` for per-tool
> reference.

## Overview

A native Mac menu-bar app that lets users hold the **Fn key**, speak a task, and release — at which point a background AI agent takes over and completes the task on their Mac while they keep working. Multiple agents run in parallel, each operating real Mac apps invisibly. The user is never interrupted unless the agent needs explicit approval for something risky or needs clarification to proceed.

### The user experience

1. User holds **Fn**, says "draft a reply to the email mom just sent," releases.
2. The transcript is generated locally (on-device) and sent to Gemini 3 Pro along with the available automation tools.
3. Gemini iterates: read the screen → decide → call a tool → observe the result → repeat.
4. A small dot appears in the top-right corner of the screen indicating the task is running). Hovering shows a live video stream of what the agent is doing inside the target app.
5. If the agent hits something risky (sending an external email, deleting a file, making a purchase), an **approval box** appears at the bottom-center of the screen — Claude-Code-style approve/deny.
6. If the agent needs information ("which Sarah did you mean?"), a **clarification panel** appears with 2–4 concrete options plus a free-response field.
7. The agent finishes silently; the dot turns green briefly and disappears. No TTS, no notifications shouting at the user.
8. Each subsequent press of Fn spawns a **new agent in parallel** — the user can run many tasks at once.

### The hard constraint

**Every action the agent takes happens entirely in the background.** The user's mouse cursor, frontmost app, active Space, window z-order, and keyboard focus are never touched by the agent. If a task cannot be completed without violating this, the agent escalates to the user rather than breaking the constraint. This is the entire reason the product is viable — without it, a multi-agent system fighting the user for the cursor is worse than no agent at all.

### Build approach

The automation engine is built on code copied from `trycua/cua` (MIT-licensed) into the repo. The MCP server, generic CLI surface, daemon scaffolding, external-client integrations (Claude Code, Cursor), auto-updater, and `check_permissions` subcommand should be removed — they existed to expose cua-driver to external processes, which this app doesn't need. What's should be kept is the **engine**: AX-based element clicks, SkyLight pixel-click fallback, scoped keyboard input, per-window screen capture, AX tree caching, and trajectory recording. These are called as in-process Swift APIs from the app's `AgentSupervisor` with no transport layer in between. MIT attribution lives in `THIRD_PARTY_LICENSES.md`.

### Stack summary

| Layer | Choice |
|---|---|
| App shell | Swift 6 / SwiftUI, menu-bar app, Developer ID signed + notarized (not Mac App Store) |
| Deployment target | macOS 26+ |
| Voice input | `SpeechAnalyzer` (NaturalLanguage / Speech, macOS 26+), on-device |
| Trigger | Fn-key push-to-talk via `CGEventTap` on `.flagsChanged` (the only trigger; no fallback) |
| Automation engine | Vendored + cleaned cua-driver Swift code (`Automation/` module) |
| Agent runtime | In-process Swift actors (warm pool, default 4) |
| Model | Gemini 3 Pro via `URLSession` + `Codable` (no third-party SDK) |
| Live screen stream | Per-window capture → in-process `AsyncStream<NSImage>` → SwiftUI view |
| Memory | SQLite (GRDB.swift) + Apple `NLContextualEmbedding` (no bundled model weight) |
| Trajectories | JSONL files indexed in SQLite |
| Auto-update | Sparkle 2 with EdDSA |

---

## Plan

### Architecture

```
┌──────────────────────────────── Cacty.app (Swift) ───────────────────────────┐
│                                                                              │
│  Menu bar     Fn PTT      Top-right task dots        Approval bar            │
│      │           │              │  ▲                       ▲                 │
│      │           │              │  │ live stream           │                 │
│      ▼           ▼              ▼  │                       │                 │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │ AgentSupervisor (actor)                                              │    │
│  │   • Speech → transcript (SpeechAnalyzer)                             │    │
│  │   • Hands tasks to a warm pool of Worker actors (default 4)          │    │
│  │   • Routes approvals, clarifications, cancels                        │    │
│  │   • Memory store (SQLite + NLContextualEmbedding)                    │    │
│  │   • Automation/ module (vendored cua engine)                         │    │
│  │     ├ AX + SkyLight automation                                       │    │
│  │     └ Per-window capture stream                                      │    │
│  └──────────────────────────────────────────┬───────────────────────────┘    │
│                                              │ direct async calls            │
│                                              ▼                               │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │ Agent/ (in-process)                                                  │    │
│  │  Worker #1 ─┐                                                        │    │
│  │  Worker #2 ─┼─► GeminiClient (URLSession) ─► Gemini 3 Pro            │    │
│  │  Worker #N ─┘   + memory context injection                           │    │
│  │                                                                      │    │
│  │  Each worker: 1 task, 1 Gemini conversation, 1 trajectory log,       │    │
│  │               emits status frames consumed by the top-right dots     │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
```

A single Swift process owns everything: AX, screen capture, event posting,
memory, the Gemini conversation. The supervisor hands a transcript to a worker
actor, the worker drives Gemini and translates each tool call into a direct
async call against `Automation/`. No IPC, no sidecar, no embedded runtime.
Worker actors are isolated by error containment, not by process — a thrown
error inside one worker is caught by the supervisor and never reaches the
others.

### What's kept from cua, what's cut, what's added

**Kept (the engine):**
- Element-indexed click via `AXUIElementPerformAction` (the no-focus-steal path — primary)
- Pixel-click via `SLEventPostToPid` (canvas/WebGL fallback)
- `CGEvent.postToPid`-scoped keyboard input
- `get_window_state` with `som`/`ax`/`vision` capture modes
- `list_apps`, `launch_app`, `list_windows`
- Per-window screen capture (extended for live streaming)
- AX tree caching keyed on `(pid, window_id)`
- Focus-restore guard (catches Chrome's internal activation paths)
- Trajectory recording

**Cut:**
- MCP server module
- Generic CLI surface (`cua-driver click '{...}'`)
- Daemon-mode `serve` command
- LaunchServices integration for `/Applications/CuaDriver.app`
- Auto-updater targeting CuaDriver.app (Sparkle handles this for our app)
- Claude Code skill files, MCP config templates
- `check_permissions` subcommand (replaced with onboarding API calls)
- Sandbox / Lume / multi-OS abstractions

**Added:**
- Voice capture + on-device STT
- Agent loop module (in-process Swift `GeminiClient` + `Worker` actors)
- Multi-agent supervisor + worker pool
- SwiftUI: floating task dots, live video popovers, approval bar, clarification panel, console, memory inspector
- Memory subsystem (preferences, routines, episodes)
- Sensitivity / approval rule engine

### The end-to-end flow

1. User holds **Fn**. A small box with a sound wave appears next to the menu bar icon.
2. `SpeechAnalyzer` transcribes streaming, on-device (macOS 26+).
3. User releases Fn. Final transcript captured.
4. Supervisor **claims a worker actor from the warm pool** (no process spawn). The pool is sized at startup (default 4); if all workers are busy, the supervisor waits and surfaces a "queued" indicator on the new dot.
5. Worker:
   - Retrieves relevant memory (preferences, routines, recent episodes) → injects into system prompt
   - First Gemini 3 Pro call: transcript + tool catalog + initial `get_window_state` of frontmost relevant app
   - A new floating dot appears in the top-right of the screen
6. Loop:
   - Gemini returns tool calls (click, type, get_window_state, launch_app, etc.)
   - Worker dispatches each tool call directly into `Automation/` via async function calls
   - `Automation/` executes and returns result + new AX state
   - **Before any action**: the sensitivity engine checks if approval is required. If yes → approval bar appears bottom-center, worker pauses
   - **If Gemini calls `ask_user`**: clarification panel appears near the dot, worker pauses
   - Each step appends to trajectory; live frame goes to dot's video stream
7. On completion: dot turns green for 3 seconds, then disappears. Final summary logged to console (no TTS).
8. Memory write proposals queue: any preference candidate (resolved clarifications, corrections, explicit "remember that...") gets stored.

### Background guarantee — how each action stays out of the user's way

| Action | Path | Why it stays in the background |
|---|---|---|
| Element click | `AXUIElementPerformAction` | Skips event synthesis entirely — no mouse event, no cursor move, no focus change. Works on hidden/occluded targets. **Primary path.** |
| Pixel click | `SLEventPostToPid` (auth-signed SkyLight recipe) | Routes a synthesized click to one pid via private SkyLight APIs. No global HID stream, no cursor movement, no window raise. |
| Keyboard input | `CGEvent.postToPid` scoped to target pid | Goes to the named process only. No frontmost-routed variant exists — keystrokes physically cannot leak. |
| `launch_app` | Hidden launch via LaunchServices | App starts backgrounded; doesn't activate or steal Space. |
| Screen capture | `CGWindowListCreateImage` / ScreenCaptureKit by window ID | Captures a specific window without activating it. Works occluded and off-Space. |
| `get_window_state` AX tree | AX API queries against pid | Pure read; never causes activation. |

The agent acts like a parallel input stream targeted at one pid at a time. The user's HID input (real mouse, real keyboard) is completely untouched and runs concurrently — this is the architectural property to preserve at all costs.

### Known background-violation cases (handle, don't pretend they don't exist)

- **Canvas / WebGL / game-engine apps** (Blender, Unity): event loops filter per-pid-routed events. Fallback requires brief frontmost activation → cursor warps. **Behavior:** detect by bundle id, surface a one-time per-session approval before acting.
- **Right-click on Chromium web content via pixel synthesis**: renderer-IPC filter coerces right-click to left. **Behavior:** use `right_click({pid, element_index})` on AX-addressable targets only; otherwise escalate.
- **HTML5 video click-to-play**: some sites reject synthetic clicks. **Behavior:** prefer keyboard (`k` for YouTube, space for generic). Tool schema describes this preference.
- **`⌘L` and other activation-implying hotkeys**: even when delivered to a backgrounded pid, the receiver interprets as activation. **Behavior:** maintain a denylist of hotkeys; refuse them at the supervisor layer; have the model `click` the address bar via AX instead.

### UI components

#### Top-right task dots

- Small (~14px) circular SwiftUI view in a borderless `NSPanel`
- Configured for all-Spaces, floating, non-activating:
  ```swift
  panel.styleMask = [.nonactivatingPanel, .borderless]
  panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
  panel.level = .statusBar
  panel.isFloatingPanel = true
  panel.hidesOnDeactivate = false
  ```
- Stacked horizontally near the top-right corner
- Color states: blue (running), amber (paused, awaiting approval/clarification), green (just completed), red (failed)
- Subtle pulse animation while running
- **Hover** → expands into a popover with a **live video stream** of the target window, current step text, and an "End task" button
- **Click** → opens the full Console window focused on that task
- "End task" cleanly cancels: drains pending input events scoped to the worker's pid, then SIGTERMs the worker

#### Live video stream

- Tap into the per-window capture path at the Swift core layer; downsample to ~640×400, encode as MJPEG at 4–6fps
- Frames go directly to a SwiftUI view via `AsyncStream<NSImage>` — fully in-process
- Only stream frames for currently-expanded/hovered dots — saves CPU
- Frame source = whatever `(pid, window_id)` the worker last interacted with

#### Approval bar (bottom-center)

- Pinned bottom-center, above Dock, ~520pt wide
- `NSPanel`, all-Spaces, floating, non-activating
- One bar at a time globally; multiple pending approvals queue with a "1 of 3" indicator
- Layout:
  ```
  ┌──────────────────────────────────────────────────────┐
  │ ⚠  Task #2 wants to send email                       │
  │    To: sarah.chen@acme.com                           │
  │    Subject: Q3 numbers                               │
  │                                                      │
  │    [ Approve (↵) ]  [ Deny (esc) ]  [ Why? ]         │
  └──────────────────────────────────────────────────────┘
  ```
- 60-second auto-deny + task pause if no response
- **Input is mouse + keyboard only.** Click a button or hit `↵` (Approve) / `Esc` (Deny). No Fn-voice approval — Fn is reserved for starting new tasks.
- "Why?" expands inline to show the full action JSON + Gemini's reasoning
- Worker is suspended until user responds

#### Clarification panel

- Appears near the relevant dot, non-modal, doesn't steal focus
- Claude-style: 2–4 concrete option buttons, last item is a free-response field
- Layout:
  ```
  ┌─ Task #2 needs info ────────────────────────┐
  │ Which Sarah did you mean?                    │
  │                                              │
  │  ① Sarah Chen — sarah.chen@acme.com         │
  │  ② Sarah Patel — sarah.p@acme.com           │
  │  ③ Sarah from yesterday's invite             │
  │                                              │
  │  ▸ Or type/say something else: [______]     │
  │                                              │
  │  [ Cancel task ]                             │
  └──────────────────────────────────────────────┘
  ```
- Number keys (1–4) select options without focus-stealing
- Free-response: keyboard text input + `↵`. No Fn dictation — Fn always means "start a new task."
- Implemented as a Gemini tool: `ask_user(question, options: [string])`. When the model calls this, the worker pauses and the panel appears.
- **Prompt rule:** the model must produce ≥2 distinct concrete options or skip options entirely (free-response only)

### Fn-key behavior

Fn has **one job**: start a new task PTT. Every press-and-hold begins
recording into a fresh worker; release ends recording and dispatches the
transcript. There are no overlay-dependent transitions, no voice commands
on top of approval bars, no Fn-dictated clarification answers.

| App state | Fn behavior |
|---|---|
| Anything | Start (or extend) a new-task PTT |
| Approval bar visible | Bar still responds to mouse/Enter/Esc; Fn ignores the bar and starts a new task |
| Clarification panel visible | Panel still responds to mouse/typed input; Fn ignores the panel and starts a new task |

Approvals and clarifications are mouse + keyboard only. This collapses the
old multi-state machine into a single rule, which is the entire point — Fn
ambiguity is rage-inducing, so we removed it.

### Memory system ("self-evolving")

The user-facing promise: *"I told the agent once, now it just knows."*

Three memory tiers, all local-first SQLite:

**1. Preferences** — durable facts the user has stated or implied
```
{ key: "email.signoff_style", value: "casual, lowercase 'thanks'",
  source: "stated 2025-11-04", confidence: 0.95, scope: "global" }
{ key: "contacts.mom", value: "mom@example.com",
  source: "clarification 2025-11-12", scope: "global" }
{ key: "calendar.default_meeting_length", value: "25min not 30",
  source: "inferred from 8 past events", scope: "global" }
```

**2. Routines** — "when user says X, they usually mean Y," derived from repeated tasks
```
{ trigger: "morning triage",
  decomposition: ["check Mail unread", "summarize Slack mentions", "list calendar today"],
  observed_count: 12, last_used: "..." }
```

**3. Episodes** — recent task summaries (last ~50 tasks), for "what did the agent do last Tuesday" recall and as context for similar tasks

#### Capture rules

- **Explicit**: planner detects "remember that..." / "from now on..." → preference write at confidence 0.95
- **Clarification 2nd-repeat**: same question asked twice with same answer → auto-promote to preference at 0.7 confidence
- **Correction**: "actually no, I meant..." → write negative + positive examples
- **Routine inference**: when 3+ similar episodes (same target_app + similar embedding) occur with similar decomposition, mint a routine

#### Retrieval (every task, before first model call)

1. Embed the user's transcript with `NLContextualEmbedding` (Apple's on-device sentence embedding, NaturalLanguage framework, no bundled model weight)
2. Top-K cosine search across episodes for similar past tasks
3. Pull preferences whose key namespace matches detected intent (transcript mentions "email" → pull all `email.*` preferences)
4. Check routine triggers via fuzzy match
5. Inject as `<user_context>` block in Gemini system prompt (~200–800 tokens typical)

#### Memory inspector UI

A "Memories" tab in Console showing every preference (value, source, confidence, last used, use count). Each row has Edit / Delete. Bulk: Export, Import, "Forget everything from this session," "Pause memory writes."

This is non-negotiable for trust. Concerned users immediately ask "what does it know about me" — the answer must be one click away.

### Sensitivity / approval rule engine

Approval bar fires on union of three sources:

```
Source 1 — Gemini's flag:
  any tool call with safety_decision == "require_confirmation"

Source 2 — Built-in rules:
  SENSITIVE_BUNDLE_IDS:
    com.apple.systempreferences, com.apple.keychain.access,
    com.apple.finder (for Trash/delete actions only),
    com.apple.Terminal, com.apple.MobileSMS
  SENSITIVE_DOMAINS:
    *.bank, paypal.com, venmo.com, *.gov, etc.
  SENSITIVE_ACTIONS:
    send_email_to_external_domain,
    file_delete_outside_downloads_or_trash,
    apple_pay_or_purchase_button_detected,
    password_field_detected_with_typing

Source 3 — User-defined rules:
  Allowlist / denylist editable in Settings
```

Default-deny on system-critical apps. Users opt apps in via Settings.

### Multi-agent rules

- **Worker isolation**: each task runs in its own actor drawn from a warm pool (default 4). Worker errors are caught at the supervisor and never bubble to peers; the worker is reset and returned to the pool. No process boundary, no IPC.
- **Window contention lock**: supervisor enforces a `(bundle_id, window_id)` lock per active task. A second task targeting the same window either waits or asks the user.
- **The user is also a "worker"**: if the user clicks into a window an agent is operating, detect via HID-tap signature differences and pause that agent. The user's input always wins.
- **The user's frontmost window is sacred**: no agent ever operates the currently-frontmost window. If the model wants to act on whatever is frontmost, it waits until the user focuses elsewhere or asks via clarification.

---

## Phases

### Phase 0 — Spike (1 week)

Goal: kill the riskiest unknowns before committing to the rest of the build.

**Tasks:**
- Get the vendored cua automation code building in isolation. Strip the MCP/CLI/daemon scaffolding. Confirm: drive Calendar in the background, no focus steal, screenshot a single window.
- Tap into the capture stream → in-process `AsyncStream<Screenshot>` → render in an `NSImageView`. **Empirical latency on stock ScreenCaptureKit is ~100ms per frame** (dominated by per-call `SCShareableContent.current` enumeration); the <50ms target requires an SCStream-based pipeline that amortizes window-list lookups across frames. Deferred to Phase 1 polish — the 5fps hover-popover use case tolerates 100ms. Regression net in tests is set to <200ms.
- ~150-line Swift `GeminiClient` (URLSession + Codable): hand-crafted tool schema mirroring the kept actions; run a 5-step Calendar task end-to-end with the supervisor calling `Automation/` directly.
- Throwaway Swift app: Fn-key tap + `SpeechAnalyzer` → print transcript.

**Real risks being de-risked:**
- Fn-key global capture (Apple reserves this for system dictation; user may need to disable it in System Settings)
- Gemini 3 Pro reliability on real Mac AX trees (computer-use was browser-tuned; this is the model unknown)
- Stripping cua code cleanly without breaking the AX paths (some logic is intertwined with the daemon scaffolding)
- `SpeechAnalyzer` quality on PTT-style short utterances (new framework on macOS 26; budget a day to verify)

**Gate:** if any of these resists for more than 2 days, stop and rethink before building Phase 1.

### Phase 1 — Vertical slice (2–3 weeks)

End-to-end single task, shippable internally.

**Deliverables:**
- Menu bar app with Fn PTT + transcript HUD
- Single worker, full Gemini loop, trajectory log on disk
- Top-right floating dot with hover → live video popover (one task at this stage)
- Approval bar at bottom-center (basic rules: external email, purchases)
- Clarification panel as a Gemini tool (`ask_user`)
- "End task" button works cleanly (drains pending input scoped to pid before SIGTERM)
- Console window with one task row showing live status

**Done means:** you can hold Fn, say "draft an email to a colleague about lunch tomorrow," release, and the agent does it without ever touching your foreground.

### Phase 2 — Multi-agent (2 weeks)

**Deliverables:**
- Spawn workers in parallel, one per Fn-press, no cap
- Multiple dots stack horizontally in top-right
- Conflict detection on `(bundle_id, window_id)` — warn or queue
- Approval queue when 2+ tasks need approval simultaneously (with "1 of N" indicator)
- Per-worker process isolation; one crash doesn't take down the others
- Console shows all tasks live with per-task status, kill button, and trajectory link

**Done means:** four tasks running in parallel, the user typing in TextEdit, no stray characters, no cursor warps.

### Phase 3 — Memory (2–3 weeks)

**Deliverables:**
- SQLite schema (preferences, routines, episodes, clarification_history) via GRDB
- `NLContextualEmbedding` wired up (built-in, no model bundling)
- Retrieval pipeline → injection into Gemini system prompt as `<user_context>` block
- Memory write proposals: explicit ("remember that..."), repeated-clarification (2nd-repeat rule), correction
- Memory inspector tab in Console — view, edit, delete, export, import
- Routine detection from repeated episode patterns (frequent-itemset over task type + target app)
- "Pause memory writes" toggle for sensitive sessions

**Done means:** the agent asks the same question once, then never again. User can audit and edit everything it knows.

### Phase 4 — Production hardening (3–4 weeks)

**Deliverables:**
- Permissions onboarding (Mic, Speech, Accessibility, Screen Recording) — beautiful, explanatory, verifying. This alone is 3–5 days done well.
- Sensitivity rule engine with editable allowlists/denylists in Settings
- Code signing (Developer ID), notarization, hardened runtime
- Hardened-runtime entitlements verified for AX, ScreenCaptureKit, and the SkyLight pixel-click recipe (no embedded interpreter to sign — pure Swift bundle)
- Sparkle 2 with EdDSA auto-update
- Telemetry (no cost cap or step budget in MVP — added later when usage data justifies tuning)
- Trajectory replay viewer
- Crash isolation, supervisor auto-restart
- Background invariant test suite (cursor unchanged, frontmost unchanged, Space unchanged) running on every PR

**Done means:** the app is signed, notarized, auto-updating, and has measurable proof the background guarantee holds.

### Phase 5 — Polish & differentiation (ongoing)

**Deliverables:**
- "Edit before approving" on the approval bar — modify subject/recipient inline
- (deliberately removed: voice answers to clarifications and approvals — Fn is reserved for new-task PTT; revisit only if user research justifies expanding Fn's scope)
- Saved/named routines the user can rename, edit, share
- Privacy mode: redact sensitive screenshots in trajectory storage (keep AX tree only)
- "What did the agent do last Tuesday?" episodic recall via the memory store
- Optional opt-in trajectory export for future model fine-tuning

---

## Implementation Guide

This section is for the engineer (or coding agent) actually building the product. It assumes Phase 0 has produced working spikes and Phase 1 is now being built for real.

### Repo layout

Single SwiftPM package at the repo root. Each module is one target.
  
```
Cacty/
├── Package.swift                     # SwiftPM root — one package, multiple targets
├── Sources/
│   ├── Automation/                   # Vendored + cleaned cua engine (target 1)
│   │   ├── AppState/                 # AX tree caching, get_window_state
│   │   ├── Apps/                     # list_apps, launch_app, list_windows
│   │   ├── Browser/                  # AX page reader, CDP client, Electron JS
│   │   ├── Capture/                  # Per-window capture (extended for streaming)
│   │   ├── Cursor/                   # Agent cursor overlay (visual only, optional)
│   │   ├── Focus/                    # Focus-restore guard, AX enablement
│   │   ├── Input/                    # AX clicks, SkyLight pixel clicks, keyboard
│   │   ├── Permissions/              # AX/Screen-Recording probes
│   │   ├── Recording/                # Trajectory recording + replay rendering
│   │   ├── Telemetry/                # Telemetry client
│   │   └── Windows/                  # Window enumeration, coordinate conversion
│   │
│   ├── Agent/                        # (added in Phase 1) In-process agent runtime
│   │   ├── WorkerPool.swift          # Warm pool of worker actors (default 4)
│   │   ├── Worker.swift              # One task, one Gemini conversation
│   │   ├── GeminiClient.swift        # URLSession + Codable; no third-party SDK
│   │   ├── ToolSchema.swift          # Gemini tool defs mirroring Automation
│   │   └── MemoryContext.swift       # Builds <user_context> from MemoryStore
│   │
│   └── App/                          # (added in Phase 1) SwiftUI app shell
│       ├── CactyApp.swift
│       ├── MenuBar/
│       ├── PTT/                      # Fn-key event tap, audio capture
│       ├── Speech/                   # SpeechAnalyzer wrapper
│       ├── Supervisor/               # AgentSupervisor actor
│       ├── UI/                       # TaskDots, ApprovalBar, ClarificationPanel, Console, Onboarding
│       └── Memory/                   # SQLite + NLContextualEmbedding
│
├── Tests/
│   ├── AutomationTests/
│   ├── AgentTests/                   # added with Sources/Agent
│   └── AppTests/                     # added with Sources/App
│
├── Scripts/
│   └── build.sh                      # codesign (Developer ID), notarize, package
│
├── docs/                             # ADRs and longer-form docs
├── plan.md                           # this file
├── CLAUDE.md
├── README.md
├── LICENSE
└── THIRD_PARTY_LICENSES.md           # attribution for vendored third-party code
```

PR 0.1 lands the `Sources/Automation/` target and its tests; `Sources/Agent/`
and `Sources/App/` are added in subsequent PRs as Phase 1 begins.

### Step-by-step build order

#### 1. Clean up the copied cua code (3–5 days)

Go through the copied automation code with this cut-list:

| Cut | Why |
|---|---|
| `cmd/cua-driver` or any `main.swift` for the CLI | App launches via the bundle, not a binary entry point |
| Argument parsing for CLI subcommands | Replace with direct Swift function calls |
| MCP server module + JSON-RPC over stdio | No external clients |
| Daemon-mode `serve` command | App is the lifecycle owner |
| LaunchServices integration for `/Applications/CuaDriver.app` | Not a separate app |
| Auto-updater | Sparkle handles it |
| `check_permissions` CLI subcommand | Replace with direct API calls in onboarding |
| Claude Code skill files, MCP config templates | Not the distribution channel |

**Do NOT cut:**
- The auth-signed SkyLight recipe for `SLEventPostToPid` — half isn't in any public Apple header
- Focus-restore guard logic (catches Chrome's internal activation)
- `_AXObserverAddNotificationAndCheckRemote` plumbing for Electron apps (Slack, Discord, VS Code)
- The AppKit run loop attached to the cua subsystem
- The `(pid, window_id)` AX state cache (element indices are cache-keyed; dropping it invalidates clicks)
- Trajectory recording

After cleanup, expose this as in-process Swift API surface:

```swift
// Sources/Automation/PublicAPI.swift
public actor Engine {
    // Identity
    public var version: String { get }

    // Read-only inventory (already shipped in PR 0.2)
    public func listApps() -> [AppInfo]
    public func listWindows(forPid pid: Int32) -> [WindowInfo]
    public func permissions() async -> PermissionsStatus

    // Action surface (lands in subsequent PRs as Phase 0 spikes finish)
    public func launchApp(bundleId: String, hidden: Bool = true) async throws -> AppInfo
    public func getWindowState(
        pid: Int32, windowId: Int,
        captureMode: CaptureMode  // .som, .ax, .vision
    ) async throws -> WindowState

    public func clickElement(
        pid: Int32, windowId: Int, elementIndex: Int
    ) async throws -> ActionResult

    public func clickPixel(
        pid: Int32, windowId: Int, x: Int, y: Int, button: MouseButton
    ) async throws -> ActionResult

    public func type(pid: Int32, text: String) async throws -> ActionResult
    public func pressKey(pid: Int32, key: String, modifiers: [Modifier]) async throws -> ActionResult
    public func scroll(pid: Int32, windowId: Int, dx: Int, dy: Int) async throws -> ActionResult

    public func captureStream(
        pid: Int32, windowId: Int, fps: Int
    ) -> AsyncStream<CapturedFrame>
}
```

Naming: the type is `Engine`, not `Automation`. The SwiftPM module is
`Automation`, and a `public actor Automation` inside it would shadow the
module name and force callers to write `Automation.Automation`. Module-
qualified, the public surface reads `Automation.Engine`.

Every method returns `ActionResult` containing `{ success, foreground_safe, side_effects, new_ax_state? }`. The supervisor uses `foreground_safe` to decide whether to escalate via approval.

#### 2. Define the agent boundary types (1–2 days)

Worker ↔ supervisor and worker ↔ Gemini boundaries are pure Swift. No
sockets, no JSON-RPC framing — just `Sendable` Swift types and async
function calls.

**Supervisor → Worker (struct messages on a `TaskInbox` actor):**
- `StartTask(taskId, transcript, frontmostAppHint, userContext)`
- `Cancel(taskId)`
- `ClarificationResponse(taskId, response)`
- `ApprovalResponse(taskId, decision, edits?)`

**Worker → Supervisor (callbacks via `SupervisorAPI` protocol):**
- `runTool(taskId, toolName, args) async throws -> ToolResult`
- `requestClarification(taskId, question, options) async -> ClarificationResponse`
- `requestApproval(taskId, summary, fullAction, reasoning) async -> ApprovalResponse`
- `progress(taskId, step, total, statusText)`
- `complete(taskId, summary, memoryProposals)`
- `failed(taskId, error)`
- `queryMemory(taskId, query) async -> MemoryContext`

**Worker → Gemini (HTTP, `Codable` request/response):**
- `GeminiClient.generate(model, contents, tools) async throws -> GeminiResponse`
- Wire format from Google's REST docs; recorded fixtures in `Agent/Tests/Fixtures/`.

Lock these types in Phase 1 v1.0; changes thereafter need a fixture update and a migration note in the PR description.

#### 3. Define the Gemini tool schema (1–2 days)

In `Agent/ToolSchema.swift`, mirror the `Automation` API as Gemini function declarations. Critical metadata in descriptions:

```swift
enum ToolSchema {
    static let all: [Tool] = [
        Tool(
            name: "click_element",
            description: """
                Preferred clicking method. Click an AX element by index. \
                Fully background-safe — does not move the cursor or change focus. \
                Always prefer this over click_pixel when an element_index is available.
                """,
            parameters: ...
        ),
        Tool(
            name: "click_pixel",
            description: """
                Fallback clicking method. Use only when element_index is unavailable \
                (canvas apps, WebGL, custom-rendered surfaces). \
                Background-safe except on canvas/WebGL apps where the cursor may briefly warp.
                """,
            parameters: ...
        ),
        Tool(
            name: "press_key",
            description: """
                Press a key in the target pid. Background-safe. \
                Prefer over click for media controls (k/space for play-pause). \
                FORBIDDEN combos: ⌘L, ⌘Tab, ⌘` — these trigger app activation.
                """,
            parameters: ...
        ),
        Tool(
            name: "ask_user",
            description: """
                Ask the user for clarification when ambiguous. Provide 2-4 distinct \
                concrete options. If you cannot produce ≥2 distinct concrete options, \
                pass options=[] and rely on free-response.
                """,
            parameters: ...
        ),
        // ... rest
    ]
}
```

The supervisor enforces the denylists at the Swift layer too — the model is not the last line of defense.

#### 4. Build the worker loop (2–3 days)

```swift
// Agent/Worker.swift (sketch)
actor Worker {
    private let gemini: GeminiClient
    private let supervisor: SupervisorAPI

    func runTask(
        _ taskId: TaskID,
        transcript: String,
        hint: String?,
        userContext: MemoryContext
    ) async {
        var history = buildInitialMessages(
            transcript: transcript, context: userContext, hint: hint
        )

        // No hard step cap in MVP (Q12: budgets deferred). Cancel via Cancel(taskId).
        while !Task.isCancelled {
            let response: GeminiResponse
            do {
                response = try await gemini.generate(
                    model: "gemini-3.1-pro-preview", contents: history, tools: ToolSchema.all
                )
            } catch {
                await supervisor.failed(taskId, error: error)
                return
            }

            if let text = response.text {
                await supervisor.progress(taskId, step: history.count, total: 0, statusText: text)
            }

            guard !response.toolCalls.isEmpty else {
                await supervisor.complete(
                    taskId, summary: response.text ?? "",
                    memoryProposals: extractProposals(from: history)
                )
                return
            }

            for call in response.toolCalls {
                if call.name == "ask_user" {
                    let answer = await supervisor.requestClarification(
                        taskId, question: call.question, options: call.options
                    )
                    history.append(.toolResult(call, .clarification(answer)))
                    continue
                }

                // Approval and window-lock checks happen inside runTool.
                let result = await supervisor.runTool(taskId, toolName: call.name, args: call.args)
                history.append(.toolResult(call, result))

                if result.denied {
                    history.append(.system("User denied this action. Try a different approach or finish."))
                }
            }
        }
    }
}
```

#### 5. Swift AgentSupervisor (3–4 days)

```swift
actor AgentSupervisor {
    private var workers: [TaskID: WorkerHandle] = [:]
    private var windowLocks: [WindowKey: TaskID] = [:]
    private let automation: Automation.Engine
    private let memory: MemoryStore
    private let sensitivity: SensitivityEngine
    private let ui: UICoordinator

    func startTask(transcript: String) async {
        let taskId = TaskID()
        let context = await memory.retrieve(for: transcript)
        let hint = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let worker = spawnWorker(taskId: taskId)
        workers[taskId] = worker
        await ui.showDot(for: taskId)

        await ipc.send(.startTask(taskId, transcript, hint, context), to: worker)
    }

    func handleToolCall(_ call: ToolCall, from taskId: TaskID) async -> ToolResult {
        // 1. Sensitivity check
        let sensitivityVerdict = sensitivity.evaluate(call)
        if sensitivityVerdict.requiresApproval {
            let decision = await ui.requestApproval(
                taskId: taskId, summary: sensitivityVerdict.summary,
                fullAction: call, reasoning: call.reasoning
            )
            if decision == .deny { return .denied }
            if let edits = decision.edits { call.applyEdits(edits) }
        }

        // 2. Window lock
        if let key = call.windowKey {
            if let owner = windowLocks[key], owner != taskId {
                return .conflict(otherTaskId: owner)
            }
            windowLocks[key] = taskId
        }

        // 3. Execute via Automation
        let result = try await automation.execute(call)

        // 4. Stream frame to dot if hovered
        if ui.isDotExpanded(taskId), let key = call.windowKey {
            ui.attachStream(taskId, automation.captureStream(pid: key.pid, windowId: key.windowId, fps: 5))
        }

        return result
    }

    func endTask(_ taskId: TaskID) async {
        guard let worker = workers[taskId] else { return }
        await automation.drainPendingInput(forPid: worker.lastPid)
        worker.terminate()
        windowLocks = windowLocks.filter { $0.value != taskId }
        workers.removeValue(forKey: taskId)
        await ui.dismissDot(for: taskId)
    }
}
```

#### 6. Top-right dots with live video (2–3 days)

```swift
final class TaskDotPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.level = .statusBar
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
    }
}

struct TaskDotView: View {
    @ObservedObject var task: TaskState
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(task.color)
            .frame(width: 14, height: 14)
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering) {
                TaskPopoverView(task: task)
            }
    }
}

struct TaskPopoverView: View {
    @ObservedObject var task: TaskState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.transcript).font(.headline)
            LiveStreamView(stream: task.captureStream)
                .frame(width: 320, height: 200)
            Text("Step \(task.currentStep)/\(task.maxSteps): \(task.statusText)")
                .font(.caption)
            HStack {
                Button("View details") { task.openInConsole() }
                Spacer()
                Button("End task") { task.cancel() }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}
```

#### 7. Approval bar (2 days)

Same `NSPanel` configuration as dots. One bar globally; queue when multiple. Auto-deny after 60s. Mouse + keyboard only — `↵` approves, `Esc` denies. **Fn does not interact with the bar; it always starts a new task.**

#### 8. Clarification panel (1–2 days)

`ask_user` is a Gemini tool. When called, the worker pauses and the panel renders near the relevant dot. Number keys 1–4 select options. Free-response via keyboard text input + `↵` only — **no Fn dictation**, since Fn always means "start a new task."

#### 9. Memory subsystem (5–7 days)

GRDB schema:

```sql
CREATE TABLE preferences(
    id INTEGER PRIMARY KEY, key TEXT NOT NULL, value TEXT NOT NULL,
    source TEXT, confidence REAL, scope TEXT,
    created_at INTEGER, last_used_at INTEGER, use_count INTEGER DEFAULT 0
);
CREATE TABLE routines(
    id INTEGER PRIMARY KEY, trigger_pattern TEXT, decomposition_json TEXT,
    observed_count INTEGER, last_used_at INTEGER
);
CREATE TABLE episodes(
    id INTEGER PRIMARY KEY, task_text TEXT, target_app TEXT, outcome TEXT,
    trajectory_path TEXT, created_at INTEGER, embedding BLOB
);
CREATE TABLE clarification_history(
    id INTEGER PRIMARY KEY, question_signature TEXT, answer TEXT,
    count INTEGER, last_seen_at INTEGER
);
```

Embeddings via Apple's `NLContextualEmbedding` (NaturalLanguage framework on
macOS 26+). Built-in, no bundled model weight, no separate download. Retrieval:
cosine top-K episodes + namespace-matched preferences + fuzzy-matched routines.

Promotion rules:
- Explicit "remember that..." → confidence 0.95, immediate write
- Same clarification answered same way 2nd time → confidence 0.7, auto-promote
- Correction → write negative + positive examples

Memory inspector: a SwiftUI table view with edit/delete on every row, and Export/Import/Pause/Forget-session buttons.

#### 10. Permissions onboarding (3–5 days)

Order matters — request progressively, explain each, verify each:

1. **Microphone** — for Fn voice input
2. **Speech Recognition** — for on-device transcription
3. **Accessibility** — required for AX-based clicking
4. **Screen Recording** — required for `som` mode and live video streams
5. **Input Monitoring** — for the global Fn-key event tap

After each grant, run a verify-step that calls a small no-op API and confirms it didn't fail. Unverified permissions are surfaced as a banner in the Console window.

Apple also reserves Fn for system dictation. Surface a step in onboarding asking the user to disable it in System Settings → Keyboard → Press Fn key to: → Do nothing.

#### 11. Background invariant test suite (2–3 days)

Automated end-to-end tests that:
1. Capture initial cursor position, frontmost app, active Space
2. Run a representative task end-to-end
3. Assert all three are unchanged
4. Run with the user simulating typing in TextEdit; assert TextEdit content matches expected (no leaked characters)

Run on every PR. Failure blocks merge. This is the test that catches regressions in the kept cua paths.

#### 12. Code signing + notarization + Sparkle (1–2 days)

A pure-Swift bundle is straightforward:
- Sign with Developer ID Application + hardened runtime
- Entitlements: Apple Events (for cooperating apps), Accessibility (granted by user, not declared), Screen Recording (granted by user)
- **Not** sandboxed — the app ships outside the Mac App Store, and the background-execution paths require unsandboxed system access
- Notarize the bundle, staple, ship
- Test on a clean Mac with Gatekeeper enabled before shipping

Sparkle 2 with EdDSA signatures, hosted appcast. Silent updates while the
app is idle. (Without an embedded Python tree, this entire step drops from
3–4 days to 1–2.)

### Critical things to nail in Phase 1 (load-bearing)

1. **The agent boundary types.** Define the supervisor/worker/Gemini Swift types early; lock at v1.0 for Phase 1.
2. **Gemini tool schema fidelity.** Bad descriptions = bad agent. Use cua's parameter docs verbatim where possible.
3. **Live stream performance.** Use ScreenCaptureKit by window ID with explicit fps throttling. Don't capture at 60Hz and downsample.
4. **`NSPanel` configuration.** Get this right or floating UI vanishes when switching Spaces.
5. **Background-invariant suite.** Wire it up in Phase 0 and keep it green every PR; it's the regression net for SkyLight/AX path drift.
6. **Fn = single behavior.** Fn always starts a new task. Approvals/clarifications use mouse + Enter only; do not let voice or Fn leak into those surfaces.

### Monday-morning starting checklist

1. Get the vendored cua automation code building. Strip MCP/CLI/daemon. Drive Calendar from a hand-written Swift call. **No daemon, no MCP, no CLI.**
2. ~150-line Swift `GeminiClient` (URLSession + Codable) wired against a hand-crafted tool schema; supervisor calls `Automation/` directly. Run "open Calendar, create event for tomorrow at 3pm" end-to-end.
3. Throwaway Swift app: Fn-key tap + `SpeechAnalyzer`, prints transcripts.
4. Sketch the four UI surfaces in Figma before SwiftUI: top-right dot (default + hover popover), approval bar, clarification panel, console. These four screens are the product.

After those four spikes work independently, every hard piece is proven solvable and Phase 1 becomes execution.

---

## Appendix: things that will bite you

- **Fn key is reserved for Apple's dictation** — onboarding must walk the user through disabling it.
- **AX state cache invalidation** — if an app's window layout changes mid-task (a dialog appears), element indices shift. The supervisor must re-fetch `get_window_state` after any failed click.
- **Electron AX trees populate lazily** — first `get_window_state` on Slack/Discord/VS Code may return a tiny tree; retry once.
- **YouTube/HTML5 video click-to-play** rejects synthetic clicks. Use keyboard shortcuts.
- **Chrome's `application(_:open:)` delegate** clobbers frontmost when opening URLs. The focus-restore guard must remain enabled.
- **Canvas apps** (Blender, Unity) require frontmost activation. Detect by bundle ID; surface one-time approval; never silently warp the cursor.
- **Two agents on one window** = garbled output. Window lock is non-optional.
- **User typing into an agent-owned window** — pause the agent immediately. The user always wins.
- **`launch_app` must always be hidden.** Activated launches break the background guarantee from step zero.
- **Trajectory storage grows fast.** Plan for rotation/cleanup from day 1, not week 12.