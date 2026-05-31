# Architecture — Cacty Voice

A voice agent that takes a spoken request over the phone (or browser), holds a
short clarifying conversation, then drives the user's Mac to actually complete
the task and reports back the real outcome.

This document describes how the pieces fit, why the boundaries are where they
are, and the constraints that shaped them. For setup and run instructions see
[`CACTY_VOICE.md`](./CACTY_VOICE.md).

---

## 1. System overview

There are **two processes** on **one Mac**:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Mac (the user's machine)                                                  │
│                                                                            │
│  ┌────────────────────────────────┐        ┌───────────────────────────┐  │
│  │  Voice bot — Python / Pipecat  │  HTTP  │  Cacty — Swift / macOS app │  │
│  │  process: `uv run bot.py`      │ ─────▶ │  process: Cacty.app        │  │
│  │                                │  POST  │                            │  │
│  │  • Transport (WebRTC / Twilio) │ /task  │  • LocalTaskServer (bridge)│  │
│  │  • STT  (NVIDIA Nemotron)      │        │  • AgentSupervisor         │  │
│  │  • LLM  (NVIDIA Nemotron)      │ ◀───── │  • Worker  (Gemini loop)   │  │
│  │  • TTS  (Gradium)              │ result │  • Automation engine (AX,  │  │
│  │  • tool: run_computer_task()   │        │    SkyLight, capture)      │  │
│  └────────────────────────────────┘        └───────────────────────────┘  │
│         the "ears, brain, mouth"                 the "hands" on the Mac     │
└──────────────────────────────────────────────────────────────────────────┘
        ▲                                                   │
        │ audio (browser mic / phone)                       │ clicks, types,
        │                                                    ▼ reads windows
     the caller                                        real Mac apps
```

- The **voice bot** owns the conversation: turning speech into intent and the
  result back into speech. It has no ability to touch the Mac.
- **Cacty** owns the automation: it cannot hear or speak; it takes a
  natural-language instruction and operates real apps.
- They meet at exactly **one seam**: an HTTP `POST /task` over loopback.

Two different LLMs, deliberately:
- **Nemotron** (NVIDIA) is the *conversational* brain — fast, voice-tuned.
- **Gemini** (Google) is the *computer-use* brain inside Cacty — it decides
  which buttons to click. This split is pre-existing in Cacty and intentionally
  left untouched.

---

## 2. Components

### 2.1 Voice bot (`server/`)

Built on [Pipecat](https://pipecat.ai). The pipeline is a linear chain of frame
processors (`server/bot.py`, `run_bot`):

```
transport.input() → STT → user_aggregator → LLM → TTS → transport.output() → assistant_aggregator
```

| Stage | Service | Notes |
|-------|---------|-------|
| Transport in/out | `SmallWebRTCTransport` or `FastAPIWebsocketTransport` | WebRTC for local browser; Twilio websocket for phone |
| STT | `NVidiaWebSocketSTTService` (`server/nvidia_stt.py`) | Nemotron Speech Streaming, 16 kHz PCM |
| LLM | `VLLMOpenAILLMService` (`server/nemotron_llm.py`) | Nemotron-3-Super-120B via vLLM (OpenAI-compatible); thinking OFF for latency |
| TTS | `GradiumTTSService` | speech synthesis |
| VAD | `SileroVADAnalyzer` | turn detection inside the user aggregator |

The LLM has exactly **two tools** (`server/bot.py`):

- `run_computer_task(task: str)` — the only way to affect the Mac. Sends a
  complete instruction to Cacty and returns Cacty's literal result.
- `end_call()` — pushes an `EndTaskFrame` to hang up after the goodbye.

The **system prompt** does the conversational work: ask one clarifying question
at a time, confirm, say a filler line ("give me a moment") in the same turn as
the tool call, and — critically — **report only what the tool returns**.

### 2.2 Bridge client (`server/cacty_client.py`)

A thin async wrapper over `aiohttp`. One job: `run_cacty_task(prompt)` →
`{"ok": bool, "text"|"error": str}`. It does **no interpretation** — it returns
Cacty's raw verdict. Transport failures (Cacty down, timeout) are caught and
returned as `{"ok": false, "error": ...}` so the bot always has something
truthful to say. Timeout is 330 s (just above Cacty's own 300 s task ceiling).

### 2.3 The bridge (`cacty/Sources/App/Bridge/LocalTaskServer.swift`) — the new seam

Cacty shipped with **no external interface by design** (its README: *"no MCP
server, no CLI… everything is one Swift process"*). The entire integration is
this one added file: a minimal HTTP/1.1 server on `NWListener`, bound to
`127.0.0.1` only.

| Endpoint | Behavior |
|----------|----------|
| `GET /health` | `{"ok": true}` — liveness; touches nothing |
| `POST /task` `{"prompt": "..."}` | Starts the task, **blocks** until terminal, returns `{"ok": true, "text"}` or `{"ok": false, "error"}` |

It is **synchronous by design**: one HTTP request maps to one completed task, so
the bot can `await` a single call and speak the result. Internally it calls
`AgentSupervisor.startTask` and polls `status(of:)` every 500 ms until terminal
(or a 300 s ceiling) — mirroring the existing `AppCoordinator.watchTask` pattern.

It is started in `cacty/Sources/App/CactyApp.swift` (`makeCoordinator`), reusing
the *same* `AgentSupervisor` the menu-bar and Fn-PTT surfaces drive. The
production app path only — unit tests construct `AppCoordinator` directly and
never open a socket.

### 2.4 Cacty internals (unchanged)

The bridge is a thin front door onto Cacty's existing machinery:

- **`AgentSupervisor`** (`actor`) — task lifecycle. `startTask(prompt) → TaskID`
  runs a `Worker` in the background; `status(of:) → .running/.succeeded(text)/
  .failed(reason)/.cancelled`.
- **`Worker`** (`actor`) — one task's Gemini loop: send prompt + tool schema to
  Gemini, dispatch the tool calls Gemini returns against the automation engine,
  feed results back, repeat until Gemini returns final text (max 30 steps).
- **Automation engine** (`Sources/Automation/`) — the vendored cua-driver: AX
  clicks, SkyLight pixel events, per-window capture, focus management. This is
  what physically operates the apps.

None of this was modified.

---

## 3. Request lifecycle

A full "create a calendar event" turn:

```
1. Caller speaks  ──▶ Transport ──▶ STT ──▶ "add a calendar event tomorrow at 3"
2. Nemotron LLM asks a clarifying question ──▶ TTS ──▶ "Sure — which calendar?"
3. Caller: "Work."  (repeat 1–2 until the bot has calendar, date, time, title)
4. Bot confirms; on "yes" it emits, in ONE turn:
      • spoken: "Okay, doing that now — give me a moment"   (covers the wait)
      • tool call: run_computer_task("Create an event in the Work calendar on
                   Saturday May 31 2026 at 3pm titled Dentist")
5. cacty_client  ──HTTP POST /task──▶  LocalTaskServer
6. LocalTaskServer ──▶ AgentSupervisor.startTask ──▶ Worker.run
7. Worker ⇄ Gemini ⇄ Automation engine:  open Calendar, click New Event, type…
8. Worker returns final text ──▶ supervisor status .succeeded(text)
9. LocalTaskServer's poll sees .succeeded ──▶ HTTP 200 {"ok":true,"text":"Done…"}
10. cacty_client returns it ──▶ tool result ──▶ Nemotron LLM
11. Bot speaks ONLY that text ──▶ TTS ──▶ "All set — it's on your Work calendar."
```

Steps 6–8 can take tens of seconds; step 4's filler line is what makes that
silence acceptable on a phone call.

---

## 4. Key design decisions

### 4.1 Why an HTTP bridge (not CLI / URL scheme / XPC)
Cacty must already be running (it's a menu-bar app holding TCC permissions and a
warm agent); spawning it per task is infeasible. So the integration must *poke a
running process*. HTTP over loopback was chosen because it is:
- **Testable in isolation** — `curl /health` and `curl /task` verify the whole
  Cacty side before any voice code exists (this is how it was validated).
- **Trivial from Python** — one `aiohttp` call, no native bindings.
- **Debuggable** — human-readable, inspectable with standard tools.

URL schemes can't return a result; XPC needs matched entitlements and is harder
to reach from Python; a CLI would re-spawn the app. HTTP won on simplicity.

### 4.2 Synchronous dispatch
The bot says "one moment" and the `POST /task` blocks until the task finishes.
One request = one completed task = one thing to speak. The alternative (async +
poll + progress updates) is more robust for very long tasks but adds state on
both sides; it was rejected for v1 simplicity.

### 4.3 Loopback-only binding
`requiredLocalEndpoint = 127.0.0.1` means nothing off the machine can reach the
bridge. Cacty can drive the Mac, so the entry point must not be network-exposed.

### 4.4 No-hallucination contract
The most important property. The bot's claim about what happened is *grounded*,
not generated:
- `cacty_client.py` returns Cacty's raw `ok/text/error`.
- `run_computer_task` passes it straight to the LLM.
- The system prompt forbids inventing confirmations, numbers, or success.

If Cacty fails or is unreachable, the caller hears the actual error. The bot
never asserts an outcome Cacty didn't report.

### 4.5 Two LLMs, left split
Nemotron is fast and voice-tuned; Gemini is what Cacty already uses for
computer-use and is verified to work. Forcing one model across both roles would
mean either a slower conversation or re-validating Cacty's automation against a
new model. The seam keeps them independent.

---

## 5. Constraints & boundaries

- **Co-location is mandatory.** Cacty automates *this* Mac, so the bot must run
  on the same machine and reach Cacty over `127.0.0.1`. The bot is **not**
  deployed to Pipecat Cloud — a cloud bot cannot reach a desk Mac.
- **Phone calls** therefore keep the bot local and tunnel only its Twilio
  websocket (ngrok). Twilio → ngrok → local bot → loopback → Cacty.
- **Cacty needs five macOS permissions** (Mic, Speech, Accessibility, Screen
  Recording, Input Monitoring) and a `GEMINI_API_KEY`. Because it is
  ad-hoc-signed, it must be launched via launchd (`open`), not the bare binary,
  or TCC hard-crashes on the speech-auth call. The key is passed via
  `launchctl setenv` (launchd strips the shell environment).
- **Task ceiling:** Cacty caps a single task at 300 s; the HTTP client allows
  330 s so the bridge's own timeout message wins the race.

---

## 6. Failure modes & handling

| Failure | Where caught | Caller hears |
|---------|--------------|--------------|
| Cacty not running | `cacty_client` `ClientConnectorError` | "Can't reach Cacty — make sure the app is running." |
| Task exceeds 300 s | `LocalTaskServer` poll ceiling | "The task took too long and timed out." |
| Gemini/automation error mid-task | `Worker` throws → supervisor `.failed` | the plain error string Cacty returned |
| Bridge port in use | `NWListener` logs `.error`, app keeps running | `/health` fails until resolved (set `CACTY_BRIDGE_PORT`) |
| Bad/incomplete HTTP request | `HTTPRequest.parse` → 400 | n/a (client-side) |

Every layer degrades to a truthful message rather than a crash or a fabricated
success.

---

## 7. What's verified vs. pending

**Verified end-to-end** (this is real, observed behavior, not just compiled):
- Swift bridge + all Cacty targets compile; 7 HTTP-parser unit tests pass.
- `GET /health` → `{"ok":true}`.
- `POST /task {"open Calculator"}` → `{"ok":true,"text":"I've opened the
  Calculator app for you."}` with Calculator actually launching.
- `bot.py` imports under Pipecat 1.3.0 and serves on `:7860`.

**Pending a human:** the spoken conversation itself (requires talking into the
browser mic) and the Twilio phone path (ngrok + TwiML wiring).

---

## 8. File map

| Path | Role |
|------|------|
| `server/bot.py` | Pipecat voice agent; two tools; no-hallucination system prompt |
| `server/cacty_client.py` | Async client for the bridge |
| `server/nvidia_stt.py` | NVIDIA Nemotron streaming STT service |
| `server/nemotron_llm.py` | Nemotron vLLM LLM service (TTFB fix) |
| `cacty/Sources/App/Bridge/LocalTaskServer.swift` | **The bridge** — only external entry point |
| `cacty/Sources/App/CactyApp.swift` | Starts the bridge on launch |
| `cacty/Sources/App/Supervisor/AgentSupervisor.swift` | Task lifecycle (unchanged) |
| `cacty/Sources/Agent/Worker.swift` | Per-task Gemini loop (unchanged) |
| `cacty/Sources/Automation/` | Vendored automation engine (unchanged) |
| `cacty/Tests/AppTests/LocalTaskServerTests.swift` | Bridge HTTP-parser tests |
| `CACTY_VOICE.md` | Setup & run guide |
| `ARCHITECTURE.md` | This document |
