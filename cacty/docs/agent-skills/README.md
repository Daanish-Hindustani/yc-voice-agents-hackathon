# Agent skills

Skills the agent (Gemini, in Cacty's case) consults when planning
how to drive a real macOS app. They are written for the agent's
ear: how to think about the tools, which paths are background-safe,
which app families have known quirks, and what the recorded
trajectory format looks like.

These docs are **not** invoked at runtime in this form. Phase 1
will lift their content into `Agent/ToolSchema.swift` tool
descriptions and into the Gemini system prompt. Keeping them here
in source control means a single place owns the institutional
knowledge — when a quirk turns out to be wrong, the fix is one
edit, and the next prompt-build picks it up.

## What's here

| File | Purpose |
|---|---|
| [`driving-mac-apps.md`](./driving-mac-apps.md) | The core skill: no-foreground contract, snapshot-before-action loop, tool preference order (`click_element` over `click_pixel`), forbidden hotkeys, AX-state-cache invalidation rules. **Lift verbatim into the Gemini system prompt.** |
| [`web-app-quirks.md`](./web-app-quirks.md) | Chromium / WebKit / Electron / Tauri quirks: minimized-Chrome keyboard limitations, omnibox commit signals, tabs-vs-windows pattern, HTML5 video click-to-play. |
| [`google-calendar.md`](./google-calendar.md) | Per-app skill for Google Calendar (web): event creation flow, time/date picker pixel-click requirement, Save-button AXPress refusal, absolute-date typing rule, read-event pattern. Operational rules lifted into Worker.swift rule 11. |
| [`trajectory-format.md`](./trajectory-format.md) | On-disk turn-folder format produced by `Sources/Automation/Recording/`. Consumed by the Phase 1 replay viewer. |

## Where they came from

The Cacty engine in `Sources/Automation/` was vendored from a Swift
`cua-driver` codebase that exposed the same primitives via an MCP
server and CLI. These skills started as Claude Code skill docs for
that wrapper. Cacty doesn't ship MCP, a CLI, or a separate `.app`
bundle — but the **engine semantics** (AX clicks, SkyLight pixel
posts, scoped keyboard input, focus-restore guard, AX-tree caching)
are identical, and so are the patterns the agent needs to follow
to drive real apps without stealing focus.

Anywhere these docs say `cua-driver call <tool>`, read it as the
matching tool call in the agent's schema. Tool names map 1:1
(`click_element`, `click_pixel`, `type_text`, `press_key`,
`get_window_state`, `launch_app`, `list_windows`, `list_apps`),
and argument shapes (`pid`, `window_id`, `element_index`) are
identical because both surfaces drive the same engine primitives.

## How Phase 1 consumes these

When `Sources/Agent/` and `Sources/App/Supervisor/` land:

1. Lift `driving-mac-apps.md` § "The no-foreground contract"
   verbatim into the Gemini system prompt.
2. Fold the action-paths table and tool preference rules from the
   same doc into each `Tool.description` in
   `Agent/ToolSchema.swift`.
3. Embed the forbidden-hotkey denylist both in the prompt **and**
   as a hard refusal at the supervisor layer (the latter is the
   actual safety contract — the model is not the last line of
   defense).
4. Surface the per-app quirks from `web-app-quirks.md` as numbered
   "known quirks" entries the model can pattern-match against
   during planning.
5. Consume the on-disk format from `trajectory-format.md` in the
   replay viewer.
