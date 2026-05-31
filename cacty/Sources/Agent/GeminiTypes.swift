import Foundation

/// Wire types for Gemini's `generateContent` REST API.
///
/// Scope of these types: the minimum needed for bare text-in /
/// text-out completion. Tool declarations, function-call response
/// parts, safety settings, generation config, and grounding
/// metadata are not modeled here — they land alongside the
/// supervisor's tool-calling loop in subsequent PRs.
///
/// The shapes match Google's REST schema verbatim, including
/// camelCase field names (Gemini's API uses camelCase even though
/// our Swift convention sometimes does too — JSON decoder default
/// strategy works without a custom keyDecoding).

// MARK: - Request

public struct GeminiRequest: Codable, Sendable, Equatable {
    public let contents: [Content]

    /// Function declarations the model can call. When non-nil and
    /// non-empty, Gemini's response may contain `functionCall`
    /// parts the supervisor then dispatches against the engine.
    /// Encoded only when present (`encodeIfPresent`) so simple
    /// text-only completions don't ship an empty `tools: []` to
    /// the wire.
    public let tools: [Tool]?

    /// Top-level steering shipped to Gemini as `systemInstruction`
    /// in the v1beta API. Unlike `contents`, this is not part of
    /// the conversational turn history — it is treated as a
    /// persistent policy the model follows on every step. Encoded
    /// only when present so simple text-only completions don't
    /// ship an empty stub.
    public let systemInstruction: Content?

    public init(
        contents: [Content],
        tools: [Tool]? = nil,
        systemInstruction: Content? = nil
    ) {
        self.contents = contents
        self.tools = tools
        self.systemInstruction = systemInstruction
    }

    private enum CodingKeys: String, CodingKey {
        case contents
        case tools
        case systemInstruction
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contents, forKey: .contents)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(systemInstruction, forKey: .systemInstruction)
    }
}

/// A bundle of function declarations Gemini can call. The wire
/// format groups them under a single tool object — Gemini's API
/// accepts multiple tool entries but most of our use cases fit in
/// one. Modeled as an array on the request so callers can mix
/// future tool types (web search, code execution) alongside
/// function declarations when those land.
public struct Tool: Codable, Sendable, Equatable {
    public let functionDeclarations: [FunctionDeclaration]

    public init(functionDeclarations: [FunctionDeclaration]) {
        self.functionDeclarations = functionDeclarations
    }
}

/// A single tool the supervisor exposes to Gemini. `name` matches
/// the `FunctionCall.name` Gemini emits when invoking the tool;
/// `description` is what Gemini reads to decide whether to call
/// the tool; `parameters` is the JSON-Schema-flavored shape of
/// the arguments the tool accepts.
///
/// Schema modeling: Gemini's parameter schema is OpenAPI-flavored
/// (uppercase types: `OBJECT`, `STRING`, `INTEGER`, etc.) and
/// supports nesting, enums, and required-field lists. Modeling
/// that statically would require either a recursive Schema type
/// or a class. For Phase 0 we model `parameters` as an opaque
/// `JSONValue` — callers construct it via `.object([...])`. The
/// supervisor's `ToolSchema.swift` (PR 0.9) wraps this in
/// type-safe builders so callers don't write JSON by hand at
/// every site.
public struct FunctionDeclaration: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: JSONValue?

    public init(
        name: String,
        description: String,
        parameters: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct Content: Codable, Sendable, Equatable {
    /// Conversation role. Gemini accepts `"user"` and `"model"`
    /// here; future tool-calling PRs add `"function"`. Modeled as
    /// `String` rather than an enum so unknown roles in responses
    /// don't fail decode — the model could surface a new role
    /// (e.g., `"system"`) and we'd rather decode and inspect than
    /// reject.
    public let role: String

    public let parts: [Part]

    public init(role: String, parts: [Part]) {
        self.role = role
        self.parts = parts
    }
}

public struct Part: Codable, Sendable, Equatable {
    /// Text payload. Set on response parts when the model emits
    /// natural-language output, and on request parts the
    /// supervisor builds for the user-role turn. Optional because
    /// Gemini's parts are a sum: text OR function call OR function
    /// response OR inline data, never more than one. The invariant
    /// is enforced at decode time (see `init(from:)` below).
    public let text: String?

    /// Function-call payload returned by the model when it
    /// decides to invoke a declared tool. The supervisor's
    /// dispatch loop reads this, runs the matching engine
    /// method, and sends a `FunctionResponse` back as a
    /// follow-up turn.
    public let functionCall: FunctionCall?

    /// Function-response payload the supervisor sends to Gemini
    /// after dispatching a tool. Carries the tool's result so
    /// Gemini can plan its next step. The role on the containing
    /// `Content` for these parts is `"function"`.
    public let functionResponse: FunctionResponse?

    /// Inline binary payload — used to attach a screenshot PNG to
    /// a user-role turn so Gemini processes it as an image rather
    /// than opaque text. The model cannot OCR a base64 string
    /// buried inside a `FunctionResponse.response` object;
    /// `inline_data` is the supported channel for image input.
    public let inlineData: InlineData?

    /// Opaque signature returned by Gemini 3+ on parts that carry
    /// model reasoning (text or functionCall). The client MUST
    /// echo it back unchanged when re-sending the model's turn as
    /// conversation history — Gemini 3 Pro returns HTTP 400
    /// "Function call is missing a thought_signature" otherwise.
    /// See https://ai.google.dev/gemini-api/docs/thought-signatures.
    public let thoughtSignature: String?

    public init(
        text: String? = nil,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil,
        inlineData: InlineData? = nil,
        thoughtSignature: String? = nil
    ) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
        self.inlineData = inlineData
        self.thoughtSignature = thoughtSignature
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case functionCall
        case functionResponse
        case inlineData
        case thoughtSignature
    }

    /// Custom decoder enforces the "exactly zero or one of
    /// {text, functionCall, functionResponse}" invariant. A
    /// response part carrying multiple keys is malformed
    /// (Gemini's wire format never produces that shape) and
    /// downstream code that runs `extractText`,
    /// `extractFunctionCalls`, etc. over the same response would
    /// otherwise count the part twice. Throwing at decode keeps
    /// the supervisor's branching predictable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let functionCall = try container.decodeIfPresent(
            FunctionCall.self, forKey: .functionCall
        )
        let functionResponse = try container.decodeIfPresent(
            FunctionResponse.self, forKey: .functionResponse
        )
        let inlineData = try container.decodeIfPresent(
            InlineData.self, forKey: .inlineData
        )
        let setCount =
            (text != nil ? 1 : 0)
            + (functionCall != nil ? 1 : 0)
            + (functionResponse != nil ? 1 : 0)
            + (inlineData != nil ? 1 : 0)
        if setCount > 1 {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription:
                    "Part may set at most one of `text`, `functionCall`, "
                    + "`functionResponse`, or `inlineData` per wire object."
            )
        }
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
        self.inlineData = inlineData
        self.thoughtSignature = try container.decodeIfPresent(
            String.self, forKey: .thoughtSignature
        )
    }

    /// Custom encoder uses `encodeIfPresent` for every field so a
    /// nil-everywhere `Part` encodes as `{}` rather than emitting
    /// explicit nulls. Gemini's REST API does not accept null
    /// slots for any of these keys in request bodies.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(functionCall, forKey: .functionCall)
        try container.encodeIfPresent(functionResponse, forKey: .functionResponse)
        try container.encodeIfPresent(inlineData, forKey: .inlineData)
        try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
    }
}

/// Inline binary blob attached to a `Part`. Gemini's REST API
/// accepts these on user-role turns to feed images (and other
/// media) into the model. `mimeType` is e.g. `"image/png"`;
/// `data` is the raw bytes base64-encoded as a plain string.
/// The model decodes the base64 itself and processes the image —
/// unlike a base64 string buried in a `FunctionResponse.response`
/// object, which is just opaque text to the model.
public struct InlineData: Codable, Sendable, Equatable {
    public let mimeType: String
    public let data: String

    public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }

    // Gemini's REST API uses camelCase (`mimeType`) for this blob;
    // default-synthesized coding keys produce the right shape.
}

/// A single function call the model decided to invoke. Surfaced
/// inside `Part.functionCall` on the response side.
public struct FunctionCall: Codable, Sendable, Equatable {
    /// Tool name. Matches the `name` field of one of the
    /// `FunctionDeclaration`s the supervisor sent in the request.
    public let name: String

    /// Arguments the model wants to pass to the tool. Modeled as
    /// `[String: JSONValue]` so the supervisor can pattern-match on
    /// the argument shape without the wire types knowing the
    /// schema of every tool.
    public let args: [String: JSONValue]

    public init(name: String, args: [String: JSONValue] = [:]) {
        self.name = name
        self.args = args
    }
}

/// A tool result the supervisor sends back to Gemini after
/// dispatching a `FunctionCall`. The containing `Content` uses
/// role `"function"` (Gemini's REST schema spelling).
///
/// `response` is modeled as `JSONValue` rather than
/// `[String: JSONValue]` so callers can return non-object results
/// (a string, an array, a primitive) when the tool's natural
/// shape isn't a dictionary. Most tools will pass an object —
/// `.object(["result": .string("ok")])` is the typical shape.
public struct FunctionResponse: Codable, Sendable, Equatable {
    /// Matches the `name` of the `FunctionCall` this response
    /// answers. Gemini uses it to thread the response back to the
    /// right tool-call slot in its conversation history.
    public let name: String

    /// Tool result. Free-form JSON; supervisor and tool author
    /// agree on the shape. For the common error/result-envelope
    /// pattern, use `.object(["result": ...])` or
    /// `.object(["error": ...])`.
    public let response: JSONValue

    public init(name: String, response: JSONValue) {
        self.name = name
        self.response = response
    }
}

// MARK: - Response

public struct GeminiResponse: Codable, Sendable, Equatable {
    public let candidates: [Candidate]
    public let usageMetadata: UsageMetadata?
    public let promptFeedback: PromptFeedback?

    public init(
        candidates: [Candidate],
        usageMetadata: UsageMetadata? = nil,
        promptFeedback: PromptFeedback? = nil
    ) {
        self.candidates = candidates
        self.usageMetadata = usageMetadata
        self.promptFeedback = promptFeedback
    }
}

public struct Candidate: Codable, Sendable, Equatable {
    public let content: Content
    /// `"STOP"`, `"MAX_TOKENS"`, `"SAFETY"`, `"RECITATION"`,
    /// `"OTHER"`. Modeled as `String?` so the supervisor can
    /// pattern-match without us needing to chase Google's enum
    /// changes.
    public let finishReason: String?
    public let index: Int?

    public init(
        content: Content,
        finishReason: String? = nil,
        index: Int? = nil
    ) {
        self.content = content
        self.finishReason = finishReason
        self.index = index
    }
}

/// Per-response token accounting. The supervisor uses this for
/// telemetry and (later) for the per-task token budget, even
/// though Q12 deferred budget enforcement to post-MVP.
public struct UsageMetadata: Codable, Sendable, Equatable {
    public let promptTokenCount: Int?
    public let candidatesTokenCount: Int?
    public let totalTokenCount: Int?

    public init(
        promptTokenCount: Int? = nil,
        candidatesTokenCount: Int? = nil,
        totalTokenCount: Int? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.totalTokenCount = totalTokenCount
    }
}

/// Surfaced when Gemini blocks the entire response on safety
/// grounds. `candidates` is empty in that case and the supervisor
/// reads `promptFeedback.blockReason` to render a useful refusal
/// message.
public struct PromptFeedback: Codable, Sendable, Equatable {
    public let blockReason: String?

    public init(blockReason: String? = nil) {
        self.blockReason = blockReason
    }
}
