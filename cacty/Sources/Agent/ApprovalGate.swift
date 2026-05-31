import Foundation

/// User decision for a pending approval request.
public enum ApprovalDecision: Sendable, Equatable {
    /// Proceed with dispatch.
    case approved

    /// Block dispatch. `reason` is surfaced back to the model
    /// inside the tool's `FunctionResponse` so it can pick a
    /// different approach instead of looping.
    case denied(reason: String)
}

/// Boundary protocol the worker calls before dispatching a tool
/// classified as `.requiresApproval`. The worker does not know
/// (and should not know) how the decision is sourced — production
/// uses the App-side `ApprovalCoordinator` actor that drives the
/// bottom-center approval panel; tests inject a deterministic
/// stub.
///
/// Conformers must be `Sendable` because the worker is an actor
/// and the gate crosses isolation boundaries on every call.
public protocol ApprovalGate: Sendable {
    /// Block until the user resolves this request. Implementations
    /// should respect task cancellation — if the worker's task is
    /// cancelled while a request is pending, the gate should
    /// return (typically with `.denied(reason: "cancelled")`) so
    /// the worker loop can exit cleanly.
    ///
    /// - Parameters:
    ///   - toolName: Engine tool the model wants to invoke.
    ///   - summary: One-line plain-English description shown on
    ///     the approval bar (from `Sensitivity.requiresApproval`).
    ///   - reason: The classifier rule that fired. Used for
    ///     telemetry; not displayed prominently.
    func requestApproval(
        toolName: String,
        summary: String,
        reason: String,
        scopeKey: String?
    ) async -> ApprovalDecision
}

/// Default gate that approves everything immediately. Used by
/// tests that don't care about the approval surface and as the
/// production default when no coordinator is wired in. Production
/// `App` always installs a real `ApprovalCoordinator`; this exists
/// so the Worker target compiles standalone.
public struct AlwaysApproveGate: ApprovalGate {
    public init() {}
    public func requestApproval(
        toolName: String, summary: String, reason: String, scopeKey: String?
    ) async -> ApprovalDecision {
        .approved
    }
}
