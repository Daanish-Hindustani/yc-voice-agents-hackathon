import AppKit
import ApplicationServices
import Foundation

/// The supervisor-facing entry point for the `Automation` module.
///
/// `Engine` is a thin coordinating actor over the engine subsystems
/// (`AppEnumerator`, `AppLauncher`, `WindowEnumerator`, `Permissions`,
/// and the AX / SkyLight / capture primitives). It exists so the
/// `AgentSupervisor` (Phase 1) has a single object to hold and a
/// single place to add cross-cutting concerns (logging, structured
/// errors, the `(pid, window_id)` AX-state cache plan.md mentions)
/// rather than reaching into a dozen free `enum`s.
///
/// Naming: the SwiftPM module is `Automation`, so the actor is named
/// `Engine` rather than `Automation` — `public actor Automation`
/// inside module `Automation` would shadow the module name and force
/// callers to write `Automation.Automation`. Module-qualified, this
/// reads `Automation.Engine` from outside.
///
/// Scope of this file (PR 0.2): the read-only / non-AX-side-effecting
/// methods that are unit-testable today. The action-tier methods
/// (`clickElement`, `clickPixel`, `type`, `pressKey`, `getWindowState`,
/// `launchApp`, `scroll`, `captureStream`) land in subsequent PRs as
/// Phase 0 spikes finish — those need real Accessibility, Screen
/// Recording, and Input Monitoring grants and belong in the future
/// `BackgroundInvariantTests` integration suite.
public actor Engine {
    /// Errors that surface across the public API.
    ///
    /// Per the no-foreground contract, every action-tier method (added
    /// in later PRs) returns a structured `ActionResult` rather than
    /// throwing for ordinary failures — that keeps the supervisor's
    /// branching predictable. `EngineError` is reserved for genuine
    /// programmer errors and unrecoverable system failures
    /// (`Permissions` probe could not run at all, etc.).
    public enum EngineError: Error, CustomStringConvertible, Sendable, Equatable {
        /// The caller asked for a window owned by a different process.
        case windowNotOwnedByPid(windowId: Int, ownerPid: Int32, requestedPid: Int32)

        /// `launchApp` failed — bundle id not resolvable, LaunchServices
        /// rejected the launch, or the OS returned an error before the
        /// target app finished launching. The wrapped `reason` is the
        /// underlying error's `String(describing:)` so the supervisor
        /// can render it directly in the approval bar / console.
        case appLaunchFailed(reason: String)

        /// The caller passed a `windowId` that doesn't fit a `CGWindowID`
        /// (a `UInt32`). Negative ints or ints larger than `UInt32.max`
        /// can't refer to a real window — the API takes `Int` for
        /// caller convenience (matches `WindowInfo.id`) but the
        /// underlying CG / AX layer is `UInt32`-typed.
        case invalidWindowId(Int)

        /// `getWindowState` failed — Accessibility not granted, target
        /// pid no longer running, AX snapshot timed out, or any other
        /// failure surfaced by the engine. The wrapped `reason`
        /// preserves the underlying error message via
        /// `String(describing:)`.
        case windowStateFailed(reason: String)

        /// The cached AX-element map for `(pid, windowId)` does not
        /// contain `elementIndex` — most commonly because no
        /// `getWindowState` call has been made for this window yet,
        /// or the snapshot's `elementCount` is smaller than the
        /// requested index. The supervisor should respond by
        /// re-snapshotting and retrying, **not** by escalating —
        /// this is a stale-cache failure, not a target-app failure.
        case elementNotFound(pid: Int32, windowId: Int, elementIndex: Int)

        /// The AX element exists in the cache but the requested
        /// action did not land. Either the element does not
        /// advertise the action (e.g. asking `AXPress` of an
        /// `AXStaticText`), or the AX dispatch itself returned a
        /// non-success code. The supervisor should treat this as
        /// "the click was a no-op against this element" and try a
        /// different interaction strategy, not retry against the
        /// same index. The wrapped `reason` preserves the
        /// underlying engine error message.
        case actionRefused(reason: String)

        /// `clickElement` failed for a reason not covered by
        /// `elementNotFound` or `actionRefused` — typically
        /// Accessibility being revoked between the snapshot and the
        /// click, or any other authorization/system-level failure
        /// surfaced by the AX layer.
        case clickFailed(reason: String)

        /// `screenshot` / `captureStream` failed — Screen Recording
        /// permission not granted, the target window has gone away,
        /// or ScreenCaptureKit returned an error. The wrapped
        /// `reason` preserves the underlying engine error message.
        case captureFailed(reason: String)

        /// `type` failed — keystroke event posting refused by the
        /// OS, target pid no longer running, or any other failure
        /// surfaced by the keyboard layer. The wrapped `reason`
        /// preserves the underlying engine error message.
        case typeFailed(reason: String)

        /// `page` (browser page primitive) failed — JS execution
        /// rejected by the browser, missing required parameter,
        /// unsupported browser, etc. Wrapped `reason` carries the
        /// underlying error message.
        case pageActionFailed(reason: String)

        public var description: String {
            switch self {
            case .windowNotOwnedByPid(let windowId, let ownerPid, let requestedPid):
                return "Window \(windowId) is owned by pid \(ownerPid), not pid \(requestedPid)."
            case .appLaunchFailed(let reason):
                return "App launch failed: \(reason)"
            case .invalidWindowId(let value):
                return "Invalid window_id \(value) — must be a non-negative integer <= UInt32.max."
            case .windowStateFailed(let reason):
                return "Window state snapshot failed: \(reason)"
            case .elementNotFound(let pid, let windowId, let elementIndex):
                return "Element index \(elementIndex) not found in cache for (pid: \(pid), window: \(windowId)). Snapshot the window first."
            case .actionRefused(let reason):
                return "Element refused the action: \(reason)"
            case .clickFailed(let reason):
                return "Click failed: \(reason)"
            case .typeFailed(let reason):
                return "Type failed: \(reason)"
            case .captureFailed(let reason):
                return "Capture failed: \(reason)"
            case .pageActionFailed(let reason):
                return "Page action failed: \(reason)"
            }
        }
    }

    /// AX state engine — owns the per-(pid, windowId) element index
    /// cache. Holding it as actor-isolated state is what unlocks
    /// element-index-based clicks: a click resolved by index has to
    /// see the same cache the snapshot wrote into.
    private let appStateEngine = AppStateEngine()

    /// Shared reactive focus-steal preventer. Used by `FocusGuard`
    /// during clicks, and directly by `launchApp` to suppress
    /// activations during the post-launch grace window
    /// (`launchSuppressionWindowNs`) for slow-to-initialize apps
    /// (Slack, Chrome, VS Code…).
    private let systemFocusStealPreventer: SystemFocusStealPreventer

    /// Total window during which `launchApp` keeps the focus-steal
    /// preventer armed and polls frontmost to re-demote the target.
    ///
    /// **Cacty divergence from cua (5th documented).** cua uses a
    /// fixed 500 ms suppression hold + one-shot belt-and-braces
    /// demote. Electron apps (Slack, Discord, Teams, VS Code) fire
    /// multiple `NSApp.activate(ignoringOtherApps:)` calls across a
    /// 2–5 s cold boot — any activation that fires after cua's
    /// 500 ms window closes leaves the target stuck frontmost. The
    /// extended 5 s window catches the full Electron boot. See
    /// CLAUDE.md "The background contract" for the full rationale.
    private static let launchSuppressionWindowNs: UInt64 = 5_000_000_000

    /// Interval between frontmost polls inside the launch
    /// suppression window. 100 ms is short enough that the user
    /// never sees a sustained foreground flash on a target
    /// activation that the observer somehow missed, and long
    /// enough that the poll is essentially free.
    private static let launchPollIntervalNs: UInt64 = 100_000_000

    /// Number of poll iterations inside the launch suppression
    /// window. Precomputed at compile time so the hot loop in
    /// `launchApp` doesn't pay a runtime `UInt64` division.
    private static let totalLaunchPollTicks: Int =
        Int(launchSuppressionWindowNs / launchPollIntervalNs)

    /// **Cacty divergence #8.** Anti-throttle flags appended to a
    /// Chromium-family browser's launch arguments when Cacty is the
    /// one launching it. Chromium pauses compositing of the Blink
    /// content layer for windows it considers occluded or
    /// non-focused, which under Cacty's "visible-but-not-frontmost"
    /// background contract means the agent-driven window's web
    /// content stops painting — the LivePopoverView capture shows
    /// the AppKit-native tab strip but a black content region until
    /// the user manually foregrounds Chrome.
    ///
    /// - `--disable-backgrounding-occluded-windows`: keep painting
    ///   when the window is judged occluded.
    /// - `--disable-renderer-backgrounding`: keep the renderer
    ///   process at normal priority when the window isn't focused.
    /// - `--disable-background-timer-throttling`: keep timers /
    ///   `requestAnimationFrame` firing at full rate.
    ///
    /// Documented limitation: LaunchServices reuses an
    /// already-running browser instance and silently drops these
    /// flags. Effective only on a cold launch from Cacty.
    private static let chromiumAntiThrottleFlags: [String] = [
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
        "--disable-background-timer-throttling",
    ]

    /// Bundle IDs that ship a Chromium / Blink renderer. Mirrors
    /// the supported-browser list in `Sources/Automation/Browser/`
    /// (Chrome, Brave, Edge) plus the common channel variants
    /// (Canary, Beta, Dev) and other shipping Chromium browsers we
    /// know about. Used to gate the anti-throttle flag injection in
    /// `launchApp` — see `chromiumAntiThrottleFlags`.
    ///
    /// Safari (`com.apple.Safari`) is NOT here: it's WebKit, has its
    /// own occlusion policy, and rejects Chromium CLI flags.
    private static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser",  // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// `true` when `bundleId` is a Chromium-family browser whose
    /// launch should include `chromiumAntiThrottleFlags`. Exact
    /// match against the known list — bundle ID misspellings or
    /// case differences silently skip injection, which is the
    /// fail-safe direction (no flags is better than wrong flags
    /// passed to an unrelated app).
    private static func isChromiumBundle(_ bundleId: String) -> Bool {
        chromiumBundleIds.contains(bundleId)
    }

    /// Shared AX-enablement assertion. Chromium / Electron apps
    /// keep their AX tree empty until we set
    /// `AXManualAccessibility` / `AXEnhancedUserInterface` on the
    /// application root. Used by `FocusGuard` and by
    /// `getWindowState` so a hidden Slack / VS Code / Chrome
    /// renders text content into the tree before we walk it.
    private let axEnablement: AXEnablementAssertion

    /// 3-layer focus-suppression guard wrapped around every AX
    /// action that touches a backgrounded app. Without this,
    /// Electron / Chromium apps like Slack respond to AXPress by
    /// invoking `[NSApp activate]` internally and steal focus —
    /// the cua-engine ships the components but the engine has to
    /// wire them. See `Focus/FocusGuard.swift`.
    private let focusGuard: FocusGuard

    public init() {
        let preventer = SystemFocusStealPreventer()
        let enablement = AXEnablementAssertion()
        self.systemFocusStealPreventer = preventer
        self.axEnablement = enablement
        self.focusGuard = FocusGuard(
            enablement: enablement,
            enforcer: SyntheticAppFocusEnforcer(),
            systemPreventer: preventer
        )
    }

    // MARK: - Identity

    /// Engine version string. Derived from `CuaDriverCore.version` so
    /// the on-disk semver source of truth stays in one place.
    ///
    /// `nonisolated` because no actor state is read — callers do not
    /// pay an actor-hop or an `await` to read this. The action-tier
    /// methods that land in subsequent PRs *do* touch actor-isolated
    /// state (the `(pid, window_id)` AX cache) and stay isolated.
    public nonisolated var version: String {
        return CuaDriverCore.version
    }

    // MARK: - Inventory (read-only, no permissions required, nonisolated)

    /// All apps macOS knows about: running processes plus installed
    /// `.app` bundles in the standard locations. Use this when the
    /// agent might need to launch an app that isn't running yet —
    /// `.running == false` means the entry came from disk, not from
    /// `NSWorkspace.runningApplications`.
    ///
    /// `nonisolated` because the underlying enumerator is stateless
    /// — concurrent callers do not contend on the actor's executor.
    public nonisolated func listApps() -> [AppInfo] {
        return AppEnumerator.apps()
    }

    /// All windows belonging to `pid`, including off-screen and
    /// minimized windows. The Phase 1 supervisor uses this to
    /// resolve a `window_id` before issuing AX clicks scoped to a
    /// specific window.
    ///
    /// Returns an empty array if the pid has no windows or doesn't
    /// exist. Does not throw — "no windows" is a normal state for a
    /// freshly-launched menu-bar-only app.
    ///
    /// `nonisolated` for the same reason as `listApps` — the
    /// `WindowEnumerator` is a stateless `CGWindowListCopyWindowInfo`
    /// query, and parallel `listWindows` calls across pids should
    /// not serialize on this actor.
    public nonisolated func listWindows(forPid pid: Int32) -> [WindowInfo] {
        return WindowEnumerator.allWindows().filter { $0.pid == pid }
    }

    /// Current Accessibility + Screen Recording grant state for the
    /// running process. The Phase 4 onboarding flow uses this to gate
    /// the "you're ready" screen. Phase 1 uses it to surface a clear
    /// error when an action call would otherwise silently no-op.
    ///
    /// `nonisolated` because the probe reads OS state, not actor
    /// state. Stays `async` because the screen-recording check is
    /// itself async.
    public nonisolated func permissions() async -> PermissionsStatus {
        return await Permissions.currentStatus()
    }

    // MARK: - Action surface (no AX state mutation yet)

    /// Launch a macOS app in the background — no focus steal, no
    /// window raise, no Space switch. The target's AX tree finishes
    /// populating during launch but it does not become the frontmost
    /// app. Returns the resulting `AppInfo`.
    ///
    /// Port of cua's `LaunchAppTool`
    /// (`cua-driver/Sources/CuaDriverServer/Tools/LaunchAppTool.swift:188-274`)
    /// with one documented divergence: cua's 500 ms one-shot
    /// suppression hold is replaced with a 5 s polling window that
    /// re-demotes the target on every 100 ms tick. The two-phase
    /// preventer (placeholder pid=0 → real pid after `open()`
    /// returns) is preserved verbatim. The window extension is
    /// Cacty's 5th cua divergence — see `launchSuppressionWindowNs`
    /// and CLAUDE.md "The background contract" for the Slack /
    /// Electron focus-steal rationale.
    ///
    /// Background-safety model: cua-style "visible-but-not-frontmost."
    /// Launched apps remain composited and may be visible to the
    /// user; the contract is that they do not steal *frontmost*
    /// from whatever the user is currently using. See CLAUDE.md
    /// "The background contract" section.
    ///
    /// Actor-isolated because the launch path arms the
    /// `SystemFocusStealPreventer` (shared per-engine state).
    public func launchApp(
        bundleId: String? = nil,
        name: String? = nil,
        urls: [URL] = [],
        additionalArguments: [String] = [],
        additionalEnvironment: [String: String] = [:],
        createsNewApplicationInstance: Bool = false,
        electronDebuggingPort: Int? = nil,
        webkitInspectorPort: Int? = nil
    ) async throws(EngineError) -> AppInfo {
        if bundleId == nil && name == nil {
            throw .appLaunchFailed(reason:
                "Provide either bundleId or name to identify the app to launch.")
        }

        var mergedArgs = additionalArguments
        if let port = electronDebuggingPort {
            mergedArgs.append("--remote-debugging-port=\(port)")
        }
        // Cacty divergence #8: inject Chromium anti-throttle flags
        // for fresh launches of Chromium-family browsers so the
        // renderer keeps painting while the window is occluded /
        // non-frontmost. Without these, the LivePopoverView capture
        // shows the AppKit-native tab strip + omnibox but a black
        // web-content region — Chrome pauses compositing of the
        // Blink layer for backgrounded windows, and Cacty's
        // background contract (`visible-but-not-frontmost`) means
        // the agent-driven window is always backgrounded. SCK
        // captures the stale IOSurface → black content.
        //
        // Only effective on a true fresh launch — LaunchServices
        // reuses an already-running instance and silently drops
        // these flags. Documented limitation; user-visible UX
        // remediation is in `LivePopoverView`'s placeholder branch.
        // See CLAUDE.md § "The background contract" divergence list.
        if let bundleId, Self.isChromiumBundle(bundleId) {
            for flag in Self.chromiumAntiThrottleFlags
                where !mergedArgs.contains(flag) {
                mergedArgs.append(flag)
            }
        }

        var mergedEnv = additionalEnvironment
        if let port = webkitInspectorPort {
            mergedEnv["WEBKIT_INSPECTOR_SERVER"] = "127.0.0.1:\(port)"
            mergedEnv["TAURI_WEBVIEW_AUTOMATION"] = "1"
        }

        // Snapshot priorFrontmost and arm the preventer with a
        // placeholder pid=0 BEFORE the launch so any
        // `NSApp.activate(ignoringOtherApps:)` the target makes
        // in `applicationDidFinishLaunching` — or during a URL-open
        // handoff (Chrome does this) — is caught by the observer.
        // Arming after launch was a race: targets that self-activate
        // synchronously during `open` would have fired their
        // activation notification before our observer attached.
        let priorFrontmost = NSWorkspace.shared.frontmostApplication

        var handle: SuppressionHandle?
        if let priorFrontmost {
            handle = await systemFocusStealPreventer
                .beginSuppression(targetPid: 0, restoreTo: priorFrontmost)
        }

        let info: AppInfo
        do {
            info = try await AppLauncher.launch(
                bundleId: bundleId,
                name: name,
                urls: urls,
                additionalArguments: mergedArgs,
                additionalEnvironment: mergedEnv,
                createsNewApplicationInstance: createsNewApplicationInstance
            )
        } catch {
            if let handle {
                await systemFocusStealPreventer.endSuppression(handle)
            }
            throw .appLaunchFailed(reason: String(describing: error))
        }

        // Replace the placeholder pid with the real one so any
        // activation the target emits from now on is caught.
        let shouldSuppress =
            priorFrontmost != nil
            && priorFrontmost?.processIdentifier != info.pid
        if shouldSuppress, let handle, let priorFrontmost {
            await systemFocusStealPreventer.endSuppression(handle)
            let reArmedHandle = await systemFocusStealPreventer
                .beginSuppression(targetPid: info.pid, restoreTo: priorFrontmost)
            // Poll frontmost every `launchPollIntervalNs` for
            // `launchSuppressionWindowNs` total — see the constants'
            // doc comments and CLAUDE.md "The background contract"
            // for why this diverges from cua's 500 ms one-shot.
            // Electron apps (Slack, Discord, Teams, VS Code) emit
            // multiple `NSApp.activate(ignoringOtherApps:)` calls
            // across a 2–5 s cold boot; the preventer's observer
            // catches each as it fires, and this poll catches any
            // activation that reached frontmost via a path that
            // didn't post `didActivateApplicationNotification`
            // (Electron has been observed to do this on some boot
            // paths). Re-demoting via `priorFrontmost.activate` is
            // the same primitive cua's one-shot uses — just
            // applied across the whole 5 s window.
            for _ in 0..<Self.totalLaunchPollTicks {
                // Honor cooperative cancellation — without this guard,
                // `try? await Task.sleep` would swallow `CancellationError`
                // and turn the remaining iterations into a tight busy-loop
                // that spams `priorFrontmost.activate` 50× after the
                // worker was cancelled.
                if Task.isCancelled { break }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == info.pid {
                    _ = priorFrontmost.activate(options: [])
                }
                try? await Task.sleep(nanoseconds: Self.launchPollIntervalNs)
            }
            await systemFocusStealPreventer.endSuppression(reArmedHandle)
        } else if let handle {
            await systemFocusStealPreventer.endSuppression(handle)
        }

        return info
    }

    /// Snapshot the AX tree for a specific window.
    ///
    /// Walks the target pid's accessibility tree, assigns numeric
    /// indices to every actionable element, and caches the
    /// `(pid, windowId) → element_index → AXUIElement` map for
    /// downstream clicks. The returned `AppStateSnapshot` carries
    /// `treeMarkdown` for the model to read and `elementCount` for
    /// quick sanity checks.
    ///
    /// **Actor-isolated** — unlike the read-only methods above, this
    /// writes the AX cache that future click-by-element-index
    /// methods will read. Concurrent callers serialize on the
    /// engine's executor so a click never sees a half-written
    /// cache. If the supervisor genuinely needs concurrent
    /// snapshots across pids, multiple `Engine` instances are the
    /// right answer (one cache per supervisor task in flight).
    ///
    /// **Background-safety:** the AX walk reads the target pid's
    /// tree — never raises a window, changes frontmost, or moves
    /// the cursor. Window screenshot capture (when `captureMode`
    /// includes the pixel pathway) uses ScreenCaptureKit's
    /// `desktopIndependentWindow` filter — also background-safe.
    ///
    /// - Parameter pid: Target process id (from `listApps()`).
    /// - Parameter windowId: Window id from `listWindows(forPid:)`.
    ///   Must fit `CGWindowID` (`UInt32`) — the API takes `Int`
    ///   for caller convenience but rejects values that can't
    ///   refer to a real window.
    /// - Parameter captureMode:
    ///   - `.som` (default): AX walk + base64 PNG screenshot.
    ///     Use to read Slack/Discord/Electron message text that
    ///     does not surface in the AX tree.
    ///   - `.ax`: AX walk only; `screenshot_*` fields omitted.
    ///     Cheaper payload — use for verification snapshots and
    ///     element-only navigation.
    ///   - `.vision`: screenshot only; `tree_markdown` is empty
    ///     and `element_count` is 0. Skips the AX walk entirely.
    /// - Returns: The AX snapshot. `screenshot_*` fields are
    ///   present only for `.som` and `.vision`.
    /// - Throws:
    ///   - `EngineError.invalidWindowId` if `windowId` doesn't fit
    ///     `UInt32`.
    ///   - `EngineError.windowStateFailed` if the AX walk fails
    ///     (Accessibility not granted, pid no longer running, etc.).
    public func getWindowState(
        pid: Int32,
        windowId: Int,
        captureMode: CaptureMode = .som
    ) async throws(EngineError) -> AppStateSnapshot {
        guard let cgWindowId = UInt32(exactly: windowId) else {
            throw .invalidWindowId(windowId)
        }
        // Build the AX half of the snapshot per captureMode.
        // `.vision` skips the AX walk entirely (and its enablement
        // assertion) — useful when only the screenshot is needed
        // and the host has Screen Recording but not Accessibility.
        // AX enablement happens inside `appStateEngine.snapshot` on
        // the `.ax` / `.som` paths via the shared
        // `AXEnablementAssertion`; cua does not arm a
        // SystemFocusStealPreventer around `get_window_state` and
        // neither do we.
        // .vision: no AX walk, no rect transform needed — just
        // metadata + screenshot below.
        if captureMode == .vision {
            let baseSnapshot: AppStateSnapshot
            do {
                baseSnapshot = try await appStateEngine.metadataOnly(pid: pid)
            } catch {
                throw .windowStateFailed(reason: String(describing: error))
            }
            return await Self.attachScreenshot(
                pid: pid, cgWindowId: cgWindowId, base: baseSnapshot
            )
        }

        // .ax: no screenshot, no transform — model can't pixel-click
        // without a screenshot anyway, so rects in the tree would be
        // misleading. Mirrors cua's behavior.
        if captureMode == .ax {
            do {
                return try await appStateEngine.snapshot(
                    pid: pid, windowId: cgWindowId
                )
            } catch {
                throw .windowStateFailed(reason: String(describing: error))
            }
        }

        // .som: capture screenshot FIRST so the AX walk can emit
        // rects in the same scaled-image-pixel space the model will
        // use to drive `click(x, y)`. If capture fails (Screen
        // Recording revoked, window unshareable), fall back to a
        // no-rect snapshot — still returns a usable tree.
        let shot: Screenshot?
        do {
            shot = try await WindowCapture().captureWindow(
                windowID: cgWindowId,
                format: .png,
                quality: 95,
                maxImageDimension: 1600
            )
        } catch {
            shot = nil
        }

        var transform: AppStateEngine.RectTransform? = nil
        if let shot {
            await ImageScaleRegistry.shared.record(
                pid: pid,
                windowId: cgWindowId,
                capturedWidth: shot.width,
                capturedHeight: shot.height,
                originalWidth: shot.originalWidth,
                originalHeight: shot.originalHeight,
                scaleFactor: shot.scaleFactor
            )
            if let scale = await ImageScaleRegistry.shared.lookup(
                pid: pid, windowId: cgWindowId
            ),
               let window = WindowEnumerator.allWindows().first(
                where: { UInt32($0.id) == cgWindowId }
               )
            {
                transform = Self.makeImagePixelTransform(
                    windowOriginX: window.bounds.x,
                    windowOriginY: window.bounds.y,
                    scale: scale
                )
            }
        }

        let baseSnapshot: AppStateSnapshot
        do {
            baseSnapshot = try await appStateEngine.snapshot(
                pid: pid,
                windowId: cgWindowId,
                imagePixelTransform: transform
            )
        } catch {
            throw .windowStateFailed(reason: String(describing: error))
        }

        guard let shot else { return baseSnapshot }
        return AppStateSnapshot(
            pid: baseSnapshot.pid,
            bundleId: baseSnapshot.bundleId,
            name: baseSnapshot.name,
            treeMarkdown: baseSnapshot.treeMarkdown,
            elementCount: baseSnapshot.elementCount,
            turnId: baseSnapshot.turnId,
            screenshotPngBase64: shot.imageData.base64EncodedString(),
            screenshotWidth: shot.width,
            screenshotHeight: shot.height,
            screenshotScaleFactor: shot.scaleFactor,
            screenshotOriginalWidth: shot.originalWidth,
            screenshotOriginalHeight: shot.originalHeight
        )
    }

    /// Capture the target window's PNG, record its scale ratio, and
    /// graft it onto `base`. Used by `.vision` mode, which has no AX
    /// walk to feed a rect transform into. Capture failure (Screen
    /// Recording revoked, etc.) is non-fatal — returns `base`
    /// unchanged.
    private static func attachScreenshot(
        pid: Int32, cgWindowId: UInt32, base: AppStateSnapshot
    ) async -> AppStateSnapshot {
        let shot: Screenshot
        do {
            shot = try await WindowCapture().captureWindow(
                windowID: cgWindowId,
                format: .png,
                quality: 95,
                maxImageDimension: 1600
            )
        } catch {
            return base
        }
        await ImageScaleRegistry.shared.record(
            pid: pid,
            windowId: cgWindowId,
            capturedWidth: shot.width,
            capturedHeight: shot.height,
            originalWidth: shot.originalWidth,
            originalHeight: shot.originalHeight,
            scaleFactor: shot.scaleFactor
        )
        return AppStateSnapshot(
            pid: base.pid,
            bundleId: base.bundleId,
            name: base.name,
            treeMarkdown: base.treeMarkdown,
            elementCount: base.elementCount,
            turnId: base.turnId,
            screenshotPngBase64: shot.imageData.base64EncodedString(),
            screenshotWidth: shot.width,
            screenshotHeight: shot.height,
            screenshotScaleFactor: shot.scaleFactor,
            screenshotOriginalWidth: shot.originalWidth,
            screenshotOriginalHeight: shot.originalHeight
        )
    }

    /// Build a closure that converts a screen-global AX rect (points,
    /// top-left origin) to a scaled-image-pixel rect — the exact
    /// coordinate space `click(x, y)` accepts. Inverse of
    /// `windowLocalToScreen`:
    ///
    ///   imagePixelX = (axGlobalX - windowBounds.x) / xRatio
    ///   imagePixelY = (axGlobalY - windowBounds.y) / yRatio
    ///
    /// Width and height divide by the same ratios (no origin offset
    /// — they're already in points). `windowBounds` and `scale` are
    /// captured by value so the returned closure can run
    /// synchronously inside the AX walk (`renderTree` is sync; it
    /// can't `await` the registry).
    ///
    /// **Cacty divergence #7** — see `AppStateEngine.RectTransform`
    /// docstring and CLAUDE.md § divergence list.
    private static func makeImagePixelTransform(
        windowOriginX: Double,
        windowOriginY: Double,
        scale: ImageScaleRegistry.Scale
    ) -> AppStateEngine.RectTransform {
        let xRatio = scale.xRatio
        let yRatio = scale.yRatio
        return { @Sendable rect in
            guard xRatio > 0, yRatio > 0 else { return rect }
            return CGRect(
                x: (rect.origin.x - windowOriginX) / xRatio,
                y: (rect.origin.y - windowOriginY) / yRatio,
                width: rect.size.width / xRatio,
                height: rect.size.height / yRatio
            )
        }
    }

    /// Click the AX element at `elementIndex` inside `(pid, windowId)`.
    ///
    /// Resolves the index against the per-`(pid, windowId)` element
    /// cache populated by `getWindowState`, then dispatches `AXPress`
    /// directly via the AX API — no event synthesis, no cursor move,
    /// no window raise. This is the primary, fully-background-safe
    /// click path. Use `clickPixel` only when no `elementIndex` is
    /// available (canvas / WebGL / custom-rendered surfaces; lands
    /// in a follow-up PR).
    ///
    /// **Caller contract:** call `getWindowState(pid:windowId:)`
    /// first in the same supervisor turn. Element indices are
    /// cache-keyed on `(pid, windowId)` and the cache is populated
    /// only by snapshot. Calling `clickElement` without a prior
    /// snapshot throws `.clickFailed`.
    ///
    /// **Background-safety:** `AXUIElementPerformAction` skips event
    /// synthesis entirely — there is no synthetic mouse event, no
    /// cursor warp, no window-raise side-effect. The frontmost app,
    /// the active Space, and the user's keyboard focus are
    /// untouched.
    ///
    /// **Actor-isolated** — reads the same cache `getWindowState`
    /// writes. Serialization on the actor's executor means a click
    /// can never observe a half-written cache from a concurrent
    /// snapshot.
    ///
    /// - Parameter pid: Target process id (must match the snapshot's pid).
    /// - Parameter windowId: Window id (must match the snapshot's
    ///   windowId — indices from one window's snapshot do **not**
    ///   resolve against another).
    /// - Parameter elementIndex: Index from the snapshot's
    ///   `treeMarkdown`.
    /// - Throws:
    ///   - `EngineError.invalidWindowId` if `windowId` doesn't fit `UInt32`.
    ///   - `EngineError.elementNotFound` if no snapshot has been
    ///     taken for `(pid, windowId)` or the index is out of range.
    ///   - `EngineError.actionRefused` if the element exists in the
    ///     cache but does not advertise `AXPress` or the AX dispatch
    ///     returned a non-success code.
    ///   - `EngineError.clickFailed` for any other failure
    ///     (Accessibility revoked between snapshot and click, etc.).
    /// Unified click entry-point — mirrors cua's `ClickTool`. Two
    /// addressing modes:
    ///
    /// 1. `elementIndex` + `windowId` — AX `AXPress` against the
    ///    cached element inside `FocusGuard`. Background-safe, no
    ///    cursor move, works on hidden windows.
    /// 2. `x` + `y` — window-local scaled-image pixel coords
    ///    (the same space the model addressed via `get_window_state`).
    ///    Translated through `ImageScaleRegistry` to native window
    ///    points, then routed through `MouseInput.click`. `count`
    ///    supports stamped double-clicks; `modifiers` propagate
    ///    cmd/shift/option/ctrl during the gesture.
    ///
    /// Exactly one mode must be supplied. Mixing modes (both
    /// elementIndex and x/y) throws `clickFailed`.
    public func click(
        pid: Int32,
        windowId: Int? = nil,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        modifiers: [String] = [],
        count: Int = 1
    ) async throws(EngineError) {
        let hasElement = (elementIndex != nil)
        let hasPixel = (x != nil && y != nil)
        if hasElement && hasPixel {
            throw .clickFailed(reason:
                "click: pass either elementIndex+windowId OR x+y, not both.")
        }
        if hasElement {
            guard let elementIndex, let windowId else {
                throw .clickFailed(reason:
                    "click: elementIndex requires windowId.")
            }
            try await clickElement(
                pid: pid, windowId: windowId, elementIndex: elementIndex
            )
            return
        }
        guard let x, let y else {
            throw .clickFailed(reason:
                "click: requires either elementIndex+windowId or x+y.")
        }
        let screenPoint = try await Self.windowLocalToScreen(
            pid: pid, windowIdHint: windowId, x: x, y: y
        )
        try Self.refuseIfMenuBar(screenPoint)
        // **Cacty extension.** When the target is on another Space
        // than the user, force MouseInput's pid-routed path
        // unconditionally. The default `isActive`-based routing
        // sends through the system HID stream, which lands on the
        // user's *visible* Space (wrong app, real cursor jumps).
        // See `MouseInput.click`'s `forcePidRoute` doc.
        let forcePidRoute = Self.shouldForcePidRoute(forPid: pid)
        await cursorPreFlight(pid: pid, to: screenPoint)
        do {
            try MouseInput.click(
                at: screenPoint, toPid: pid,
                button: .left,
                count: max(1, min(3, count)),
                modifiers: modifiers,
                forcePidRoute: forcePidRoute
            )
        } catch {
            throw .clickFailed(reason: String(describing: error))
        }
        await cursorPostClick(pid: pid)
    }

    public func clickElement(
        pid: Int32,
        windowId: Int,
        elementIndex: Int
    ) async throws(EngineError) {
        guard let cgWindowId = UInt32(exactly: windowId) else {
            throw .invalidWindowId(windowId)
        }
        let element: AXUIElement
        do {
            element = try await appStateEngine.lookup(
                pid: pid, windowId: cgWindowId, elementIndex: elementIndex
            )
        } catch {
            // `lookup` throws for cache miss or out-of-range index;
            // both surface as `elementNotFound` so the supervisor
            // can pattern-match without parsing strings.
            throw .elementNotFound(
                pid: pid, windowId: windowId, elementIndex: elementIndex
            )
        }
        // Belt-and-suspenders Accessibility guard. The snapshot
        // step already required AX to be granted, but a user can
        // revoke it between snapshot and click; without this guard
        // the call would silently return success because
        // `AXUIElementPerformAction` returns success for un-
        // authorized callers and does nothing.
        do {
            try AXInput.requireAuthorized()
        } catch {
            throw .clickFailed(reason: String(describing: error))
        }
        // `AXUIElementPerformAction` returns success even when the
        // element doesn't advertise the action (silent no-op). Check
        // the advertised list ourselves and refuse rather than
        // pretending the click landed. The `!isEmpty` guard
        // preserves "try anyway" behavior for elements where
        // `AXUIElementCopyActionNames` itself fails (returns empty)
        // — that's the right default for exotic apps that don't
        // report their actions.
        let advertised = AXInput.advertisedActionNames(of: element)
        if !advertised.isEmpty && !advertised.contains("AXPress") {
            // **Cacty divergence from cua-driver.** cua refuses (and
            // its tool layer warns the model to retry with a pixel
            // click); Cacty's voice-PTT UX can't afford the extra
            // round-trip, so when the element exposes a resolvable
            // screen position we fall back to a pid-routed
            // pixel click at its center. Common case: Google
            // Calendar end-time popover items advertise only
            // `AXShowMenu` / `AXScrollToVisible`, where the model
            // empirically needed two extra steps (re-snapshot,
            // pixel-click retry) to land the click — wiring the
            // fallback in-engine removes that latency.
            //
            // Safety: still inside `FocusGuard.withFocusSuppressed`
            // semantics indirectly via `MouseInput.click` with
            // `forcePidRoute` when the target is off-Space, plus
            // the post-click idle-hide on the agent cursor. We do
            // NOT fall back when the element has no screen
            // center (e.g. occluded / off-screen) — pixel-clicking
            // a nonexistent point would only deliver to whatever's
            // currently rendered there.
            if let center = AXInput.screenCenter(of: element) {
                try Self.refuseIfMenuBar(center)
                let forcePidRoute = Self.shouldForcePidRoute(forPid: pid)
                await cursorPreFlight(pid: pid, to: center)
                do {
                    try MouseInput.click(
                        at: center, toPid: pid,
                        button: .left,
                        count: 1,
                        modifiers: [],
                        forcePidRoute: forcePidRoute
                    )
                } catch {
                    throw .clickFailed(reason:
                        "AXPress unavailable, pixel-click fallback failed: "
                        + String(describing: error)
                    )
                }
                let focusRect = AXInput.screenBoundingRect(of: element)
                await cursorPostClick(pid: pid, focusRect: focusRect)
                return
            }
            throw .actionRefused(
                reason:
                    "Element at index \(elementIndex) does not advertise AXPress "
                    + "and has no resolvable screen position for pixel-click "
                    + "fallback. Advertised actions: "
                    + advertised.joined(separator: ", ")
            )
        }
        // System menu-bar items (the File/Edit/View row at the top
        // of the screen) belong to the frontmost app by macOS
        // contract. Clicking one foregrounds the target — a
        // background-guarantee violation that no amount of
        // FocusGuard plumbing can prevent. Refuse here and let
        // the model retry with a keyboard shortcut via `type`
        // (pid-scoped CGEvent.postToPid, no foreground needed).
        let role = AXInput.stringAttribute("AXRole", of: element)
        if role == "AXMenuBarItem" || role == "AXMenuBar" {
            throw .actionRefused(
                reason:
                    "Refusing to click a system menu-bar element (role=\(role ?? "?")). "
                    + "Clicking macOS menu-bar items requires foregrounding "
                    + "the target app, violating the background guarantee. "
                    + "Use the `hotkey` tool with the menu item's keyboard "
                    + "equivalent instead (e.g. `hotkey(keys: [\"cmd\", \"n\"])` "
                    + "for New, `hotkey(keys: [\"cmd\", \"f\"])` for Find, "
                    + "`hotkey(keys: [\"cmd\", \",\"])` for Settings). Do NOT "
                    + "tell the user the action is impossible — re-issue the "
                    + "operation as a hotkey against the same pid."
            )
        }
        // Animate the visual agent cursor to the target before
        // firing the AX action. `cursorPreFlight` no-ops when the
        // overlay is disabled or when the element has no
        // resolvable position. Mirrors cua's
        // `ClickTool.swift:270-283`.
        if let center = AXInput.screenCenter(of: element) {
            await cursorPreFlight(pid: pid, to: center)
        }
        // Wrap the AX action in FocusGuard so Electron / Chromium
        // targets (Slack, Chrome, VS Code, …) don't activate
        // themselves in response to AXPress. The guard's layer-3
        // SystemFocusStealPreventer also catches late activations
        // and re-activates the prior frontmost app.
        let capturedElement = element
        do {
            try await focusGuard.withFocusSuppressed(
                pid: pid, element: capturedElement
            ) {
                try AXInput.performAction("AXPress", on: capturedElement)
            }
        } catch let err as AXInputError {
            throw .actionRefused(reason: String(describing: err))
        } catch {
            throw .clickFailed(reason: String(describing: error))
        }
        // Post-action: re-pin the overlay above the (possibly
        // raised) target window, draw a focus-rect highlight on
        // the element, then play the press pulse + dwell.
        // Mirrors cua's `ClickTool.swift:308-333`.
        let focusRect = AXInput.screenBoundingRect(of: capturedElement)
        await cursorPostClick(pid: pid, focusRect: focusRect)
    }

    /// Type `text` into the target pid via pid-scoped CGEvent posts.
    ///
    /// Each character of `text` is converted to a `CGEvent` keystroke
    /// pair (key-down + key-up) and dispatched via
    /// `CGEvent.postToPid` — meaning the events go to one process
    /// only and **never** route through the global HID stream.
    /// Keystrokes physically cannot leak to whatever the user is
    /// typing into; that's the property the no-foreground contract
    /// is built on.
    ///
    /// **Background-safety:** scoped event posting bypasses
    /// frontmost routing entirely. The user's keyboard focus, the
    /// frontmost app, and any keystrokes the user is actively
    /// pressing are all untouched. Hidden apps still receive these
    /// events — `launchApp` hides the target by default and `type`
    /// works against hidden apps the same as visible ones.
    ///
    /// **Nonisolated** — typing doesn't read or write the AX cache,
    /// so concurrent `type` calls into different pids should not
    /// serialize on the actor's executor.
    ///
    /// **Pending isolation promotion (Phase 1):** if per-pid IME
    /// state, throttling, or rate-limiting lands on the actor,
    /// promote here. The call-site syntax (`await engine.type(...)`)
    /// is unchanged but execution semantics will be.
    ///
    /// **Cooperative-pool friendliness:** `KeyboardInput.typeCharacters`
    /// uses synchronous `usleep` between characters (~30ms each), so
    /// running it directly on Swift's cooperative thread pool would
    /// park a pool thread for the full duration of the typing —
    /// risking pool exhaustion under concurrent supervisor load.
    /// Wrap the call in `DispatchQueue.global` via a checked
    /// continuation so the cooperative thread is freed while the
    /// typing runs on a global-queue thread instead.
    ///
    /// **Empty text is a fast no-op** — `type(pid:, text: "")`
    /// returns immediately without raising any events. Useful when
    /// the supervisor's planner produces a degenerate result and
    /// shouldn't have to special-case the empty path.
    ///
    /// - Parameter pid: Target process id (from `listApps()` or
    ///   `launchApp`).
    /// - Parameter text: The literal characters to type. Modifier
    ///   chords (`⌘C`, etc.) are NOT supported here — those land
    ///   in `pressKey` / `hotkey` in a follow-up PR. Unicode
    ///   characters that need an IME are best-effort; ASCII is
    ///   the supported surface.
    /// - Throws: `EngineError.typeFailed` if the keyboard subsystem
    ///   refuses event posting (target pid no longer running, OS
    ///   denied event posting, etc.).
    public nonisolated func type(
        pid: Int32,
        text: String
    ) async throws(EngineError) {
        guard !text.isEmpty else { return }
        // Faithful port of cua's `TypeTextCharsTool` invoke body
        // (`cua-driver/Sources/CuaDriverServer/Tools/TypeTextCharsTool.swift:74-79`):
        // just `KeyboardInput.typeCharacters(text, toPid: pid)`,
        // nothing else. No pre-settle sleep, no FocusGuard, no AX
        // enablement assertion. cua's tool surface separates the
        // focus problem from the key-delivery problem: the model
        // must focus the receiving element via `click_element` /
        // `set_element_value` first; this primitive just posts the
        // characters. CGEvent.postToPid is pid-scoped and physically
        // cannot leak to another process.
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    do {
                        try KeyboardInput.typeCharacters(text, toPid: pid)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw .typeFailed(reason: String(describing: error))
        }
    }

    /// Press a single key (or modifier+key combo) into `pid` via
    /// `CGEvent.postToPid` — the same scoped path `type` uses, with
    /// the same physical inability to leak to other processes. Use
    /// for keys that have semantic meaning beyond their character
    /// (Return to submit, Tab to advance focus, Escape to cancel,
    /// arrow keys, function keys), and for chorded shortcuts (cmd+s,
    /// cmd+f, cmd+enter). Modifiers in `keys` are auto-classified
    /// (cmd / command / shift / option / alt / ctrl / control / fn);
    /// the remaining entry is the keycap. Multiple non-modifiers in
    /// the same call resolve to the last one.
    ///
    /// Background-safety: identical to `type` — pid-scoped delivery,
    /// no cursor movement, no frontmost change. Forbidden hotkeys
    /// (cmd+l, cmd+tab, cmd+`) are denied at the supervisor layer.
    ///
    /// Same 80ms pre-fire settle delay as `type` so a `click_element`
    /// → `pressKey` chain doesn't race the renderer's focus routing.
    public func pressKey(
        pid: Int32,
        keys: [String],
        windowId: Int? = nil,
        elementIndex: Int? = nil
    ) async throws(EngineError) {
        guard !keys.isEmpty else {
            throw .typeFailed(reason: "pressKey requires at least one key")
        }

        // Faithful port of cua's `PressKeyTool` (`cua-driver/Sources/
        // CuaDriverServer/Tools/PressKeyTool.swift`). Two modes:
        //
        // 1. Without element_index — raw `KeyboardInput.hotkey`,
        //    pid-scoped, no FocusGuard. The caller has already
        //    focused the receiving element (typical: click then
        //    press_key in adjacent tool calls).
        //
        // 2. With element_index + windowId — look up the cached
        //    element, focus it via `AXSetAttribute(kAXFocused, true)`
        //    inside FocusGuard.withFocusSuppressed, then post the
        //    key. The canonical "fill field → press Return on this
        //    exact field" path.
        if let elementIndex, let windowId {
            guard let cgWindowId = UInt32(exactly: windowId) else {
                throw .invalidWindowId(windowId)
            }
            let element: AXUIElement
            do {
                element = try await appStateEngine.lookup(
                    pid: pid, windowId: cgWindowId, elementIndex: elementIndex
                )
            } catch {
                throw .elementNotFound(
                    pid: pid, windowId: windowId, elementIndex: elementIndex
                )
            }
            do {
                try await focusGuard.withFocusSuppressed(
                    pid: pid, element: element
                ) {
                    try? AXInput.setAttribute(
                        "AXFocused",
                        on: element,
                        value: kCFBooleanTrue as CFTypeRef
                    )
                    try KeyboardInput.hotkey(keys, toPid: pid)
                }
            } catch {
                throw .typeFailed(reason: String(describing: error))
            }
            return
        }

        // Bare form — no element pre-focus.
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    do {
                        try KeyboardInput.hotkey(keys, toPid: pid)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw .typeFailed(reason: String(describing: error))
        }
    }

    /// Set the text contents of a specific AX text element directly,
    /// bypassing keystroke synthesis entirely. The preferred path
    /// for filling text fields on backgrounded apps — works even
    /// when the user's foreground app holds key focus.
    ///
    /// Why this exists: `type(pid:text:)` posts synthetic
    /// CGEvent keystrokes scoped to `pid`. If the target app has
    /// no focused text responder (because your foreground app
    /// owns key focus), those keystrokes go to no receiver and
    /// macOS plays the system beep for each character. Setting
    /// `kAXValueAttribute` directly avoids the responder chain
    /// altogether.
    ///
    /// Requires `get_window_state` to have been called for the
    /// `(pid, windowId)` so the element index resolves.
    ///
    /// - Throws:
    ///   - `EngineError.elementNotFound` if the index is stale or
    ///     out of range.
    ///   - `EngineError.actionRefused` if the element is not a
    ///     writeable text type or AX rejects the value set.
    public func setElementValue(
        pid: Int32,
        windowId: Int,
        elementIndex: Int,
        text: String
    ) async throws(EngineError) {
        guard let cgWindowId = UInt32(exactly: windowId) else {
            throw .invalidWindowId(windowId)
        }
        let element: AXUIElement
        do {
            element = try await appStateEngine.lookup(
                pid: pid, windowId: cgWindowId, elementIndex: elementIndex
            )
        } catch {
            throw .elementNotFound(
                pid: pid, windowId: windowId, elementIndex: elementIndex
            )
        }
        do {
            try AXInput.requireAuthorized()
        } catch {
            throw .typeFailed(reason: String(describing: error))
        }
        do {
            // cua's `type_text` tool writes `AXSelectedText` (insert
            // at the current cursor / replace selection), not
            // `AXValue` (overwrite the whole field). Match cua.
            try AXInput.setAttribute(
                "AXSelectedText", on: element, value: text as CFTypeRef
            )
        } catch {
            throw .actionRefused(reason: String(describing: error))
        }
    }

    // MARK: - Capture surface

    /// Single-shot screenshot of one window. Targets the specific
    /// `(pid, windowId)` via ScreenCaptureKit's
    /// `desktopIndependentWindow` filter — captures the window
    /// even when it's hidden, off-screen, or behind other
    /// windows, without raising or activating it. Returns the
    /// vendored `Screenshot` value (PNG bytes + dimensions +
    /// scale factor).
    ///
    /// **Background-safety:** SCK's window-targeted capture path
    /// does not change frontmost state, doesn't re-order windows,
    /// and works against hidden apps (which is the normal Cacty
    /// case after `launchApp`). Screen Recording permission must
    /// be granted; if not, throws `.captureFailed`.
    ///
    /// `nonisolated` because capture is stateless from the actor's
    /// perspective — concurrent screenshots across pids should
    /// not serialize on the engine's executor.
    public nonisolated func screenshot(
        pid: Int32,
        windowId: Int
    ) async throws(EngineError) -> Screenshot {
        guard let cgWindowId = UInt32(exactly: windowId) else {
            throw .invalidWindowId(windowId)
        }
        do {
            return try await WindowCapture().captureWindow(
                windowID: cgWindowId
            )
        } catch {
            throw .captureFailed(reason: String(describing: error))
        }
    }

    /// Continuous capture stream for a window. Yields a
    /// `Screenshot` every `1/fps` seconds until the consumer
    /// stops awaiting (which cancels the producer task) or the
    /// containing actor is deinitialized.
    ///
    /// Used by the Phase 1 hover popover that shows the agent's
    /// live target window in a small SwiftUI view next to the
    /// floating dot. The supervisor only opens a stream when the
    /// dot is hovered — saves CPU when the user isn't watching.
    ///
    /// Transient capture failures (window briefly uncapturable
    /// during system events, transient SCShareableContent
    /// errors) are swallowed and the loop continues; consumers
    /// see a brief frame gap rather than the stream terminating.
    /// A persistent failure (window no longer exists, permission
    /// revoked) ends the stream cleanly via `continuation.finish()`.
    ///
    /// - Parameter fps: Frames per second, clamped to `[1, 60]`.
    ///   Plan calls for 4-6fps for the hover popover; default 5.
    public nonisolated func captureStream(
        pid: Int32,
        windowId: Int,
        fps: Int = 5
    ) -> AsyncStream<Screenshot> {
        AsyncStream { continuation in
            guard let cgWindowId = UInt32(exactly: windowId) else {
                continuation.finish()
                return
            }
            let clampedFps = max(1, min(60, fps))
            let frameIntervalNs: UInt64 = 1_000_000_000 / UInt64(clampedFps)

            let task = Task {
                let capture = WindowCapture()
                while !Task.isCancelled {
                    do {
                        let frame = try await capture.captureWindow(
                            windowID: cgWindowId
                        )
                        continuation.yield(frame)
                    } catch CaptureError.windowNotFound {
                        // Persistent failure — window is gone.
                        continuation.finish()
                        return
                    } catch CaptureError.permissionDenied {
                        // Persistent failure — user revoked grant.
                        continuation.finish()
                        return
                    } catch {
                        // Transient failure — try again next tick.
                    }
                    try? await Task.sleep(nanoseconds: frameIntervalNs)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Browser page primitives — execute JavaScript, extract page
    /// text, or query DOM elements via CSS selector. Faithful port
    /// of cua's `PageTool`
    /// (`cua-driver/Sources/CuaDriverServer/Tools/PageTool.swift`)
    /// adapted to Cacty's engine-method shape.
    ///
    /// The browser does NOT need to be frontmost for read actions —
    /// Apple Events / CDP / Mach IPC reach the renderer directly
    /// without window activation or tab switching. That's what makes
    /// this the preferred path for reading non-active Chrome tabs
    /// (e.g. Google Calendar) without disturbing the user's session.
    ///
    /// Backend routing (in order):
    /// 1. Apple Events (`BrowserJS`) — Chrome, Brave, Edge, Safari.
    /// 2. Electron CDP (`ElectronJS`) — Slack/Discord/VS Code.
    /// 3. WebKit TCP (`WebKitJS`) — GTK/WPE WebKit.
    /// 4. WebKit Mach IPC (`WebInspectorXPC`) — Tauri / WKWebView.
    /// 5. AX-tree fallback (`AXPageReader`) — for `get_text` /
    ///    `query_dom` when JS is unavailable.
    ///
    /// - Parameter pid: Browser process id.
    /// - Parameter windowId: CGWindowID of the target window.
    /// - Parameter action: One of `execute_javascript`, `get_text`,
    ///   `query_dom`, `enable_javascript_apple_events`.
    /// - Parameter javascript: Required for `execute_javascript`.
    /// - Parameter cssSelector: Required for `query_dom`.
    /// - Parameter attributes: Optional list of element attributes
    ///   to include in `query_dom` results.
    /// - Parameter bundleId: Required for
    ///   `enable_javascript_apple_events`.
    /// - Parameter userHasConfirmedEnabling: Must be `true` for
    ///   `enable_javascript_apple_events`. The caller is responsible
    ///   for asking the user first; the engine just enforces the
    ///   flag.
    /// - Returns: A Markdown-formatted result string ready for the
    ///   model.
    public nonisolated func page(
        pid: Int32,
        windowId: Int,
        action: String,
        javascript: String? = nil,
        cssSelector: String? = nil,
        attributes: [String] = [],
        bundleId: String? = nil,
        userHasConfirmedEnabling: Bool = false
    ) async throws(EngineError) -> String {
        guard let cgWindowId = UInt32(exactly: windowId) else {
            throw .invalidWindowId(windowId)
        }

        // Resolve the running bundle id (Apple Events routing uses it).
        let resolvedBundleId: String = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .first(where: { $0.processIdentifier == pid })?
                .bundleIdentifier ?? ""
        }

        switch action {

        case "enable_javascript_apple_events":
            guard userHasConfirmedEnabling else {
                throw .pageActionFailed(reason:
                    "action=enable_javascript_apple_events requires "
                    + "userHasConfirmedEnabling=true. You MUST ask the user "
                    + "for explicit permission before calling this action.")
            }
            guard let targetBundleId = bundleId, !targetBundleId.isEmpty else {
                throw .pageActionFailed(reason:
                    "action=enable_javascript_apple_events requires a "
                    + "bundle_id (e.g. com.google.Chrome).")
            }
            do {
                try await BrowserJS.enableJavaScriptAppleEvents(bundleId: targetBundleId)
                return "'Allow JavaScript from Apple Events' has been enabled "
                    + "in \(targetBundleId). The browser has been relaunched. "
                    + "You can now use execute_javascript."
            } catch {
                throw .pageActionFailed(reason: String(describing: error))
            }

        case "execute_javascript":
            guard let js = javascript, !js.isEmpty else {
                throw .pageActionFailed(reason:
                    "action=execute_javascript requires a non-empty "
                    + "javascript field.")
            }
            do {
                let result = try await Self.executePageJS(
                    js, bundleId: resolvedBundleId,
                    pid: pid, windowId: cgWindowId
                )
                return "## Result\n\n```\n\(result)\n```"
            } catch {
                throw .pageActionFailed(reason: String(describing: error))
            }

        case "get_text":
            // WKWebView/Tauri apps: bypass JS injection (no entitlement)
            // and read the AX tree directly. Safari is BrowserJS-supported
            // so it isn't misrouted here.
            if !BrowserJS.supports(bundleId: resolvedBundleId)
                && WebInspectorXPC.isWKWebViewApp(pid: pid) {
                if let axText = await axGetText(pid: pid, windowId: cgWindowId) {
                    return "## Page text (via AX tree)\n\n\(axText)"
                }
                throw .pageActionFailed(reason:
                    "No accessible text found in \(resolvedBundleId). The "
                    + "app's AX tree may not expose web content. Try "
                    + "get_window_state to inspect the full accessibility tree.")
            }
            do {
                let result = try await Self.executePageJS(
                    "document.body.innerText",
                    bundleId: resolvedBundleId, pid: pid, windowId: cgWindowId
                )
                return result
            } catch {
                if let axText = await axGetText(pid: pid, windowId: cgWindowId) {
                    return "## Page text (via AX tree)\n\n\(axText)"
                }
                throw .pageActionFailed(reason: String(describing: error))
            }

        case "query_dom":
            guard let selector = cssSelector, !selector.isEmpty else {
                throw .pageActionFailed(reason:
                    "action=query_dom requires a non-empty css_selector field.")
            }
            // WKWebView/Tauri apps: go straight to AX role query.
            if !BrowserJS.supports(bundleId: resolvedBundleId)
                && WebInspectorXPC.isWKWebViewApp(pid: pid) {
                if let axJson = await axQueryDom(
                    selector: selector, pid: pid, windowId: cgWindowId
                ) {
                    return "## AX query: `\(selector)` (via accessibility tree)\n\n"
                        + "```json\n\(axJson)\n```"
                }
                throw .pageActionFailed(reason:
                    "No elements matching '\(selector)' found in the AX "
                    + "tree of \(resolvedBundleId).")
            }
            let attrJS = attributes.isEmpty
                ? "[]"
                : "[\(attributes.map { Self.pageJSONString($0) }.joined(separator: ", "))]"
            let js = """
            (() => {
              const attrs = \(attrJS);
              return JSON.stringify(
                Array.from(document.querySelectorAll(\(Self.pageJSONString(selector)))).map(el => {
                  const obj = { tag: el.tagName.toLowerCase(), text: el.innerText?.trim() };
                  for (const a of attrs) obj[a] = el.getAttribute(a);
                  return obj;
                })
              );
            })()
            """
            do {
                let result = try await Self.executePageJS(
                    js, bundleId: resolvedBundleId, pid: pid, windowId: cgWindowId
                )
                return "## DOM query: `\(selector)`\n\n```json\n\(result)\n```"
            } catch {
                if let axJson = await axQueryDom(
                    selector: selector, pid: pid, windowId: cgWindowId
                ) {
                    return "## AX query: `\(selector)` (via accessibility tree)\n\n"
                        + "```json\n\(axJson)\n```"
                }
                throw .pageActionFailed(reason: String(describing: error))
            }

        default:
            throw .pageActionFailed(reason:
                "Unknown action '\(action)'. Valid: execute_javascript, "
                + "get_text, query_dom, enable_javascript_apple_events.")
        }
    }

    /// Route JS execution to the right backend — mirrors cua's
    /// `PageTool.executeJS`.
    private static func executePageJS(
        _ javascript: String,
        bundleId: String,
        pid: Int32,
        windowId: UInt32
    ) async throws -> String {
        if BrowserJS.supports(bundleId: bundleId) {
            return try await BrowserJS.execute(
                javascript: javascript, bundleId: bundleId, windowId: windowId
            )
        }
        if ElectronJS.isElectron(pid: pid) {
            return try await ElectronJS.execute(javascript: javascript, pid: pid)
        }
        if await WebKitJS.isAvailable() {
            return try await WebKitJS.execute(javascript: javascript)
        }
        if WebInspectorXPC.isWKWebViewApp(pid: pid) {
            throw PageError.wkWebViewJSUnavailable(bundleId: bundleId)
        }
        throw BrowserJS.Error.unsupportedBrowser(bundleId)
    }

    /// AX-tree fallback for `get_text` — used when JS injection is
    /// unavailable (Tauri / WKWebView without the inspector
    /// entitlement). Reads `getWindowState`'s tree and extracts text.
    private nonisolated func axGetText(pid: Int32, windowId: UInt32) async -> String? {
        guard let snapshot = try? await getWindowState(
            pid: pid, windowId: Int(windowId), captureMode: .ax
        ) else { return nil }
        let text = AXPageReader.extractText(from: snapshot.treeMarkdown)
        if !text.isEmpty { return text }
        return snapshot.treeMarkdown.isEmpty ? nil : snapshot.treeMarkdown
    }

    /// AX-tree fallback for `query_dom` — selector is mapped onto
    /// AX roles. Used when JS injection is unavailable.
    private nonisolated func axQueryDom(
        selector: String,
        pid: Int32,
        windowId: UInt32
    ) async -> String? {
        guard let snapshot = try? await getWindowState(
            pid: pid, windowId: Int(windowId), captureMode: .ax
        ) else { return nil }
        let elements = AXPageReader.query(
            selector: selector, from: snapshot.treeMarkdown
        )
        guard !elements.isEmpty else { return nil }
        let items: [[String: Any]] = elements.map { el in
            var obj: [String: Any] = [
                "role": el.role,
                "text": el.title.isEmpty ? el.value : el.title,
            ]
            if let idx = el.index { obj["element_index"] = idx }
            if !el.description.isEmpty { obj["description"] = el.description }
            return obj
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: items, options: [.prettyPrinted]
            ),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    /// JSON-safe string literal for embedding in JS source. Mirrors
    /// cua's `PageTool.jsonString` so the produced JS is byte-for-byte
    /// identical and any escaping bugs surface in the same way.
    private static func pageJSONString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// JS-unavailable error for WKWebView / Tauri apps on macOS — the
/// `webinspectord` inspector requires a Apple-provisioned
/// entitlement that third parties can't ship. Surfaced verbatim from
/// cua's PageTool nested type.
private enum PageError: Error, CustomStringConvertible {
    case wkWebViewJSUnavailable(bundleId: String)

    var description: String {
        switch self {
        case .wkWebViewJSUnavailable(let bundleId):
            return "execute_javascript is not available for WKWebView/Tauri "
                + "apps (\(bundleId)) — the macOS webinspectord inspector "
                + "requires com.apple.private.webinspector.remote-inspection-"
                + "debugger (Apple-provisioned only). Use get_text or "
                + "query_dom instead — both work via the AX tree without "
                + "any entitlement."
        }
    }
}

// MARK: - cua tool ports (Phase 3)
//
// Engine methods that mirror cua's `cua-driver/Sources/CuaDriverServer/
// Tools/*.swift` invoke bodies. Each method = one cua tool. Where cua's
// tool surface has multiple addressing modes (element_index vs pixel),
// we accept optional args and dispatch internally. Background-safety
// notes match cua's tool docstrings.

extension Engine {

    // MARK: - Action tools

    /// Right-click: AX `AXShowMenu` on a cached element when
    /// `elementIndex`/`windowId` are given, or a pid-scoped CGEvent
    /// right-mouse pair at window-local `(x, y)` pixels otherwise.
    /// Mirrors cua's `RightClickTool`.
    public func rightClick(
        pid: Int32,
        windowId: Int? = nil,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        modifiers: [String] = []
    ) async throws(EngineError) {
        if let elementIndex, let windowId {
            guard let cgWindowId = UInt32(exactly: windowId) else {
                throw .invalidWindowId(windowId)
            }
            let element: AXUIElement
            do {
                element = try await appStateEngine.lookup(
                    pid: pid, windowId: cgWindowId, elementIndex: elementIndex
                )
            } catch {
                throw .elementNotFound(
                    pid: pid, windowId: windowId, elementIndex: elementIndex
                )
            }
            // Cursor pre-flight mirrors cua's
            // `RightClickTool.swift:184-189`.
            if let center = AXInput.screenCenter(of: element) {
                await cursorPreFlight(pid: pid, to: center)
            }
            do {
                try await focusGuard.withFocusSuppressed(
                    pid: pid, element: element
                ) {
                    _ = AXUIElementPerformAction(
                        element, "AXShowMenu" as CFString
                    )
                }
            } catch {
                throw .clickFailed(reason: String(describing: error))
            }
            await cursorPostClick(pid: pid)
            return
        }
        guard let x, let y else {
            throw .clickFailed(reason:
                "right_click requires either elementIndex+windowId or x+y.")
        }
        let screenPoint = try await Self.windowLocalToScreen(
            pid: pid, windowIdHint: windowId, x: x, y: y
        )
        try Self.refuseIfMenuBar(screenPoint)
        let forcePidRoute = Self.shouldForcePidRoute(forPid: pid)
        // Cursor pre-flight mirrors cua's
        // `RightClickTool.swift:278-282`.
        await cursorPreFlight(pid: pid, to: screenPoint)
        do {
            try MouseInput.rightClick(
                at: screenPoint, toPid: pid,
                modifiers: modifiers, forcePidRoute: forcePidRoute
            )
        } catch {
            throw .clickFailed(reason: String(describing: error))
        }
        await cursorPostClick(pid: pid)
    }

    /// Double-click: AX `AXOpen` when advertised, else pixel
    /// double-click. Mirrors cua's `DoubleClickTool`.
    public func doubleClick(
        pid: Int32,
        windowId: Int? = nil,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        modifiers: [String] = []
    ) async throws(EngineError) {
        if let elementIndex, let windowId {
            guard let cgWindowId = UInt32(exactly: windowId) else {
                throw .invalidWindowId(windowId)
            }
            let element: AXUIElement
            do {
                element = try await appStateEngine.lookup(
                    pid: pid, windowId: cgWindowId, elementIndex: elementIndex
                )
            } catch {
                throw .elementNotFound(
                    pid: pid, windowId: windowId, elementIndex: elementIndex
                )
            }
            // Cursor pre-flight mirrors cua's
            // `DoubleClickTool.swift:178-183`.
            if let preCenter = AXInput.screenCenter(of: element) {
                await cursorPreFlight(pid: pid, to: preCenter)
            }
            // Try AXOpen; if the action isn't advertised, fall through
            // to a synthesized pixel double-click at the element's
            // screen-space center. `AXUIElementPerformAction` is
            // synchronous and returns within a few ms — no Task hop
            // required.
            let openResult = AXUIElementPerformAction(
                element, "AXOpen" as CFString
            )
            if openResult == .success {
                await cursorPostClick(pid: pid)
                return
            }
            // Fallback: read AX position+size, double-click at center.
            if let center = Self.elementCenter(element) {
                try Self.refuseIfMenuBar(center)
                let forcePidRoute = Self.shouldForcePidRoute(forPid: pid)
                do {
                    try MouseInput.click(
                        at: center, toPid: pid, button: .left,
                        count: 2, modifiers: modifiers,
                        forcePidRoute: forcePidRoute
                    )
                } catch {
                    throw .clickFailed(reason: String(describing: error))
                }
                await cursorPostClick(pid: pid)
                return
            }
            throw .clickFailed(reason: "double_click: element neither "
                + "advertises AXOpen nor reports a screen position.")
        }
        guard let x, let y else {
            throw .clickFailed(reason:
                "double_click requires either elementIndex+windowId or x+y.")
        }
        let screenPoint = try await Self.windowLocalToScreen(
            pid: pid, windowIdHint: windowId, x: x, y: y
        )
        try Self.refuseIfMenuBar(screenPoint)
        let forcePidRoute = Self.shouldForcePidRoute(forPid: pid)
        // Cursor pre-flight mirrors cua's
        // `DoubleClickTool.swift:269-273`.
        await cursorPreFlight(pid: pid, to: screenPoint)
        do {
            try MouseInput.click(
                at: screenPoint, toPid: pid, button: .left,
                count: 2, modifiers: modifiers,
                forcePidRoute: forcePidRoute
            )
        } catch {
            throw .clickFailed(reason: String(describing: error))
        }
        await cursorPostClick(pid: pid)
    }

    /// Pixel-addressed press-drag-release gesture. Mirrors cua's
    /// `DragTool` — no AX path (macOS AX has no drag action).
    public func drag(
        pid: Int32,
        windowId: Int? = nil,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int = 500,
        steps: Int = 20,
        modifiers: [String] = []
    ) async throws(EngineError) {
        let from = try await Self.windowLocalToScreen(
            pid: pid, windowIdHint: windowId, x: fromX, y: fromY
        )
        let to = try await Self.windowLocalToScreen(
            pid: pid, windowIdHint: windowId, x: toX, y: toY
        )
        try Self.refuseIfMenuBar(from)
        try Self.refuseIfMenuBar(to)
        let forcePidRoute = Self.shouldForcePidRoute(forPid: pid)
        // Cursor glides to the drag start, then to the endpoint
        // after MouseInput.drag completes. Mirrors cua's
        // `DragTool.swift:260-294`.
        await cursorPreFlight(pid: pid, to: from)
        do {
            try MouseInput.drag(
                from: from, to: to, toPid: pid,
                button: .left, durationMs: durationMs,
                steps: steps, modifiers: modifiers,
                forcePidRoute: forcePidRoute
            )
        } catch {
            throw .clickFailed(reason: String(describing: error))
        }
        await MainActor.run { AgentCursor.shared.pinAbove(pid: pid) }
        await AgentCursor.shared.animateAndWait(to: to)
        await AgentCursor.shared.finishClick(pid: pid)
    }

    /// Upper bound on `scroll` keystroke repeats. Duplicated in the
    /// ToolSchema declaration (`maximum: 50`) — keep in sync.
    private static let maxScrollKeystrokes = 50

    /// Scroll via synthesized arrow / Page keystrokes. Mirrors cua's
    /// `ScrollTool` rationale — wheel events are silently dropped on
    /// Chromium via the auth-signed per-pid path.
    public func scroll(
        pid: Int32,
        direction: String,
        amount: Int = 3,
        by: String = "line",
        windowId: Int? = nil,
        elementIndex: Int? = nil
    ) async throws(EngineError) {
        let key: String
        switch (direction.lowercased(), by.lowercased()) {
        case ("up", "page"):    key = "pageup"
        case ("down", "page"):  key = "pagedown"
        case ("up", "line"):    key = "up"
        case ("down", "line"):  key = "down"
        case ("left", _):       key = "left"
        case ("right", _):      key = "right"
        default:
            throw .typeFailed(reason:
                "scroll: invalid direction '\(direction)' / by '\(by)'.")
        }
        // Optional element pre-focus.
        if let elementIndex, let windowId {
            guard let cgWindowId = UInt32(exactly: windowId) else {
                throw .invalidWindowId(windowId)
            }
            let element: AXUIElement
            do {
                element = try await appStateEngine.lookup(
                    pid: pid, windowId: cgWindowId, elementIndex: elementIndex
                )
            } catch {
                throw .elementNotFound(
                    pid: pid, windowId: windowId, elementIndex: elementIndex
                )
            }
            do {
                try await focusGuard.withFocusSuppressed(
                    pid: pid, element: element
                ) {
                    try? AXInput.setAttribute(
                        "AXFocused",
                        on: element,
                        value: kCFBooleanTrue as CFTypeRef
                    )
                    for _ in 0..<max(1, min(Self.maxScrollKeystrokes, amount)) {
                        try KeyboardInput.press(key, toPid: pid)
                    }
                }
            } catch {
                throw .typeFailed(reason: String(describing: error))
            }
            return
        }
        do {
            for _ in 0..<max(1, min(Self.maxScrollKeystrokes, amount)) {
                try KeyboardInput.press(key, toPid: pid)
            }
        } catch {
            throw .typeFailed(reason: String(describing: error))
        }
    }

    /// Press a chord combo on `pid`. Mirrors cua's `HotkeyTool` —
    /// thin wrapper over `KeyboardInput.hotkey`.
    public nonisolated func hotkey(
        pid: Int32, keys: [String]
    ) async throws(EngineError) {
        guard !keys.isEmpty else {
            throw .typeFailed(reason: "hotkey requires at least one key.")
        }
        do {
            try KeyboardInput.hotkey(keys, toPid: pid)
        } catch {
            throw .typeFailed(reason: String(describing: error))
        }
    }

    /// Move the system cursor instantly via `CGWarpMouseCursorPosition`.
    /// Mirrors cua's `MoveCursorTool`.
    public nonisolated func moveCursor(x: Int, y: Int) {
        CursorControl.move(to: CGPoint(x: x, y: y))
    }

    /// Zoom into a region of the target window at native resolution.
    /// Mirrors cua's `ZoomTool`: captures the window at native
    /// resolution, maps `(x1, y1, x2, y2)` from scaled-image pixel
    /// space (the space the model addresses via `get_window_state`
    /// / `screenshot`) back to native pixel space using the most
    /// recent capture's resize ratio, crops, and returns the
    /// cropped region without further resizing.
    public nonisolated func zoom(
        pid: Int32, x1: Double, y1: Double, x2: Double, y2: Double
    ) async throws(EngineError) -> Screenshot {
        guard x2 > x1, y2 > y1 else {
            throw .captureFailed(reason:
                "zoom: x2 must be > x1 and y2 must be > y1.")
        }
        guard let window = WindowCapture.selectFrontmostWindow(forPid: pid)
        else {
            throw .captureFailed(reason:
                "zoom: pid \(pid) has no on-screen window to capture.")
        }
        let windowId = UInt32(window.id)

        // Capture at native resolution (maxImageDimension: 0 →
        // no resize). The CGImage we crop is in backing-store
        // pixel space.
        let shot: Screenshot
        do {
            shot = try await WindowCapture().captureWindow(
                windowID: windowId, format: .png,
                quality: 95, maxImageDimension: 0
            )
        } catch {
            throw .captureFailed(reason: String(describing: error))
        }

        // Map (x1, y1, x2, y2) from the model's scaled-image
        // space to backing-store pixels. Use the last recorded
        // scale for this (pid, window) if there is one; otherwise
        // assume coords are already in native pixel space.
        let scale = await ImageScaleRegistry.shared.lookup(
            pid: pid, windowId: windowId
        )
        let xMul: Double
        let yMul: Double
        if let scale {
            xMul = Double(scale.originalWidth) / Double(scale.scaledWidth)
            yMul = Double(scale.originalHeight) / Double(scale.scaledHeight)
        } else {
            xMul = 1.0
            yMul = 1.0
        }
        let nativeX1 = Int((x1 * xMul).rounded(.down))
        let nativeY1 = Int((y1 * yMul).rounded(.down))
        let nativeX2 = Int((x2 * xMul).rounded(.up))
        let nativeY2 = Int((y2 * yMul).rounded(.up))

        // Clamp to image bounds (cua adds 20% padding; we mirror
        // that, then clamp).
        let regionWidth = nativeX2 - nativeX1
        let regionHeight = nativeY2 - nativeY1
        let padX = Int(Double(regionWidth) * 0.2)
        let padY = Int(Double(regionHeight) * 0.2)
        let cropX = max(0, nativeX1 - padX)
        let cropY = max(0, nativeY1 - padY)
        let cropMaxX = min(shot.width, nativeX2 + padX)
        let cropMaxY = min(shot.height, nativeY2 + padY)
        let cropWidth = max(1, cropMaxX - cropX)
        let cropHeight = max(1, cropMaxY - cropY)

        return try Self.cropScreenshot(
            shot,
            x: cropX, y: cropY,
            width: cropWidth, height: cropHeight
        )
    }

    /// Crop `shot`'s underlying CGImage to the given pixel rect and
    /// re-encode as PNG. Returns a fresh `Screenshot` value
    /// preserving the original `scaleFactor`. Throws
    /// `EngineError.captureFailed` if decode / crop / encode fails.
    fileprivate static func cropScreenshot(
        _ shot: Screenshot,
        x: Int, y: Int, width: Int, height: Int
    ) throws(EngineError) -> Screenshot {
        guard
            let dataProvider = CGDataProvider(data: shot.imageData as CFData),
            let cgImage = CGImage(
                pngDataProviderSource: dataProvider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw .captureFailed(reason:
                "zoom: failed to decode captured PNG for cropping.")
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(
                x: 0, y: 0,
                width: cgImage.width, height: cgImage.height
            ))
        guard !rect.isNull, rect.width > 0, rect.height > 0,
              let cropped = cgImage.cropping(to: rect)
        else {
            throw .captureFailed(reason:
                "zoom: crop rect \(rect) outside image bounds "
                + "(\(cgImage.width)x\(cgImage.height)).")
        }
        // Re-encode the cropped CGImage to PNG via ImageIO.
        guard
            let mutableData = CFDataCreateMutable(nil, 0),
            let dest = CGImageDestinationCreateWithData(
                mutableData, "public.png" as CFString, 1, nil
            )
        else {
            throw .captureFailed(reason:
                "zoom: failed to create PNG destination for cropped image.")
        }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw .captureFailed(reason:
                "zoom: failed to finalize cropped PNG.")
        }
        return Screenshot(
            imageData: mutableData as Data,
            format: shot.format,
            width: cropped.width,
            height: cropped.height,
            scaleFactor: shot.scaleFactor,
            originalWidth: cropped.width,
            originalHeight: cropped.height
        )
    }

    // MARK: - Read tools

    /// Current cursor screen position. Mirrors `GetCursorPositionTool`.
    public nonisolated func getCursorPosition() -> CursorPoint {
        let pos = CursorControl.currentPosition()
        return CursorPoint(x: Int(pos.x), y: Int(pos.y))
    }

    /// Main display logical size + backing scale.
    /// Mirrors `GetScreenSizeTool`.
    public nonisolated func getScreenSize() throws(EngineError) -> ScreenSize {
        guard let size = ScreenInfo.mainScreenSize() else {
            throw .captureFailed(reason: "No main display detected.")
        }
        return size
    }

    /// Raw AX tree markdown for `(pid, windowId)`. Convenience over
    /// `getWindowState(captureMode: .ax)` — same data, no screenshot.
    /// Mirrors `GetAccessibilityTreeTool`.
    public func getAccessibilityTree(
        pid: Int32, windowId: Int
    ) async throws(EngineError) -> String {
        let snap = try await getWindowState(
            pid: pid, windowId: windowId, captureMode: .ax
        )
        return snap.treeMarkdown
    }

    /// Standalone screenshot of `(pid, windowId)`. Mirrors
    /// `ScreenshotTool`. When `windowId` is omitted, picks the
    /// pid's frontmost on-screen window.
    public nonisolated func screenshot(
        pid: Int32, windowId: Int? = nil,
        maxImageDimension: Int = 1600
    ) async throws(EngineError) -> Screenshot {
        let resolvedWindowId: UInt32
        if let windowId, let cg = UInt32(exactly: windowId) {
            resolvedWindowId = cg
        } else if let frontmost = WindowCapture.selectFrontmostWindow(forPid: pid) {
            resolvedWindowId = UInt32(frontmost.id)
        } else {
            throw .captureFailed(reason:
                "screenshot: pid \(pid) has no on-screen window.")
        }
        let shot: Screenshot
        do {
            shot = try await WindowCapture().captureWindow(
                windowID: resolvedWindowId,
                format: .png,
                quality: 95,
                maxImageDimension: maxImageDimension
            )
        } catch {
            throw .captureFailed(reason: String(describing: error))
        }
        await ImageScaleRegistry.shared.record(
            pid: pid,
            windowId: resolvedWindowId,
            capturedWidth: shot.width,
            capturedHeight: shot.height,
            originalWidth: shot.originalWidth,
            originalHeight: shot.originalHeight,
            scaleFactor: shot.scaleFactor
        )
        return shot
    }

    /// Check macOS permission grants. Mirrors `CheckPermissionsTool`.
    /// Returns the existing `PermissionsStatus` via `permissions()`.
    public func checkPermissions() async -> PermissionsStatus {
        await permissions()
    }

    // MARK: - Recording tools

    /// Enable / disable trajectory recording. Mirrors cua's
    /// `SetRecordingTool` — single boolean toggle — by bridging to
    /// Cacty's richer `RecordingSession.configure(enabled:outputDir:)`.
    ///
    /// When `enabled` is true and no `outputDir` is supplied, the
    /// bridge picks `~/Library/Application Support/Cacty/recordings/
    /// <ISO-8601-timestamp>` and creates the directory. This matches
    /// cua's "no caller-supplied path" default behavior.
    public func setRecording(
        enabled: Bool,
        outputDir: String? = nil,
        videoExperimental: Bool = false
    ) async throws(EngineError) {
        if !enabled {
            do {
                try await RecordingSession.shared.configure(
                    enabled: false, outputDir: nil
                )
            } catch {
                throw .pageActionFailed(reason: String(describing: error))
            }
            return
        }
        let resolvedDir: URL
        if let outputDir, !outputDir.isEmpty {
            resolvedDir = URL(
                fileURLWithPath: (outputDir as NSString).expandingTildeInPath
            )
        } else {
            resolvedDir = Self.defaultRecordingDirectory()
        }
        do {
            try await RecordingSession.shared.configure(
                enabled: true,
                outputDir: resolvedDir,
                videoExperimental: videoExperimental
            )
        } catch {
            throw .pageActionFailed(reason: String(describing: error))
        }
    }

    /// Return recording state. Mirrors `GetRecordingStateTool`.
    public func getRecordingState() async -> RecordingSession.State {
        await RecordingSession.shared.currentState()
    }

    /// Replay a previously-recorded trajectory directory. cua's
    /// `ReplayTrajectoryTool` re-executes recorded actions; Cacty's
    /// `Recording/` pipeline does not currently expose an
    /// action-replay primitive (it only renders the visual capture
    /// via `RecordingRenderer`). Surface a clear unsupported error
    /// pointing callers at the rendering alternative so the gap
    /// has a documented escape hatch.
    public func replayTrajectory(path: String) async throws(EngineError) {
        _ = path
        throw .pageActionFailed(reason:
            "replay_trajectory: action-replay is not implemented in "
            + "Cacty's Recording pipeline. The recorded trajectory's "
            + "visual capture can be rendered via "
            + "`RecordingRenderer.render(from:to:)`; re-driving actions "
            + "requires a separate replay primitive that's tracked as "
            + "future work.")
    }

    /// Resolve the default location for new recording sessions —
    /// `~/Library/Application Support/Cacty/recordings/<ISO-8601>`.
    /// The directory itself is created by `RecordingSession.configure`.
    fileprivate static func defaultRecordingDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return support
            .appendingPathComponent("Cacty/recordings", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }

    // MARK: - Agent-cursor overlay tools

    /// Return agent-cursor enabled state. Mirrors
    /// `GetAgentCursorStateTool`.
    @MainActor
    public func getAgentCursorState() -> Bool {
        AgentCursor.shared.isEnabled
    }

    /// Enable / disable the agent-cursor overlay. Mirrors
    /// `SetAgentCursorEnabledTool`.
    @MainActor
    public func setAgentCursorEnabled(_ enabled: Bool) {
        AgentCursor.shared.setEnabled(enabled)
    }

    /// Configure motion-path options. Mirrors
    /// `SetAgentCursorMotionTool` — minimal port; takes named
    /// numeric tuneables that map to `CursorMotionPath.Options`.
    @MainActor
    public func setAgentCursorMotion(
        glideDurationSeconds: Double? = nil,
        idleHideDelaySeconds: Double? = nil
    ) {
        let cursor = AgentCursor.shared
        if let g = glideDurationSeconds { cursor.glideDurationSeconds = g }
        if let i = idleHideDelaySeconds { cursor.idleHideDelay = i }
    }

    // MARK: - Config tools

    /// Load the persisted driver config. Mirrors `GetConfigTool`.
    public func getConfig() async -> CuaDriverConfig {
        await ConfigStore.shared.load()
    }

    /// Mutate the persisted driver config (capture mode, telemetry,
    /// auto-update, agent-cursor sub-config). Mirrors `SetConfigTool`.
    ///
    /// Validates `schemaVersion` against the current expected
    /// version. Future bumps will need a migration before older
    /// configs round-trip — rather than silently accept a stale
    /// shape, refuse it explicitly so the caller knows to update.
    public func setConfig(_ config: CuaDriverConfig) async throws(EngineError) {
        let expected = Self.expectedConfigSchemaVersion
        guard config.schemaVersion == expected else {
            throw .pageActionFailed(reason:
                "set_config: schemaVersion \(config.schemaVersion) does "
                + "not match expected version \(expected). Migrate the "
                + "config explicitly before calling set_config.")
        }
        do {
            try await ConfigStore.shared.save(config)
        } catch {
            throw .pageActionFailed(reason: String(describing: error))
        }
    }

    /// CuaDriverConfig schema version this build understands. Bump
    /// together with `CuaDriverConfig.schemaVersion`'s default and
    /// any migration logic.
    private static let expectedConfigSchemaVersion = 1

    // MARK: - Helpers shared across pixel-coord tools

    /// Convert window-local screenshot pixel coordinates to a screen
    /// point suitable for `MouseInput.*`. Picks the frontmost
    /// on-screen window of `pid` when `windowIdHint` is `nil`.
    ///
    /// **Coordinate spaces.** The model addresses pixels in the
    /// PNG returned by `get_window_state` / `screenshot`. That PNG
    /// is downscaled to `maxImageDimension` (default 1600 px on
    /// the longest edge), so its pixel space is NOT the same as
    /// the window's native point space. We look up the most
    /// recent capture's resize ratio in `ImageScaleRegistry` and
    /// rescale before adding the window's screen origin.
    ///
    /// When no capture has been recorded yet (model called a
    /// pixel-coord tool without a preceding snapshot), we fall
    /// back to a 1:1 mapping — clicks may land inaccurately on
    /// Retina + downscaled paths, but the model can't have known
    /// that without a screenshot. The fallback matches cua's
    /// behavior for the same gap.
    fileprivate static func windowLocalToScreen(
        pid: Int32, windowIdHint: Int?, x: Double, y: Double
    ) async throws(EngineError) -> CGPoint {
        let target: WindowInfo?
        let resolvedWindowId: UInt32?
        if let windowIdHint, let cg = UInt32(exactly: windowIdHint) {
            target = WindowEnumerator.allWindows().first { UInt32($0.id) == cg }
            resolvedWindowId = cg
        } else {
            target = WindowCapture.selectFrontmostWindow(forPid: pid)
            resolvedWindowId = target.map { UInt32($0.id) }
        }
        guard let window = target else {
            throw .clickFailed(reason:
                "could not resolve a window for pid \(pid) "
                + "(windowId=\(windowIdHint.map(String.init) ?? "auto")).")
        }

        // Convert scaled-image-pixel coords to window-local points.
        // `Scale.xRatio` / `yRatio` already account for both the
        // resize (originalWidth / scaledWidth) and the backing-store
        // factor (divide by `scaleFactor`), so a single multiply
        // lands directly in point space. No remap available (no
        // prior capture) → 1:1 fallback; better to mislocate
        // slightly than refuse the click outright.
        var pointX = x
        var pointY = y
        if let wid = resolvedWindowId,
           let scale = await ImageScaleRegistry.shared.lookup(
               pid: pid, windowId: wid
           ) {
            pointX = x * scale.xRatio
            pointY = y * scale.yRatio
        }
        return CGPoint(
            x: window.bounds.x + pointX,
            y: window.bounds.y + pointY
        )
    }

    /// macOS menu-bar height in points. Constant across all
    /// shipping Macs (1.0×) and used as the y-coordinate cutoff
    /// below which a pixel click would land on the system menu
    /// bar. Matches the `AXMenuBarItem` refusal that
    /// `clickElement` enforces at the AX-action layer.
    fileprivate static let menuBarHeightPoints: Double = 24.0

    /// Refuse pixel-coord mouse gestures whose resolved screen
    /// point lies in the menu-bar region. The element-indexed
    /// path already refuses `AXMenuBarItem` clicks (see
    /// `clickElement`'s role check); without this guard the
    /// pixel path was a documented background-contract hole —
    /// any model that learned to hit the menu bar by coordinate
    /// could foreground the target. Throws `actionRefused` with
    /// a hint pointing the model at `press_key` for the same
    /// outcome via a keyboard shortcut.
    fileprivate static func refuseIfMenuBar(_ point: CGPoint) throws(EngineError) {
        guard point.y < menuBarHeightPoints else { return }
        throw .actionRefused(reason:
            "Refusing pixel click at (\(point.x), \(point.y)) — y < "
            + "\(Int(menuBarHeightPoints)) lands on the macOS menu bar. "
            + "Clicking menu-bar items foregrounds the target and "
            + "violates the background contract. Use the `hotkey` tool "
            + "with the menu item's keyboard equivalent instead "
            + "(e.g. `hotkey(keys: [\"cmd\", \"n\"])` for New, "
            + "`hotkey(keys: [\"cmd\", \"f\"])` for Find, "
            + "`hotkey(keys: [\"cmd\", \",\"])` for Settings). Do NOT tell "
            + "the user the action is impossible — re-issue as a hotkey.")
    }

    /// **Cacty extension.** Decide whether a pixel-coord mouse
    /// gesture (`click` / `right_click` / `double_click` / `drag`)
    /// should force `MouseInput`'s pid-routed delivery path,
    /// bypassing the default `isActive` → HID-tap branch. Returns
    /// `true` when `SpaceMigrator` reports the target's primary
    /// window lives on a different macOS Space than the user's
    /// active one.
    ///
    /// **Why.** `MouseInput.click`'s default routing assumes
    /// `isActive == true` means "the user is looking at the
    /// target." That assumption breaks when Cacty has caused the
    /// target to be frontmost on its own Space (typical after a
    /// background launch + AX-write reflex activation) but the
    /// user is still on a different Space. HID-tap delivery in
    /// that state lands on whatever app is frontmost on the
    /// user's *visible* Space — wrong app, real cursor jumps.
    /// Forcing pid-routed delivery keeps the click on the
    /// target's pid regardless of which Space the user is on,
    /// and leaves the cursor where it was.
    fileprivate static func shouldForcePidRoute(forPid pid: Int32) -> Bool {
        switch SpaceMigrator.status(forPid: pid) {
        case .onAnotherSpace: return true
        case .onCurrentSpace, .unknown: return false
        }
    }

    /// AX-reported screen-space center of an element. Used by
    /// `double_click` when `AXOpen` is unavailable. Returns `nil` if
    /// the element doesn't report position+size.
    fileprivate static func elementCenter(_ element: AXUIElement) -> CGPoint? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &posValue
            ) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue
            ) == .success,
            let pos = posValue, let size = sizeValue,
            CFGetTypeID(pos) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        let posAX = unsafeBitCast(pos, to: AXValue.self)
        let sizeAX = unsafeBitCast(size, to: AXValue.self)
        var origin = CGPoint.zero
        var dim = CGSize.zero
        guard
            AXValueGetValue(posAX, .cgPoint, &origin),
            AXValueGetValue(sizeAX, .cgSize, &dim)
        else { return nil }
        return CGPoint(
            x: origin.x + dim.width / 2,
            y: origin.y + dim.height / 2
        )
    }

    /// Pin the agent-cursor overlay above the target app's window
    /// stack and glide it to `point`. No-op when the overlay is
    /// disabled (cua's `AgentCursor.animateAndWait` and `pinAbove`
    /// both early-return on `!isEnabled`), so call sites don't
    /// need to branch. Mirrors cua's tool-layer pre-flight
    /// sequence (`ClickTool.swift:279-283`).
    fileprivate nonisolated func cursorPreFlight(
        pid: Int32, to point: CGPoint
    ) async {
        await MainActor.run { AgentCursor.shared.pinAbove(pid: pid) }
        await AgentCursor.shared.animateAndWait(to: point)
    }

    /// Re-pin the overlay (AX presses can raise the target window
    /// above the cursor), optionally draw a focus-rect highlight,
    /// then play the press pulse and arm the idle-hide timer.
    /// Mirrors cua's tool-layer post-action sequence
    /// (`ClickTool.swift:315-333`). No-op when the overlay is
    /// disabled.
    fileprivate nonisolated func cursorPostClick(
        pid: Int32, focusRect: CGRect? = nil
    ) async {
        await MainActor.run {
            AgentCursor.shared.pinAbove(pid: pid)
            if let rect = focusRect {
                AgentCursor.shared.showFocusRect(rect)
            }
        }
        await AgentCursor.shared.playClickPress()
        await AgentCursor.shared.finishClick(pid: pid)
    }
}
