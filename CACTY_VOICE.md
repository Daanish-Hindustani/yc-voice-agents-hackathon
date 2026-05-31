# Cacty Voice — phone-driven Mac automation

> For how the system fits together and why, see **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

**Quick start:** once `server/.env` has your keys, just run **`./run.sh`** from the
repo root — it builds CactyVoice, launches it, pauses for the one-time macOS
permission grant, then starts the voice bot. The manual steps below are for
understanding what the script does (or running pieces by hand).

Call in, say what you want done on your Mac, and a voice agent carries it out.

- **You speak** → the bot has a short conversation to nail down the details
  (which calendar, what time, etc.).
- **The bot dispatches** the task to **Cacty** — a macOS computer-use app that
  actually clicks through your apps in the background.
- **The bot reports back** exactly what Cacty did. It never invents success.

```
   You (browser mic over WebRTC, or a real phone via Twilio)
        │  audio
        ▼
  ┌─────────────────────────────┐         ┌──────────────────────────────┐
  │  Pipecat voice bot (Python) │  HTTP   │  Cacty.app (Swift, running)   │
  │  Parakeet STT → Nemotron    │ ──────▶ │  loopback bridge :8765        │
  │  LLM → Gradium TTS          │ POST    │  → AgentSupervisor.startTask  │
  │  tool: run_computer_task()  │ /task   │  → Worker.run(prompt)         │
  │                             │ ◀────── │  → returns the real result    │
  └─────────────────────────────┘  result └──────────────────────────────┘
        server/bot.py                       cacty/  (Gemini does the clicking)
```

The voice path is all NVIDIA (Nemotron STT + LLM) except Gradium for TTS.
The Mac automation is Cacty, which runs **Google Gemini** under the hood.

> **Local-first.** Cacty automates *this* Mac, so the bot must run on the same
> machine. Browser-WebRTC is the fast iteration loop. Real phone calls work too
> — but the bot still runs locally and is exposed to Twilio through a tunnel
> (ngrok). The bot is **not** deployed to Pipecat Cloud, because a cloud bot
> can't reach a Mac sitting on your desk.

---

## What you need

### API keys

| Key | Used by | Where it goes | Get it |
|-----|---------|---------------|--------|
| `GEMINI_API_KEY` | **Cacty** (the actual Mac automation) | passed when you launch Cacty | [aistudio.google.com](https://aistudio.google.com/apikey) |
| `GRADIUM_API_KEY` | bot TTS (the voice you hear) | `server/.env` | [gradium.ai](https://gradium.ai) |
| `NVIDIA_ASR_URL` | bot STT (Nemotron speech) | `server/.env` | hackathon-provided (default in `.env.example`) |
| `NEMOTRON_LLM_URL` | bot LLM (Nemotron) | `server/.env` | hackathon-provided (default in `.env.example`) |
| `TWILIO_ACCOUNT_SID` + `TWILIO_AUTH_TOKEN` | **only** for real phone calls | `server/.env` | [twilio.com](https://twilio.com) |

The NVIDIA URLs ship with working defaults in `.env.example`. For local
browser testing you only really need **two** secrets: `GEMINI_API_KEY` (for
Cacty) and `GRADIUM_API_KEY` (for the bot's voice). Twilio is optional and only
for the phone demo.

### macOS permissions for Cacty

Cacty drives real apps, so macOS requires you to grant it privacy permissions.
**This is the #1 thing that blocks a first run** — give it a careful minute.
See the dedicated section [**Granting macOS permissions**](#granting-macos-permissions-read-this)
below for the full walkthrough and troubleshooting.

Short version — grant all five to the **CactyVoice** entry in
**System Settings → Privacy & Security**: Microphone, Speech Recognition,
**Accessibility**, **Screen Recording**, Input Monitoring.

### Tools

- macOS 26+ and the Swift toolchain (Xcode 16+) — to build Cacty.
- Python 3.11+ and [`uv`](https://docs.astral.sh/uv/) — to run the bot.

---

## Run it (local browser — the iteration loop)

### 1. Build and launch Cacty (with its bridge)

```bash
cd cacty
swift build                                    # compiles engine + agent + app
swift test --filter LocalTaskServerTests       # optional: verify the bridge parser
Scripts/build-app.sh                           # wraps the binary into Cacty.app
```

Launch it. **Use `open`, not the bare binary** — an ad-hoc-signed bundle only
gets its `Info.plist` usage descriptions honored by TCC when launched through
launchd, otherwise the speech-auth call hard-crashes (`SIGABRT`). Since launchd
strips the shell environment, pass the Gemini key via `launchctl`:

```bash
launchctl setenv GEMINI_API_KEY sk-...     # GUI apps inherit launchctl env
open build/Cacty.app
```

On first launch macOS prompts for Microphone, Speech, Accessibility, Screen
Recording, and Input Monitoring — grant all five.

Cacty starts as a menu-bar app and opens the **loopback bridge on
`127.0.0.1:8765`**. Confirm it's up:

```bash
curl http://127.0.0.1:8765/health
# → {"ok":true}
```

You can even drive Cacty directly, no voice needed, to sanity-check automation:

```bash
curl -X POST http://127.0.0.1:8765/task \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"open the Calculator app"}'
# → {"ok":true,"text":"..."}   (blocks until the task finishes)
```

> Port in use? Launch Cacty with `CACTY_BRIDGE_PORT=9000 ...` and set
> `CACTY_URL=http://127.0.0.1:9000` in `server/.env`.

### 2. Run the voice bot

```bash
cd server
cp .env.example .env          # fill in GRADIUM_API_KEY (and keep ENV=local)
uv sync
uv run bot.py
```

Open [http://localhost:7860](http://localhost:7860), click **Connect**, and
talk. First launch takes ~20s while Pipecat downloads VAD/turn models.

Try: *"Create a calendar event tomorrow at 3pm called Dentist."* The bot will
ask which calendar, confirm, say "give me a moment," and Cacty will do it — then
the bot tells you what actually happened.

> If the bot says *"Cacty isn't reachable"* or Cacty replies that it lacks
> permissions, you haven't finished the permission grant — see the next section.

---

## Granting macOS permissions (read this)

Cacty acts on your Mac through Apple's privacy-gated APIs, so macOS (TCC)
requires **you** to grant permission in System Settings. This cannot be done
programmatically — only you, with Touch ID / your password, can flip these
switches. Budget a careful minute; this is the most common first-run snag.

### The app appears as "CactyVoice"

This build is named **CactyVoice** (bundle id `com.cactyvoice.app`) specifically
so it has its own, clearly-labeled row in each permission list — distinct from
any other "Cacty" build you may have. **Always grant to the `CactyVoice` row.**

### What to grant

In **System Settings → Privacy & Security**, turn **CactyVoice** on in:

| Permission | Why Cacty needs it | Needed for |
|------------|--------------------|------------|
| **Accessibility** | Inspect & operate other apps' windows/buttons | **Everything** — the critical one |
| **Screen Recording** | Capture window contents to "see" the UI | Everything |
| **Input Monitoring** | Send keystrokes | Typing into apps |
| Microphone | On-device speech (Fn-PTT path) | Only Cacty's own mic mode |
| Speech Recognition | On-device transcription (Fn-PTT path) | Only Cacty's own mic mode |

For the **voice-bot** flow, the bot does the listening, so the three that
matter for Cacty are **Accessibility, Screen Recording, Input Monitoring**.

### Step by step

1. Build & launch CactyVoice (see step 1 above). It registers itself in the
   permission lists the first time it checks — so launch it *before* looking.
2. Open **System Settings → Privacy & Security → Accessibility**.
3. Find the **CactyVoice** row and click its switch **on**.
4. **macOS will ask for Touch ID or your password — approve it.**
   ⚠️ If you are *not* asked to authenticate, the switch did **not** actually
   change. That auth prompt is the proof the grant took.
5. Confirm the switch is now **green**.
6. Repeat for **Screen Recording** and **Input Monitoring**.
7. **Quit and relaunch CactyVoice** — Accessibility grants only take effect
   after a restart:
   ```bash
   pkill -x CactyVoice; sleep 2
   launchctl setenv GEMINI_API_KEY sk-...
   open cacty/build/Cacty.app
   ```
8. Verify Cacty sees them — it should report all granted:
   ```bash
   curl -s -X POST http://127.0.0.1:8765/task \
     -H 'Content-Type: application/json' \
     -d '{"prompt":"Report your Accessibility and Screen Recording permission status."}'
   ```

### Troubleshooting

- **"CactyVoice" isn't in the list.** Launch it first (it appears only after it
  runs once). Still missing? Add it manually: click **`+`**, press **⌘⇧G**,
  paste `…/yc-voice-agents-hackathon/cacty/build`, select **Cacty.app**, Open.
- **The switch flips back off / won't stick.** You almost certainly weren't
  prompted for Touch ID — try again and complete the authentication. If it's
  genuinely stuck, reset this app's records and re-grant from a clean slate:
  ```bash
  tccutil reset Accessibility com.cactyvoice.app
  tccutil reset ScreenCapture com.cactyvoice.app
  tccutil reset ListenEvent com.cactyvoice.app
  pkill -x CactyVoice; sleep 2; open cacty/build/Cacty.app
  ```
  Then toggle the freshly-registered **CactyVoice** rows on again.
- **You see two "Cacty"-ish rows.** An older `com.cacty.app` dev build also
  registered one. Grant to **CactyVoice**; ignore the plain **Cacty** row.
- **Granted but still "not granted".** You toggled the *wrong* row, or didn't
  relaunch after granting (step 7). Accessibility is read at launch.
- **If you ever rebuild Cacty** (`Scripts/build-app.sh`), the signature changes
  and macOS may drop the grant — just re-toggle Accessibility once.

---

## Add a phone number (real calls — Twilio + tunnel)

The bot stays **local** so it can still reach Cacty on `127.0.0.1`; Twilio
reaches the bot through an ngrok tunnel. The Pipecat runner **auto-serves the
Twilio TwiML** when launched with `-t twilio -x <host>`, so you do *not* hand-
write a TwiML Bin — you just point the number's webhook at your tunnel.

1. **Twilio number.** Sign up at [twilio.com](https://twilio.com), add credit
   ([hackathon link](https://twil.io/yc-hack)), and buy a number with **Voice**.

2. **Creds in `server/.env`:**
   ```
   TWILIO_ACCOUNT_SID=ACxxxxxxxx
   TWILIO_AUTH_TOKEN=xxxxxxxx
   ```

3. **Make sure CactyVoice is running + permissioned** (Steps 1–2 above).

4. **Start a tunnel** (install [ngrok](https://ngrok.com/download) first):
   ```bash
   ngrok http 7860
   ```
   Copy the forwarding host, e.g. `a1b2c3.ngrok.app` (no `https://`).

5. **Run the bot in Twilio mode** (the `-x` value is your ngrok host):
   ```bash
   cd server
   uv run bot.py -t twilio -x a1b2c3.ngrok.app
   ```
   The runner now serves the TwiML at `POST /` and the media socket at `/ws`.

6. **Point the Twilio number at the tunnel.** Twilio Console → your number →
   **Voice Configuration → "A call comes in" → Webhook**, set to your ngrok
   root and method **HTTP POST**:
   ```
   https://a1b2c3.ngrok.app/
   ```

7. **Call the number.** Twilio → ngrok → local bot → `127.0.0.1` CactyVoice.

> **Why not Pipecat Cloud?** A bot deployed to the cloud cannot reach a Mac on
> your desk, and Cacty *is* that Mac. Keep the bot local; tunnel only its
> websocket.

---

## How "no hallucination" is enforced

The bot's answer to *"did it work?"* is only ever the literal text Cacty returns
from `Worker.run`:

- `server/cacty_client.py` returns Cacty's raw `{"ok", "text"|"error"}` — no
  interpretation.
- `server/bot.py`'s `run_computer_task` passes that straight to the LLM.
- The system prompt forbids inventing outcomes: report `ok=true` text as done,
  read `ok=false` errors plainly, never fabricate confirmations.

If Cacty fails or isn't reachable, the caller hears the actual failure — not a
made-up success.

---

## Files that matter

| Path | What it is |
|------|------------|
| `server/bot.py` | The voice agent (Nemotron STT/LLM, Gradium TTS, two tools). |
| `server/cacty_client.py` | Async client for Cacty's bridge. |
| `cacty/Sources/App/Bridge/LocalTaskServer.swift` | The loopback HTTP bridge (the only external entry point added to Cacty). |
| `cacty/Sources/App/CactyApp.swift` | Starts the bridge on launch (search `LocalTaskServer`). |
| `cacty/Tests/AppTests/LocalTaskServerTests.swift` | Tests for the bridge's HTTP parser. |

Everything else under `cacty/` is the unmodified Cacty app. The original
flower-shop starter (`server/bot-gpt.py`, `server/bot-nemotron.py`,
`server/mock_backend.py`) is left in place for reference.
