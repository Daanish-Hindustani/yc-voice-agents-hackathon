import ApplicationServices
import Foundation

/// Writes the two boolean AX attributes that tell a target app "an AX client
/// is actually here, please build your full accessibility tree":
///
/// - `AXManualAccessibility` — the modern Chromium-specific hint.
/// - `AXEnhancedUserInterface` — the legacy AppleScript-era equivalent.
///
/// Chromium-family apps (Slack, Discord, VS Code, Chrome, Edge, every other
/// Electron/Blink shell) ship with their web accessibility tree off as a power
/// optimization and turn it on when they see either of these attributes flipped
/// to `true`. Native-AX apps (Finder, Calculator, TextEdit, most Cocoa apps)
/// reject both writes — harmless, but repeatedly paying the cost for those
/// targets would slow every action down, so we cache the negative outcome.
///
/// The assertion is idempotent per pid: once we've seen a pid accept at least
/// one of the two attributes, we record it and skip future writes. Pids that
/// rejected both go into a separate "known non-assertable" negative cache.
/// Callers can ask ``isKnownNonAssertable(pid:)`` to skip follow-up work
/// (observer registration, run-loop pumps) that only matters for Chromium.
public actor AXEnablementAssertion {
    private var assertedPids: Set<pid_t> = []
    private var nonAssertablePids: Set<pid_t> = []

    public init() {}

    /// Assert `AXManualAccessibility` + `AXEnhancedUserInterface` on the
    /// application root element. Returns `true` if at least one attribute
    /// write succeeded (or we've previously recorded success for this pid);
    /// returns `false` if both writes failed — in which case the pid is
    /// cached as "known non-assertable" so subsequent calls short-circuit.
    ///
    /// Short-circuits on positive cache. Writing
    /// `AXEnhancedUserInterface=true` on a Chromium-family app
    /// (Slack, Discord, Chrome, VS Code) is interpreted by the
    /// target as "an assistive technology client just connected"
    /// and triggers an internal `[NSApp activate]` — observed as a
    /// foreground flash on every `get_window_state` call.
    /// Re-asserting per snapshot was originally chosen to defend
    /// against Chromium resetting the attribute on backgrounding /
    /// tab switches / occlusion; in practice the user-visible flash
    /// is a worse failure mode than an occasionally sparse AX tree.
    /// Callers that detect a sparse tree can force re-assertion via
    /// ``invalidate(pid:)``.
    public func assert(pid: pid_t, root: AXUIElement) -> Bool {
        if nonAssertablePids.contains(pid) { return false }
        if assertedPids.contains(pid) { return true }

        let manualResult = AXUIElementSetAttributeValue(
            root, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        let enhancedResult = AXUIElementSetAttributeValue(
            root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )

        if manualResult != .success && enhancedResult != .success {
            // Only snapshot-native apps (which reject both writes) go into
            // the negative cache — prevents repeated rejected writes for
            // Finder / Calculator / TextEdit / etc. Chromium always accepts
            // at least one, so it won't land here.
            nonAssertablePids.insert(pid)
            return false
        }

        assertedPids.insert(pid)
        return true
    }

    /// Force the next ``assert(pid:root:)`` call to actually write
    /// the AX attributes again. Use when a prior snapshot returned
    /// a sparse / empty AX tree, indicating Chromium has reset
    /// `AXEnhancedUserInterface` on a state transition.
    public func invalidate(pid: pid_t) {
        assertedPids.remove(pid)
    }

    /// True if a prior ``assert(pid:root:)`` call recorded this pid as having
    /// rejected both attribute writes. Callers that only do extra work for
    /// Chromium-family targets (e.g. attaching an `AXObserver`, pumping the
    /// run loop for AX-client detection) can use this as a cheap gate.
    public func isKnownNonAssertable(pid: pid_t) -> Bool {
        nonAssertablePids.contains(pid)
    }

    /// True if this pid has already accepted at least one of the two
    /// attributes. Mainly useful for callers that want to skip the 500 ms
    /// run-loop pump on subsequent snapshots.
    public func isAlreadyAsserted(pid: pid_t) -> Bool {
        assertedPids.contains(pid)
    }
}
