# FnSpike — Phase 0 throwaway

The fourth and final Phase 0 spike per `PLAN.md` § Phase 0:

> Throwaway Swift app: Fn-key tap + `SpeechAnalyzer` → print transcript.

This target validates two risks named in the spec:

1. **Fn-key global capture.** Apple reserves Fn for system dictation by default; some macOS configurations may not deliver `flagsChanged` events for the Fn key at all. We test this with `CGEvent.tapCreate` listening for `kCGEventFlagMaskSecondaryFn` transitions.
2. **On-device speech transcription quality on PTT-style short utterances.** New `SpeechAnalyzer` framework on macOS 26 is the production target (Q5 of the planning chat); for the spike we use the well-known `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Phase 1's `App/Speech/` module migrates to `SpeechAnalyzer`.

## Code quality

This is **spike-grade**, not production. Single file, MainActor-everywhere, run-loop run, no error recovery beyond logging. Phase 1's `App/PTT/FnKeyHandler.swift` and `App/Speech/SpeechRecognizer.swift` re-implement these surfaces with proper supervisor wiring, `Sendable`-correct concurrency, and `SpeechAnalyzer` integration.

## How to run

### One-time setup

1. **Disable Fn → Dictation** in System Settings → Keyboard → "Press 🌐 key to:" → choose **"Do Nothing"**. Otherwise macOS will swallow Fn before our event tap can see it.

2. **Grant permissions on first run.** The spike will prompt for:
   - **Input Monitoring** (System Settings → Privacy & Security → Input Monitoring)
   - **Microphone**
   - **Speech Recognition**

   The first run will fail with "FAILED to create CGEventTap" until Input Monitoring is granted to the binary. After granting, re-run.

### Run

```bash
swift run fn-spike
```

You should see:

```
[2026-05-10T…] Phase 0 spike: Fn-key + on-device speech recognition
[2026-05-10T…] Hold Fn, speak, release. Ctrl-C to exit.
[2026-05-10T…] ✓ Speech Recognition authorized
[2026-05-10T…] ✓ Microphone authorized
[2026-05-10T…] ✓ Event tap installed
[2026-05-10T…] Ready. Listening for Fn-key state changes…
```

Now hold Fn and speak. Expected output:

```
[…] Fn DOWN — recording…
[…]   …open
[…]   …open mail
[…]   …open mail and reply to mom
[…] Fn UP — finalizing transcript
[…] FINAL: open mail and reply to mom
```

Press **Ctrl-C** to exit.

## What success looks like

- `Fn DOWN` / `Fn UP` lines fire as you press and release Fn → **Phase 0 risk #4 (global Fn capture) is killed.**
- `FINAL: <transcript>` matches what you said reasonably well → **Phase 0 risk #5 (SpeechAnalyzer/SFSpeechRecognizer quality on PTT-style short utterances) is killed.**

## What failure tells you

| Symptom | Diagnosis |
|---|---|
| `FAILED to create CGEventTap` | Input Monitoring not granted. Grant + re-run. |
| Fn DOWN/UP lines never fire | Fn → Dictation still enabled in System Settings, or this Mac's keyboard doesn't emit Fn modifier events (rare; some external keyboards). The Phase 0 risk surfaced — Phase 1 needs a fallback hotkey or a different input mechanism. |
| `Speech Recognition denied` | Grant in System Settings → Privacy → Speech Recognition. |
| `Microphone denied` | Grant in System Settings → Privacy → Microphone. |
| Transcript is empty or wildly wrong | Check the recognizer locale (defaults to system); short PTT-style utterances have higher word-error-rate than long sentences — note the Phase 1 design implications. |

## Cleanup

Nothing to clean up — the spike runs in foreground until Ctrl-C and doesn't write any persistent state.
