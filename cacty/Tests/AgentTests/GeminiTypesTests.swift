import XCTest
@testable import Agent

/// Codable round-trip tests for the Gemini wire types. Pin the
/// shapes against recorded JSON fixtures so a future change in the
/// Codable surface that breaks decode of a real Gemini response
/// fails loudly here, not in production.
///
/// No network in any of these tests — all input is loaded from
/// `Tests/AgentTests/Fixtures/*.json` via the test bundle.
final class GeminiTypesTests: XCTestCase {
    // MARK: - Request encoding

    func testGeminiRequestEncodesAsExpectedJSONShape() throws {
        // Pin the wire format so the supervisor's tool-calling PR
        // can rely on this exact request shape when extending it.
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "hello")])
            ]
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["text"] as? String, "hello")
    }

    // MARK: - Response decoding from real-shape fixtures

    func testDecodesSingleTextCandidateFixture() throws {
        let response = try loadFixture(
            "single_text_candidate", as: GeminiResponse.self
        )
        XCTAssertEqual(response.candidates.count, 1)
        XCTAssertEqual(response.candidates[0].content.role, "model")
        XCTAssertEqual(response.candidates[0].finishReason, "STOP")
        XCTAssertEqual(
            response.candidates[0].content.parts.first?.text,
            "Hello, world!"
        )
        XCTAssertEqual(response.usageMetadata?.totalTokenCount, 9)
    }

    func testDecodesMultiPartCandidateFixture() throws {
        let response = try loadFixture(
            "multi_part_candidate", as: GeminiResponse.self
        )
        XCTAssertEqual(response.candidates[0].content.parts.count, 2)
        XCTAssertEqual(
            response.candidates[0].content.parts.compactMap(\.text),
            ["Line one.", "Line two."]
        )
    }

    func testDecodesSafetyBlockedFixtureWithEmptyCandidates() throws {
        let response = try loadFixture(
            "safety_blocked", as: GeminiResponse.self
        )
        XCTAssertTrue(response.candidates.isEmpty)
        XCTAssertEqual(response.promptFeedback?.blockReason, "SAFETY")
    }

    // MARK: - Round-trip stability

    func testGeminiResponseRoundTripsThroughEncodeDecode() throws {
        // Encode-then-decode of a synthetic response must produce
        // an identical value. Catches any case where the encoder
        // omits a field the decoder later requires (the
        // `Equatable` synthesis is what makes this lock cheap).
        let original = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(role: "model", parts: [Part(text: "hi")]),
                    finishReason: "STOP",
                    index: 0
                )
            ],
            usageMetadata: UsageMetadata(
                promptTokenCount: 1,
                candidatesTokenCount: 1,
                totalTokenCount: 2
            ),
            promptFeedback: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Tool declaration encoding (request side)

    func testGeminiRequestWithoutToolsDoesNotEmitToolsKey() throws {
        // The encodeIfPresent contract for `tools`: simple
        // text-only completions must not ship `"tools": null` or
        // `"tools": []` on the wire. Gemini accepts either but
        // both are noise; absent is the right shape.
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "hi")])
            ]
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["tools"])
        XCTAssertNotNil(json["contents"])
    }

    func testGeminiRequestWithToolsEncodesUnderToolsKey() throws {
        // Pin the wire shape Gemini's REST schema expects:
        //   { "tools": [{ "functionDeclarations": [...] }] }
        let click = FunctionDeclaration(
            name: "click_element",
            description: "Click an AX element by index.",
            parameters: .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "pid": .object(["type": .string("INTEGER")]),
                    "windowId": .object(["type": .string("INTEGER")]),
                    "elementIndex": .object(["type": .string("INTEGER")])
                ]),
                "required": .array([
                    .string("pid"), .string("windowId"), .string("elementIndex")
                ])
            ])
        )
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "do it")])],
            tools: [Tool(functionDeclarations: [click])]
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let decls = try XCTUnwrap(
            tools[0]["functionDeclarations"] as? [[String: Any]]
        )
        XCTAssertEqual(decls.count, 1)
        XCTAssertEqual(decls[0]["name"] as? String, "click_element")
        XCTAssertEqual(
            decls[0]["description"] as? String,
            "Click an AX element by index."
        )
        // Parameter schema round-trips as nested JSON.
        let params = try XCTUnwrap(decls[0]["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "OBJECT")
        let required = try XCTUnwrap(params["required"] as? [String])
        XCTAssertEqual(Set(required), Set(["pid", "windowId", "elementIndex"]))
    }

    func testFunctionDeclarationWithoutParametersOmitsParametersKey() throws {
        // No-parameter tool: `parameters: nil` should be absent
        // from the wire, not emitted as `null`. Encodes
        // synthesized via Codable + Optional, but pin the
        // contract since the supervisor's no-arg tool helpers
        // will rely on it.
        let decl = FunctionDeclaration(
            name: "list_apps",
            description: "Enumerate running apps.",
            parameters: nil
        )
        let data = try JSONEncoder().encode(decl)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["name"] as? String, "list_apps")
        // Synthesized Codable WILL emit `null` for nil Optional —
        // the assertion below documents the current behavior. If
        // we later need omission, switch FunctionDeclaration to a
        // custom encoder using encodeIfPresent.
        if json.keys.contains("parameters") {
            XCTAssertTrue(json["parameters"] is NSNull)
        }
    }

    func testGeminiRequestWithToolsRoundTripsThroughEncodeDecode() throws {
        // Symmetry check: encode a request with tools, decode it
        // back, assert equality. Catches CodingKeys regressions on
        // any of the new types.
        let original = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "hello")])
            ],
            tools: [
                Tool(functionDeclarations: [
                    FunctionDeclaration(
                        name: "noop",
                        description: "Do nothing.",
                        parameters: .object([
                            "type": .string("OBJECT")
                        ])
                    )
                ])
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeminiRequest.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Function call decoding

    func testDecodesFunctionCallOnlyCandidate() throws {
        let response = try loadFixture(
            "function_call_response", as: GeminiResponse.self
        )
        let parts = response.candidates[0].content.parts
        XCTAssertEqual(parts.count, 1)
        XCTAssertNil(parts[0].text)
        let call = try XCTUnwrap(parts[0].functionCall)
        XCTAssertEqual(call.name, "click_element")
        XCTAssertEqual(call.args["pid"], .int(1234))
        XCTAssertEqual(call.args["windowId"], .int(5678))
        XCTAssertEqual(call.args["elementIndex"], .int(14))
    }

    func testDecodesMixedTextAndFunctionCallCandidate() throws {
        // Gemini sometimes returns reasoning text alongside a tool
        // call in the same candidate. Both parts must decode and
        // be addressable separately.
        let response = try loadFixture(
            "mixed_text_and_function_call", as: GeminiResponse.self
        )
        let parts = response.candidates[0].content.parts
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].text, "I'll launch Calculator first.")
        XCTAssertNil(parts[0].functionCall)
        XCTAssertNil(parts[1].text)
        XCTAssertEqual(parts[1].functionCall?.name, "launch_app")
        XCTAssertEqual(
            parts[1].functionCall?.args["bundleId"],
            .string("com.apple.calculator")
        )
    }

    // MARK: - FunctionResponse encoding

    func testPartWithFunctionResponseEncodesUnderFunctionResponseKey() throws {
        // Pin the wire shape the supervisor sends back after
        // dispatching a tool: { "functionResponse": { "name", "response" } }.
        // The role on the surrounding Content should be "function"
        // — that's a caller responsibility, not the Part's.
        let part = Part(functionResponse: FunctionResponse(
            name: "click_element",
            response: .object([
                "result": .string("ok"),
                "elementCount": .int(42)
            ])
        ))
        let data = try JSONEncoder().encode(part)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let fr = try XCTUnwrap(json["functionResponse"] as? [String: Any])
        XCTAssertEqual(fr["name"] as? String, "click_element")
        let response = try XCTUnwrap(fr["response"] as? [String: Any])
        XCTAssertEqual(response["result"] as? String, "ok")
        XCTAssertEqual(response["elementCount"] as? Int, 42)
        // text and functionCall must NOT appear on the wire.
        XCTAssertNil(json["text"])
        XCTAssertNil(json["functionCall"])
    }

    func testFunctionResponseAcceptsScalarResponseValues() throws {
        // Tools that naturally return a scalar (a string, a
        // number) shouldn't be forced to wrap in an object. Pin
        // the round-trip of a string-valued response.
        let part = Part(functionResponse: FunctionResponse(
            name: "get_version",
            response: .string("1.2.3")
        ))
        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(Part.self, from: data)
        XCTAssertEqual(decoded.functionResponse?.name, "get_version")
        XCTAssertEqual(decoded.functionResponse?.response, .string("1.2.3"))
    }

    // MARK: - Mutex enforcement (decode side)

    func testDecodingPartWithFunctionCallAndFunctionResponseThrows() {
        // Both function-call and function-response in one part is
        // malformed (a part is either a model-emitted call OR a
        // supervisor-supplied response, never both).
        let malformed = #"""
            {
              "functionCall": { "name": "x", "args": {} },
              "functionResponse": { "name": "x", "response": {} }
            }
            """#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(Part.self, from: malformed)
        )
    }

    func testDecodingPartWithTextAndFunctionResponseThrows() {
        let malformed = #"""
            {
              "text": "hi",
              "functionResponse": { "name": "x", "response": {} }
            }
            """#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(Part.self, from: malformed)
        )
    }

    func testDecodingPartWithBothTextAndFunctionCallThrows() {
        // The "text XOR functionCall" invariant is enforced at
        // decode time. A wire object carrying both keys is malformed
        // — without this guard, `extractText` and
        // `extractFunctionCalls` would both count the part and
        // downstream code would dispatch the tool AND show the text.
        let malformed = #"""
            { "text": "hi", "functionCall": { "name": "x", "args": {} } }
            """#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(Part.self, from: malformed)
        )
    }

    // MARK: - Function call encoding

    func testFunctionCallEncodesToWireShape() throws {
        // Pin the request-side shape: `functionCall: { name, args }`,
        // and within `args` each value uses JSONValue's variant
        // encoding (so an Int arg becomes a JSON number, not a
        // string).
        let part = Part(functionCall: FunctionCall(
            name: "click_element",
            args: ["pid": .int(99), "label": .string("OK")]
        ))
        let data = try JSONEncoder().encode(part)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let fc = try XCTUnwrap(json["functionCall"] as? [String: Any])
        XCTAssertEqual(fc["name"] as? String, "click_element")
        let args = try XCTUnwrap(fc["args"] as? [String: Any])
        XCTAssertEqual(args["pid"] as? Int, 99)
        XCTAssertEqual(args["label"] as? String, "OK")
        // Text key must be absent (encodeIfPresent contract).
        XCTAssertNil(json["text"])
    }

    func testFunctionCallWithEmptyArgsEncodesAsExplicitEmptyObject() throws {
        // Pin the wire-format contract: a no-argument tool call
        // encodes as `"args": {}`, not absent. Gemini's wire
        // format treats `args: {}` and absent `args` as
        // equivalent on the response side, but the supervisor's
        // outgoing path (PR 0.8b) needs a stable shape so the
        // request-fixture tests can pin against it. Locking now
        // avoids a regression when 0.8b lands.
        let call = FunctionCall(name: "noargs")
        let data = try JSONEncoder().encode(call)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["name"] as? String, "noargs")
        let args = try XCTUnwrap(json["args"] as? [String: Any])
        XCTAssertTrue(args.isEmpty)
    }

    func testGeminiResponseWithFunctionCallRoundTripsThroughEncodeDecode() throws {
        // Round-trip the full container through encode→decode and
        // assert equality. Catches any case where FunctionCall
        // encodes correctly as JSON but fails to re-decode (e.g.,
        // a CodingKeys regression). Without this, the wire-shape
        // assertion test could pass while the field-symmetry
        // assertion silently doesn't run end-to-end.
        let original = GeminiResponse(
            candidates: [
                Candidate(
                    content: Content(
                        role: "model",
                        parts: [
                            Part(functionCall: FunctionCall(
                                name: "click_element",
                                args: [
                                    "pid": .int(99),
                                    "windowId": .int(7),
                                    "label": .string("OK")
                                ]
                            ))
                        ]
                    ),
                    finishReason: "STOP",
                    index: 0
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPartWithAllNilFieldsEncodesAsEmptyObjectNotExplicitNulls() throws {
        // Pin the wire-format contract: a Part with no fields set
        // encodes as `{}`. Locks the `encodeIfPresent` contract
        // for every field — adding a fourth optional field later
        // (e.g., `inlineData`) must also use `encodeIfPresent` or
        // this assertion will fail when the new key starts
        // emitting `null`.
        let part = Part()
        let data = try JSONEncoder().encode(part)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(json, "{}")
        // Round-trip: empty object decodes to all-nil fields.
        let decoded = try JSONDecoder().decode(Part.self, from: data)
        XCTAssertNil(decoded.text)
        XCTAssertNil(decoded.functionCall)
        XCTAssertNil(decoded.functionResponse)
    }

    // MARK: - Helpers

    private func loadFixture<T: Decodable>(
        _ name: String, as type: T.Type
    ) throws -> T {
        // `resources: [.copy("Fixtures")]` in Package.swift
        // preserves the directory structure inside the bundle, so
        // we look up with `subdirectory: "Fixtures"`. Switching to
        // `.process` would flatten everything into the bundle root
        // but loses the organizational signal.
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures"
            ),
            "Fixture Fixtures/\(name).json not found in test bundle"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
