import XCTest
@testable import Automation

/// Codable round-trip tests for `AppStateSnapshot` covering the
/// `screenshot_*` payload that lands when `getWindowState` is called
/// with `captureMode: .som` (or `.vision`). The engine populates
/// these fields with the base64-encoded PNG bytes returned by
/// `WindowCapture.captureWindow`; the wire shape they take on the
/// FunctionResponse is what Gemini's tool reader consumes, so the
/// keys and omit-when-nil behavior are part of the tool contract.
final class AppStateSnapshotCodableTests: XCTestCase {

    func testEncodeOmitsScreenshotFieldsWhenNil() throws {
        let snapshot = AppStateSnapshot(
            pid: 42,
            bundleId: "com.example.app",
            name: "Example",
            treeMarkdown: "- AXApplication\n",
            elementCount: 0,
            turnId: 1
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = try JSONSerialization.jsonObject(
            with: data
        ) as! [String: Any]

        XCTAssertNil(json["screenshot_png_b64"])
        XCTAssertNil(json["screenshot_width"])
        XCTAssertNil(json["screenshot_height"])
        XCTAssertNil(json["screenshot_scale_factor"])
    }

    func testRoundTripPreservesScreenshotFields() throws {
        // Minimal PNG-ish payload — content is irrelevant, only the
        // round-trip through JSON matters here.
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let base64 = pngBytes.base64EncodedString()

        let snapshot = AppStateSnapshot(
            pid: 100,
            bundleId: "com.tinyspeck.slackmacgap",
            name: "Slack",
            treeMarkdown: "- AXApplication\n  - AXWindow\n",
            elementCount: 2,
            turnId: 7,
            screenshotPngBase64: base64,
            screenshotWidth: 1600,
            screenshotHeight: 900,
            screenshotScaleFactor: 2.0,
            screenshotOriginalWidth: 3200,
            screenshotOriginalHeight: 1800
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            AppStateSnapshot.self, from: data
        )

        XCTAssertEqual(decoded.screenshotPngBase64, base64)
        XCTAssertEqual(decoded.screenshotWidth, 1600)
        XCTAssertEqual(decoded.screenshotHeight, 900)
        XCTAssertEqual(decoded.screenshotScaleFactor, 2.0)
        XCTAssertEqual(decoded.screenshotOriginalWidth, 3200)
        XCTAssertEqual(decoded.screenshotOriginalHeight, 1800)
    }

    func testEncodeUsesSnakeCaseKeysForScreenshotFields() throws {
        let snapshot = AppStateSnapshot(
            pid: 1,
            bundleId: nil,
            name: nil,
            treeMarkdown: "",
            elementCount: 0,
            turnId: 0,
            screenshotPngBase64: "AAAA",
            screenshotWidth: 10,
            screenshotHeight: 20,
            screenshotScaleFactor: 1.0
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = try JSONSerialization.jsonObject(
            with: data
        ) as! [String: Any]

        XCTAssertEqual(json["screenshot_png_b64"] as? String, "AAAA")
        XCTAssertEqual(json["screenshot_width"] as? Int, 10)
        XCTAssertEqual(json["screenshot_height"] as? Int, 20)
        XCTAssertEqual(json["screenshot_scale_factor"] as? Double, 1.0)
    }
}
