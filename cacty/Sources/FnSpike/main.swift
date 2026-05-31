import AppKit
import CoreGraphics
import Foundation

// PHASE 0 SPIKE — throwaway code, not for production.
//
// **Scope reduction note:** an earlier draft of this spike also
// drove `AVAudioEngine` + `SFSpeechRecognizer` to validate the
// PTT-style speech path. That path crashes immediately under
// `swift run` with `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` because
// modern macOS TCC requires a real `.app` bundle (or fully-signed
// binary with embedded entitlements) before honoring usage-
// description strings. Embedding `Info.plist` via `-sectcreate`
// alone is insufficient. Building the `.app` shell is Phase 1
// work — the spike scope strips speech to focus on the actual
// Phase 0 unknown.
//
// Risk this spike validates: PLAN.md § Phase 0 risk #4
// > "Fn-key global capture (Apple reserves this for system
// > dictation; user may need to disable it in System Settings)."
//
// Risk explicitly NOT validated by this spike: PLAN.md risk #5
// > "SpeechAnalyzer quality on PTT-style short utterances."
// SFSpeechRecognizer has shipped on macOS 13+ for years and
// works against `requiresOnDeviceRecognition = true`. The
// quality unknown is real but is downstream of having a `.app`
// shell — that's Phase 1 work.
//
// Required permission for THIS reduced spike:
//   - Input Monitoring (System Settings → Privacy & Security)
//
// To run:
//   swift run fn-spike
//
// First run will fail with "FAILED to create CGEventTap" — that's
// the cue to grant Input Monitoring to the binary, then re-run.
// No microphone or speech-recognition prompts will appear; this
// reduced spike doesn't need them.

@MainActor
final class FnSpike {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnHeld = false
    private var pressCount = 0

    func run() {
        log("Phase 0 spike (reduced): Fn-key global capture")
        log("Hold Fn, release. Ctrl-C to exit.")
        log("Reduced scope — no audio/speech (TCC blocks SwiftPM CLI binaries; Phase 1 .app shell will validate that path).")
        log("")

        installFnTap()
        log("")
        log("Listening for Fn-key state changes…")
        log("System Settings → Keyboard → Press 🌐 key to: → 'Do Nothing' must be set,")
        log("otherwise macOS swallows Fn for dictation before our tap can see it.")
        log("")

        CFRunLoopRun()
    }

    // MARK: - CGEventTap on flagsChanged

    private func installFnTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // Pass `self` through `userInfo` as the unmanaged pointer
        // since C function callbacks can't capture Swift `self`.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let spike = Unmanaged<FnSpike>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                Task { @MainActor in
                    spike.handleFlagsChanged(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            log("✗ FAILED to create CGEventTap.")
            log("  This means Input Monitoring permission is denied.")
            log("  Grant in System Settings → Privacy → Input Monitoring,")
            log("  then re-run.")
            exit(1)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        log("✓ Event tap installed")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        // The Fn-key state lives in `kCGEventFlagMaskSecondaryFn`
        // (a.k.a. `.maskSecondaryFn`). When pressed and held, the
        // bit is set; when released, cleared. flagsChanged events
        // fire on the transitions only — exactly the edges we want.
        let flags = event.flags
        let isFnSet = flags.contains(.maskSecondaryFn)

        if isFnSet, !fnHeld {
            fnHeld = true
            pressCount += 1
            log("Fn DOWN  (press #\(pressCount))")
        } else if !isFnSet, fnHeld {
            fnHeld = false
            log("Fn UP    (press #\(pressCount))")
        }
    }

    // MARK: - Logging

    private nonisolated func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}

let spike = FnSpike()
spike.run()
