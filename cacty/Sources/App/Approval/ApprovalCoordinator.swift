import Agent
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.cacty", category: "approval")

/// MainActor-bound queue of pending approval requests + the
/// boundary surface the worker reaches through (`ApprovalGate`).
///
/// Why MainActor + @Observable rather than a plain actor: the
/// approval bar UI reads the queue head every frame and needs
/// SwiftUI observation. Hopping the worker call onto MainActor
/// is cheap (one actor hop per sensitive tool — typically <10
/// per task) and avoids a separate inbox-pump goroutine.
///
/// Cancellation contract: when a worker task is cancelled while
/// a request is pending, the gate resolves with
/// `.denied(reason: "cancelled")` and the request disappears
/// from the queue. The worker treats this like a user-deny
/// (sees an `error` payload, can decide whether to abort or try
/// a different approach). This matches the project rule that
/// cancellation is cooperative and explicit.
@MainActor
@Observable
public final class ApprovalCoordinator: ApprovalGate {
    /// One pending approval. The view renders the head of
    /// `pending`; users can only see one at a time per the Phase
    /// 1 design (multi-task queueing UI is Phase 2's "1 of N"
    /// indicator).
    public struct Request: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let toolName: String
        public let summary: String
        public let reason: String
    }

    /// FIFO queue of pending approvals. The head is shown in the
    /// approval bar; resolving the head pops it and exposes the
    /// next one (if any).
    public private(set) var pending: [Request] = []

    /// Per-request continuations. Removed atomically with the
    /// `pending` entry on resolve, so a double-resolve (e.g. user
    /// click + cancellation racing) can never resume a
    /// continuation twice — the second `resolve` finds nothing in
    /// the dict and no-ops.
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]

    /// Scope keys the user has previously approved this session.
    /// When the worker requests approval with a `scopeKey` already
    /// present here, the gate resolves to `.approved` immediately
    /// without enqueuing a prompt. Today these scopes are
    /// per-(action, bundleId) for the `page` tool — see
    /// `SensitivityEngine.classifyPage`. Cleared on app restart
    /// only; we never auto-revoke within a session because
    /// revoking mid-task would surprise the model with denials
    /// after a green light.
    private var approvedScopes: Set<String> = []

    /// Per-pending-request scope key, used to record the scope
    /// only when the user actually approves (deny doesn't grant).
    private var pendingScopes: [UUID: String] = [:]

    public init() {}

    // MARK: - ApprovalGate (called from worker actor)

    /// Worker-facing entry point. The protocol requires this be
    /// callable across isolation boundaries — `nonisolated` lets
    /// the worker `await` it from its own actor without first
    /// hopping to MainActor.
    nonisolated public func requestApproval(
        toolName: String, summary: String, reason: String, scopeKey: String?
    ) async -> ApprovalDecision {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
                Task { @MainActor in
                    // If the worker task was cancelled before we
                    // reached MainActor, short-circuit. Without
                    // this check the request would land in
                    // `pending` and never get drained — the
                    // cancellation handler already ran with
                    // nothing to find.
                    if Task.isCancelled {
                        cont.resume(returning: .denied(reason: "cancelled"))
                        return
                    }
                    if let scopeKey, self.approvedScopes.contains(scopeKey) {
                        log.info("approval auto-approved via scope: \(scopeKey, privacy: .public)")
                        cont.resume(returning: .approved)
                        return
                    }
                    if let scopeKey {
                        self.pendingScopes[id] = scopeKey
                    }
                    self.enqueue(
                        Request(
                            id: id,
                            toolName: toolName,
                            summary: summary,
                            reason: reason
                        ),
                        continuation: cont
                    )
                }
            }
        } onCancel: {
            // Cancellation handler runs synchronously on whatever
            // thread cancels us. Hop to MainActor to mutate the
            // queue safely.
            Task { @MainActor in
                self.resolve(id: id, decision: .denied(reason: "cancelled"))
            }
        }
    }

    // MARK: - UI-facing API

    /// Approve the head request (or a specific one by id when the
    /// future multi-pending UI exists). Pops it from the queue
    /// and resumes the worker.
    public func approve(_ id: UUID) {
        resolve(id: id, decision: .approved)
    }

    /// Deny with a user-supplied reason that gets surfaced back
    /// to the model. Empty `reason` falls back to "user_denied".
    public func deny(_ id: UUID, reason: String = "user_denied") {
        let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        resolve(
            id: id,
            decision: .denied(reason: cleaned.isEmpty ? "user_denied" : cleaned)
        )
    }

    // MARK: - Internal

    private func enqueue(
        _ request: Request,
        continuation: CheckedContinuation<ApprovalDecision, Never>
    ) {
        continuations[request.id] = continuation
        pending.append(request)
        log.info("approval pending: \(request.toolName, privacy: .public) — \(request.reason, privacy: .public)")
    }

    private func resolve(id: UUID, decision: ApprovalDecision) {
        guard let cont = continuations.removeValue(forKey: id) else {
            // Already resolved (race between user click and
            // cancellation). The first resolve won; we just no-op.
            return
        }
        pending.removeAll { $0.id == id }
        let scopeKey = pendingScopes.removeValue(forKey: id)
        if case .approved = decision, let scopeKey {
            approvedScopes.insert(scopeKey)
            log.info("approval scope granted: \(scopeKey, privacy: .public)")
        }
        log.info("approval resolved: \(id, privacy: .public) → \(String(describing: decision), privacy: .public)")
        cont.resume(returning: decision)
    }
}
