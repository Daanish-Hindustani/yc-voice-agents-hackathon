import XCTest
@testable import Automation

/// Smoke tests verifying the `Automation` SwiftPM target imports cleanly
/// after the engine restructure (PR 0.1: `CuaDriverCore` -> `Automation`).
///
/// Failures here mean the target name, target path, or test target's
/// dependency wiring in `Package.swift` is wrong — i.e. the move from
/// `cua-driver/Sources/CuaDriverCore/` to `Sources/Automation/` did not
/// land cleanly.
final class AutomationModuleTests: XCTestCase {
    func testVersionStringIsNonEmpty() {
        // The `CuaDriverCore` enum is the original namespace from
        // upstream; we kept the type name unchanged this PR per
        // CLAUDE.md "no unrequested refactors." A future PR can rename
        // it to `Automation.version`.
        XCTAssertFalse(CuaDriverCore.version.isEmpty)
    }

    func testVersionStringMatchesSemver() {
        // Loose check: x.y.z. We only enforce the shape, not specific
        // values — bumping the version shouldn't churn this test.
        let parts = CuaDriverCore.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "Expected semver MAJOR.MINOR.PATCH")
        for part in parts {
            XCTAssertNotNil(Int(part), "Version component '\(part)' is not numeric")
        }
    }
}
