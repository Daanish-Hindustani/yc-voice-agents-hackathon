import AppKit
import SwiftUI

/// NSPanel that never accepts key-window status, even when its
/// content view receives a click.
///
/// `.nonactivatingPanel` alone does NOT prevent the panel from
/// becoming the *key window* on a button click — it only prevents
/// the *app* from activating. But a key-window switch is enough
/// to make Cacty's panel briefly intercept keyboard focus, which:
///
/// - Causes a visible "flash" as Discord (or whatever was
///   frontmost) loses key-window status
/// - Drops the keystroke buffer and IME state of whatever the
///   user was typing into
/// - Makes the immediately-following `press_key Return` ambiguous
///   about which app it lands in
///
/// Overriding `canBecomeKey` (and `canBecomeMain`) to return
/// `false` blocks the key-window switch entirely. SwiftUI
/// buttons inside still receive mouse events through the content
/// view's responder chain — they don't need key status to fire
/// their action.
private final class NonKeyApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Bottom-center floating panel that hosts `ApprovalBarView`.
/// Same NSPanel discipline as `TaskDotsPanel` — non-activating,
/// all-Spaces, status-bar level — so showing the approval bar
/// never steals focus from whatever the user is actively typing
/// into. See `TaskDotsPanel` for the full rationale on each
/// flag; the constraints are identical.
///
/// Visibility is driven by the coordinator's `pending` queue:
/// `refresh()` (call from a SwiftUI `.onChange` or a polling
/// observer) shows the panel when the queue is non-empty, hides
/// it when empty. The panel doesn't poll on its own — push
/// model from the app shell.
@MainActor
final class ApprovalBarPanel {
    private let panel: NSPanel
    private let coordinator: ApprovalCoordinator
    private var observer: Task<Void, Never>?

    /// Pixels of inset from the screen's bottom edge. Mirrors
    /// `TaskDotsPanel.edgeInset` for visual symmetry across the
    /// two surfaces.
    private static let bottomInset: CGFloat = 24

    init(coordinator: ApprovalCoordinator) {
        self.coordinator = coordinator

        let hosting = NSHostingController(
            rootView: ApprovalBarView(coordinator: coordinator)
        )
        // Deliberately NOT setting `sizingOptions =
        // [.preferredContentSize]`: the SwiftUI view has a fixed
        // 480x56 frame, and pairing preferredContentSize with a
        // toggling-empty view body produced an NSISEngine
        // recursion crash in an earlier revision. The panel's
        // contentRect below pins the size; the view fills it.

        let panel = NonKeyApprovalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // Pin size back to the contentRect dimensions — see
        // TaskDotsPanel.swift for the long-form explanation of
        // why this is necessary (contentViewController reset to
        // SwiftUI's zero-intrinsic-size before first layout).
        panel.setContentSize(NSSize(width: 480, height: 56))
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle,
        ]
        panel.level = .statusBar
        panel.ignoresMouseEvents = false

        self.panel = panel
    }

    /// Wire the panel to the coordinator's `pending` queue. Polls
    /// every 200ms — push-style observation would require an
    /// AsyncStream from the coordinator, which adds plumbing for
    /// no user-visible win at this cadence. The poll is cheap
    /// (one MainActor read of an array length).
    func start() {
        observer?.cancel()
        observer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        observer?.cancel()
        observer = nil
        panel.orderOut(nil)
    }

    /// Show / hide / reposition based on current queue state.
    /// Idempotent — safe to call repeatedly.
    private func refresh() {
        if coordinator.pending.isEmpty {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        } else {
            // Reposition every refresh in case the screen
            // configuration changed (display added/removed,
            // resolution change). Cheap, and the alternative
            // (NSScreen change notifications) is more code for
            // the same outcome.
            positionAtBottomCenter()
        }
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomInset
        )
        panel.setFrameOrigin(origin)
    }
}
