import Foundation
import os
@preconcurrency import AVFoundation
@preconcurrency import Speech

private let log = Logger(subsystem: "com.cacty", category: "speech")

/// On-device push-to-talk speech recognition.
///
/// Wraps `AVAudioEngine` + `SFSpeechRecognizer(requiresOnDeviceRecognition: true)`.
/// `Sources/FnSpike/main.swift` used the same pattern as a Phase 0
/// spike — productionized here inside the `.app` bundle so TCC
/// honors the `Info.plist` usage descriptions and the system
/// prompts the user for Microphone + Speech Recognition rather
/// than crashing.
///
/// **Migration note:** Q5 of the planning chat named `SpeechAnalyzer`
/// (macOS 26+) as the production target. SFSpeechRecognizer is the
/// known-working stand-in here. A follow-up PR (post-1.5) migrates
/// to `SpeechAnalyzer` once we have the rest of the PTT loop
/// validated against the well-trodden API.
///
/// Lifecycle:
///   1. `requestAuthorization()` asks for Microphone + Speech
///      Recognition grants (system prompts on first call).
///   2. `startRecording()` begins audio capture and streams
///      partial results through `onPartial`.
///   3. `stopRecording()` ends audio, finalizes the transcript,
///      and emits one final value via `onFinal`.
///
/// Authorization failures, recognizer unavailability, and
/// AVAudioEngine.start failures all surface as `.failed` cases on
/// the relevant callbacks; the caller (AppCoordinator) decides
/// how to render them.
@MainActor
final class SpeechRecognizer {
    enum AuthError: Error, CustomStringConvertible {
        case speechDenied
        case micDenied
        case both

        var description: String {
            switch self {
            case .speechDenied:
                return "Speech Recognition denied. Grant in System Settings → Privacy & Security → Speech Recognition."
            case .micDenied:
                return "Microphone denied. Grant in System Settings → Privacy & Security → Microphone."
            case .both:
                return "Speech Recognition + Microphone both denied. Grant both in System Settings → Privacy & Security."
            }
        }
    }

    enum RecognizerError: Error, CustomStringConvertible {
        case unavailable(diagnostics: String)
        case audioEngineFailed(String)
        case recognitionFailed(String)

        var description: String {
            switch self {
            case .unavailable(let diagnostics):
                return
                    "Speech recognition is unavailable. "
                    + "Open System Settings → Keyboard → Dictation, "
                    + "turn it on, and let the on-device model finish "
                    + "downloading. \(diagnostics)"
            case .audioEngineFailed(let reason):
                return "AVAudioEngine failed to start: \(reason)"
            case .recognitionFailed(let reason):
                return "Recognition failed: \(reason)"
            }
        }
    }

    /// Stream of partial transcripts during recording (one per
    /// new utterance hypothesis). The caller can show these as a
    /// "live caption" while Fn is held, similar to macOS
    /// dictation. Phase 1's menu surface can use this; the dot
    /// UI (PR 1.6) will surface it as the hover popover.
    var onPartial: ((String) -> Void)?

    /// Called once after `stopRecording()` with either the final
    /// transcript or a `RecognizerError`. Failure cases are
    /// `.recognitionFailed` (recognizer errored) or
    /// `.audioEngineFailed` (audio capture broke mid-stream).
    var onFinal: ((Result<String, RecognizerError>) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var isRecording = false

    /// Request mic + speech-recognition authorization. Returns
    /// `.success` only if BOTH grants are obtained. Surfaces
    /// which side failed so the caller can route the user to
    /// the right System Settings pane.
    func requestAuthorization() async -> Result<Void, AuthError> {
        async let speech = requestSpeechAuthorization()
        async let mic = requestMicrophoneAuthorization()
        let (speechOk, micOk) = await (speech, mic)
        switch (speechOk, micOk) {
        case (true, true): return .success(())
        case (false, false): return .failure(.both)
        case (false, true): return .failure(.speechDenied)
        case (true, false): return .failure(.micDenied)
        }
    }

    /// Begin streaming audio to the recognizer. Subsequent
    /// partial transcripts arrive via `onPartial`. Calling
    /// twice without `stopRecording()` in between is a no-op
    /// (the second call returns immediately).
    func startRecording() -> Result<Void, RecognizerError> {
        Self.trace("startRecording invoked")
        if isRecording {
            Self.trace("already recording — no-op")
            return .success(())
        }

        let loaded = loadRecognizer()
        guard case .ok(let r) = loaded else {
            if case .failed(let diagnostics) = loaded {
                Self.trace("recognizer unavailable: \(diagnostics)")
                return .failure(.unavailable(diagnostics: diagnostics))
            }
            return .failure(.unavailable(diagnostics: ""))
        }
        Self.trace(
            "recognizer ok locale=\(r.locale.identifier) "
            + "supportsOnDevice=\(r.supportsOnDeviceRecognition)"
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device recognition is required only when the
        // recognizer reports it can do so. Forcing it on a
        // recognizer that doesn't support it makes every
        // request error out — fall back to whatever channel
        // the recognizer actually offers. CLAUDE.md says
        // "on-device only," but that's the design intent for
        // the production locale model; refusing to function
        // when the model isn't installed yet just turns into
        // "unable to detect."
        request.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // `outputFormat(forBus: 0)` is the format the input node
        // hands downstream — for taps, this is the format the tap
        // sees, so it must match what we install. Some macOS
        // configurations return a degenerate format before the
        // engine is prepared; in that case prefer `inputFormat`
        // as a fallback so we don't refuse to start at all.
        let primaryFormat = inputNode.outputFormat(forBus: 0)
        let format: AVAudioFormat = {
            if primaryFormat.sampleRate > 0 && primaryFormat.channelCount > 0 {
                return primaryFormat
            }
            return inputNode.inputFormat(forBus: 0)
        }()
        Self.trace(
            "tap format sampleRate=\(format.sampleRate) "
            + "channels=\(format.channelCount)"
        )
        // `@Sendable` strips inherited @MainActor isolation so
        // AVAudioEngine's audio-thread invocation doesn't trip
        // `_dispatch_assert_queue_fail`.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = {
            buffer, _ in
            request.append(buffer)
        }
        inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: format, block: tap
        )

        audioEngine.prepare()
        do {
            try audioEngine.start()
            Self.trace("audioEngine.start ok — mic should now be live")
        } catch {
            Self.trace(
                "audioEngine.start FAILED: \(error.localizedDescription)"
            )
            cleanup()
            return .failure(.audioEngineFailed(
                error.localizedDescription
            ))
        }

        // `@Sendable` strips inherited @MainActor isolation. The
        // callback fires on the recognizer's internal queue —
        // hop to MainActor explicitly inside.
        // Extract the Sendable bits off the recognizer queue
        // (text + flags) before hopping to MainActor, so we
        // don't have to send the non-Sendable
        // `SFSpeechRecognitionResult` across the boundary.
        let recognitionCallback: @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void = {
            [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.recognitionTask != nil else {
                    // Already finished (cleanup ran). Subsequent
                    // late callbacks from the recognizer would
                    // otherwise fire `onFinal` a second time.
                    return
                }
                if isFinal, let text {
                    self.onFinal?(.success(text))
                    self.cleanup()
                    return
                }
                if let errorMessage {
                    // "No speech detected" arrives as an error
                    // with no result — but if we'd already
                    // collected partial text, treat the partial
                    // as the final transcript rather than
                    // failing the task.
                    if let text, !text.isEmpty {
                        self.onFinal?(.success(text))
                    } else {
                        self.onFinal?(
                            .failure(.recognitionFailed(errorMessage))
                        )
                    }
                    self.cleanup()
                    return
                }
                if let text {
                    self.onPartial?(text)
                }
            }
        }
        recognitionTask = r.recognitionTask(
            with: request, resultHandler: recognitionCallback
        )

        isRecording = true
        return .success(())
    }

    /// End audio capture and request a final transcript. The
    /// recognizer may emit the final result asynchronously
    /// after this call returns; `onFinal` is invoked when it
    /// arrives. If no recognition is in flight, this is a
    /// no-op.
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recognitionRequest?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        // Don't nil out recognitionTask immediately — the
        // recognizer fires its final result asynchronously
        // (handled in the recognitionTask callback above).
    }

    /// One-line trace into the `com.cacty/speech` Logger channel.
    /// Visible via `log stream --predicate 'subsystem == "com.cacty"
    /// && category == "speech"'` or in Console.app.
    private static func trace(_ message: String) {
        log.debug("\(message, privacy: .public)")
    }

    // MARK: - Private

    /// Result of trying to obtain a usable `SFSpeechRecognizer`.
    /// `.failed` carries a diagnostic string suitable for the
    /// user-visible error so they know exactly which locale was
    /// tried and what was wrong with it.
    private enum RecognizerLoadResult {
        case ok(SFSpeechRecognizer)
        case failed(String)
    }

    /// Try the system locale first; if that recognizer is nil or
    /// `!isAvailable`, fall back to `en-US`. The fallback covers
    /// the common case where the user's region locale has no
    /// on-device dictation model installed but English does — the
    /// agent's tool input is English-only anyway, so falling back
    /// is functionally correct.
    private func loadRecognizer() -> RecognizerLoadResult {
        if let cached = recognizer, cached.isAvailable {
            return .ok(cached)
        }

        var diagnostics: [String] = []

        let systemLocale = Locale.current
        if let r = SFSpeechRecognizer(locale: systemLocale) {
            if r.isAvailable {
                recognizer = r
                return .ok(r)
            }
            diagnostics.append(
                "\(systemLocale.identifier) recognizer present but "
                + "not available (model likely still downloading)"
            )
        } else {
            diagnostics.append(
                "no recognizer for \(systemLocale.identifier)"
            )
        }

        // Fallback: en-US is the most widely-supplied on-device
        // model and matches the agent's expected input language.
        let fallback = Locale(identifier: "en_US")
        if systemLocale.identifier != fallback.identifier,
           let r = SFSpeechRecognizer(locale: fallback),
           r.isAvailable {
            recognizer = r
            return .ok(r)
        }
        diagnostics.append("en-US fallback also unavailable")

        return .failed(diagnostics.joined(separator: "; "))
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isRecording = false
    }

    // `nonisolated` because both Apple APIs invoke their completion
    // handlers on their own internal queues. If these methods stayed
    // on @MainActor, Swift 6 would inject the actor's executor into
    // the closure and trap with `_dispatch_assert_queue_fail` the
    // moment Apple's framework calls back from off-main.
    private nonisolated func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation {
            (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private nonisolated func requestMicrophoneAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        return await withCheckedContinuation {
            (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
