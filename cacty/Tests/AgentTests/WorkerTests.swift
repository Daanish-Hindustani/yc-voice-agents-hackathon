import XCTest
@testable import Agent
@testable import Automation

/// Unit tests for `Worker` parts that don't require a real Gemini
/// client or engine. The full closed-loop test (network + AX +
/// real Calculator) lives in `WorkerIntegrationTests.swift`.
final class WorkerTests: XCTestCase {
    // MARK: - encodeAsJSON helper

    func testEncodeAsJSONForAppInfoProducesObjectWithSnakeCaseKeys() throws {
        // The engine's `AppInfo` declares snake_case CodingKeys
        // (`bundle_id`). Verify the encoder→decoder round-trip
        // through `JSONValue` preserves those — they're the keys
        // Gemini will see in the function-response payload.
        let info = AppInfo(
            pid: 1234,
            bundleId: "com.apple.calculator",
            name: "Calculator",
            running: true,
            active: false
        )
        let json = try Worker.encodeAsJSON(info)
        let object = try XCTUnwrap(json.objectValue)
        XCTAssertEqual(object["pid"], .int(1234))
        XCTAssertEqual(object["bundle_id"], .string("com.apple.calculator"))
        XCTAssertEqual(object["name"], .string("Calculator"))
        XCTAssertEqual(object["running"], .bool(true))
        XCTAssertEqual(object["active"], .bool(false))
    }

    func testEncodeAsJSONForArrayProducesArrayValue() throws {
        let infos = [
            AppInfo(pid: 1, bundleId: nil, name: "A", running: true, active: false),
            AppInfo(pid: 2, bundleId: nil, name: "B", running: true, active: true),
        ]
        let json = try Worker.encodeAsJSON(infos)
        let array = try XCTUnwrap(json.arrayValue)
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0].objectValue?["name"], .string("A"))
        XCTAssertEqual(array[1].objectValue?["name"], .string("B"))
    }

    // MARK: - WorkerError

    func testWorkerErrorDescriptionsAreUseful() {
        // Pin the surface the supervisor will render in the
        // approval bar / console. Each case must produce a
        // non-empty, agent-readable message.
        let cases: [Worker.WorkerError] = [
            .maxStepsExceeded(stepCount: 12),
            .noCandidates,
            .invalidArguments(toolName: "x", reason: "y"),
            .unsupportedTool(name: "z"),
            .resultEncodingFailed(toolName: "x", reason: "y"),
            .geminiFailed(.noCandidates),
        ]
        for error in cases {
            XCTAssertFalse(error.description.isEmpty)
        }
    }

    // MARK: - Construction

    func testWorkerInstantiatesWithDefaultMaxSteps() {
        // Smoke test: the supervisor will hold a Worker per task,
        // so the public init must accept just (client, engine,
        // model) without forcing maxSteps.
        let client = GeminiClient(apiKey: "test")
        let engine = Engine()
        _ = Worker(client: client, engine: engine, model: "gemini-3.1-pro-preview")
    }

    func testWorkerInstantiatesWithVerifyAfterActionDisabled() {
        // The verify-via-snapshot pass defaults on. Tests that
        // want to exercise the raw dispatch loop without the
        // auto-verify pass it off explicitly. This smoke test
        // pins the public init surface.
        let client = GeminiClient(apiKey: "test")
        let engine = Engine()
        _ = Worker(
            client: client,
            engine: engine,
            model: "gemini-3.1-pro-preview",
            maxSteps: 4,
            verifyAfterAction: false
        )
    }

    // MARK: - verificationSnapshotCount initial state

    func testFreshWorkerHasZeroVerificationSnapshots() async {
        let client = GeminiClient(apiKey: "test")
        let engine = Engine()
        let worker = Worker(
            client: client, engine: engine, model: "gemini-3.1-pro-preview"
        )
        let count = await worker.verificationSnapshotCount
        XCTAssertEqual(count, 0)
    }
}
