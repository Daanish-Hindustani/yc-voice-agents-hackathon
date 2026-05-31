import AppKit
import Automation
import SwiftUI

/// Same `canBecomeKey = false` discipline as the other Cacty
/// panels — the preview is read-only, so refusing key status
/// keeps focus on whatever the user was actually using.
private final class NonKeyPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts `LivePopoverView` in its own floating panel. Shown when
/// `state.focus != nil` (the user is hovering a running dot
/// whose worker has reported a window target), hidden otherwise.
/// Positioned just below the supplied anchor frame so it tracks
/// the HUD pill — including after the user drags it.
///
/// Why a separate panel rather than SwiftUI `.popover`: the
/// SwiftUI popover requires its host window to be capable of
/// becoming key. Our `NonKeyDotsPanel` deliberately refuses
/// key status to avoid focus-yank flashes; the popover then
/// either fails to appear or appears without proper layout.
/// A dedicated `NonKeyPreviewPanel` sidesteps the issue
/// entirely while preserving the no-focus-steal contract.
@MainActor
final class LivePreviewPanel {
    private let panel: NSPanel
    private let state: LivePreviewState
    private let hudFrameProvider: @MainActor () -> NSRect
    private var observer: Task<Void, Never>?

    private static let previewWidth: CGFloat = 372    // 360 + 12 chrome
    private static let previewHeight: CGFloat = 264   // 240 + 24 chrome
    private static let gapBelowHUD: CGFloat = 8

    init(
        state: LivePreviewState,
        engine: Engine,
        hudFrameProvider: @escaping @MainActor () -> NSRect
    ) {
        self.state = state
        self.hudFrameProvider = hudFrameProvider

        let hosting = NSHostingController(
            rootView: LivePopoverView(engine: engine, state: state)
        )

        let panel = NonKeyPreviewPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.previewWidth,
                height: Self.previewHeight
            ),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(
            width: Self.previewWidth, height: Self.previewHeight
        ))
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Mirror HUD's visibility flags so the preview shows in
        // fullscreen Spaces and never sits behind the HUD.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.level = .floating
        panel.ignoresMouseEvents = false

        self.panel = panel
    }

    /// Begin observing the shared state. Poll-based for parity
    /// with the other panels; SwiftUI's @Observable doesn't give
    /// us a synchronous notification surface usable from AppKit.
    /// 100ms cadence keeps hover→show latency well under
    /// human-perception threshold without measurable cost.
    func start() {
        observer?.cancel()
        observer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        observer?.cancel()
        observer = nil
        panel.orderOut(nil)
    }

    private func refresh() {
        if state.focus == nil {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        positionBelowHUD()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Right-edge align the preview under the HUD so the two
    /// panels read as a stacked unit even after the user drags
    /// the HUD around the screen.
    private func positionBelowHUD() {
        let hud = hudFrameProvider()
        guard hud.width > 0 else { return }
        let size = panel.frame.size
        // Cocoa Y is bottom-up; HUD `minY` is its bottom edge.
        // Place preview such that its top edge sits a small gap
        // below the HUD's bottom edge.
        let origin = CGPoint(
            x: hud.maxX - size.width,
            y: hud.minY - size.height - Self.gapBelowHUD
        )
        panel.setFrameOrigin(origin)
    }
}
