import XCTest
@testable import Agent

/// Tests for `GeminiClient` that don't touch the network. The full
/// network path of `generate(model:prompt:)` requires a real API
/// key against a real endpoint; that's an integration test the
/// supervisor will land alongside the worker loop in a future PR.
///
/// What we CAN test here without a network: the
/// response-extraction logic that pulls candidate text out of a
/// decoded `GeminiResponse`. That's where the supervisor will
/// branch on Gemini's actual output, so it's the load-bearing
/// pure-function path.
final class GeminiClientTests: XCTestCase {
    // MARK: - extractText

    func testExtractTextReturnsFirstCandidateSingleTextPart() throws {
        let response = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [Part(text: "answer")]
                    )
                )
            ]
        )
        let text = try GeminiClient.extractText(from: response)
        XCTAssertEqual(text, "answer")
    }

    func testExtractTextJoinsMultipleTextPartsWithNewline() throws {
        // The model sometimes returns multiple text parts in a
        // single candidate (chain-of-thought variants, multi-line
        // outputs). Join with newline so the supervisor receives
        // a single string it can render or post-process.
        let response = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [
                            Part(text: "line one"),
                            Part(text: "line two"),
                        ]
                    )
                )
            ]
        )
        let text = try GeminiClient.extractText(from: response)
        XCTAssertEqual(text, "line one\nline two")
    }

    func testExtractTextSkipsNonTextParts() throws {
        // Future tool-calling parts will appear here as `Part`
        // values where `text == nil`. Pin the contract: those slots
        // are filtered out, not coerced into empty strings.
        let response = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [
                            Part(text: nil),
                            Part(text: "the answer"),
                            Part(text: nil),
                        ]
                    )
                )
            ]
        )
        let text = try GeminiClient.extractText(from: response)
        XCTAssertEqual(text, "the answer")
    }

    func testExtractTextThrowsNoCandidatesOnEmptyResponse() {
        // Capture the typed error and assert via `XCTAssertEqual`
        // rather than pattern-matching inside an `XCTAssertThrowsError`
        // closure. The `guard case` pattern silently turns a wrong-
        // case throw into an `XCTFail` *inside* the closure, which
        // does fail the test but obscures *which* assertion fired —
        // the equality assertion below points the failure straight
        // at the captured value. This requires `GeminiError:
        // Equatable`, which the type now is.
        let response = GeminiResponse(candidates: [])
        var caught: GeminiClient.GeminiError?
        XCTAssertThrowsError(try GeminiClient.extractText(from: response)) { error in
            caught = error as? GeminiClient.GeminiError
        }
        XCTAssertEqual(caught, .noCandidates)
    }

    func testExtractTextReturnsEmptyStringWhenAllPartsAreNonText() throws {
        // Edge case: a candidate with only non-text parts (future
        // function-call-only response). `noCandidates` is reserved
        // for the "model declined entirely" case; a candidate that
        // exists but has no text parts is a structurally valid
        // tool-only turn and should return an empty string rather
        // than throw. The supervisor distinguishes the two by
        // checking the candidate count.
        let response = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [Part(text: nil)]
                    )
                )
            ]
        )
        let text = try GeminiClient.extractText(from: response)
        XCTAssertEqual(text, "")
    }

    // MARK: - extractFunctionCalls

    func testExtractFunctionCallsReturnsAllCallsInFirstCandidate() throws {
        let response = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [
                            Part(text: "thinking..."),
                            Part(functionCall: FunctionCall(
                                name: "click_element",
                                args: ["pid": .int(1)]
                            )),
                            Part(functionCall: FunctionCall(
                                name: "type",
                                args: ["text": .string("hi")]
                            )),
                        ]
                    )
                )
            ]
        )
        let calls = try GeminiClient.extractFunctionCalls(from: response)
        XCTAssertEqual(calls.map(\.name), ["click_element", "type"])
    }

    func testExtractFunctionCallsReturnsEmptyForTextOnlyResponse() throws {
        // Text-only candidate is a valid "no tools called this
        // turn" signal. Empty array, not throw.
        let response = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [Part(text: "just text")]
                    )
                )
            ]
        )
        let calls = try GeminiClient.extractFunctionCalls(from: response)
        XCTAssertTrue(calls.isEmpty)
    }

    func testExtractFunctionCallsThrowsNoCandidatesOnEmptyResponse() {
        let response = GeminiResponse(candidates: [])
        var caught: GeminiClient.GeminiError?
        XCTAssertThrowsError(
            try GeminiClient.extractFunctionCalls(from: response)
        ) { error in
            caught = error as? GeminiClient.GeminiError
        }
        XCTAssertEqual(caught, .noCandidates)
    }

    // MARK: - Initialization

    func testGeminiClientInstantiatesWithDefaultBaseURL() async {
        // The supervisor will hold a single `GeminiClient` and
        // share it across worker actors. The actor must be
        // constructible via the public init with just an API key.
        _ = GeminiClient(apiKey: "test-key-not-used")
    }

    func testGeminiClientAcceptsCustomBaseURL() async {
        // Custom baseURL injection is what enables future
        // recorded-fixture-server tests against a `URLProtocol`
        // mock. Lock the constructor surface.
        let custom = URL(string: "https://example.invalid/v1")!
        _ = GeminiClient(apiKey: "test-key", baseURL: custom)
    }
}
