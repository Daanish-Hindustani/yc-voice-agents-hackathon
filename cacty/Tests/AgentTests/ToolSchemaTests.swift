import XCTest
@testable import Agent

/// Pure-function tests for `ToolSchema` builders. No network — these
/// pin the schema shape Gemini will receive on every turn so a
/// future change to the parameter encoding (e.g., a typed Schema
/// struct replacing `JSONValue` opaque parameters) preserves the
/// wire contract.
final class ToolSchemaTests: XCTestCase {
    // MARK: - launch_app

    func testLaunchAppDeclarationHasExpectedNameAndRequiredArg() {
        let decl = ToolSchema.launchApp()
        XCTAssertEqual(decl.name, "launch_app")
        XCTAssertFalse(decl.description.isEmpty, "description must guide model")

        let params = try? extractParameterObject(from: decl)
        let requiredList = params?["required"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        XCTAssertEqual(requiredList, ["bundleId"])
    }

    func testLaunchAppDeclarationDeclaresBundleIdAsString() {
        let decl = ToolSchema.launchApp()
        let params = try? extractParameterObject(from: decl)
        let bundleIdSpec = params?["properties"]?.objectValue?["bundleId"]?.objectValue
        XCTAssertEqual(bundleIdSpec?["type"]?.stringValue, "STRING")
        XCTAssertNotNil(
            bundleIdSpec?["description"]?.stringValue,
            "bundleId field must have a description so Gemini knows the format"
        )
    }

    func testLaunchAppDeclarationEncodesAsValidGeminiToolWireShape() throws {
        // End-to-end wire shape: wrap the declaration in a Tool +
        // GeminiRequest, encode, walk the JSON, assert the shape
        // Gemini's REST schema documents.
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "open Calculator")])
            ],
            tools: [Tool(functionDeclarations: [ToolSchema.launchApp()])]
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let decls = try XCTUnwrap(
            tools[0]["functionDeclarations"] as? [[String: Any]]
        )
        XCTAssertEqual(decls[0]["name"] as? String, "launch_app")

        let params = try XCTUnwrap(decls[0]["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "OBJECT")
        let required = try XCTUnwrap(params["required"] as? [String])
        XCTAssertEqual(required, ["bundleId"])
        let properties = try XCTUnwrap(params["properties"] as? [String: Any])
        let bundleIdSpec = try XCTUnwrap(properties["bundleId"] as? [String: Any])
        XCTAssertEqual(bundleIdSpec["type"] as? String, "STRING")
    }

    // MARK: - list_apps

    func testListAppsDeclarationHasNoRequiredArgs() {
        let decl = ToolSchema.listApps()
        XCTAssertEqual(decl.name, "list_apps")
        let params = try? extractParameterObject(from: decl)
        // No required args — list_apps takes no parameters.
        XCTAssertNil(params?["required"])
        let properties = params?["properties"]?.objectValue ?? [:]
        XCTAssertTrue(
            properties.isEmpty,
            "list_apps declares no parameters; properties must be empty"
        )
    }

    // MARK: - list_windows

    func testListWindowsRequiresPid() {
        let decl = ToolSchema.listWindows()
        XCTAssertEqual(decl.name, "list_windows")
        let params = try? extractParameterObject(from: decl)
        let required = params?["required"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        XCTAssertEqual(required, ["pid"])
        let pidSpec = params?["properties"]?
            .objectValue?["pid"]?.objectValue
        XCTAssertEqual(pidSpec?["type"]?.stringValue, "INTEGER")
    }

    // MARK: - get_window_state

    func testGetWindowStateRequiresPidAndWindowId() {
        let decl = ToolSchema.getWindowState()
        XCTAssertEqual(decl.name, "get_window_state")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid", "windowId"])
        let properties = params?["properties"]?.objectValue ?? [:]
        XCTAssertEqual(
            properties["pid"]?.objectValue?["type"]?.stringValue,
            "INTEGER"
        )
        XCTAssertEqual(
            properties["windowId"]?.objectValue?["type"]?.stringValue,
            "INTEGER"
        )
        // captureMode is optional (not in `required`) but must be
        // declared as a string enum advertising `som` and `ax`.
        // The model needs to see the option to pick `som` for
        // Slack/Discord content reads.
        let captureMode = properties["captureMode"]?.objectValue
        XCTAssertEqual(captureMode?["type"]?.stringValue, "STRING")
        let enumValues = Set(
            captureMode?["enum"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(enumValues, ["som", "ax"])
    }

    // MARK: - click_element

    func testClickElementRequiresAllThreeArgs() {
        let decl = ToolSchema.clickElement()
        XCTAssertEqual(decl.name, "click")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
        )
        // Only `pid` is required at the JSON-Schema layer — the
        // (elementIndex+windowId) vs (x+y) mode exclusion is
        // enforced inside `Engine.click` at runtime, not at the
        // schema level (JSON Schema can't express "exactly one of
        // these mutually-exclusive subsets" without `oneOf`, which
        // Gemini doesn't honor consistently).
        XCTAssertEqual(required, ["pid"])
        // Both addressing modes' params must be present as optional
        // properties — the model can use either.
        let properties = params?["properties"]?.objectValue ?? [:]
        XCTAssertNotNil(properties["elementIndex"])
        XCTAssertNotNil(properties["windowId"])
        XCTAssertNotNil(properties["x"])
        XCTAssertNotNil(properties["y"])
    }

    func testClickElementDescriptionInstructsToSnapshotFirst() {
        // The cache-keying contract is the trickiest part of the
        // engine; the description must explicitly tell the model
        // to call get_window_state first or the click_element call
        // will fail with .elementNotFound. Pin this so a future
        // doc rewrite doesn't drop the warning.
        let decl = ToolSchema.clickElement()
        XCTAssertTrue(
            decl.description.lowercased().contains("get_window_state"),
            "click_element description must reference get_window_state — "
                + "the cache-keying contract is non-obvious"
        )
    }

    // MARK: - type_text

    func testTypeTextRequiresPidAndText() {
        let decl = ToolSchema.typeText()
        XCTAssertEqual(decl.name, "type_text_chars")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid", "text"])
        let properties = params?["properties"]?.objectValue ?? [:]
        XCTAssertEqual(
            properties["text"]?.objectValue?["type"]?.stringValue,
            "STRING"
        )
    }

    // MARK: - allEngineTools

    func testAllEngineToolsReturnsEveryDeclaredTool() {
        // Defensive cross-check: as new tools are added, this
        // assertion forces the author to update both the
        // declaration AND the aggregator. Catches the
        // "added a new builder, forgot to register it" footgun.
        let tools = ToolSchema.allEngineTools()
        let names = Set(tools.map(\.name))
        XCTAssertEqual(names, Set([
            "list_apps",
            "list_windows",
            "launch_app",
            "get_window_state",
            "click",
            "type_text_chars",
            "type_text",
            "press_key",
            "page",
            "right_click",
            "double_click",
            "drag",
            "scroll",
            "hotkey",
            "move_cursor",
            "zoom",
            "get_cursor_position",
            "get_screen_size",
            "get_accessibility_tree",
            "screenshot",
            "check_permissions",
            "set_recording",
            "get_recording_state",
            "replay_trajectory",
            "get_agent_cursor_state",
            "set_agent_cursor_enabled",
            "set_agent_cursor_motion",
            "get_config",
            "set_config",
            "ask_user",
        ]))
        // Names must be unique across the surface — Gemini
        // disambiguates tool calls by name, so a duplicate would
        // make one of the entries unreachable.
        XCTAssertEqual(tools.count, names.count)
    }

    // MARK: - cua-mirror tool shape spot-checks
    //
    // One assertion per new tool that pins (a) the registered name
    // and (b) the required-args set. Catches accidental rename /
    // shape drift during cua re-syncs without exhaustively encoding
    // every property.

    func testRightClickShape() {
        let decl = ToolSchema.rightClick()
        XCTAssertEqual(decl.name, "right_click")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid"])
    }

    func testDragRequiresFourCoordinates() {
        let decl = ToolSchema.drag()
        XCTAssertEqual(decl.name, "drag")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid", "fromX", "fromY", "toX", "toY"])
    }

    func testScrollRequiresPidAndDirection() {
        let decl = ToolSchema.scroll()
        XCTAssertEqual(decl.name, "scroll")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid", "direction"])
    }

    func testMoveCursorRequiresOnlyXY() {
        let decl = ToolSchema.moveCursor()
        XCTAssertEqual(decl.name, "move_cursor")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["x", "y"])
    }

    func testGetScreenSizeHasNoRequiredArgs() {
        let decl = ToolSchema.getScreenSize()
        XCTAssertEqual(decl.name, "get_screen_size")
        let params = try? extractParameterObject(from: decl)
        // Read tools with no args have an empty (or absent)
        // `required` array. Both shapes are acceptable JSON Schema.
        let required = params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(required.isEmpty)
    }

    func testScreenshotRequiresOnlyPid() {
        let decl = ToolSchema.screenshot()
        XCTAssertEqual(decl.name, "screenshot")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid"])
    }

    func testHotkeyRequiresPidAndKeys() {
        let decl = ToolSchema.hotkey()
        XCTAssertEqual(decl.name, "hotkey")
        let params = try? extractParameterObject(from: decl)
        let required = Set(
            params?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertEqual(required, ["pid", "keys"])
    }

    // MARK: - Helpers

    private func extractParameterObject(
        from decl: FunctionDeclaration
    ) throws -> [String: JSONValue] {
        let params = try XCTUnwrap(decl.parameters)
        return try XCTUnwrap(params.objectValue)
    }
}
