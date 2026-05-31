import SwiftUI

/// Console window content. One row per task — newest first —
/// with prompt, status, age, and an end-task button for the
/// running ones. Phase 1 surface; Phase 4 expands with
/// trajectory replay + memory inspector.
struct ConsoleView: View {
    let model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.summaries.isEmpty {
                emptyState
            } else {
                List(model.summaries) { summary in
                    ConsoleRowView(summary: summary) {
                        model.cancel(summary.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .foregroundStyle(.blue)
            Text("Tasks")
                .font(.headline)
            Spacer()
            Text("\(model.summaries.count)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No tasks yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Hold Fn and speak a task, or use the menu-bar text input.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row per task. Status pill on the left, prompt + age on
/// the right, end-task button on running tasks. Pulled out so
/// SwiftUI can diff per-row efficiently as new tasks land.
private struct ConsoleRowView: View {
    let summary: AgentSupervisor.TaskSummary
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.prompt)
                    .font(.system(size: 13))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)
                    Text("•").foregroundStyle(.tertiary)
                    Text(relativeStart)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isRunning {
                Button(action: onCancel) {
                    Label("End", systemImage: "xmark.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .help("End task")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var isRunning: Bool {
        if case .running = summary.status { return true }
        return false
    }

    private var statusBadge: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .padding(.top, 5)
    }

    private var statusColor: Color {
        switch summary.status {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private var statusText: String {
        switch summary.status {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Short human age — "12s ago", "3m ago". Uses
    /// `RelativeDateTimeFormatter` so the localization is right
    /// and the strings adapt to whatever locale macOS is set to.
    private var relativeStart: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: summary.startedAt, relativeTo: Date()
        )
    }
}
