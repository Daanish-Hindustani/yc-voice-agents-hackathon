import Agent
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.cacty", category: "clarification")

/// MainActor-bound queue of pending `ask_user` requests + the
/// `ClarificationGate` surface the worker reaches through.
///
/// Mirrors `ApprovalCoordinator` in shape (continuations dict +
/// observable pending queue) but the resolution payload is
/// richer — a `ClarificationReply` carries the user's choice
/// index, free-form text, or a skip marker.
///
/// Cancellation contract: a cancelled worker resolves the
/// pending request as `.cancelled` and removes it from the
/// queue. The worker loop's `Task.checkCancellation()` check
/// then exits before shipping the reply to the model.
@MainActor
@Observable
public final class ClarificationCoordinator: ClarificationGate {
    public struct PendingItem: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let request: ClarificationRequest
    }

    public private(set) var pending: [PendingItem] = []

    private var continuations: [UUID: CheckedContinuation<ClarificationReply, Never>] = [:]

    public init() {}

    // MARK: - ClarificationGate (called from worker actor)

    nonisolated public func askUser(
        _ request: ClarificationRequest
    ) async -> ClarificationReply {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ClarificationReply, Never>) in
                Task { @MainActor in
                    if Task.isCancelled {
                        cont.resume(returning: .cancelled)
                        return
                    }
                    self.enqueue(
                        PendingItem(id: id, request: request),
                        continuation: cont
                    )
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id: id, reply: .cancelled)
            }
        }
    }

    // MARK: - UI-facing API

    /// User picked one of the offered choices. `index` is the
    /// position in `pending.first.request.choices`; the
    /// matching string is looked up here so callers don't have
    /// to duplicate the array.
    public func selectChoice(_ id: UUID, index: Int) {
        guard let item = pending.first(where: { $0.id == id }) else { return }
        guard index >= 0, index < item.request.choices.count else {
            log.error("selectChoice out of bounds: \(index) for \(item.request.choices.count) choices")
            return
        }
        resolve(
            id: id,
            reply: .selected(index: index, text: item.request.choices[index])
        )
    }

    /// Hard cap on free-form clarification text. Any realistic
    /// answer fits comfortably under this; the bound is here to
    /// stop a paste of megabytes blowing up the next Gemini
    /// request (cost, latency, possible 4xx).
    public static let maxFreeformLength = 4_096

    /// User submitted a free-form answer. Empty/whitespace text
    /// is treated as a skip — the user pressed Return on an
    /// empty field, which is unambiguous. Overlong text is
    /// truncated to `maxFreeformLength` characters.
    public func submitFreeform(_ id: UUID, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            resolve(id: id, reply: .skipped)
            return
        }
        let bounded = cleaned.count > Self.maxFreeformLength
            ? String(cleaned.prefix(Self.maxFreeformLength))
            : cleaned
        resolve(id: id, reply: .freeform(text: bounded))
    }

    /// User explicitly skipped via the Skip control.
    public func skip(_ id: UUID) {
        resolve(id: id, reply: .skipped)
    }

    // MARK: - Internal

    private func enqueue(
        _ item: PendingItem,
        continuation: CheckedContinuation<ClarificationReply, Never>
    ) {
        continuations[item.id] = continuation
        pending.append(item)
        log.info("clarification pending: \(item.request.question, privacy: .public)")
    }

    private func resolve(id: UUID, reply: ClarificationReply) {
        guard let cont = continuations.removeValue(forKey: id) else {
            return
        }
        pending.removeAll { $0.id == id }
        log.info("clarification resolved: \(id, privacy: .public) → \(String(describing: reply), privacy: .public)")
        cont.resume(returning: reply)
    }
}
