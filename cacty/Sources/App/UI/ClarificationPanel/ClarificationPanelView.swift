import SwiftUI

/// Bottom-center panel that surfaces the head pending
/// clarification request. Layout:
///
/// - Question text (one line; truncates if too long)
/// - 0–4 choice buttons (rendered as a wrapping HStack)
/// - Free-form text field (always present; Enter submits)
/// - Skip control (always present per `plan.md` — "≥2 options
///   or skip options")
///
/// Like `ApprovalBarView`, the body ALWAYS returns a fixed
/// frame even when the queue is empty (transparent placeholder)
/// to avoid the NSISEngine recursion crash seen with
/// preferredContentSize + a toggling-empty SwiftUI body.
struct ClarificationPanelView: View {
    let coordinator: ClarificationCoordinator

    /// Free-form text state, scoped to the currently-shown
    /// request id. Reset to empty whenever the head item changes
    /// so a deferred answer doesn't leak into the next prompt.
    @State private var freeformText: String = ""
    @State private var lastShownID: UUID?

    var body: some View {
        ZStack {
            if let head = coordinator.pending.first {
                content(for: head)
                    .onAppear { resetTextIfNeeded(for: head.id) }
                    .onChange(of: head.id) { _, newID in
                        resetTextIfNeeded(for: newID)
                    }
            } else {
                Color.clear
            }
        }
        .frame(width: 520, height: 160)
        .animation(.easeInOut(duration: 0.15), value: coordinator.pending.first?.id)
    }

    @ViewBuilder
    private func content(for head: ClarificationCoordinator.PendingItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 14))
                Text(head.request.question)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
            }

            if !head.request.choices.isEmpty {
                // Choices laid out as a horizontal wrap. SwiftUI
                // doesn't have a built-in FlowLayout < iOS 16
                // equivalent for macOS — Phase 1 keeps it simple
                // with a single-row HStack that truncates if
                // choices overflow. Multi-line wrapping is
                // Phase-4 polish if real prompts hit the limit.
                HStack(spacing: 6) {
                    ForEach(Array(head.request.choices.enumerated()), id: \.offset) { idx, choice in
                        Button(choice) {
                            coordinator.selectChoice(head.id, index: idx)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                TextField("Type an answer…", text: $freeformText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        coordinator.submitFreeform(head.id, text: freeformText)
                        freeformText = ""
                    }
                Button("Skip") {
                    coordinator.skip(head.id)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Skip")
            }
        }
        .padding(14)
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

    private func resetTextIfNeeded(for id: UUID) {
        if lastShownID != id {
            freeformText = ""
            lastShownID = id
        }
    }
}
