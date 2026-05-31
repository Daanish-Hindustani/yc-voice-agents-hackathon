import AppKit
import SwiftUI

/// Wraps `ConsoleView` in a regular `NSWindow` (not a panel —
/// the Console is a foreground tool the user explicitly opens
/// from the menu bar; it MAY take focus, accept text input, and
/// be resized like any normal window).
///
/// One window per app, lazy-created on first open. Subsequent
/// opens just bring the existing window to front so the user's
/// position / size persist within the session.
@MainActor
final class ConsoleWindow {
    private let window: NSWindow
    private let model: ConsoleViewModel

    init(model: ConsoleViewModel) {
        self.model = model

        let hosting = NSHostingController(
            rootView: ConsoleView(model: model)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cacty Console"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false  // we hold the only reference
        window.center()

        self.window = window
    }

    /// Bring the window to front, activating the app so the user
    /// can interact (unlike the other Cacty panels). Console is
    /// the one surface that breaks the "never become key"
    /// contract — by design: the user asked for it.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
