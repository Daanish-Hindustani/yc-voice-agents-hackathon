import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.cacty", category: "dots-panel")

/// Same shape as `NonKeyApprovalPanel`. The dot strip is buttons-
/// only (no text input), so we can refuse key status entirely
/// and avoid focus-yank flashes when the user clicks the kill
/// button. See `ApprovalBarPanel.swift` for the long-form
/// rationale.
private final class NonKeyDotsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts `TaskDotsView` in a borderless, non-activating, all-Spaces
/// floating panel pinned to the top-right of the primary display.
///
/// The panel configuration here is **load-bearing** for the
/// product's background guarantee — these flags together mean:
///
/// - `.nonactivatingPanel` + `.borderless`: clicks don't activate
///   Cacty.app or switch the frontmost app.
/// - `.canJoinAllSpaces`: dots are visible on every Space, the
///   user doesn't lose them by switching desktops.
/// - `.stationary`: the panel doesn't follow Mission Control's
///   zoom animation; it stays where it is.
/// - `.ignoresCycle`: ⌘\` window-cycle skips us, so the user
///   never lands inside the dot strip.
/// - `level = .statusBar`: floats above ordinary windows but
///   below system overlays (volume, brightness).
/// - `hidesOnDeactivate = false`: stays visible when Cacty.app
///   loses focus (which, given `LSUIElement = true`, is always).
///
/// **Do not soften any of these flags** without re-reading
/// `CLAUDE.md` § "The hard constraint." The product's own UI is
/// held to the same no-foreground rule as the agent.
@MainActor
final class TaskDotsPanel {
    private let panel: NSPanel
    private let model: TaskDotsViewModel

    /// Pixels of inset from the screen's right edge. Larger
    /// values move the strip further left — chosen to clear
    /// system menu-bar items (Control Center, clock, battery)
    /// on M-series MacBooks where the notch + dense menu items
    /// can push UI off the visible region.
    private static let rightInset: CGFloat = 96

    /// Pixels of inset from the top of the visible screen area
    /// (i.e. below the menu bar). Generous enough to clear the
    /// MacBook notch region on M-series displays where the
    /// "visible frame" still overlaps the camera housing for
    /// menu-bar-level items.
    private static let topInset: CGFloat = 60

    init(model: TaskDotsViewModel) {
        self.model = model

        let hosting = NSHostingController(rootView: TaskDotsView(model: model))
        // Deliberately NOT setting `sizingOptions =
        // [.preferredContentSize]`. The dot strip's intrinsic
        // width changes whenever a dot is added/removed, and
        // pairing that with preferredContentSize triggered an
        // NSISEngine recursion crash at launch (same shape as
        // the ApprovalBarPanel fix in this PR). The panel keeps
        // its fixed 180×40 contentRect; the SwiftUI view aligns
        // itself inside that frame via a trailing Spacer.

        // Borderless + nonactivating; the SwiftUI view renders
        // the capsule chrome itself. `.hudWindow` was tried
        // earlier but limits visual control — we want gradient
        // fills + animated glow that the system HUD chrome
        // doesn't expose.
        let panel = NonKeyDotsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // Setting `contentViewController` triggers AppKit to fit
        // the panel's frame to the hosting view's intrinsic size,
        // which is 0×0 before SwiftUI's first layout pass — so
        // the panel ends up zero-sized and invisible. Pin the
        // size back to the contentRect dimensions explicitly so
        // the panel matches the SwiftUI view's `.frame(width:
        // 260, height: 48)`.
        panel.setContentSize(NSSize(width: 260, height: 48))
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // User can drag the HUD by its background — pure
        // AppKit, no SwiftUI gesture needed. Buttons inside
        // (the kill ✕ on hover) still receive clicks; the
        // drag only fires on non-control hit-tested regions.
        panel.isMovableByWindowBackground = true
        // `.fullScreenAuxiliary` is load-bearing: without it the
        // panel disappears whenever the user is in a fullscreen
        // app (the most common Cacty scenario — running an agent
        // task while Discord/Chrome/Cursor are fullscreen). This
        // was the actual reason the previous strip was invisible
        // on the user's machine.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        // `.floating` is the standard for HUD overlays — well
        // above ordinary windows, but below `.popUpMenu` which
        // empirically gets hidden during fullscreen-app overlay
        // animations on macOS 26 (the user's setup). Combined
        // with `.fullScreenAuxiliary` above, this is the
        // configuration AppKit's own status-item code uses.
        panel.level = .floating
        panel.ignoresMouseEvents = false

        self.panel = panel
    }

    /// Position in the top-right of the primary screen and show
    /// without activating the app. Idempotent.
    func show() {
        positionInTopRight()
        panel.orderFrontRegardless()
        log.info("dots panel ordered front at frame=\(NSStringFromRect(self.panel.frame), privacy: .public), level=\(self.panel.level.rawValue, privacy: .public), visible=\(self.panel.isVisible, privacy: .public)")
        model.start()
    }

    func hide() {
        panel.orderOut(nil)
        model.stop()
    }

    /// Current screen-coordinate frame of the HUD pill. The
    /// `LivePreviewPanel` reads this to anchor itself just below
    /// the HUD — even after the user drags the HUD to a new
    /// position via `isMovableByWindowBackground`.
    var currentFrame: NSRect { panel.frame }

    private func positionInTopRight() {
        // `NSScreen.main` is the screen containing the key window
        // — but Cacty is LSUIElement with a non-key panel, so
        // `.main` is sometimes nil or refers to a screen the user
        // is not currently looking at. Fall back to the first
        // entry in `NSScreen.screens`, which is the primary
        // display in display-arrangement order.
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            log.error("no NSScreen available for positioning")
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(
            x: visible.maxX - size.width - Self.rightInset,
            y: visible.maxY - size.height - Self.topInset
        )
        panel.setFrameOrigin(origin)
        log.debug("positioned dots panel: screen.visibleFrame=\(NSStringFromRect(visible), privacy: .public), origin=\(NSStringFromPoint(origin), privacy: .public)")
    }
}
