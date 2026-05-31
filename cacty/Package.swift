// swift-tools-version: 6.0
import PackageDescription

// Cacty — voice-driven multi-agent macOS computer-use app.
//
// Targets land in dependency order:
//
//   Automation  — vendored cua engine (AX, SkyLight, capture).
//   Agent       — in-process Gemini client + tool schema + worker
//                 actors. Depends on Automation for tool dispatch.
//   App         — SwiftUI shell, supervisor, PTT, UI surfaces.
//                 Built as a SwiftPM executable; `Scripts/build-app.sh`
//                 wraps the binary in a `.app` bundle, copies the
//                 Info.plist, and ad-hoc codesigns so macOS TCC will
//                 honor the usage-description strings. Phase 1.2.
//
// The engine was vendored from the cua-driver Swift project; the MCP
// server, CLI, and daemon scaffolding were dropped during repo
// restructure.
let package = Package(
    name: "Cacty",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "Automation", targets: ["Automation"]),
        .library(name: "Agent", targets: ["Agent"]),
        .executable(name: "fn-spike", targets: ["FnSpike"]),
        .executable(name: "cacty-app", targets: ["App"])
    ],
    targets: [
        .target(
            name: "Automation"
        ),
        .target(
            name: "Agent",
            dependencies: ["Automation"]
        ),
        // Phase 0 spike #4 (PLAN.md § Phase 0 Monday checklist).
        // Throwaway: validates Fn-key global capture only. The
        // original scope also covered speech recognition, but
        // that path crashes under `swift run` with
        // `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` — modern macOS
        // TCC requires a real `.app` bundle (or fully-signed
        // binary with embedded entitlements) before honoring
        // usage-description strings, and embedding Info.plist via
        // `-sectcreate` alone isn't enough. The `.app` shell
        // scaffolding is Phase 1 work; the spike scope is
        // reduced to the actual Phase 0 unknown (Fn capture).
        //
        // Phase 1's App/PTT and App/Speech modules re-implement
        // this surface against a proper SwiftUI app shell with
        // the supervisor wired in.
        .executableTarget(
            name: "FnSpike",
            exclude: ["README.md"]
        ),
        // The Cacty app shell. Bare menu-bar app for PR 1.2 — just a
        // `MenuBarExtra` with "About" and "Quit". Subsequent PRs
        // layer in the supervisor, PTT, dot UI, approval bar, etc.
        //
        // Info.plist lives in `Sources/App/Info.plist` for editor
        // convenience and gets copied into the `.app` bundle by
        // `Scripts/build-app.sh`. We exclude it from the SwiftPM
        // build copy so it doesn't get warned as an unhandled file.
        .executableTarget(
            name: "App",
            dependencies: ["Automation", "Agent"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "AutomationTests",
            dependencies: ["Automation"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: ["Agent"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App", "Agent", "Automation"]
        )
    ]
)
