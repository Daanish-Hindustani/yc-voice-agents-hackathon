import AppKit
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "com.cacty", category: "ptt")

/// Global Fn-key push-to-talk detector.
///
/// Promotes the throwaway pattern from `Sources/FnSpike/main.swift`
/// (validated Phase 0 risk #4) into a production component that
/// publishes press/release transitions through `@MainActor`
/// closures suitable for SwiftUI binding.
///
/// Two preconditions the user has to handle once:
///
/// 1. System Settings → Keyboard → "Press 🌐 key to:" must be
///    set to "Do Nothing." Otherwise macOS swallows Fn for
///    dictation before our `CGEventTap` sees it. The onboarding
///    flow (Phase 4) walks the user through this; for now,
///    `start()` returns `.missingFnRouting` if we suspect this
///    is the case (we can't detect it directly — the symptom is
///    "no events fire" which manifests as a hung PTT).
/// 2. Input Monitoring permission must be granted. `CGEvent.tapCreate`
///    returns `nil` without it; `start()` surfaces this as
///    `.permissionDenied` and the supervisor / onboarding shows
///    the system-settings deeplink.
///
/// The handler runs on the main run loop because the
/// `CGEventTap` callback is invoked on the main thread by
/// design; we don't need a background queue for the polling.
@MainActor
final class FnKeyHandler {
    enum StartError: Error, CustomStringConvertible {
        case permissionDenied
        case missingFnRouting

        var description: String {
            switch self {
            case .permissionDenied:
                return "Input Monitoring permission denied. Grant in "
                    + "System Settings → Privacy & Security → Input Monitoring."
            case .missingFnRouting:
                return "Fn key not delivering flagsChanged events. "
                    + "Check System Settings → Keyboard → Press 🌐 key to: "
                    + "Do Nothing."
            }
        }
    }

    /// Fired when Fn transitions from up to down. Called on the
    /// main actor. The Coordinator subscribes here to start audio
    /// capture for the PTT session.
    var onPress: (() -> Void)?

    /// Fired when Fn transitions from down to up. Called on the
    /// main actor. The Coordinator subscribes here to finalize
    /// the transcript and hand it to the supervisor.
    var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnHeld = false

    deinit {
        // Tearing down the tap reference removes the source from
        // the run loop. We can't await main-actor isolation here
        // (`deinit` is nonisolated), but the run loop drains
        // sources on the main thread.
    }

    /// Install the event tap. Idempotent — calling twice is a
    /// no-op. Returns `false` on permission denial; the caller
    /// (`AppCoordinator`) surfaces the error to the menu UI.
    @discardableResult
    func start() -> Result<Void, StartError> {
        if eventTap != nil { return .success(()) }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
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
                let handler = Unmanaged<FnKeyHandler>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                // Hop to MainActor to invoke the SwiftUI-bound
                // closures. The CGEventTap callback runs on the
                // main thread already, but Swift 6 strict
                // concurrency requires the explicit boundary.
                Task { @MainActor in
                    handler.handleFlagsChanged(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return .failure(.permissionDenied)
        }

        let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, tap, 0
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return .success(())
    }

    /// Remove the tap. Used by tests and (Phase 4) the "pause
    /// PTT" surface when the user wants to type a multi-line
    /// prompt elsewhere without the agent intercepting Fn.
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), source, .commonModes
            )
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Internal

    private func handleFlagsChanged(_ event: CGEvent) {
        let isFnSet = event.flags.contains(.maskSecondaryFn)
        if isFnSet, !fnHeld {
            fnHeld = true
            log.debug("Fn down")
            onPress?()
        } else if !isFnSet, fnHeld {
            fnHeld = false
            log.debug("Fn up")
            onRelease?()
        }
    }
}
