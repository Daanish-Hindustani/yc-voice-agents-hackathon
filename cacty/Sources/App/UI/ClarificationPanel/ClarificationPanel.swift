import AppKit
import SwiftUI

/// Bottom-center floating panel that hosts `ClarificationPanelView`.
///
/// Background-safety differs slightly from `ApprovalBarPanel`:
/// approvals are buttons-only so we forbid key-window status to
/// prevent focus yank. Clarifications include a TextField — text
/// input requires key-window status. We use AppKit's
/// `becomesKeyOnlyIfNeeded = true` so the panel takes key status
/// **only when the user actively clicks the text field** (their
/// own action; not Cacty stealing focus). Choice/Skip buttons
/// fire through the responder chain on mouse events alone and
/// don't promote the panel to key.
///
/// Trade-off documented in `plan.md` § Phase 5: voice answers to
/// clarifications were deliberately removed (Fn is reserved for
/// new-task PTT). When typing is the answer surface, briefly
/// taking key window on field-click is the minimum cost of
/// supporting it. The pre-typing UX (show panel, no flash) is
/// preserved.
@MainActor
final class ClarificationPanel {
    private let panel: NSPanel
    private let coordinator: ClarificationCoordinator
    private var observer: Task<Void, Never>?

    /// Mirrors `ApprovalBarPanel.bottomInset` so the two panels
    /// share a baseline. The clarification panel is taller so it
    /// will appear slightly above where the approval pill sits;
    /// the two never coexist in Phase 1 (one task = one panel
    /// active at a time, and clarification never overlaps an
    /// approval since `ask_user` returns before the next
    /// engine-touching tool can be classified).
    private static let bottomInset: CGFloat = 24

    init(coordinator: ClarificationCoordinator) {
        self.coordinator = coordinator

        let hosting = NSHostingController(
            rootView: ClarificationPanelView(coordinator: coordinator)
        )
        // No sizingOptions for the same reason as ApprovalBarPanel
        // — fixed view frame matches the panel's contentRect, and
        // toggling preferredContentSize caused an NSISEngine
        // recursion crash in an earlier revision.

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // Pin size — see TaskDotsPanel.swift for rationale.
        panel.setContentSize(NSSize(width: 520, height: 160))
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
        // Key window only when the embedded TextField needs it.
        // Show-time, the panel renders without yanking focus.
        panel.becomesKeyOnlyIfNeeded = true

        self.panel = panel
    }

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

    private func refresh() {
        if coordinator.pending.isEmpty {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible {
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        } else {
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
