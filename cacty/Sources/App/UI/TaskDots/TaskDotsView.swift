import SwiftUI

/// SwiftUI strip of colored dots rendered into the floating
/// top-right `TaskDotsPanel`. One dot per active or recently-
/// terminated task; color reflects status (see `dotColor`).
///
/// Hover an in-flight (`.running`) dot to reveal a kill control:
/// click it to cancel the task. Terminated dots (succeeded /
/// failed / cancelled) do not expose the control — there's
/// nothing to cancel.
///
/// PR 1.7 adds a hover popover with the live engine capture
/// stream; the dot itself stays the same. Keep this view dumb —
/// no business logic, no supervisor reads. The view model
/// (`TaskDotsViewModel`) owns all of that.
struct TaskDotsView: View {
    let model: TaskDotsViewModel

    /// `true` when any dot represents a running task. Drives the
    /// pill's tinted background + status text so the user can
    /// tell at a glance "Cacty is doing something."
    private var hasRunningTask: Bool {
        model.dots.contains { dot in
            if case .running = dot.status { return true }
            return false
        }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            capsule
        }
        .frame(width: 260, height: 48)
        .animation(.easeInOut(duration: 0.28), value: hasRunningTask)
        .animation(.easeInOut(duration: 0.2), value: model.dots)
    }

    /// The chrome itself — capsule-shaped, glass background,
    /// gradient + glow when active. Pulled into its own view to
    /// keep the body readable.
    private var capsule: some View {
        HStack(spacing: 10) {
            iconBadge
            Text(hasRunningTask ? "Working" : "Cacty")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if !model.dots.isEmpty {
                Divider()
                    .frame(height: 14)
                    .overlay(Color.white.opacity(0.18))
                    .padding(.horizontal, 2)
            }
            ForEach(model.dots) { dot in
                DotItemView(dot: dot, model: model) {
                    model.cancelDot(dot.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(capsuleFill, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderGradient, lineWidth: 1)
        )
        .shadow(
            color: hasRunningTask
                ? Color(red: 0.31, green: 0.55, blue: 1.0).opacity(0.45)
                : Color.black.opacity(0.35),
            radius: hasRunningTask ? 14 : 10,
            x: 0,
            y: hasRunningTask ? 4 : 3
        )
    }

    private var iconBadge: some View {
        ZStack {
            // Soft halo behind the icon when running — visual
            // anchor that reads as "live" without screaming.
            if hasRunningTask {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.48, green: 0.74, blue: 1.0).opacity(0.55),
                                Color(red: 0.48, green: 0.74, blue: 1.0).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 14
                        )
                    )
                    .frame(width: 26, height: 26)
            }
            Image(systemName: hasRunningTask ? "sparkles" : "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    hasRunningTask
                        ? LinearGradient(
                            colors: [
                                Color(red: 0.78, green: 0.91, blue: 1.0),
                                Color(red: 0.45, green: 0.72, blue: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                          )
                        : LinearGradient(
                            colors: [
                                .white.opacity(0.95),
                                .white.opacity(0.7),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                          )
                )
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: hasRunningTask
                )
        }
    }

    /// Layered fill: tinted gradient when running, dark glass
    /// when idle. Both share the same near-black base so the
    /// transition between states reads as "the same pill, lit up"
    /// rather than two separate UIs.
    private var capsuleFill: AnyShapeStyle {
        if hasRunningTask {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.14, green: 0.20, blue: 0.36),
                        Color(red: 0.09, green: 0.13, blue: 0.24),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.58),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Subtle hairline that picks up the active-state tint at
    /// the top edge to suggest depth (lit from above).
    private var borderGradient: LinearGradient {
        if hasRunningTask {
            return LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.78, blue: 1.0).opacity(0.55),
                    Color.white.opacity(0.05),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color.white.opacity(0.22),
                Color.white.opacity(0.04),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Single dot + hover-to-kill overlay + hover-to-preview popover.
/// Per-dot `@State` keeps hover/preview state scoped; using a
/// single state on the parent would track hover across the
/// whole strip.
///
/// Popover behavior:
/// - Only opens for `.running` dots (terminated dots have nothing
///   live to preview).
/// - Debounced by `popoverOpenDelay` so a casual mouse-drag
///   across the strip doesn't flash a popover per dot.
/// - The popover content (`LivePopoverView`) starts its own
///   capture stream on appear and cancels on disappear, so cost
///   is paid only while the user is actively looking.
private struct DotItemView: View {
    let dot: TaskDotsViewModel.Dot
    let model: TaskDotsViewModel
    let onCancel: () -> Void

    @State private var isHovering = false
    @State private var hoverWorkTask: Task<Void, Never>?

    /// Delay between mouse-enter and preview-open. Short enough
    /// to feel responsive; long enough that a casual sweep
    /// across the strip doesn't strobe previews.
    private static let previewOpenDelay: Duration = .milliseconds(280)

    var body: some View {
        ZStack {
            Circle()
                .fill(dot.status.dotColor)
                .frame(width: 16, height: 16)
                .shadow(color: dot.status.dotColor.opacity(0.7), radius: 5)
                .opacity(isHovering && dot.isRunning ? 0 : 1)

            if isHovering && dot.isRunning {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("End task")
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            handleHoverChange(hovering)
        }
        .transition(.scale.combined(with: .opacity))
    }

    /// SwiftUI `.popover` doesn't work reliably from a non-key
    /// NSPanel host — see `LivePreviewPanel` doc for why. The
    /// hover instead writes to the shared `LivePreviewState`
    /// that an app-level `LivePreviewPanel` observes and
    /// renders.
    private func handleHoverChange(_ hovering: Bool) {
        hoverWorkTask?.cancel()
        if hovering, dot.isRunning {
            hoverWorkTask = Task { @MainActor in
                try? await Task.sleep(for: Self.previewOpenDelay)
                if Task.isCancelled { return }
                model.beginHoverPreview(dot.id)
            }
        } else {
            model.endHoverPreview()
        }
    }
}

private extension TaskDotsViewModel.Dot {
    /// `true` only for `.running`. Terminated dots are read-only.
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }
}
