import XCTest
@testable import Agent

/// Codable round-trip and accessor tests for `JSONValue`.
/// Pin the variant ordering — JSON `5` decodes as `.int(5)`, not
/// `.double(5.0)` — and the boundary cases that matter when
/// downstream tools pattern-match on argument shape.
final class JSONValueTests: XCTestCase {
    // MARK: - Decode primitives

    func testDecodesNull() throws {
        let value = try decode("null")
        XCTAssertEqual(value, .null)
    }

    func testDecodesBool() throws {
        XCTAssertEqual(try decode("true"), .bool(true))
        XCTAssertEqual(try decode("false"), .bool(false))
    }

    func testDecodesIntPreferredOverDoubleForWholeNumbers() throws {
        // The decoding-order contract: a JSON `5` lands as
        // `.int(5)` so a tool that expects an integer argument
        // gets one without coercion. If the order ever flips
        // (Double tried first), this test fails — which is the
        // point.
        XCTAssertEqual(try decode("5"), .int(5))
        XCTAssertEqual(try decode("0"), .int(0))
        XCTAssertEqual(try decode("-42"), .int(-42))
    }

    func testDecodesDoubleForFractional() throws {
        XCTAssertEqual(try decode("5.5"), .double(5.5))
        XCTAssertEqual(try decode("-0.25"), .double(-0.25))
    }

    func testDecodesString() throws {
        XCTAssertEqual(try decode("\"hello\""), .string("hello"))
    }

    // MARK: - Decode structures

    func testDecodesArrayOfMixedPrimitives() throws {
        let value = try decode("[1, \"a\", true, null]")
        XCTAssertEqual(value, .array([
            .int(1), .string("a"), .bool(true), .null
        ]))
    }

    func testDecodesObjectWithNestedShapes() throws {
        let value = try decode(#"{"pid": 1234, "title": "ok", "rect": [0, 1.5, 2]}"#)
        guard case .object(let obj) = value else {
            XCTFail("Expected object, got \(value)"); return
        }
        XCTAssertEqual(obj["pid"], .int(1234))
        XCTAssertEqual(obj["title"], .string("ok"))
        XCTAssertEqual(obj["rect"], .array([.int(0), .double(1.5), .int(2)]))
    }

    // MARK: - Encode round-trips

    func testEncodeDecodeRoundTripsAllVariants() throws {
        let originals: [JSONValue] = [
            .null,
            .bool(true),
            .int(-1),
            .double(3.14),
            .string("text"),
            .array([.int(1), .string("two"), .null]),
            .object(["k": .bool(false), "n": .int(7)])
        ]
        for original in originals {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(
                decoded, original,
                "Round-trip failed for \(original)"
            )
        }
    }

    // MARK: - Accessor sugar

    func testAccessorsReturnNilOnWrongCase() {
        XCTAssertNil(JSONValue.string("x").intValue)
        XCTAssertNil(JSONValue.int(5).stringValue)
        XCTAssertEqual(JSONValue.int(5).intValue, 5)
        XCTAssertEqual(JSONValue.string("x").stringValue, "x")
        // Cross-numeric accessors do NOT coerce — `.double(5)` is
        // not `.int(5)` and the accessor reflects that.
        XCTAssertNil(JSONValue.double(5).intValue)
        XCTAssertNil(JSONValue.int(5).doubleValue)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> JSONValue {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
