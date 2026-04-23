# meee2 Architecture

This doc is for contributors who need to understand how the pieces fit together. For API / data-type reference see [SCHEMAS.md](SCHEMAS.md). For writing plugins see [PLUGIN_DEVELOPMENT.md](PLUGIN_DEVELOPMENT.md).

---

## 1. Overview

meee2 is a single macOS process that:

1. **Ingests** events from Claude CLI hooks (and other AI clients) over a Unix domain socket.
2. **Reconciles** those events against the transcript on disk to derive a single truthful `SessionStatus`.
3. **Publishes** a unified session model to four surfaces: the Dynamic Island (SwiftUI), a TUI dashboard (ncurses), a CLI, and a Web Board (React, served by an embedded HTTP server).
4. **Routes** messages between AI sessions through A2A channels, and handles permission-request round-trips back to the CLI.

The whole app runs as a `.accessory` activation policy process — no Dock icon, just the menu bar + overlay window. The CLI/TUI and GUI share the same `meee2Kit` Swift module; the binary dispatches on argv in `Meee2App.init()`.

---

## 2. Process Model

One process, multiple surfaces:

| Surface | Thread / Runloop | Entry | Purpose |
|---|---|---|---|
| **GUI** | main runloop (NSApplication) | `App/Meee2App.swift` → `AppDelegate` | Status bar item + Dynamic Island window + Settings window |
| **TUI** | main runloop (ncurses owns stdin) | `meee2 dashboard` | Full-screen terminal dashboard |
| **CLI** | main thread, exits after command | `meee2 list / send / jump / channel / msg / board / note …` | Scriptable commands |
| **Hook Socket** | `com.meee2.socket` serial `DispatchQueue` | `HookSocketServer.shared.start(...)` | Accept Unix-socket clients, parse JSON, dispatch events |
| **Board HTTP** | own queue inside `BoardServer` | `meee2 board` or GUI start | Serves `web/` static files + JSON API on `:9876` |
| **Session Monitor** | background | `SessionMonitor` | Watches `~/.claude/sessions/` for new sessions |

The CLI and TUI read the same `SessionStore` that the GUI writes to, via the `~/.meee2/` filesystem (below). There is no IPC between CLI invocations and the running GUI for most commands — they both read/write the same JSON files.

---

## 3. Data Flow (10,000-foot view)

```
                    ┌──────────────────────────────┐
                    │      Claude Code CLI         │
                    │  (settings.json hooks 配置)  │
                    └──────────────┬───────────────┘
                                   │ stdin JSON per event
                                   ▼
                    ┌──────────────────────────────┐
                    │  Bridge/claude-hook-bridge.sh│ ◄── captures tty / termProgram /
                    └──────────────┬───────────────┘     cmuxSocket / ghosttyTerminalId
                                   │ connect + write /tmp/meee2.sock
                                   ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                         meee2 process                                      │
│                                                                            │
│  ┌────────────────────┐     ┌────────────────────┐                        │
│  │ HookSocketServer   │────▶│   ClaudePlugin     │  (SessionPlugin impl)  │
│  │  (/tmp/meee2.sock) │     └─────────┬──────────┘                        │
│  └─────────▲──────────┘               │ parse + enrich                    │
│            │ permission reply         ▼                                    │
│            │              ┌────────────────────────┐                      │
│            │              │ TranscriptParser +     │                      │
│            │              │ TranscriptStatusResolver│  reads JSONL tail    │
│            │              └────────────┬───────────┘                      │
│            │                           ▼                                    │
│            │              ┌────────────────────────┐                      │
│            │              │     SessionStore       │  single source of    │
│            │              │  ~/.meee2/sessions/    │  truth (ObservableObject)│
│            │              └─────────┬──────────────┘                      │
│            │                        │                                      │
│  ┌─────────┴────────┐      ┌────────▼─────────┐      ┌───────────────┐   │
│  │  PluginManager   │◄────▶│  StatusManager   │◄────▶│ MessageRouter │   │
│  │  (dylib loader)  │      │ (@Published agg) │      │ ChannelRegistry│  │
│  └──────────────────┘      └────┬─────────────┘      └───────┬───────┘   │
│                                 │                             │           │
│      ┌──────────────────────────┼─────────────────────────────┼───────┐  │
│      ▼                          ▼                             ▼        │  │
│  ┌─────────┐            ┌──────────────┐               ┌────────────┐  │  │
│  │ Island  │            │   TUI        │               │BoardServer │──┼─▶ web/ (React)
│  │  View   │            │ DashboardView│               │ /api/state │  │
│  └────┬────┘            └──────────────┘               └────────────┘  │  │
│       │                                                                 │  │
│       └── TerminalManager / TerminalJumper ──────────────────────────┘  │
│           (cmux · Ghostty AppleScript · iTerm2 · tmux)                  │
└───────────────────────────────────────────────────────────────────────────┘
```

Three interlocking pipelines run on top of this plumbing:

- **Event pipeline** — socket → `ClaudePlugin` → `SessionStore` → UI.
- **State resolution** — `SessionData` + transcript → `TranscriptStatusResolver` → canonical `SessionStatus`.
- **A2A messaging** — CLI/Web send → `MessageRouter` + `ChannelRegistry` → target session's inbox count.

---

## 4. Module Map

```
Sources/
  Models/        Data types            AISession, HookEvent, SessionType, Channel, A2AMessage
  Services/      Runtime services      SessionStore, HookSocketServer, ClaudePlugin,
                                       SessionMonitor, PluginManager, StatusManager,
                                       TranscriptParser, TranscriptStatusResolver,
                                       ChannelRegistry, MessageRouter, TerminalManager,
                                       TerminalJumper, AuditLogger, UsageTracker,
                                       SoundManager, LogManager, SessionEventBus, …
  Views/         SwiftUI               IslandView, DashboardView, SettingsView,
                                       PluginSessionRowView, BuddyASCIIView
  TUI/           ncurses dashboard     DashboardView, Table, Curses, InputReader
  CLI/           argv commands         CLI, ListCommand, SendCommand, JumpCommand,
                                       ChannelCommand, MsgCommand, BoardCommand, NoteCommand
  Board/         Embedded HTTP API     BoardServer, BoardAPI, BoardDTO, CardTemplateStore
  Utils/         Concurrency helpers   SafeUtils
App/             Entry point           Meee2App, AppDelegate
meee2-plugin-kit/  Plugin SDK (dylib)  SessionPlugin, PluginSession, SessionStatus,
                                       PluginTerminalInfo, UrgentEventInfo, SessionTask,
                                       UsageStats, StatusMappingService,
                                       TranscriptStatusParser
plugins-builtin/   Bundled plugins     CursorPlugin, OpenClawPlugin
Bridge/            Hook forwarder      claude-hook-bridge.sh
web/               React + Vite        Board frontend (consumes Board DTOs)
Tests/             XCTest              AISessionTests, HookEventTests, SessionDataTests,
                                       A2ATests, SessionEventBusTests
```

The `meee2Kit` Swift package target contains `Sources/` excluding `App/`. That's what CLI/TUI/GUI all import.

---

## 5. Hook Ingress Pipeline

The most load-bearing path in the app. Every hook event follows these steps.

### 5.1 Bridge (shell)

`Bridge/claude-hook-bridge.sh` is registered in `~/.claude/settings.json` under the appropriate hook keys (`PreToolUse`, `PostToolUse`, `Notification`, `PermissionRequest`, `Stop`, etc.). Claude CLI spawns it and streams the event JSON on stdin.

The bridge:

1. Reads the hook JSON from stdin.
2. **Enriches** it with local context the hook can't see: `tty`, `termProgram`, `termBundleId`, `cmuxSocketPath`, `cmuxSurfaceId`, `ghosttyTerminalId`.
3. Connects to `/tmp/meee2.sock` and writes the enriched JSON.
4. For events that expect a response (permission requests), waits for the server to write back and exits with a matching exit code so Claude CLI honors the decision.

### 5.2 Socket server

`HookSocketServer` (`Sources/Services/HookSocketServer.swift`) runs a GCD `DispatchSourceRead` on a bound `AF_UNIX`/`SOCK_STREAM` socket. On each `accept`:

1. Read the JSON payload.
2. Decode into `HookEvent`.
3. If the event is an **A2A delivery opportunity** (we have queued inbox messages for the receiving session), write back a `decision: "block"` response embedding those messages so Claude surfaces them — see `BoardAPI.swift` + the A2A router for the cases this triggers.
4. If the event is a **PermissionRequest** (`expectsResponse == true`), keep the client socket open, store a `PendingPermission` entry keyed by `tool_use_id`, and dispatch to `eventHandler` so `ClaudePlugin` can update UI. A timeout is scheduled — see §10.
5. Otherwise close the socket and dispatch the event.

### 5.3 ClaudePlugin

The event handler lives in `ClaudePlugin` (a built-in `SessionPlugin`). It:

- Upserts an `AISession` / `SessionData` into `SessionStore`, preserving sticky fields (see §7).
- Derives `SessionStatus` from `HookEvent.inferredStatus` as a first cut.
- Publishes an urgent event (`UrgentEventInfo`) when the event is a permission request or a user-facing notification.
- Calls `onSessionsUpdated` so `StatusManager` re-publishes to the UI.

---

## 6. State Resolution

`HookEvent.inferredStatus` is a coarse guess. The authoritative status comes from `TranscriptStatusResolver.resolve(for: SessionData)`, which:

1. Reads the last N lines of the transcript JSONL at `SessionData.transcriptPath`.
2. Parses the tail via `TranscriptStatusParser` (shared between meee2Kit and plugin-kit).
3. Decides `thinking` vs `tooling` vs `waitingForUser` vs `completed` vs etc.
4. `resolveCurrentTool` can similarly override the currently-running tool name.

All three display surfaces (Island, TUI, Board) use `TranscriptStatusResolver.resolve` rather than consuming `SessionData.status` directly — this keeps them in sync even when a hook arrives late or out of order. `BoardDTOBuilder.sessionDTO` and `SessionData.toPluginSession()` are the two places this happens.

---

## 7. SessionStore & Persistence

### 7.1 In-memory + disk

`SessionStore.shared` is the single source of truth:

- `@Published var sessions: [SessionData]` — live state for SwiftUI subscribers.
- Backed by `~/.meee2/sessions/<sessionId>.json` (one file per session, atomic tmp+rename writes).
- `upsert()` is the primary write path and implements **sticky-field preservation**: `ghosttyTerminalId` and a non-empty `terminalInfo` survive subsequent writes with empty values. This matters because not every hook carries terminal info, and we don't want late hooks to clobber it.

### 7.2 Schema versioning

`SessionData` embeds a `schemaVersion: Int` (JSON key `schema_version`). See [SCHEMAS.md §SessionData](SCHEMAS.md#sessiondata) for field details.

- Newly constructed records default to `SessionData.currentSchemaVersion`.
- Files written before versioning existed decode as `schemaVersion = 0`.
- `SessionStore.loadFromDisk` detects older records and runs `SessionDataMigrations.apply(to:from:)`, then rewrites the file so migrations only happen once per record.

When you change the on-disk shape:

1. Bump `SessionData.currentSchemaVersion`.
2. Add a `case` to `SessionDataMigrations.step(_:from:)` covering the old→new transformation.
3. Add a test in `Tests/SessionDataTests.swift` using a frozen legacy JSON fixture.

Each step should be idempotent and do no I/O — the store handles reading/writing around it.

### 7.3 Filesystem layout

```
~/.meee2/
  sessions/<sessionId>.json          # SessionData, versioned
  queues/<sessionId>.queue           # legacy inbox queue (A2A transitioning)
  unread/<sessionId>.json            # per-session unread notification
  logs/                              # MLog file sink (LogManager)
  plugins/<pluginId>/plugin.json     # third-party plugin metadata
  plugins/<pluginId>/*.dylib         # third-party plugin binary
  plugins/<pluginId>/settings.json   # per-plugin saved config
/tmp/meee2.sock                      # hook ingress socket (0o700)
```

---

## 8. Plugin Loading

`PluginManager.shared` discovers plugins in `~/.meee2/plugins/`:

1. For each directory, parse `plugin.json` for metadata.
2. Load the `.dylib` via `dlopen`, look up the `createPlugin` C-exported factory (see [PLUGIN_DEVELOPMENT.md](PLUGIN_DEVELOPMENT.md)).
3. Instantiate the `SessionPlugin` subclass, call `initialize()` then `start()`.
4. Wire `onSessionsUpdated` and `onUrgentEvent` so the plugin can push state into `StatusManager`.

Because the app entitlements disable library validation, any valid `.dylib` in that directory will run with the app's full privileges. `SECURITY.md` makes the trust model explicit: this is a local trust boundary, same as running a script you `chmod +x`.

The `ClaudePlugin` in `Sources/Services/` is **not** dynamically loaded — it's a built-in SessionPlugin compiled into `meee2Kit` and registered at startup. It was kept this way so the app works with zero plugins installed.

---

## 9. A2A Messaging

Inter-session communication uses two services:

- **`ChannelRegistry.shared`** — owns the channel graph. A `Channel` has a name, a `ChannelMode` (`.auto | .intercept | .paused`), members (`alias` ↔ `sessionId`), and metadata.
- **`MessageRouter.shared`** — owns `[A2AMessage]`. Each message has a `MessageStatus` (`.pending`, `.held`, `.delivered`, etc.).

The **delivery mechanism** reuses the hook socket: when Claude sends us any event for a session that has pending/held inbox items, the server writes a `PermissionResponse(decision: "block", reason: combined)` back to the CLI. That `reason` string contains the inbox content; Claude surfaces it as if it were a permission-block reason, effectively injecting the message into the session. See the socket server's handler for the exact conditions (search for `block-decision`).

Inbox count on the Web Board is computed in `BoardDTOBuilder.pendingInboxCount(for:)` — it walks all channels, finds aliases owned by the session, and counts `pending + held` messages addressed to those aliases (or broadcast to `*`, excluding self-sends).

---

## 10. Permission Handling

### 10.1 Happy path

```
CLI hooks PermissionRequest
  → Bridge → socket (client stays connected)
    → HookSocketServer stores PendingPermission{toolUseId → clientSocket}
      → ClaudePlugin publishes urgentEvent(PermissionRequest)
        → UI (Island / Board) shows Allow / Deny buttons
          → user clicks → HookSocketServer.respondToPermission(toolUseId, decision)
            → writes PermissionResponse to clientSocket, close()
              → Bridge returns the decision to Claude CLI
```

### 10.2 Timeout / default-deny

`HookSocketServer` must never leave Claude CLI blocked forever when the GUI crashes, the user walks away, or the socket otherwise goes quiet. When a pending permission is stored, `scheduleAutoResponse(toolUseId:)` queues a `DispatchQueue.asyncAfter` for `HookSocketServer.permissionTimeoutSeconds` (default **300s**). If the entry is still in `pendingPermissions` when the timer fires, the server auto-responds with `HookSocketServer.permissionTimeoutDecision` (default **"deny"**) and closes the socket.

Both knobs are `public static var` so tests / future settings UI can override them. Setting the timeout ≤ 0 disables the fallback (only useful in tests).

The race between a real response and the timeout is safe: `sendPermissionResponse` uses `pendingPermissions.removeValue` under `permissionsLock`, so whichever caller gets there first wins, and the other sees "no pending" and returns.

### 10.3 Cancellation

If Claude decides on its own to stop waiting (Stop event), `cancelPendingPermissions(sessionId:)` drops all entries for that session and closes their sockets. Individual cancellations by `toolUseId` also work — used when the terminal approves a tool before the UI does.

---

## 11. Terminal Jumping

`TerminalJumper` (via `TerminalManager`) maps a `PluginTerminalInfo` back to the right terminal window. Strategies, tried in order:

1. **cmux** — if `cmuxSocketPath` + `cmuxSurfaceId` are known, use cmux's control socket to focus the surface.
2. **Ghostty** — if `ghosttyTerminalId` is known, AppleScript: `tell application "Ghostty" to focus (terminal id "X")`. The fallback walks windows by `tty` title marker: meee2 writes an escape sequence to `/dev/tty<n>`, then finds the AXUIElement whose title contains the marker.
3. **iTerm2 / Terminal.app** — AppleScript matching by `tty`.
4. **tmux** — best-effort: find the pane whose `pane_tty` matches.

Plugins can register a custom `jumpHandlerId` on `PluginTerminalInfo` to opt into a bespoke jump handler.

---

## 12. Concurrency Model

- **Main thread** owns all `@Published` mutations on `SessionStore` / `StatusManager`. `HookSocketServer` callbacks that touch those go through `DispatchQueue.main.async` (via `ClaudePlugin`).
- **`com.meee2.socket` serial queue** owns the socket, the `pendingPermissions` dictionary (guarded by `permissionsLock: NSLock` for defensive reasons — some setters come from other queues), and all timer bookkeeping.
- **File I/O** for `SessionStore` is synchronous on whichever thread called `upsert`/`saveToDisk`. Writes are atomic (`write to tmp → rename`), so readers on other threads never see a half-written file.
- **`SessionEventBus.shared`** is a lightweight publish/subscribe used to decouple emitters of "session changed" from subscribers (TUI refresh, web polling). It uses a `DispatchQueue` barrier for mutation.

---

## 13. Invariants / Rules of the House

These are the things that, if you forget them, will bite you later. All of them are enforced by convention, not the compiler — don't bypass them without a commit-message explanation.

1. **`SessionStatus` is the single enum.** Don't introduce a parallel status type in a new surface. If the resolver doesn't give you what you need, extend the resolver.
2. **Three surfaces agree.** Island, TUI, Board all go through `TranscriptStatusResolver.resolve`. Don't short-circuit by reading `SessionData.status` directly in a view.
3. **No `print()` in `Sources/Services/`.** Use `MLog / MDebug / MInfo / MWarn / MError`. CI + validate.sh enforce this.
4. **No hardcoded `/Users/<name>` paths.** Use `NSHomeDirectory()`, `Bundle.main`, `FileManager`. SwiftLint + CI enforce this.
5. **Bump `schemaVersion` when `SessionData` shape changes.** Write a migrator and a regression test.
6. **Don't close the permission socket early.** The client is blocked on read. If you drop the fd without writing, Claude CLI hangs until the timeout fires.
7. **Plugins are trusted.** `disable-library-validation` is intentional. Document any new code path that executes user-provided code (e.g., card templates) in `SECURITY.md`.
8. **`meee2Kit` must not assume the GUI is running.** CLI/TUI import it too. Guard any `NSApplication` / SwiftUI use behind AppDelegate.

---

## 14. Known Gaps

These are the rough edges we're aware of; contributions welcome:

- Hook protocol isn't formally specified (no JSON Schema for `HookEvent`).
- The Board API isn't OpenAPI-documented; `BoardDTO.swift` is the de facto spec.
- Plugin SDK has no SemVer / ABI stability policy yet. `meee2-plugin-kit` is versioned with the app.
- No end-to-end integration tests — tests are at the model/parse layer. The socket→plugin→store pipeline is only covered by manual testing.
- No crash reporting or opt-in telemetry.
- No Localizable strings; UI copy is inline.

If you're tackling any of these, open an issue first so we can align on the approach.
