# AutomationTests

Tests for the `Automation` SwiftPM target.

## What this directory contains

Pure-function unit tests that run on any developer machine without
permissions and without live macOS state:

| File | Covers |
|---|---|
| `AutomationModuleTests.swift` | Module imports cleanly; `version` is a non-empty semver string |
| `CubicBezierTests.swift` | Cubic-bezier point sampling, tangent direction, `cgPath` start point |
| `CursorMotionPathTests.swift` | Motion-path Bezier construction, endpoint preservation, degenerate inputs |
| `FrameTransformTests.swift` | Recording fast-path (scale=1) identity, clamp helper |
| `CodableValueTypeTests.swift` | `CursorPoint`, `AppInfo`, `CuaDriverConfig`, `CaptureMode` JSON round-trips, snake_case mapping, legacy aliases, default fallbacks |
| `ZoomMathTests.swift` | Recording-zoom math (vendored from upstream cua) |

These are the pieces that don't touch private Apple frameworks, the
filesystem, the network, the AX subsystem, or the windowing system.

## What is NOT covered here (and why)

`Automation/` is mostly system-side-effecting code that drives real
macOS apps. The remaining surfaces all need at least one of:
Accessibility permission, Screen Recording permission, Input
Monitoring permission, a real running app, or actual mouse/keyboard
hardware. Unit-testing them in isolation is not meaningful — they
either need mocks that test the mock or they need real systems.

| Untested surface | Why no unit test | Where it should be tested |
|---|---|---|
| `Input/AXInput.swift` | Drives `AXUIElementPerformAction` against live AX elements | `BackgroundInvariantTests/` (Phase 4) |
| `Input/SkyLightEventPost.swift` | Calls private `SLEventPostToPid`; needs a real pid + auth token | Integration tests with a fixture app |
| `Input/KeyboardInput.swift` / `MouseInput.swift` | Posts `CGEvent`s to a real pid | Integration tests with TextEdit fixture |
| `Capture/WindowCapture.swift` | Calls ScreenCaptureKit / `CGWindowListCreateImage` | Integration tests with Screen Recording permission |
| `Focus/FocusGuard.swift` etc. | Reacts to real activation events | Integration tests with cooperating apps |
| `Apps/AppEnumerator.swift`, `Windows/WindowEnumerator.swift` | Read live system state | Integration tests; use AX/CG fixtures |
| `Browser/CDPClient.swift`, `Browser/WebInspectorXPC.swift` | Speak Chrome DevTools / WebKit Inspector protocols | Integration tests with real Chrome / Safari instances |
| `Recording/VideoRecorder.swift` | `AVAssetWriter` against a temp file | Integration tests; assert produced video has expected duration |
| `Config/ConfigStore.swift` | Reads/writes `~/Library/Application Support/...` | Could be unit-tested if `configDirectoryURL` were dependency-injected; deferred to a focused refactor |
| `Telemetry/TelemetryClient.swift` | Posts to PostHog HTTP endpoint | Currently dead code in this repo (no caller); slated for neutralization before any executable target consumes the engine |
| `Cursor/AgentCursor*.swift` | NSWindow / CALayer side-effects | Visual review; not unit-testable |

## The integration / background-invariant target (not in this PR)

`CLAUDE.md` § Testing mandates a `Tests/BackgroundInvariantTests/`
target that runs end-to-end against real apps and asserts the
"every action stays in the background" contract:

- Cursor position unchanged before/after a task
- Frontmost app unchanged
- Active Space unchanged
- TextEdit-typing-during-task content matches expected (no leaked keystrokes)

That target is built in Phase 4 once an executable consumes
`Automation/`. The right time to add it is after the
`AgentSupervisor` actor lands in Phase 1 — then the invariant suite
has something concrete to drive end-to-end. Until then, this
directory is unit-only.

## Integration tests (`EngineIntegrationTests.swift`)

Action-tier `Engine` methods that touch real macOS state — launching
apps, driving AX trees, posting events — get an integration test
here, gated behind the `CACTY_INTEGRATION_TESTS=1` env var so
routine `swift test` runs skip them. Two contracts:

1. **CI never launches Calculator on every push.** Default
   `swift test` stays fast and side-effect-free.
2. **Background-safety regressions get caught at developer-machine
   speed.** Every integration test snapshots the frontmost app
   before the action and asserts it is unchanged after. That is
   the whole reason the engine exists, and these tests are the only
   thing that catches a regression in the no-foreground guarantee.

Naming: integration tests live in files ending
`*IntegrationTests.swift` and use `XCTSkip` in `setUpWithError`
when the env var is unset.

## Running

```bash
swift test                                                # all tests; integration tier skipped without env var
swift test --filter Cubic                                 # just cubic-bezier
swift test --filter Codable                               # just value-type round-trips
CACTY_INTEGRATION_TESTS=1 swift test                      # everything including real-launch tests
CACTY_INTEGRATION_TESTS=1 swift test --filter Integration # just the integration tier
```
