import Foundation

/// Request the worker hands to the clarification gate. The model
/// composes both the `question` (one sentence, plain English) and
/// the optional `choices` list; if the model wants free-text only
/// it leaves `choices` empty.
public struct ClarificationRequest: Sendable, Equatable {
    public let question: String
    public let choices: [String]

    public init(question: String, choices: [String] = []) {
        self.question = question
        self.choices = choices
    }
}

/// User reply for one clarification request.
public enum ClarificationReply: Sendable, Equatable {
    /// User picked one of the offered choices (by index into the
    /// request's `choices` array). The matching string is also
    /// carried so the gate doesn't have to look it up.
    case selected(index: Int, text: String)

    /// User typed a free-form answer.
    case freeform(text: String)

    /// User explicitly skipped — the model gets a structured
    /// `skipped` payload and decides whether to abort or proceed
    /// without the answer. Distinct from `cancelled` so the model
    /// can tell "I chose not to answer" from "the worker stopped."
    case skipped

    /// Worker task was cancelled while a request was pending. The
    /// model never sees this — the worker loop exits before
    /// shipping another turn.
    case cancelled
}

/// Boundary protocol the worker calls when the model invokes
/// `ask_user`. Same shape as `ApprovalGate`: production wires the
/// App-side `ClarificationCoordinator` that drives the
/// bottom-center panel; tests inject a deterministic stub.
public protocol ClarificationGate: Sendable {
    /// Block until the user resolves the request (or the worker
    /// task is cancelled — see `ClarificationReply.cancelled`).
    /// Implementations must respect `Task.isCancelled` so a
    /// cancelled worker doesn't leave a request orphaned in the
    /// UI queue.
    func askUser(_ request: ClarificationRequest) async -> ClarificationReply
}

/// Default gate that always returns `.skipped`. Used by tests
/// that don't care about clarification and as the standalone
/// Agent target's compile-time default. Production wires a real
/// `ClarificationCoordinator`.
public struct AlwaysSkipClarificationGate: ClarificationGate {
    public init() {}
    public func askUser(_ request: ClarificationRequest) async -> ClarificationReply {
        .skipped
    }
}
