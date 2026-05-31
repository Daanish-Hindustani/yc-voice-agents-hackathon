import XCTest
@testable import Automation

/// Codable round-trip tests for the engine's small public value types.
/// These contracts are wire-format-stable (used in trajectories,
/// telemetry payloads, persisted config) so an accidental rename of a
/// `CodingKey` would break replay and forward compatibility.
final class CodableValueTypeTests: XCTestCase {
    // MARK: CursorPoint

    func testCursorPointRoundTripsViaJSON() throws {
        let point = CursorPoint(x: 42, y: -17)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CursorPoint.self, from: data)
        XCTAssertEqual(decoded, point)
    }

    func testCursorPointJSONUsesCamelCaseKeys() throws {
        // No snake_case mapping declared on CursorPoint — keys ship as
        // `x` and `y` verbatim. Lock this so a future contributor
        // can't silently flip global encoder strategies and rename
        // the public surface.
        let data = try JSONEncoder().encode(CursorPoint(x: 1, y: 2))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"x\":1"))
        XCTAssertTrue(json.contains("\"y\":2"))
    }

    // MARK: AppInfo

    func testAppInfoEncodesBundleIdAsSnakeCase() throws {
        // AppInfo declares an explicit `bundle_id` mapping; the rest
        // ride the synthesized camelCase. Verify the wire format.
        let info = AppInfo(
            pid: 1234,
            bundleId: "com.apple.Calendar",
            name: "Calendar",
            running: true,
            active: false
        )
        let data = try JSONEncoder().encode(info)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"bundle_id\":\"com.apple.Calendar\""))
        XCTAssertFalse(
            json.contains("\"bundleId\""),
            "bundleId must be encoded as bundle_id"
        )
    }

    func testAppInfoDecodesFromSnakeCaseJSON() throws {
        let json = """
            {
              "pid": 7,
              "bundle_id": "com.apple.Notes",
              "name": "Notes",
              "running": true,
              "active": true
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppInfo.self, from: json)
        XCTAssertEqual(decoded.pid, 7)
        XCTAssertEqual(decoded.bundleId, "com.apple.Notes")
        XCTAssertEqual(decoded.name, "Notes")
        XCTAssertTrue(decoded.running)
        XCTAssertTrue(decoded.active)
    }

    func testAppInfoDecodesNullBundleIdAsNil() throws {
        // bundleId is optional — apps without a bundle (some helper
        // processes) decode to nil rather than failing.
        let json = """
            { "pid": 0, "bundle_id": null, "name": "Helper", "running": false, "active": false }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppInfo.self, from: json)
        XCTAssertNil(decoded.bundleId)
    }

    // MARK: CuaDriverConfig

    func testCuaDriverConfigDecodesEmptyJSONAsDefaults() throws {
        // The custom init(from:) per-field falls back to defaults so
        // an older config (missing every new field) never breaks
        // load. Lock this contract.
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CuaDriverConfig.self, from: json)
        XCTAssertEqual(decoded, .default)
    }

    func testCuaDriverConfigDecodesPartialJSONFillingMissingFields() throws {
        // A config that only sets a couple of fields gets defaults
        // for everything else. Necessary for forward-compat: a user
        // whose config predates the `maxImageDimension` field still
        // loads without error.
        let json = """
            { "schemaVersion": 1, "telemetryEnabled": false }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CuaDriverConfig.self, from: json)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertFalse(decoded.telemetryEnabled)
        // Defaulted:
        XCTAssertEqual(decoded.captureMode, .som)
        XCTAssertEqual(
            decoded.maxImageDimension,
            CuaDriverConfig.defaultMaxImageDimension
        )
        XCTAssertTrue(decoded.autoUpdateEnabled)
    }

    func testCuaDriverConfigRoundTripsDefaults() throws {
        // Encode the default, decode, expect equality. Catches any
        // case where a synthesized encoder writes a key the custom
        // decoder can't read.
        let original = CuaDriverConfig.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CuaDriverConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: CaptureMode legacy alias

    func testCaptureModeDecodesScreenshotAsVisionAlias() throws {
        // Pre-rename configs persisted "screenshot" — the custom
        // decoder accepts that string and maps to .vision so users
        // don't need a manual config edit after upgrading.
        let json = "\"screenshot\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptureMode.self, from: json)
        XCTAssertEqual(decoded, .vision)
    }

    func testCaptureModeDecodesEachKnownValue() throws {
        for raw in ["vision", "ax", "som"] {
            let data = "\"\(raw)\"".data(using: .utf8)!
            XCTAssertNoThrow(
                try JSONDecoder().decode(CaptureMode.self, from: data),
                "Failed to decode known capture mode '\(raw)'"
            )
        }
    }

    func testCaptureModeRejectsUnknownValue() {
        let json = "\"giraffe\"".data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(CaptureMode.self, from: json)
        )
    }
}
