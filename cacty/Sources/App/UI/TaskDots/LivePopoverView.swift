import AppKit
import Automation
import SwiftUI

/// Live capture preview hosted inside `LivePreviewPanel`. Reads
/// the current `(pid, windowId)` target from a shared
/// `LivePreviewState` observable so the user can hover one dot,
/// then another, and the same panel re-targets without
/// teardown.
///
/// The stream is bound to the focus value: a new focus tears
/// down the prior stream and starts a fresh one. The view also
/// auto-cancels on disappear so the cost only runs while the
/// panel is on screen.
///
/// Captured frames do not include the system cursor, so we
/// overlay a green pointer at the live cursor position whenever
/// it lies inside the focused window's screen-bounds. Tasks
/// that don't drive the cursor (pure AX writes, etc.) leave the
/// cursor outside the window and the overlay hides itself —
/// matching the "show cursor only when the agent is using it"
/// requirement.
@MainActor
struct LivePopoverView: View {
    let engine: Engine
    let state: LivePreviewState

    @State private var image: NSImage?
    @State private var streamTask: Task<Void, Never>?
    @State private var cursorTask: Task<Void, Never>?
    @State private var ended = false
    @State private var windowBounds: WindowBounds?
    @State private var cursorScreenPos: CGPoint?

    private static let previewWidth: CGFloat = 360
    private static let previewHeight: CGFloat = 240
    private static let captureFps: Int = 30
    private static let cursorPollIntervalNs: UInt64 = 33_000_000   // ~30 Hz

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    imageLayer(in: geo.size)
                    if let p = cursorOverlayPoint(in: geo.size) {
                        GreenCursorMark()
                            .position(x: p.x, y: p.y)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(width: Self.previewWidth, height: Self.previewHeight)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(6)
        .onAppear {
            restartStream(for: state.focus)
            startCursorPoll()
        }
        .onDisappear {
            stopStream()
            stopCursorPoll()
        }
        .onChange(of: state.focus) { _, newFocus in
            restartStream(for: newFocus)
            refreshWindowBounds(for: newFocus)
        }
    }

    @ViewBuilder
    private func imageLayer(in size: CGSize) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        } else if state.focus == nil {
            centeredText("waiting for first window action…", in: size)
        } else if ended {
            centeredText("preview unavailable", in: size)
        } else {
            ZStack {
                Color.clear
                ProgressView().controlSize(.small)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func centeredText(_ text: String, in size: CGSize) -> some View {
        ZStack {
            Color.clear
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: size.width, height: size.height)
    }

    private func restartStream(for focus: AgentSupervisor.Focus?) {
        stopStream()
        image = nil
        ended = false
        refreshWindowBounds(for: focus)
        guard let focus else { return }
        let stream = engine.captureStream(
            pid: focus.pid, windowId: focus.windowId, fps: Self.captureFps
        )
        streamTask = Task { @MainActor in
            for await screenshot in stream {
                if Task.isCancelled { break }
                self.image = NSImage(data: screenshot.imageData)
            }
            self.ended = true
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func startCursorPoll() {
        cursorTask?.cancel()
        cursorTask = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                // Read the agent-cursor overlay's tip position
                // (`AgentCursorRenderer.shared.position`), NOT the
                // real system cursor. Cacty's clicks go via
                // `CGEventPostToPid` — they never warp the real
                // cursor — so `engine.getCursorPosition()` would
                // stay frozen during a task. The overlay's
                // position is what `cursorPreFlight` animates and
                // what the user sees on the real screen, so
                // mirroring it in the preview keeps the two views
                // in sync.
                let p = AgentCursorRenderer.shared.position
                // Renderer uses (-200, -200) as the "no motion
                // yet" sentinel; treat anything left of x = -100
                // as "no cursor to show" (matches the renderer's
                // own draw-guard).
                self.cursorScreenPos = (p.x > -100)
                    ? CGPoint(x: p.x, y: p.y)
                    : nil
                // Refresh window bounds at ~3 Hz so a moved/resized
                // window doesn't desync the overlay placement.
                if tick % 10 == 0 {
                    refreshWindowBounds(for: state.focus)
                }
                tick &+= 1
                try? await Task.sleep(nanoseconds: Self.cursorPollIntervalNs)
            }
        }
    }

    private func stopCursorPoll() {
        cursorTask?.cancel()
        cursorTask = nil
        cursorScreenPos = nil
    }

    private func refreshWindowBounds(for focus: AgentSupervisor.Focus?) {
        guard let focus else { windowBounds = nil; return }
        let windows = engine.listWindows(forPid: focus.pid)
        windowBounds = windows.first(where: { $0.id == focus.windowId })?.bounds
    }

    /// Map the global cursor position into the view's local
    /// coordinate space, accounting for `.scaledToFit` aspect
    /// letterboxing. Returns `nil` when the cursor is outside
    /// the focused window (i.e. the agent isn't currently
    /// driving the cursor there).
    private func cursorOverlayPoint(in containerSize: CGSize) -> CGPoint? {
        guard
            let bounds = windowBounds,
            let cursor = cursorScreenPos,
            bounds.width > 0, bounds.height > 0
        else { return nil }

        let rx = cursor.x - CGFloat(bounds.x)
        let ry = cursor.y - CGFloat(bounds.y)
        let w = CGFloat(bounds.width)
        let h = CGFloat(bounds.height)
        // Previously this guard returned nil when the cursor's
        // projection landed outside the window rect — but
        // CGWindowBounds excludes Chrome's drop-shadow halo while
        // `AgentCursorRenderer.position` includes the shadow
        // region, so a click on a button near the window edge can
        // sit a few points outside `bounds` and the overlay
        // silently vanished. The view is `.clipShape`-clipped, so
        // a far-out cursor just gets cropped — let SwiftUI handle
        // off-canvas positions instead of pre-filtering. We still
        // bail when the cursor is wildly far (>200pt margin) so a
        // stale sentinel position can't draw inside the popover.
        let margin: CGFloat = 200
        guard
            rx >= -margin, ry >= -margin,
            rx <= w + margin, ry <= h + margin
        else { return nil }

        let containerAspect = containerSize.width / containerSize.height
        let windowAspect = w / h
        let displayW: CGFloat
        let displayH: CGFloat
        if windowAspect > containerAspect {
            displayW = containerSize.width
            displayH = containerSize.width / windowAspect
        } else {
            displayH = containerSize.height
            displayW = containerSize.height * windowAspect
        }
        let offsetX = (containerSize.width - displayW) / 2
        let offsetY = (containerSize.height - displayH) / 2
        let scale = displayW / w
        return CGPoint(
            x: offsetX + rx * scale,
            y: offsetY + ry * scale
        )
    }
}

/// Green pointer rendered at the cursor location inside the
/// preview. Uses SF Symbol `cursorarrow.fill` so the shape
/// stays sharp at any preview size; the dual shadow gives it a
/// green halo for visibility and a thin dark edge so it reads
/// on light backgrounds too.
private struct GreenCursorMark: View {
    var body: some View {
        Image(systemName: "cursorarrow.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Color(red: 0x36/255, green: 0xD3/255, blue: 0x6B/255))
            .shadow(
                color: Color(red: 0x36/255, green: 0xD3/255, blue: 0x6B/255)
                    .opacity(0.8),
                radius: 6
            )
            .shadow(color: .black.opacity(0.55), radius: 1)
            // SF cursor symbol's hot-spot is offset from the
            // glyph center; nudge so the tip lands on the
            // reported screen coordinate.
            .offset(x: 5, y: 6)
    }
}
