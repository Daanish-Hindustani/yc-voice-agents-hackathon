import XCTest
@testable import App
@testable import Agent
@testable import Automation

/// Unit tests for `AppCoordinator` state transitions that don't
/// require a real Fn-key tap, microphone, or speech recognizer.
/// Full PTT loop (hold Fn, speak, release, see task run) is
/// **only** validatable interactively by running the `.app` —
/// `swift test` can't simulate a CGEventTap firing for the
/// global Fn key or feed audio to SFSpeechRecognizer.
///
/// What we CAN test in this PR:
///   - Initial state is `.idle`
///   - Coordinator can be constructed against a real supervisor
///     without throwing
///
/// What the integration of this PR looks like — and which a
/// future PR will fold into the BackgroundInvariantTests suite
/// once we have UI-test infrastructure — is the user-facing
/// runbook:
///   1. `./Scripts/build-app.sh`
///   2. `GEMINI_API_KEY=… build/Cacty.app/Contents/MacOS/Cacty`
///   3. Grant Microphone + Speech Recognition + Input Monitoring prompts
///   4. Hold Fn, say "open Calculator," release
///   5. Observe Calculator launch hidden + menu icon transitions
///      idle → recording → transcribing → running → settling →
///      idle
final class AppCoordinatorTests: XCTestCase {
    @MainActor
    func testFreshCoordinatorIsIdle() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.lastFinalTranscript, "")
        XCTAssertNil(coordinator.lastStartedTaskId)
    }

    @MainActor
    func testCoordinatorStateEquatableForBlockedAndSettling() {
        // Pin Equatable across the cases the SwiftUI binding
        // will diff most often.
        let a: AppCoordinator.State = .blocked(reason: "x")
        let b: AppCoordinator.State = .blocked(reason: "x")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, .blocked(reason: "y"))

        let c: AppCoordinator.State = .settling(text: "done")
        let d: AppCoordinator.State = .settling(text: "done")
        XCTAssertEqual(c, d)
        XCTAssertEqual(AppCoordinator.State.idle, .idle)
        XCTAssertNotEqual(AppCoordinator.State.idle, .transcribing)
    }

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator() -> AppCoordinator {
        let engine = Engine()
        let client = GeminiClient(apiKey: "test-key-not-used")
        let supervisor = AgentSupervisor(
            client: client, engine: engine,
            model: "gemini-3.1-pro-preview"
        )
        // Real FnKeyHandler / SpeechRecognizer instances — the
        // coordinator only wires their closures; it doesn't
        // call .start() until coordinator.start() runs. So
        // construction is permission-free.
        return AppCoordinator(supervisor: supervisor)
    }
}
