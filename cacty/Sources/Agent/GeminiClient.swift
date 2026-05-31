import Foundation

/// HTTP client for Google's Gemini `generateContent` REST endpoint.
///
/// Scope of this PR (Phase 0 spike #2): bare text-in / text-out. No
/// tool calling, no streaming, no conversation history, no retries.
/// Those land in subsequent PRs as the worker loop comes online.
///
/// Why actor: future PRs will add per-client state — rate-limit
/// counters, in-flight request tracking, optional conversation
/// memory. Holding `GeminiClient` as an actor now lets the
/// supervisor compose one against each `Worker` without re-typing
/// the surface when state arrives.
///
/// Authentication: the Gemini REST API accepts the API key either as
/// `?key=...` query parameter or as the `x-goog-api-key` header. We
/// use the header form so the key never leaks into URL access logs
/// or error pages.
public actor GeminiClient {
    /// Errors that surface across the public API.
    public enum GeminiError: Error, CustomStringConvertible, Sendable, Equatable {
        /// HTTP layer reported a non-2xx status. The wrapped `body`
        /// is the response payload as UTF-8 text (or a placeholder
        /// for non-text bodies) so the supervisor can surface
        /// Gemini's own error message in the approval bar /
        /// console.
        case requestFailed(statusCode: Int, body: String)

        /// `URLSession.data(for:)` itself failed (network down,
        /// TLS error, request cancellation, etc.). The wrapped
        /// `reason` is `String(describing: underlyingError)`.
        case transportFailed(reason: String)

        /// The HTTP response was 2xx but the body did not decode as
        /// a `GeminiResponse`. Either the model's wire format
        /// shifted or the response is in an error-like shape that
        /// returned 200. Wrapped `reason` describes the
        /// `JSONDecoder` failure.
        case decodingFailed(reason: String)

        /// `JSONEncoder.encode(GeminiRequest)` failed. Should be
        /// unreachable for the request types defined here; surfaces
        /// as a typed-throws case so a future change that
        /// introduces a non-encodable nested value (e.g., raw
        /// `Any`) fails loudly rather than silently dropping.
        case encodingFailed(reason: String)

        /// The response decoded successfully but contained zero
        /// candidates. Gemini does this when safety filters or
        /// `finishReason: .other` block the entire output. The
        /// supervisor should treat this as a "model declined"
        /// signal, not a transient error to retry.
        case noCandidates

        public var description: String {
            switch self {
            case .requestFailed(let code, let body):
                return "Gemini HTTP \(code): \(body)"
            case .transportFailed(let reason):
                return "Gemini transport failed: \(reason)"
            case .decodingFailed(let reason):
                return "Gemini response decode failed: \(reason)"
            case .encodingFailed(let reason):
                return "Gemini request encode failed: \(reason)"
            case .noCandidates:
                return "Gemini returned no candidates (safety-filtered or model-declined)"
            }
        }
    }

    /// Centralized default base URL — pulled out so the literal
    /// only appears once and the force-unwrap is justified by a
    /// known-valid absolute URL string.
    public static let defaultBaseURL = URL(
        string: "https://generativelanguage.googleapis.com/v1beta"
    )!

    private let apiKey: String
    private let baseURL: URL
    private let urlSession: URLSession

    public init(
        apiKey: String,
        baseURL: URL = GeminiClient.defaultBaseURL,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    /// Bare text-in / text-out completion against `model`. The
    /// prompt is sent as a single user-role content with one text
    /// part. The first candidate's text parts are joined with a
    /// newline and returned.
    ///
    /// For Phase 0 this is the entire client surface. Tool calling
    /// (function declarations + tool-result roles) and streaming
    /// land in PRs that follow this one.
    ///
    /// - Parameter model: Model id, e.g. `"gemini-3.1-pro-preview"`.
    /// - Parameter prompt: Single-turn user input.
    /// - Returns: The first candidate's text, parts joined with `\n`.
    ///   **An empty string is a valid return value** — it means the
    ///   first candidate exists but has no text parts (a structurally
    ///   valid future tool-only turn). The supervisor distinguishes
    ///   "model declined entirely" (which throws `.noCandidates`)
    ///   from "model returned no text" (empty string return) by
    ///   which path it ends up on.
    /// - Throws: `GeminiError.requestFailed` for non-2xx HTTP
    ///   responses; `.transportFailed` for network failures or
    ///   non-HTTP response objects; `.decodingFailed` for malformed
    ///   bodies; `.noCandidates` when Gemini returns an empty
    ///   candidate list (typically safety filtering).
    public func generate(
        model: String,
        prompt: String
    ) async throws(GeminiError) -> String {
        let response = try await generateResponse(model: model, prompt: prompt)
        return try Self.extractText(from: response)
    }

    /// Lower-level variant of `generate(model:prompt:)` that returns
    /// the full `GeminiResponse` rather than just the text. Use
    /// this when the caller needs to read function calls (via
    /// `extractFunctionCalls(from:)`), inspect `usageMetadata`, or
    /// branch on `finishReason` — the supervisor's tool-calling
    /// loop ends here on every turn.
    ///
    /// Same throws contract as `generate`.
    public func generateResponse(
        model: String,
        prompt: String
    ) async throws(GeminiError) -> GeminiResponse {
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: prompt)])
            ]
        )
        return try await generateResponse(model: model, request: request)
    }

    /// Full-control variant: caller hands in a complete
    /// `GeminiRequest` (with tool declarations, multi-turn
    /// `contents`, function-response parts, etc.). Used by the
    /// supervisor's tool-calling loop where each turn passes a
    /// growing conversation history.
    ///
    /// Same throws contract as `generate` / the prompt-taking
    /// `generateResponse` overload.
    public func generateResponse(
        model: String,
        request: GeminiRequest
    ) async throws(GeminiError) -> GeminiResponse {
        return try await postGenerate(model: model, request: request)
    }

    /// Pull the first candidate's text out of a response.
    /// `nonisolated static` so unit tests can exercise this path
    /// without spinning up the actor or hitting the network — every
    /// JSON-decoding test in `AgentTests` ends here. The
    /// `nonisolated` is implicit for `static` on an actor in Swift
    /// 6 but written explicitly so the signature reads
    /// unambiguously.
    public nonisolated static func extractText(
        from response: GeminiResponse
    ) throws(GeminiError) -> String {
        guard let firstCandidate = response.candidates.first else {
            throw .noCandidates
        }
        return firstCandidate.content.parts
            .compactMap(\.text)
            .joined(separator: "\n")
    }

    /// Pull every function call the model emitted in the first
    /// candidate. Returns an empty array when the candidate has no
    /// function calls (text-only response, or
    /// non-text-and-non-function parts).
    ///
    /// Same `nonisolated static` shape as `extractText` — the
    /// supervisor's tool-dispatch loop ends here on every turn,
    /// and the static surface keeps it network-free for tests.
    ///
    /// Throws `.noCandidates` when the response had no candidates
    /// at all (the same "model declined entirely" signal). A
    /// candidate that exists but emitted only text returns `[]` —
    /// not an error, just "no tools called this turn."
    public nonisolated static func extractFunctionCalls(
        from response: GeminiResponse
    ) throws(GeminiError) -> [FunctionCall] {
        guard let firstCandidate = response.candidates.first else {
            throw .noCandidates
        }
        return firstCandidate.content.parts.compactMap(\.functionCall)
    }

    private func postGenerate(
        model: String,
        request: GeminiRequest
    ) async throws(GeminiError) -> GeminiResponse {
        let url = baseURL.appendingPathComponent("models/\(model):generateContent")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw .encodingFailed(reason: String(describing: error))
        }
        urlRequest.httpBody = body

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: urlRequest)
        } catch {
            throw .transportFailed(reason: String(describing: error))
        }

        // Assert the cast rather than letting a non-HTTP response
        // fall through to the decoder — a custom URLProtocol mock
        // that forgets to return an `HTTPURLResponse` would
        // otherwise surface a confusing `.decodingFailed` instead
        // of the actual transport-shape problem.
        guard let http = urlResponse as? HTTPURLResponse else {
            throw .transportFailed(
                reason: "Unexpected non-HTTP response: \(type(of: urlResponse))"
            )
        }
        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw .requestFailed(statusCode: http.statusCode, body: bodyText)
        }

        do {
            return try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            throw .decodingFailed(reason: String(describing: error))
        }
    }
}
