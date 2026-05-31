import XCTest
@testable import Agent

/// Integration tests that hit the **real Gemini API**.
///
/// **These tests cost money** (small token charges per run) and
/// require a working API key. They are gated behind two env vars
/// so default `swift test` runs and CI jobs skip them entirely:
///
/// - `CACTY_INTEGRATION_TESTS=1` enables the integration tier
///   (same gate as `EngineIntegrationTests`).
/// - `GEMINI_API_KEY=<key>` provides the API credentials.
///
/// Run them manually on a developer machine when validating
/// engine-vs-model integration:
///
/// ```bash
/// CACTY_INTEGRATION_TESTS=1 GEMINI_API_KEY=… swift test --filter GeminiIntegrationTests
/// ```
///
/// **Phase 0 gate:** PLAN.md § Phase 0 names "Gemini reliability
/// on real Mac AX trees" as the highest-risk unknown. The first
/// test below is the gate clearer — it proves Gemini emits a
/// structured `FunctionCall` against our schema rather than just
/// chatting back text. If this fails, every downstream
/// supervisor design assumption needs to be revisited before
/// Phase 1 starts.
final class GeminiIntegrationTests: XCTestCase {
    /// Model id env override. Defaults to
    /// `gemini-3.1-pro-preview` (the production-capable preview at
    /// the time of writing); users with access only to other
    /// model variants can set `GEMINI_MODEL` to override.
    private var model: String {
        ProcessInfo.processInfo.environment["GEMINI_MODEL"]
            ?? "gemini-3.1-pro-preview"
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CACTY_INTEGRATION_TESTS"] == "1"
        else {
            throw XCTSkip(
                "Integration tests skipped — set CACTY_INTEGRATION_TESTS=1 to enable."
            )
        }
    }

    // MARK: - Phase 0 gate clearer

    func testGeminiEmitsFunctionCallForLaunchAppPrompt() async throws {
        // PHASE 0 GATE TEST.
        //
        // Send a prompt that should trigger our `launch_app` tool
        // and assert Gemini returns a structured `FunctionCall`
        // (not free-form text). What we DON'T pin: the exact
        // bundle id Gemini chooses (it could pick
        // `com.apple.calculator` or `com.apple.Calculator`
        // depending on the model's training), or whether Gemini
        // also emits a text part alongside the call. What we DO
        // pin: at least one function call with name `launch_app`,
        // carrying a non-empty `bundleId` string.
        let apiKey = try requireApiKey()
        let client = GeminiClient(apiKey: apiKey)

        let request = GeminiRequest(
            contents: [
                Content(
                    role: "user",
                    parts: [Part(text: """
                        The user asked you to open the macOS Calculator app.
                        Call the launch_app tool with the appropriate bundle id.
                        """)]
                )
            ],
            tools: [Tool(functionDeclarations: [ToolSchema.launchApp()])]
        )

        let response = try await client.generateResponse(
            model: model, request: request
        )
        let calls = try GeminiClient.extractFunctionCalls(from: response)
        XCTAssertFalse(
            calls.isEmpty,
            "Gemini did not emit any function call — Phase 0 gate FAILED. "
                + "Got candidates: \(response.candidates)"
        )
        let launchCall = try XCTUnwrap(
            calls.first(where: { $0.name == "launch_app" }),
            "No launch_app call in response. Calls returned: "
                + "\(calls.map(\.name))"
        )
        let bundleId = try XCTUnwrap(
            launchCall.args["bundleId"]?.stringValue,
            "launch_app call missing string `bundleId` arg. "
                + "Args: \(launchCall.args)"
        )
        XCTAssertFalse(bundleId.isEmpty)
    }

    // MARK: - Helpers

    private func requireApiKey() throws -> String {
        guard
            let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
            !key.isEmpty
        else {
            throw XCTSkip(
                "GEMINI_API_KEY not set — cannot run real-API integration tests."
            )
        }
        return key
    }
}
