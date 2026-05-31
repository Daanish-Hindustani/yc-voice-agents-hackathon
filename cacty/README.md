# Cacty

A native macOS menu-bar app. Hold **Fn**, speak a task, release. The transcript
is generated on-device, goes to Gemini 3 Pro along with the cua action toolset,
and Gemini drives a real Mac app in the background while you keep working.
Multiple tasks run in parallel — each is a small floating dot in the top-right
of the screen; hovering reveals a live video stream of what the agent is
doing. Mid-task, the agent can pop up an approval box for risky actions or a
multiple-choice + free-response panel when it needs info. The agent remembers
preferences across tasks so you don't repeat yourself.

## Status

Pre-Phase-1. The repo currently contains the vendored `Automation` engine
(AX clicks, SkyLight pixel clicks, scoped keyboard, per-window capture) and
nothing else. The app shell, agent runtime, and UI surfaces ship in
subsequent PRs. See [`plan.md`](./plan.md).

## Repo layout

```
Cacty/
├── Package.swift            # SwiftPM root — one package, multiple targets
├── Sources/
│   └── Automation/          # Vendored cua-driver engine (the only target today)
├── Tests/
│   └── AutomationTests/
├── plan.md                  # Full product spec
├── CLAUDE.md                # Working conventions for coding agents
├── README.md                # This file
├── LICENSE                  # (TBD)
└── THIRD_PARTY_LICENSES.md  # Attribution for vendored third-party code
```

`Sources/Agent/` (in-process Gemini client + worker pool) and `Sources/App/`
(SwiftUI app shell) land in Phase 1 PRs.

## Build & test

Requires Swift 6.0+ / Xcode 26+, macOS 26+.

```bash
swift build
swift test
```

There is no embedded Python runtime, no MCP server, no CLI. Everything is one
Swift process.

## Documentation

- [`plan.md`](./plan.md) — full product specification and phased build plan
- [`CLAUDE.md`](./CLAUDE.md) — conventions and hard constraints for coding agents
- [`THIRD_PARTY_LICENSES.md`](./THIRD_PARTY_LICENSES.md) — vendored-code attribution
