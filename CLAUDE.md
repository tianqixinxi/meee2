# meee2

macOS menu bar app that monitors Claude Code (and other AI) sessions via a Dynamic Island overlay + web board + ncurses TUI + CLI.

Deeper references: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (+ §6 for hook → state → UI flow and ESC handling), [`docs/SCHEMAS.md`](docs/SCHEMAS.md).

## Build

```bash
swift build                 # Debug (fastest iteration)
swift build -c release      # Release
swift test                  # Full test suite (currently 54 tests)
./scripts/validate.sh       # Pre-commit gate: build + test + swiftlint + hardcoded-path/print scans
./build.sh                  # Release + codesign + dylib install to ~/.meee2/lib
```

## Architecture

Hook flow:

```
Claude CLI hook → Bridge/claude-hook-bridge.sh → /tmp/meee2.sock
               → HookSocketServer → ClaudePlugin → SessionStore
               → StatusManager / BoardServer → Island / TUI / Web
```

Core runtime services (`Sources/Services/`) — the authoritative state layer:

| Module | Role |
|---|---|
| `SessionStore` | Single source of truth, `@Published`, persists to `~/.meee2/sessions/<sid>.json` |
| `HookSocketServer` | `/tmp/meee2.sock` + pending permissions (`permissionTimeoutSeconds`) |
| `TranscriptStatusResolver` | Canonical `SessionStatus` — Island / TUI / Board all read through this |
| `MessageRouter` | A2A message store + per-session inbox queue |
| `ChannelRegistry` | A2A channels |
| `PluginManager` | Dynamic plugin loader (`~/.meee2/plugins/<id>/*.dylib`) |

Surfaces:
- **Island** — SwiftUI `IslandView`, menubar overlay
- **TUI** — `meee2 dashboard`, ncurses
- **CLI** — `meee2 list / send / jump / note / channel / msg / board / whoami`
- **Web Board** — React + Vite @ `localhost:5173` (dev) or `localhost:9876` (served by `BoardServer`)

Plugin SDK: `meee2-plugin-kit/` (shared dylib, defines `SessionPlugin` open class + public types).

## Code Conventions

- **Logging**: `MLog / MDebug / MInfo / MWarn / MError` in `Sources/`. NEVER `print()` in `Sources/Services/` — validate.sh enforces. `print()` only in `Sources/CLI/` for stdout output.
- **No hardcoded user paths**: `NSHomeDirectory() / Bundle.main / FileManager`. SwiftLint + validate.sh enforce.
- **`SessionData` schema**: Bump `SessionData.currentSchemaVersion` + add a migrator in `SessionDataMigrations` when on-disk shape changes. Include a regression test with a frozen legacy JSON fixture.
- **Single `SessionStatus` enum**: Don't fork a parallel status type. Extend `TranscriptStatusResolver` if new case logic is needed.
- **Plugins**: Subclass `SessionPlugin`. Inter-plugin comm through `PluginManager`.
- **Comments**: Chinese inline comments are fine. Doc comments describe *why*, not *what*.
- **Minimum**: macOS 13.0, Swift 5.7.

## Debugging

Most debug loops follow one pattern: **tail the log + trigger the action + grep the trace**.

### Log file

meee2 writes all `NSLog` / `[StateTrace]` events to `/tmp/meee2.log` (plus `~/Library/Logs/meee2.log` as fd 3). Watch in real time:

```bash
tail -F /tmp/meee2.log | grep -a -E "StateTrace|TerminalJumper|MessageRouter"
```

Common trace tags:

| Tag | When |
|---|---|
| `[StateTrace][hook-ingress][socket]` | Incoming hook JSON hit the socket |
| `[StateTrace][hook]` | After ClaudePlugin processed it, with before/after hookStatus |
| `[StateTrace][resolver]` | `TranscriptStatusResolver` decision (+ tail reason) |
| `[StateTrace][boardDTO]` | What `/api/state` reports to Web |
| `[TerminalJumper]` | Open-terminal flow (marker → AppleScript focus) |
| `[MessageRouter]` | A2A send / deliver / drain / direct-push |

### Quick state inspection

```bash
curl -s http://localhost:9876/api/state | \
  jq '.sessions[] | {id: .id[:8], title, status, currentTool}'
```

### Restart meee2 after a rebuild

Swift changes need a restart; Vite web changes hot-reload themselves.

```bash
kill $(pgrep -f '\.build/.*meee2$') 2>/dev/null; sleep 1
nohup /Users/<you>/projects/meee1_code/meee2/.build/arm64-apple-macosx/debug/meee2 \
  >/tmp/meee2.log 2>&1 &
```

### Web UI (browser console)

For card / overlay bugs, drive a visible puppeteer yourself instead of asking the user to paste console output. Setup + runner live at `/tmp/meee2-browser-debug/debug.js`:

```bash
: > /tmp/browser.log
cd /tmp/meee2-browser-debug && (node debug.js >> /tmp/browser.log 2>&1 &)
tail -F /tmp/browser.log
```

The Chromium window is interactive — the user clicks, you read the log.

## Acceptance / Validation

Before committing, **every PR**:

```bash
./scripts/validate.sh   # build + test + swiftlint + hardcoded-path + bare-print() scans
```

For non-trivial behavior changes, also smoke these by hand:

1. Launch the GUI — menubar icon appears, Island window renders
2. In a test Claude session, send a prompt — the card transitions `idle → thinking → tooling → idle` (not stuck)
3. Open Terminal from two different session cards — each focuses its own Ghostty tab (not all the same)
4. `meee2 msg send --channel __ops-<sid> --from operator --to session --human "ping"` — target session receives it within ~2s
5. `curl /api/state` returns current sessions with correct `status`

For UI changes, **hard-refresh** `localhost:5173` before evaluating (Vite HMR sometimes leaks stale chunks).

## Common Pitfalls

- `.accessory` activation policy — no Dock icon, menubar + Island only.
- `HookSocketServer` holds the permission socket open until user responds or `permissionTimeoutSeconds` (default 300s) expires. Don't close early.
- `meee2Kit` is imported by CLI/TUI/GUI — code in `Sources/` must not assume `NSApplication` is running.
- `DynamicIslandWindow`'s `NSHostingView` must have `sizingOptions = []` (prevents infinite constraint update loops).
- Entitlements disable sandbox + library validation — required for plugin dylib loading. Document any new code path that executes user-provided code in [`SECURITY.md`](SECURITY.md).
- **Ghostty tab jumping**: `focus (terminal id X)` per its sdef only raises the window, doesn't switch tab. Must walk `windows → tabs → terminals`, `select tab`, then `focus`. See `TerminalJumper.focusGhosttyTerminal`.
- Ad-hoc codesign (`--sign -`) invalidates Accessibility permissions every rebuild — use a stable identity for dev.
- `DEFAULT_TEMPLATE` is a backtick-wrapped template literal. Bare `\n` in its content gets evaluated at import time — breaks `//` comments and `'...'` strings. Write `\\n` inside to get literal `\n` at runtime.
