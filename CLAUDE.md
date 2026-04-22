# meee2

macOS menu bar app that monitors Claude Code sessions via a Dynamic Island-style overlay.

## Build Commands

```bash
swift build                 # Debug build (fastest, use for iteration)
swift build -c release      # Release build
swift test                  # Run all tests
./build.sh                  # Release build + codesign + dylib install
./scripts/validate.sh       # Pre-commit validation (build + test + lint)
```

## Architecture

### Entry Point

- `App/Meee2App.swift` — SwiftUI `@main`. Dispatches CLI commands in `init()`, falls through to GUI if no args.
- `App/AppDelegate.swift` — Status bar icon, Dynamic Island window setup, TUI launch.

### Data Flow

```
Claude CLI hooks → Bridge/claude-hook-bridge.sh (shell)
    → Unix socket /tmp/meee2.sock
    → HookSocketServer (receives JSON events)
    → ClaudePlugin (processes events, updates caches)
    → SessionStore (single source of truth, persists to ~/.meee2/sessions/)
    → StatusManager → IslandView (SwiftUI)
```

### Module Layout

```
Sources/
  Models/       — Data types: AISession, HookEvent, SessionType
  Services/     — Core services: SessionMonitor, HookSocketServer, ClaudePlugin,
                  PluginManager, TerminalManager, SessionStore, LogManager
  Views/        — SwiftUI: IslandView, SettingsView, PluginSessionRowView
  TUI/          — Terminal dashboard (ncurses-based)
  CLI/          — CLI commands: list, send, jump, note
  Utils/        — SafeUtils
App/            — App entry point + AppDelegate
meee2-plugin-kit/ — Plugin SDK (dynamic library, shared by all plugins)
plugins-builtin/  — CursorPlugin, OpenClawPlugin
Bridge/         — claude-hook-bridge.sh (hook event forwarder)
```

### Key Types

- `SessionStore` (`Sources/Services/SessionStore.swift`) — Single source of truth. Both TUI and GUI read from here.
- `SessionData` — Full session model with status, tasks, usage stats, terminal info, pending permissions.
- `HookEvent` — Parsed hook event from Claude CLI. Drives all state transitions.
- `ClaudePlugin` — Main plugin. Processes hook events, enriches sessions, handles permission requests.
- `PluginSession` (in `meee2-plugin-kit`) — UI-facing session model passed to views.
- `StatusManager` — Aggregates all plugin data, drives the Dynamic Island UI.

## Code Conventions

- **Logging**: Use `MLog()` / `MDebug()` / `MInfo()` / `MWarn()` / `MError()` in `Sources/`. Never use `print()` in Services. `print()` is only for CLI stdout output (`Sources/CLI/`).
- **No hardcoded paths**: Use `Bundle.main`, `NSHomeDirectory()`, `FileManager`. Never write `/Users/username/...`.
- **Plugin architecture**: Subclass `SessionPlugin` (open class). All inter-plugin communication goes through `PluginManager`.
- **Comments**: Chinese (Mandarin) for inline comments is fine. Keep doc comments descriptive.
- **Minimum deployment**: macOS 13.0, Swift 5.7.

## Common Pitfalls

- The app runs as `.accessory` (`NSApp.setActivationPolicy(.accessory)`) — no Dock icon, only status bar + Dynamic Island.
- `HookSocketServer` keeps sockets open for `PermissionRequest` events awaiting user response. Do not close them early.
- `meee2Kit` is used by both the GUI app and the CLI/TUI. Code in `Sources/` must not assume GUI is running.
- `DynamicIslandWindow` must have `sizingOptions = []` on its `NSHostingView` to prevent infinite constraint update loops.
- Entitlements disable sandbox and library validation — required for dynamic plugin loading.
- Ghostty tab jumping uses a TTY title marker approach (writes escape sequence to `/dev/ttyNNN`, matches via Accessibility API).
- Ad-hoc codesigning (`--sign -`) invalidates macOS accessibility permissions on every rebuild. Use a stable identity for development.

## Testing

```bash
swift test                          # Run all tests
swift test --filter HookEventTests  # Run specific test class
```

Test files are in `Tests/`. Fixtures (sample JSON) are in `Tests/Fixtures/`.

## Validation

Before committing, run:

```bash
./scripts/validate.sh
```

This checks: compilation, tests, lint rules, hardcoded paths, and bare `print()` in library code.
