# 🌵 Cacty Voice

**Call a phone number, speak a task, and an AI agent actually does it on a real Mac — then tells you the truth about what happened.**

> Voice in → conversation → a background computer-use agent clicks through real
> macOS apps → spoken result. Built at the YC Voice Agents Hackathon on
> **Pipecat** + **NVIDIA Nemotron** (open-weights STT & LLM).

📖 Deep docs: **[ARCHITECTURE.md](./ARCHITECTURE.md)** · **[CACTY_VOICE.md](./CACTY_VOICE.md)** (setup, permissions, phone) · Original hackathon starter preserved in **[HACKATHON_STARTER.md](./HACKATHON_STARTER.md)**

---

## 1. What is this?

**Cacty Voice turns a phone call into actions on your computer.** You call in and
say something like *"add a dentist appointment to my calendar tomorrow at 3pm"* or
*"open TextEdit and draft a thank-you note."* The agent has a short, natural
conversation to nail down the details, then hands the task to **Cacty** — a macOS
computer-use agent that drives your real apps (clicking, typing, reading windows)
in the background. When it's done, the voice agent tells you **exactly what
happened** — and never claims success it didn't actually observe.

Think of it as **"a phone call to your computer."** No screen, no keyboard — just
your voice, anywhere you have a phone.

### Why it's interesting

- **Voice → real computer actions.** Most voice agents look things up or call an
  API. This one operates a full desktop GUI — the same Calendar, Mail, browser,
  and editor a human uses — through accessibility APIs.
- **A truthfulness contract.** Computer-use agents love to *claim* they clicked
  the button. Cacty Voice is architected so the agent's spoken answer is **only
  ever the literal result** the automation layer returns. If the task fails, you
  hear the real failure, not a hallucinated "all set!" (See
  [§ No-hallucination](#the-no-hallucination-contract).)
- **Two specialized brains.** A fast, voice-tuned **open-weights** model
  (Nemotron) runs the conversation; a separate computer-use model runs the
  clicking. Each does what it's best at.

### How it works (architecture)

```
   📞 You (phone via Twilio, or browser mic via WebRTC)
        │ audio
        ▼
  ┌──────────────────────────────────┐        ┌──────────────────────────────┐
  │  Voice bot — Pipecat (Python)     │  HTTP  │  Cacty — macOS app (Swift)    │
  │  • NVIDIA Nemotron STT            │ ─────▶ │  • loopback bridge :8765 ★NEW │
  │  • NVIDIA Nemotron LLM (dialog)   │  POST  │  • AgentSupervisor → Worker   │
  │  • Gradium TTS                    │ /task  │  • computer-use loop          │
  │  • tool: run_computer_task() ★NEW │ ◀───── │  • clicks/types/reads apps    │
  └──────────────────────────────────┘ result └──────────────────────────────┘
         "ears, brain, mouth"                       "hands" on the Mac
```

★ = built during this hackathon. The voice bot and Cacty run on the **same Mac**
(Cacty automates the local machine); for real phone calls the bot stays local and
Twilio reaches it through an ngrok tunnel. Full rationale in
[ARCHITECTURE.md](./ARCHITECTURE.md).

#### The no-hallucination contract

The bot's answer to *"did it work?"* is wired to be ground-truth, not generated:

1. `server/cacty_client.py` returns Cacty's raw `{ok, text|error}` — **zero**
   interpretation.
2. `server/bot.py`'s `run_computer_task` tool passes that verbatim to the LLM.
3. The system prompt forbids inventing confirmations: report `ok=true` text as
   done, read `ok=false` errors plainly, never fabricate.

Real example from our testing — Cacty couldn't reach a blank browser tab and the
agent said so, instead of pretending: *"I'm unable to create the event — the
Google Calendar page isn't loading."*

---

## 2. Demo (≤ 60 seconds)

> 📹 **Watch the demo:** _[link here]_  &nbsp;·&nbsp; **Under 60 seconds. Really.**

<!-- Replace the link above with your uploaded clip (Loom/YouTube/MP4). Keep it
     to a single live take of the loop below — no narration of section 1. -->
---

## 3. How we used Pipecat, Nemotron, and Cekura

### 🛠️ Pipecat — *orchestration (used heavily)*

Pipecat is the backbone of the entire voice layer. We use it for:

- **The pipeline:** `transport.input → STT → user-aggregator → LLM → TTS →
  transport.output` assembled in `server/bot.py`.
- **Tool calling:** the LLM's two direct functions — `run_computer_task` (the
  bridge to Cacty) and `end_call` — registered via Pipecat's
  `ToolsSchema` + `register_direct_function`.
- **Turn-taking & VAD:** Silero VAD + `FilterIncompleteUserTurnStrategies` so the
  agent waits for complete utterances before dispatching a task.
- **Dual transport, one codebase:** `SmallWebRTCTransport` for browser iteration
  **and** `FastAPIWebsocketTransport` + `TwilioFrameSerializer` for real phone
  calls — selected at runtime by the Pipecat runner.
- **Telephony plumbing:** the Pipecat runner auto-serves the Twilio TwiML
  (`-t twilio -x <ngrok-host>`), which made wiring a real phone number genuinely
  a 5-minute job.

### 🧠 NVIDIA Nemotron — *open-weights voice brain (used heavily)*

The whole conversational stack runs on **NVIDIA open-weights models**:

- **STT — Nemotron Speech Streaming** (`server/nvidia_stt.py`): streaming ASR over
  WebSocket, 16 kHz PCM, with cumulative-transcript stitching.
- **LLM — Nemotron-3-Super-120B** via vLLM (`server/nemotron_llm.py`): the
  dialog + tool-calling brain. It handles the clarify→confirm→dispatch flow and
  emits the `run_computer_task` tool calls with fully-resolved arguments (relative
  dates expanded, etc.).
- We wrote a **TTFB-correctness wrapper** (`VLLMOpenAILLMService`) because, for a
  reasoning model served with thinking enabled, stock Pipecat stops the
  time-to-first-byte clock on the first *reasoning* token rather than the first
  *spoken* token — badly understating real voice latency. Our subclass defers the
  TTFB stop until a user-visible content/tool token actually streams. Thinking is
  kept **off** for voice latency by default.
---

## 4. What we built **during** the hackathon

Be explicit about old vs. new vs. borrowed:

| | Component | Status |
|---|---|---|
| 🆕 **New (this hackathon)** | **The entire voice ↔ computer-use application** — see below | **built here** |
| **Cacty**, the macOS computer-use app (Swift, Gemini-driven, vendored `cua-driver` automation engine) | personal project, predates the event |
| 🟨 Provided / borrowed | The Pipecat "Field & Flower" starter; NVIDIA Nemotron endpoints; Gradium TTS; Twilio | hackathon-provided |

---

## 5. Feedback on the tools

### NVIDIA Nemotron

**What it did well**
- **Tool-calling was reliable.** Nemotron-3-Super produced clean, well-formed
  `run_computer_task` calls and correctly resolved relative dates ("tomorrow at
  3pm" → an absolute date) before dispatching — exactly what we needed.
- **Good conversational discipline.** With a tight system prompt it asked one
  clarifying question at a time and confirmed before acting, which suits voice.
- **Streaming STT held up** on real-time mic and phone audio.

**What could be better**
- **Reasoning vs. voice latency is a sharp edge.** With thinking enabled, the
  model doesn't emit spoken content until it finishes reasoning, so naive TTFB
  metrics are wildly optimistic and the *felt* latency is high. We had to write a
  subclass to even measure it correctly. A first-class "reasoning, but stream a
  short spoken ack first" mode for voice would be huge.
- **Thinking-token leakage.** Unless the vLLM server runs a reasoning parser,
  chain-of-thought can land in the `content` field and get **spoken aloud**. A
  safer default (route reasoning to a separate field) would prevent foot-guns.
- A clearer, copy-paste **"Nemotron for low-latency voice" recipe** (thinking off,
  parser config, recommended decoding params) would have saved us time.

### Pipecat

**What it did well**
- The **single-codebase, multi-transport** design (WebRTC for dev, Twilio for
  prod) is excellent — we flipped to a real phone number with one CLI flag.
- **Auto-served Twilio TwiML** (`-t twilio -x <host>`) removed an entire class of
  webhook busywork.
- Direct-function tool registration made adding our custom `run_computer_task`
  trivial.

**What could be better**
- The exact **local Twilio invocation** wasn't obvious from the docs — we read the
  runner source to find `-t twilio -x <ngrok-host>` and that the webhook should
  point at `POST /` (not a hand-written TwiML Bin). A short "local telephony"
  doc page would help.
- The `av`/`opencv` duplicate-dylib warning on import is noisy and looks scary
  even though it's benign.

---

## Setup & run

```bash
# 1. keys
cp server/.env.example server/.env      # add GRADIUM_API_KEY; GEMINI_API_KEY for Cacty

# 2. one command: build Cacty, launch it, grant permissions, start the bot
./run.sh
```

Then open **http://localhost:7860**, click **Connect**, and talk. Full
walkthrough (incl. the macOS permission grant and adding a phone number) is in
**[CACTY_VOICE.md](./CACTY_VOICE.md)**.

---

*Built at the YC Voice Agents Hackathon (Cekura × Daily, with NVIDIA, AWS,
Twilio). Voice on Pipecat; open-weights brain on NVIDIA Nemotron.*
