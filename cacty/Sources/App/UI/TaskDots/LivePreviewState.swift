import Foundation
import Observation

/// Shared `@Observable` state driving the hover-preview panel.
/// Single instance owned by the app shell; the dot strip writes
/// to it (`show(_:)` / `hide()`) and the `LivePreviewPanel`
/// observes it to know when to render and what to stream.
///
/// Modeled as observable state rather than a method-based API on
/// the panel so SwiftUI can react via `.onChange(of: state.focus)`
/// inside the popover view — re-subscribes the capture stream
/// when the user hovers a different running dot in succession
/// without tearing down the panel.
@MainActor
@Observable
public final class LivePreviewState {
    public private(set) var focus: AgentSupervisor.Focus?

    public init() {}

    public func show(_ focus: AgentSupervisor.Focus) {
        self.focus = focus
    }

    public func hide() {
        self.focus = nil
    }
}
