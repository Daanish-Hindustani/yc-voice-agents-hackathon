import Agent
import AppKit
import Automation
import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.cacty", category: "app")

/// Cacty's SwiftUI entry point. Phase 1 PR 1.5: the menu-bar
/// shell now holds an `AppCoordinator` that wires Fn → speech →
/// supervisor → task. Hold Fn, speak, release, and a task runs
/// in the background.
///
/// API key: read from `GEMINI_API_KEY` env var. When launched
/// via `open Cacty.app`, that env var won't be set (launchd
/// gives a minimal environment); run the binary directly from a
/// shell to pick up the key:
///
/// ```bash
/// GEMINI_API_KEY=... build/Cacty.app/Contents/MacOS/Cacty
/// ```
///
/// Phase 4 onboarding will replace this with a keychain-backed
/// preference. For PR 1.5, the env-var route is intentional —
/// keeps the surface tiny while validating the wire-up.
@main
struct CactyApp: App {
    @State private var coordinator: AppCoordinator = Self.makeCoordinator()
    @State private var dotsPanel: TaskDotsPanel?

    /// Retains the loopback bridge for the app's lifetime. Started in
    /// `makeCoordinator` (production path only — unit tests construct
    /// `AppCoordinator` directly and never start a server), so an
    /// out-of-process caller (the Pipecat voice bot) can drive the same
    /// supervisor the menu-bar and Fn-PTT surfaces drive.
    ///
    /// `nonisolated(unsafe)`: written exactly once, on the main actor,
    /// during coordinator construction; never mutated afterward.
    nonisolated(unsafe) private static var taskServer: LocalTaskServer?
    @State private var approvalPanel: ApprovalBarPanel?
    @State private var clarificationPanel: ClarificationPanel?
    @State private var previewPanel: LivePreviewPanel?
    @State private var consoleWindow: ConsoleWindow?

    var body: some Scene {
        MenuBarExtra("Cacty", systemImage: menuSystemImage) {
            CactyMenuView(coordinator: coordinator, onOpenConsole: openConsole)
        }
        // `.window` (not `.menu`) so the dropdown can host a real
        // TextField. `.menu` style only allows Button/Toggle/Text.
        .menuBarExtraStyle(.window)
        .onChange(of: coordinator.state, initial: true) { _, _ in
            // The first change (initial: true) installs the dot
            // strip and approval bar; subsequent changes are no-ops
            // because show() is idempotent. SwiftUI Scenes can't
            // run logic at construction time, so we piggyback on
            // the binding.
            installDotsIfNeeded()
            installApprovalIfNeeded()
            installClarificationIfNeeded()
            installPreviewIfNeeded()
        }
    }

    @MainActor
    private func installDotsIfNeeded() {
        if dotsPanel != nil { return }
        let model = TaskDotsViewModel(
            supervisor: coordinator.supervisor,
            livePreviewState: coordinator.livePreviewState
        )
        let panel = TaskDotsPanel(model: model)
        panel.show()
        dotsPanel = panel
    }

    @MainActor
    private func installPreviewIfNeeded() {
        if previewPanel != nil { return }
        // installDotsIfNeeded ran immediately above this call,
        // so dotsPanel is guaranteed non-nil here. Strong capture
        // is intentional — both panels live for the full app
        // lifetime; the closure's job is to feed the preview the
        // HUD's current frame after every drag.
        guard let dots = dotsPanel else { return }
        let panel = LivePreviewPanel(
            state: coordinator.livePreviewState,
            engine: coordinator.supervisor.publicEngine,
            hudFrameProvider: { dots.currentFrame }
        )
        panel.start()
        previewPanel = panel
    }

    @MainActor
    private func installApprovalIfNeeded() {
        if approvalPanel != nil { return }
        let panel = ApprovalBarPanel(coordinator: coordinator.approvalCoordinator)
        panel.start()
        approvalPanel = panel
    }

    @MainActor
    private func installClarificationIfNeeded() {
        if clarificationPanel != nil { return }
        let panel = ClarificationPanel(coordinator: coordinator.clarificationCoordinator)
        panel.start()
        clarificationPanel = panel
    }

    @MainActor
    private func openConsole() {
        if let consoleWindow {
            consoleWindow.show()
            return
        }
        let model = ConsoleViewModel(supervisor: coordinator.supervisor)
        let window = ConsoleWindow(model: model)
        window.show()
        consoleWindow = window
    }

    /// SF Symbol chosen by current PTT state so the menu-bar
    /// icon itself carries a hint (recording / running / idle).
    /// The full color states for the dot UI land in PR 1.6;
    /// here we just vary the icon glyph.
    private var menuSystemImage: String {
        switch coordinator.state {
        case .idle: return "wand.and.stars"
        case .recording: return "mic.fill"
        case .transcribing: return "ellipsis.bubble"
        case .running: return "circle.dotted.circle"
        case .settling: return "checkmark.circle"
        case .blocked: return "exclamationmark.triangle"
        }
    }

    private static func makeCoordinator() -> AppCoordinator {
        let engine = Engine()
        let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        if key.isEmpty {
            log.error("GEMINI_API_KEY not set. Tasks will fail until you relaunch from a shell with it exported.")
        }
        let client = GeminiClient(apiKey: key)
        let approvalCoordinator = ApprovalCoordinator()
        let clarificationCoordinator = ClarificationCoordinator()
        let supervisor = AgentSupervisor(
            client: client,
            engine: engine,
            model: ProcessInfo.processInfo.environment["GEMINI_MODEL"]
                ?? "gemini-2.5-flash",
            approvalGate: approvalCoordinator,
            clarificationGate: clarificationCoordinator
        )
        let coordinator = AppCoordinator(
            supervisor: supervisor,
            approvalCoordinator: approvalCoordinator,
            clarificationCoordinator: clarificationCoordinator
        )

        // Start the loopback bridge so the voice bot can submit tasks
        // to this same supervisor. Loopback-only; logs (never crashes)
        // on bind failure. Port overridable via CACTY_BRIDGE_PORT.
        let bridgePort = ProcessInfo.processInfo.environment["CACTY_BRIDGE_PORT"]
            .flatMap { UInt16($0) } ?? 8765
        let server = LocalTaskServer(supervisor: supervisor, port: bridgePort)
        server.start()
        Self.taskServer = server

        // Kick off auth + Fn-tap install asynchronously. The
        // coordinator's state goes `.idle → .blocked` if auth
        // fails; the menu surface picks that up via the
        // @Observable binding.
        Task { @MainActor in
            await coordinator.start()
        }
        return coordinator
    }
}

private struct CactyMenuView: View {
    let coordinator: AppCoordinator
    let onOpenConsole: @MainActor () -> Void
    @State private var typedPrompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cacty").font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Divider()
            // Text-input testing surface — bypasses Fn+speech so
            // testers can submit a prompt directly. Enter submits.
            TextField("Type a task and press Enter…", text: $typedPrompt)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
                .onSubmit {
                    let prompt = typedPrompt
                    typedPrompt = ""
                    coordinator.submitTextPrompt(prompt)
                }
            Divider()
            Button("Open Console…") {
                onOpenConsole()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("About Cacty") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
            Divider()
            Button("Quit Cacty") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle:
            return "Hold Fn to start a task."
        case .recording(let partial):
            return partial.isEmpty ? "Listening…" : "🎙 \(partial)"
        case .transcribing:
            return "Transcribing…"
        case .running(_, let prompt):
            return "Running: \(prompt)"
        case .settling(let text):
            let trimmed = text.prefix(80)
            return String(trimmed)
        case .blocked(let reason):
            return "⚠ \(reason)"
        }
    }
}
