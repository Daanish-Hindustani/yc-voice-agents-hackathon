import SwiftUI

/// Bottom-center pill that surfaces the head pending approval.
/// Approve = green ✓, Deny = red ✗, Enter activates Approve to
/// match Claude-Code's bar behavior. Hidden when the queue is
/// empty (the host panel orders out).
///
/// Per `CLAUDE.md` § PTT: this surface accepts mouse + Return only.
/// Fn always means "start a new task." Don't add a Fn binding here.
struct ApprovalBarView: View {
    let coordinator: ApprovalCoordinator

    /// The hosting view ALWAYS returns a fixed-size body — even
    /// when `pending` is empty. A previous version used
    /// `if let head = coordinator.pending.first { ... }` and an
    /// otherwise-empty view; combined with NSHostingController's
    /// `preferredContentSize` sizing, that produced a layout
    /// feedback loop in NSISEngine when the queue toggled
    /// non-empty → empty (stack overflow in
    /// `_updateSimpleAutoresizingConstraints`). Stable frame +
    /// opacity-hide avoids it.
    var body: some View {
        ZStack {
            if let head = coordinator.pending.first {
                content(for: head)
            } else {
                Color.clear
            }
        }
        .frame(width: 480, height: 56)
        .animation(.easeInOut(duration: 0.15), value: coordinator.pending.first?.id)
    }

    @ViewBuilder
    private func content(for head: ApprovalCoordinator.Request) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(head.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(head.toolName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                coordinator.deny(head.id)
            } label: {
                Label("Deny", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Deny")

            Button {
                coordinator.approve(head.id)
            } label: {
                Label("Approve", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .help("Approve")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(radius: 12, y: 4)
    }
}
