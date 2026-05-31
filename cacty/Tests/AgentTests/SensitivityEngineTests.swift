import XCTest
@testable import Agent

/// Pure-function tests for the sensitivity classifier. Every
/// branch in `SensitivityEngine.classify` should have at least
/// one safe + one requires-approval case.
final class SensitivityEngineTests: XCTestCase {
    // MARK: - Default branch

    func testUnknownToolDefaultsSafe() {
        let verdict = SensitivityEngine.classify(
            toolName: "click", args: [:]
        )
        XCTAssertEqual(verdict, .safe)
    }

    func testListAppsAlwaysSafe() {
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "list_apps", args: [:]),
            .safe
        )
    }

    // MARK: - Hotkey

    func testCmdReturnHotkeyRequiresApproval() {
        let args: [String: JSONValue] = [
            "keys": .array([.string("cmd"), .string("return")])
        ]
        let verdict = SensitivityEngine.classify(toolName: "hotkey", args: args)
        guard case .requiresApproval(let reason, let summary, _) = verdict else {
            return XCTFail("expected requiresApproval, got \(verdict)")
        }
        XCTAssertEqual(reason, "send_hotkey")
        XCTAssertTrue(summary.contains("⌘"))
        XCTAssertTrue(summary.contains("Return"))
    }

    func testCmdShiftDApprovalForMailSend() {
        let args: [String: JSONValue] = [
            "keys": .array([
                .string("cmd"), .string("shift"), .string("d"),
            ])
        ]
        let verdict = SensitivityEngine.classify(toolName: "hotkey", args: args)
        XCTAssertNotEqual(verdict, .safe)
    }

    func testHotkeyOrderInvariant() {
        // ["return", "cmd"] should match ["cmd", "return"].
        let a: [String: JSONValue] = [
            "keys": .array([.string("return"), .string("cmd")])
        ]
        let b: [String: JSONValue] = [
            "keys": .array([.string("cmd"), .string("return")])
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "hotkey", args: a),
            SensitivityEngine.classify(toolName: "hotkey", args: b)
        )
    }

    func testCmdCHotkeyIsSafe() {
        // Copy is not in the send pattern set.
        let args: [String: JSONValue] = [
            "keys": .array([.string("cmd"), .string("c")])
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "hotkey", args: args),
            .safe
        )
    }

    func testHotkeyModifierAliasesCanonicalize() {
        // "command" and "cmd" should normalize identically so
        // adding a `ctrl,*` pattern in future doesn't silently miss
        // the `control,*` synonym.
        let alias: [String: JSONValue] = [
            "keys": .array([.string("command"), .string("return")])
        ]
        let canonical: [String: JSONValue] = [
            "keys": .array([.string("cmd"), .string("return")])
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "hotkey", args: alias),
            SensitivityEngine.classify(toolName: "hotkey", args: canonical)
        )
    }

    func testHotkeyMissingKeysSafe() {
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "hotkey", args: [:]),
            .safe
        )
    }

    // MARK: - press_key

    func testBareReturnRequiresApproval() {
        let args: [String: JSONValue] = [
            "keys": .array([.string("return")])
        ]
        let verdict = SensitivityEngine.classify(
            toolName: "press_key", args: args
        )
        guard case .requiresApproval(let reason, _, _) = verdict else {
            return XCTFail("expected requiresApproval, got \(verdict)")
        }
        XCTAssertEqual(reason, "bare_return")
    }

    func testEnterAliasRequiresApproval() {
        let args: [String: JSONValue] = [
            "keys": .array([.string("enter")])
        ]
        XCTAssertNotEqual(
            SensitivityEngine.classify(toolName: "press_key", args: args),
            .safe
        )
    }

    func testPressKeyTabIsSafe() {
        let args: [String: JSONValue] = [
            "keys": .array([.string("tab")])
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "press_key", args: args),
            .safe
        )
    }

    func testPressKeyMultipleKeysIsSafe() {
        // Multi-key chords route through `hotkey`; press_key with
        // multiple keys is unusual and we let it through to avoid
        // double-prompting on chords already classified above.
        let args: [String: JSONValue] = [
            "keys": .array([.string("return"), .string("tab")])
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "press_key", args: args),
            .safe
        )
    }

    // MARK: - page

    func testPageEnableAppleEventsRequiresApprovalWithoutFlag() {
        let args: [String: JSONValue] = [
            "action": .string("enable_javascript_apple_events"),
            "bundleId": .string("com.google.Chrome"),
        ]
        let verdict = SensitivityEngine.classify(toolName: "page", args: args)
        XCTAssertNotEqual(verdict, .safe)
    }

    func testPageEnableAppleEventsSafeWithConsentFlag() {
        // Voice-as-consent path documented in
        // Worker.systemInstructionContent rule 7.
        let args: [String: JSONValue] = [
            "action": .string("enable_javascript_apple_events"),
            "bundleId": .string("com.google.Chrome"),
            "userHasConfirmedEnabling": .bool(true),
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "page", args: args),
            .safe
        )
    }

    func testPageReadActionSafe() {
        let args: [String: JSONValue] = [
            "action": .string("get_text"),
            "bundleId": .string("com.google.Chrome"),
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "page", args: args),
            .safe
        )
    }

    func testPageExecuteJavascriptIsSafe() {
        // `execute_javascript` runs against the user's existing
        // browser session for read-only reflection (cookies, DOM,
        // location). It's classified `.safe` so the model doesn't
        // hit approval friction on routine page reads.
        let args: [String: JSONValue] = [
            "action": .string("execute_javascript"),
            "javascript": .string("document.cookie"),
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "page", args: args),
            .safe
        )
    }

    func testPageQueryDomSafe() {
        let args: [String: JSONValue] = [
            "action": .string("query_dom"),
            "cssSelector": .string("h1"),
        ]
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "page", args: args),
            .safe
        )
    }

    // MARK: - Engine config writes

    func testSetConfigRequiresApproval() {
        XCTAssertNotEqual(
            SensitivityEngine.classify(toolName: "set_config", args: [:]),
            .safe
        )
    }

    func testGetConfigSafe() {
        XCTAssertEqual(
            SensitivityEngine.classify(toolName: "get_config", args: [:]),
            .safe
        )
    }

    func testReplayTrajectoryRequiresApproval() {
        XCTAssertNotEqual(
            SensitivityEngine.classify(toolName: "replay_trajectory", args: [:]),
            .safe
        )
    }
}
