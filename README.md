# meee2

> macOS menubar app that watches your AI coding sessions (Claude CLI, Claude Desktop, Codex, Cursor, OpenClaw, …) through a Dynamic Island overlay, a web Board, an ncurses TUI, and a CLI — one process, one source of truth.

![status: active development](https://img.shields.io/badge/status-active--dev-orange) ![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift 5.7+](https://img.shields.io/badge/Swift-5.7%2B-orange)

---

## Table of contents

- [What it does](#what-it-does)
- [Surfaces](#surfaces)
- [Install / build](#install--build)
- [Hook setup (Claude CLI)](#hook-setup-claude-cli)
- [CLI reference](#cli-reference)
- [Plugin system](#plugin-system)
- [Architecture overview (for contributors)](#architecture-overview-for-contributors)
- [Repository layout](#repository-layout)
- [Development workflow](#development-workflow)
- [Documentation](#documentation)
- [License](#license)

---

## What it does

meee2 is a single macOS process that:

1. **Ingests** events from Claude CLI hooks (and other AI clients) over a Unix domain socket at `/tmp/meee2.sock`.
2. **Reconciles** those events against the on-disk transcript (`.jsonl`) to derive a single canonical `SessionStatus` per session.
3. **Publishes** a unified session model to four surfaces — Dynamic Island, TUI, CLI, Web Board — that all read from the same `SessionStore`.
4. **Routes** A2A (agent-to-agent) messages between sessions through named channels, and handles permission-request round-trips back to the CLI.

The whole app runs with `.accessory` activation policy — no Dock icon, just the menu bar item and the Island overlay.

---

## Surfaces

| Surface | Entry | What it's for |
|---|---|---|
| **Dynamic Island** | menubar icon → click | Always-on overlay; shows current session + permission prompts; click `Allow` / `Deny` without leaving the editor |
| **Web Board** | `localhost:9876` (built-in HTTP) or `localhost:5173` (Vite dev) | Multi-session canvas: cards, transcripts, sidebar, A2A channel chat, MCP/template editors |
| **TUI** | `meee2 dashboard` | Full-screen ncurses dashboard (works over SSH) |
| **CLI** | `meee2 list / send / jump / channel / msg / board / note / whoami / test` | Scriptable inspect + control |

All four read the same on-disk `~/.meee2/` state and the same in-memory `SessionStore` when the GUI is running.

---

## Install / build

### From source

```bash
git clone https://github.com/tianqixinxi/meee2.git
cd meee2

# Debug build, fastest iteration
swift build

# Release + codesign + dylib install to ~/.meee2/lib + Sparkle wiring
./build.sh

# Build + deploy to /Applications (preserves Accessibility TCC if you set IDENTITY)
./deploy.sh
```

Web frontend is built automatically by `build.sh` if `pnpm` is installed and `packages/board-app/` is present. To skip (e.g. CI already built it): `SKIP_WEB_BUILD=1 ./build.sh`.

For a universal arm64+x86_64 binary (distribution): `UNIVERSAL=1 ./build.sh` (~2× slower).

Code signing: set `IDENTITY` env to a Developer ID identity (e.g. `"Developer ID Application: Your Name (TEAMID)"`) for stable signing across rebuilds — without it, ad-hoc signing rotates the signature every build and macOS revokes Accessibility permission.

### Pre-built DMG

See [Releases](https://github.com/tianqixinxi/meee2/releases) for notarized DMGs.

### System requirements

- macOS 13.0 (Ventura) or newer
- Swift 5.7+ (only required for source builds)
- Optional: Node 20+ and pnpm 10+ for web frontend dev

---

## Hook setup (Claude CLI)

Add hooks to `~/.claude/settings.json` so the CLI calls the bridge on each event. The bridge captures `tty` / `term_program` / `cmuxSocket` / `ghosttyTerminalId` and writes the JSON to `/tmp/meee2.sock`:

```json
{
  "hooks": {
    "SessionStart":      [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }],
    "PreToolUse":        [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }],
    "PostToolUse":       [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }],
    "PermissionRequest": [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }],
    "Notification":      [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }],
    "Stop":              [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }],
    "UserPromptSubmit":  [{ "command": "/Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh" }]
  }
}
```

Source: [`Bridge/claude-hook-bridge.sh`](Bridge/claude-hook-bridge.sh).

`SessionStart` is enough to make a session appear; the rest enable the live status / permission flows.

---

## CLI reference

```
meee2                       Launch the GUI (default)
meee2 board                 Run only the Web Board HTTP server (no GUI)
meee2 dashboard             ncurses TUI

meee2 list [--json|--simple]              List sessions
meee2 send <sessionId> <message>          Push a one-off message to a session
meee2 jump <sessionId>                    Open the originating terminal/app
meee2 note <sessionId> <text>             Attach a sticky note
meee2 whoami                              Print this session's id (when run from inside a session)

meee2 channel ...                         A2A channel admin (create/list/join)
meee2 msg send --channel <name> --from <a> --to <b> --human "..."
                                          Send an A2A message

meee2 test capture <sid-prefix> --name <slug> --desc "..."
                                          Freeze the current resolver state
                                          into Tests/Fixtures/StateTraces/
meee2 test list / replay <name>           Manage state-trace fixtures
```

The CLI and GUI share the same on-disk state under `~/.meee2/`, so commands work whether the GUI is running or not.

---

## Plugin system

Plugins are dynamic libraries (`.dylib`) that subclass `SessionPlugin` from the [`meee2-plugin-kit`](meee2-plugin-kit/) shared SDK. Drop them in `~/.meee2/plugins/<id>/` and meee2 loads them at startup.

**Built-in plugins** (in [`plugins-builtin/`](plugins-builtin/)): Cursor, Codex, OpenClaw — installed automatically.

**Writing your own**: see [`plugin-template/`](plugin-template/) and [`docs/PLUGIN_DEVELOPMENT.md`](docs/PLUGIN_DEVELOPMENT.md).

The Claude CLI integration is itself a plugin (`Sources/ClaudeCLI/ClaudePlugin.swift`) compiled into the main binary — same SDK, just statically linked.

---

## Architecture overview (for contributors)

```
                    ┌──────────────────────────────┐
                    │      Claude Code CLI         │
                    │  (settings.json hooks)       │
                    └──────────────┬───────────────┘
                                   │ stdin JSON per event
                                   ▼
                    ┌──────────────────────────────┐
                    │ Bridge/claude-hook-bridge.sh │ ◄── captures tty / termProgram /
                    └──────────────┬───────────────┘     cmuxSocket / ghosttyTerminalId
                                   │ /tmp/meee2.sock
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                          meee2 process                                 │
│                                                                        │
│  ┌────────────────────┐     ┌────────────────────┐                     │
│  │ HookSocketServer   │────▶│   ClaudePlugin     │                     │
│  └─────────▲──────────┘     └─────────┬──────────┘                     │
│            │ permission reply         │ parse + enrich                 │
│            │              ┌───────────▼─────────────┐                  │
│            │              │ TranscriptParser +      │                  │
│            │              │ TranscriptStatusResolver│                  │
│            │              └───────────┬─────────────┘                  │
│            │                          ▼                                │
│            │              ┌────────────────────────┐                   │
│            │              │     SessionStore       │  source of truth  │
│            │              │  ~/.meee2/sessions/    │  (@Published)     │
│            │              └─────────┬──────────────┘                   │
│  ┌─────────┴────────┐               │                                  │
│  │  PluginManager   │      ┌────────▼─────────┐    ┌────────────────┐  │
│  │  (dylib loader)  │      │  StatusManager   │◄──▶│ MessageRouter +│  │
│  └──────────────────┘      └────┬─────────────┘    │ ChannelRegistry│  │
│                                 │                  └────────────────┘  │
│      ┌──────────────────────────┼──────────────────────────────┐       │
│      ▼                          ▼                              ▼       │
│  ┌─────────┐            ┌──────────────┐               ┌─────────────┐ │
│  │ Island  │            │   TUI        │               │ BoardServer │─┼─▶ packages/board-app
│  │  View   │            │ DashboardView│               │ /api/state  │ │   (React)
│  └─────────┘            └──────────────┘               └─────────────┘ │
└────────────────────────────────────────────────────────────────────────┘
```

### Core runtime services (`Sources/Core/`, `Sources/ClaudeCLI/`, `Sources/Board/`)

| Module | File | Role |
|---|---|---|
| `SessionStore` | `Sources/Core/SessionStore.swift` | Single source of truth, `@Published`, persists to `~/.meee2/sessions/<sid>.json` |
| `SessionMonitor` | `Sources/Core/SessionMonitor.swift` | Watches `~/.claude/projects/` for new transcripts |
| `HookSocketServer` | `Sources/ClaudeCLI/HookSocketServer.swift` | `/tmp/meee2.sock` server + pending permission queue |
| `ClaudePlugin` | `Sources/ClaudeCLI/ClaudePlugin.swift` | Translates hook events into `SessionData` mutations |
| `TranscriptStatusResolver` | `Sources/ClaudeCLI/TranscriptStatusResolver.swift` | Canonical `SessionStatus` — Island / TUI / Board all read through this |
| `MessageRouter` | A2A inbox queue + delivery hints (queued-until-next-turn, …) |
| `ChannelRegistry` | A2A channel membership + persistence |
| `PluginManager` | `dlopen` loader for `~/.meee2/plugins/<id>/*.dylib` |
| `BoardServer` | `Sources/Board/BoardServer.swift` | HTTP server (port `9876`) for the Web Board, `/api/state`, attachments, etc. |

### Filesystem layout

```
~/.meee2/
├── sessions/<sid>.json     # SessionData per session (schema-versioned)
├── plugins/<id>/*.dylib    # User-installed plugins
├── lib/                    # libMeee2PluginKit.dylib (install path for SDK)
├── channels/               # A2A channel state
├── attachments/            # Web Board uploads
└── logs/meee2.log          # Long-form log

/tmp/
├── meee2.sock              # Hook socket
└── meee2.log               # Live log (tail this for debugging)
```

For the full picture (process model, schema versioning, ESC handling, terminal jumping, A2A semantics) see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Repository layout

```
App/                          GUI entry (AppDelegate, Meee2App, Island window controller)
Sources/
  Core/                       SessionStore, SessionMonitor, ClaudeSession types
  ClaudeCLI/                  ClaudePlugin + transcript / hook plumbing
  Board/                      HTTP server, REST API, DTOs, web dist locator
  CLI/                        Subcommands (list, send, jump, msg, channel, test, …)
  TUI/                        ncurses dashboard
  Terminal/                   TerminalJumper + Ghostty/iTerm/cmux glue
  PluginRuntime/              Dynamic plugin loader
  SystemServices/             Sound, settings, version check, debug export
  Views/                      SwiftUI views (Island, settings)
  Utils/                      Logging (MLog/MDebug/...), small helpers

meee2-plugin-kit/             Public Swift SDK (SessionPlugin, types) — shipped as dylib
meee2-comm-kit/               Shared comms types between meee2 and plugins
plugins-builtin/              Cursor / Codex / OpenClaw plugins, statically loaded
plugin-template/              Skeleton for third-party plugins

packages/                     pnpm workspace (TypeScript)
  board-app/                  React + Vite Web Board UI
  board-cards/                Reusable card components
  board-core/                 Shared types + helpers
  board-persistence-http/     HTTP-backed state store
  board-ui/                   Design system primitives

Bridge/                       claude-hook-bridge.sh, mcp-meee2, meee360-reporter.sh
extension/                    Companion browser extension (Chrome MV3)
landingpage/                  Marketing site
Resources/                    App assets (icons, plist fragments)
Tests/                        XCTest suite + Tests/Fixtures/StateTraces/

scripts/                      validate.sh (pre-commit gate), CI helpers, lib-codesign.sh
build.sh                      Release + codesign + dylib install
deploy.sh                     build.sh + copy to /Applications
create-dmg.sh                 Notarizable DMG packaging
docs/                         ARCHITECTURE / SCHEMAS / PLUGIN_DEVELOPMENT / UPDATES
```

---

## Development workflow

```bash
swift build                  # Debug build (use this for iteration)
swift test                   # Full test suite
./scripts/validate.sh        # Pre-commit gate: build + test + swiftlint + hardcoded-path/print scans
```

Web frontend (hot-reloads, no Swift restart needed):

```bash
pnpm install
pnpm dev:web                 # Vite at localhost:5173, talks to BoardServer at :9876
pnpm typecheck               # TS typecheck across all packages
pnpm build                   # Production build → Sources/Board/WebDist
```

After a Swift change, restart the running app:

```bash
kill $(pgrep -f '\.build/.*meee2$') 2>/dev/null; sleep 1
nohup ./.build/arm64-apple-macosx/debug/meee2 >/tmp/meee2.log 2>&1 &
tail -F /tmp/meee2.log | grep -aE 'StateTrace|MessageRouter|TerminalJumper'
```

### Conventions

- **Logging**: use `MLog / MDebug / MInfo / MWarn / MError` in `Sources/`. `print()` only allowed in `Sources/CLI/`.
- **No hardcoded user paths**: use `NSHomeDirectory()` / `Bundle.main` / `FileManager`. `validate.sh` enforces.
- **`SessionData` schema**: bump `currentSchemaVersion` + add a migrator in `SessionDataMigrations`, and freeze a legacy JSON fixture as a regression test.
- **Resolver bug fixes**: capture a state-trace fixture (`meee2 test capture …`) before / after — the diff alone won't tell you which other cases you broke.
- **Comments**: Chinese inline comments are fine. Doc comments describe *why*, not *what*.

See [`AGENTS.md`](AGENTS.md) and [`CLAUDE.md`](CLAUDE.md) for the full house rules.

---

## Documentation

| Doc | What's in it |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Module map, data flow, hook ingress, state resolution, plugin loading, A2A, permission handling, terminal jumping, concurrency model |
| [`docs/SCHEMAS.md`](docs/SCHEMAS.md) | All public types: hook events, `SessionData`, plugin SDK, Board HTTP DTOs |
| [`docs/PLUGIN_DEVELOPMENT.md`](docs/PLUGIN_DEVELOPMENT.md) | Writing, packaging, installing third-party plugins |
| [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md) | House rules + debugging cookbook for human + AI contributors |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Local build, test, PR flow |
| [`PACKAGING.md`](PACKAGING.md) / [`RELEASING.md`](RELEASING.md) | DMG packaging, notarization, release flow |
| [`SECURITY.md`](SECURITY.md) | Vulnerability disclosure + trust boundaries |

---

## License

[MIT](LICENSE)
