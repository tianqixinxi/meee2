# meee2 Schemas

Reference for every public / shared type in the meee2 codebase. Paired with [ARCHITECTURE.md](ARCHITECTURE.md), which explains how these types flow through the system.

Types are grouped by module. Each entry lists the **file path**, **purpose**, **fields**, and **producer → consumer** so you can trace who writes each piece of state and who reads it.

## Contents

- [Sources/Models — event & message types](#sourcesmodels)
  - [AISession](#aisession)
  - [HookEvent](#hookevent)
  - [HookEventType](#hookeventtype)
  - [SessionType](#sessiontype)
  - [A2AMessage](#a2amessage)
  - [MessageStatus](#messagestatus)
  - [Channel / ChannelMember / ChannelMode](#channel--channelmember--channelmode)
- [Sources/Services — runtime state](#sourcesservices)
  - [SessionData](#sessiondata)
  - [UnreadNotification](#unreadnotification)
- [meee2-plugin-kit — public SDK](#meee2-plugin-kit)
  - [SessionPlugin (base class)](#sessionplugin-base-class)
  - [SessionStatus](#sessionstatus)
  - [PluginSession](#pluginsession)
  - [PluginTerminalInfo](#pluginterminalinfo)
  - [UrgentEventInfo / PermissionDecision](#urgenteventinfo--permissiondecision)
  - [SessionTask / TaskStatus](#sessiontask--taskstatus)
  - [UsageStats](#usagestats)
- [Sources/Board — HTTP API DTOs](#sourcesboard)
  - [StateDTO](#statedto)
  - [SessionDTO](#sessiondto)
  - [UsageStatsDTO / TaskDTO / TranscriptEntryDTO](#usagestatsdto--taskdto--transcriptentrydto)
  - [ChannelDTO / MemberDTO](#channeldto--memberdto)
  - [MessageDTO](#messagedto)
  - [ErrorDTO + envelopes](#errordto--envelopes)

---

## Sources/Models

### AISession

**File** `Sources/Models/ClaudeSession.swift` (typealiased as `ClaudeSession`)

**Purpose** Legacy session model, still used for some persistent snapshots and by the plugin template. New code should prefer [`SessionData`](#sessiondata) — which carries the additional runtime fields (`tasks`, `usageStats`, `terminalInfo`, pending permissions) that the UI actually renders.

**Persistent fields** (from disk / `SessionStart` hook)

| Field | Type | JSON key | Notes |
|---|---|---|---|
| `id` | `String` | `sessionId` | UUID |
| `pid` | `Int` | `pid` | Claude CLI process ID |
| `cwd` | `String` | `cwd` | Working directory — `projectName` is derived from the last path component |
| `startedAt` | `Date` | `startedAt` | Accepts both ms timestamps (Int) and seconds (Double) on decode; always encoded as ms Int |
| `type` | `SessionType` | `type` | Defaults to `.claude` |
| `kind` | `String` | `kind` | e.g. `"interactive"` |
| `entrypoint` | `String` | `entrypoint` | e.g. `"cli"` |

**Runtime fields** (hook-driven, not persisted via `CodingKeys`)

| Field | Type | Set by |
|---|---|---|
| `status` | `SessionStatus` | `ClaudePlugin` from `HookEvent.inferredStatus`, later overridden by `TranscriptStatusResolver` |
| `currentTask`, `toolName`, `progress`, `errorMessage` | `String? / Int?` | `ClaudePlugin` |
| `tty`, `termProgram`, `termBundleId`, `cmuxSocketPath`, `cmuxSurfaceId`, `ghosttyTerminalId` | `String?` | Bridge script → `HookEvent` → `AISession.withTerminalInfo(...)` |
| `lastActivityTimestamp` | `Double?` | Bumped every hook; used for cleanup of stale sessions |
| `lastUpdated` | `Date` | Bumped on every status/tool change |

**Computed**: `projectName`, `duration`, `formattedDuration`, `isActive` (true if `lastUpdated < 5 min ago`).

---

### HookEvent

**File** `Sources/Models/HookEvent.swift`

**Purpose** The single event type coming off the hook socket. Decoded from Claude CLI JSON, enriched by the bridge with terminal info.

| Field | Type | JSON key | Notes |
|---|---|---|---|
| `event` | `HookEventType?` | `hook_event_name` (preferred) or `event` | `nil` if the hook didn't name an event |
| `sessionId` | `String?` | `session_id` | Claude CLI session UUID |
| `cwd` | `String?` | `cwd` | |
| `notification` | `String?` | `notification` | Populated for `.notification` events |
| `lastAssistantMessage` | `String?` | `last_assistant_message` | For `.stop` / `.sessionEnd` |
| `toolUseId` | `String?` | `tool_use_id` | Correlates `PreToolUse` / `PermissionRequest` / `PostToolUse`. If missing on a `PermissionRequest`, `HookSocketServer` falls back to a `(sessionId, toolName, toolInput)` cache populated by earlier `PreToolUse` events |
| `toolName` | `String?` | `tool_name` | |
| `rawToolInput` | `AnyCodable?` | `tool_input` | Unstructured JSON; `toolInput` / `toolInputDict` expose string or dict views |
| `rawToolOutput` | `AnyCodable?` | `tool_response` | Same shape for outputs |
| `permission`, `resource` | `String?` | `permission`, `resource` | For `.permissionRequest` |
| `status` | `String?` | `status` | `"waiting_for_approval"`, `"waiting_for_input"`, `"running_tool"`, `"processing"`, `"starting"`, `"compacting"` — drives `inferredStatus` |
| `tty`, `termProgram`, `termBundleId`, `cmuxSocketPath`, `cmuxSurfaceId`, `ghosttyTerminalId` | `String?` | Same names | Only present on user-triggered hooks (session start, prompt submit) |
| `timestamp` | `Date?` | `timestamp` | |
| `rawData` | `String?` | — | Populated post-decode for debugging; not a JSON field |

**Computed helpers**

| Property | Returns | Purpose |
|---|---|---|
| `inferredStatus` | `SessionStatus` | First-cut state for the session; `TranscriptStatusResolver` may override |
| `needsUserAction` | `Bool` | `.permissionRequest`, `.notification`, `.stop`, `.sessionEnd` |
| `shouldShowUrgentPanel` | `Bool` | Filters out low-value notifications (`"Task completed"`, `"Done"`, empty stops) |
| `expectsResponse` | `Bool` | True iff `.permissionRequest && status == "waiting_for_approval"` — causes `HookSocketServer` to keep the socket open |
| `statusDescription` | `String?` | Human-readable summary for UI |

**AnyCodable** is a `Decodable` wrapper around `Any?` used for `tool_input` / `tool_response` since Claude emits arbitrary JSON shapes there.

---

### HookEventType

`enum HookEventType: String, Codable, Sendable`

| Case | Raw value | Notes |
|---|---|---|
| `.notification` | `Notification` | Task-complete / idle notices |
| `.permissionRequest` | `PermissionRequest` | Socket stays open until response or timeout |
| `.preToolUse` | `PreToolUse` | Drives `thinking` status + populates toolUseId cache |
| `.postToolUse` | `PostToolUse` | Drives `tooling` status |
| `.preCompact` | `PreCompact` | Drives `compacting` status |
| `.sessionStart` | `SessionStart` | Creates `SessionData` |
| `.sessionEnd` | `SessionEnd` | Drives `completed` |
| `.stop` | `Stop` | Drives `completed` |
| `.subagentStart` | `SubagentStart` | `active` |
| `.subagentStop` | `SubagentStop` | `active` |
| `.userPromptSubmit` | `UserPromptSubmit` | `thinking` |

Each case maps to a `SoundEvent?` via `.soundEvent` for `SoundManager`.

---

### SessionType

`enum SessionType: String, Codable, CaseIterable` — values: `claude`, `cursor`, `copilot`, `aime`, `other`.

Used to tag which AI client owns a session, and to theme its Dynamic Island row. `.icon` returns an SF Symbol name.

---

### A2AMessage

**File** `Sources/Models/Message.swift`

**Purpose** A single message in an A2A channel — either agent-authored or human-injected via CLI.

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | `A2AMessage.newId()` generates short URL-safe ids |
| `channel` | `String` | Channel name |
| `fromAlias`, `fromSessionId` | `String`, `String` | Sender's alias within the channel + its underlying `sessionId` |
| `toAlias` | `String` | Recipient alias, or `"*"` for broadcast |
| `content` | `String` | Free text |
| `replyTo` | `String?` | Optional parent message id |
| `createdAt` | `Date` | Wall clock on the sender side |
| `status` | `MessageStatus` | See below |
| `deliveredAt` | `Date?` | Set by `MessageRouter` when delivered |
| `deliveredTo` | `[String]` | Aliases this message has been delivered to (important for broadcasts) |
| `injectedByHuman` | `Bool` | True if `meee2 msg send --human` was used |

Helpers: `renderForInbox()` returns the text block shown to an agent when a message is injected via the socket "block" decision. `isHumanDirect` is `injectedByHuman && toAlias != "*"`.

---

### MessageStatus

`enum MessageStatus: String, Codable, Sendable` — `pending`, `held`, `delivered`, `dropped`.

- **pending** — queued, will be delivered on next opportunity.
- **held** — intercepted by a channel in `.intercept` mode; waits for human approval.
- **delivered** — at least one recipient confirmed delivery (via hook-socket "block" response).
- **dropped** — explicitly discarded; doesn't count toward inbox.

`BoardDTOBuilder.pendingCount` counts `pending + held`.

---

### Channel / ChannelMember / ChannelMode

**File** `Sources/Models/Channel.swift`

```swift
enum ChannelMode: String, Codable, Sendable { case auto, intercept, paused }

struct ChannelMember {
    let alias: String       // channel-local handle, e.g. "alice"
    let sessionId: String   // underlying session UUID
    let joinedAt: Date
}

struct Channel {
    var name: String
    var members: [ChannelMember]
    var mode: ChannelMode
    let createdAt: Date
    var description: String?
    var id: String { name }
}
```

**Modes**

- **auto** — messages deliver via the next compatible hook event without human review.
- **intercept** — messages go to `held` status; human must approve.
- **paused** — nothing delivers; messages pile up in `pending`.

Lookups: `memberByAlias(_:)`, `memberBySessionId(_:)`.

---

## Sources/Services

### SessionData

**File** `Sources/Services/SessionStore.swift`

**Purpose** The primary in-memory + on-disk session model. This is what the UI binds to (via `SessionStore.sessions`), what gets serialized to `~/.meee2/sessions/<id>.json`, and what `BoardDTOBuilder.sessionDTO` starts from. Supersedes `AISession` for anything that touches the UI.

**Schema version** `SessionData.currentSchemaVersion = 1`. On-disk files written before this existed decode as `schemaVersion = 0` and get lazily migrated by `SessionDataMigrations.apply(to:from:)` at load time. See [ARCHITECTURE.md §7.2](ARCHITECTURE.md#72-schema-versioning).

| Field | Type | JSON key | Notes |
|---|---|---|---|
| `schemaVersion` | `Int` | `schema_version` | Defaults to `currentSchemaVersion` for new records; 0 for pre-versioning legacy |
| `sessionId` | `String` | `session_id` | Primary key |
| `project` | `String` | `project` | Working directory |
| `pid` | `Int?` | `pid` | |
| `ghosttyTerminalId` | `String?` | `ghostty_terminal_id` | Sticky across upserts (see §7.1) |
| `transcriptPath` | `String?` | `transcript_path` | Where `TranscriptStatusResolver` reads from |
| `startedAt` | `Date` | `started_at` | ISO8601 on disk |
| `lastActivity` | `Date` | `last_activity` | ISO8601 on disk; bumped on every `update` |
| `status` | `SessionStatus` | `status` (+ legacy `detailed_status`) | `SessionStatus.from(rawString:)` handles old case names |
| `currentTool` | `String?` | `current_tool` | Last observed tool from `PreToolUse` / `PostToolUse` |
| `description` | `String?` | `description` | User-provided note (via `meee2 note`) |
| `tasks` | `[SessionTask]` | `tasks` | |
| `currentTask` | `String?` | `current_task` | |
| `terminalInfo` | `PluginTerminalInfo?` | `terminal_info` | Sticky across upserts when incoming value is empty |
| `usageStats` | `UsageStats?` | `usage_stats` | Updated by `UsageTracker` |
| `lastMessage` | `String?` | `last_message` | Summary string |
| `pendingPermissionTool` | `String?` | `pending_permission_tool` | Set while a permission UI is visible |
| `pendingPermissionMessage` | `String?` | `pending_permission_message` | Human-readable context |

**Computed**: `id == sessionId`, `progress: String` (returns `"done/total"` from `tasks`).

**Producer → consumer**

- Written by: `ClaudePlugin`, `UsageTracker`, `SessionMonitor`, CLI `note` command.
- Read by: `IslandView`, `DashboardView`, `BoardDTOBuilder`, CLI `list` command, `TranscriptStatusResolver`.

**Example JSON (current schema)**

```json
{
  "schema_version": 1,
  "session_id": "3f4a1c2e-...",
  "project": "/Users/me/code/meee2",
  "pid": 52031,
  "transcript_path": "/Users/me/.claude/projects/...jsonl",
  "started_at": "2026-04-22T15:20:13Z",
  "last_activity": "2026-04-22T15:44:02Z",
  "status": "tooling",
  "current_tool": "Bash",
  "tasks": [
    { "id": "t1", "name": "Run tests", "status": "done" },
    { "id": "t2", "name": "Write docs", "status": "in_progress" }
  ],
  "terminal_info": {
    "tty": "/dev/ttys012",
    "termProgram": "ghostty",
    "ghosttyTerminalId": "terminal-7"
  },
  "usage_stats": {
    "turns": 12, "inputTokens": 40321, "outputTokens": 5412,
    "cacheCreateTokens": 0, "cacheReadTokens": 80000, "model": "claude-opus-4-7"
  }
}
```

---

### UnreadNotification

`Sources/Services/SessionStore.swift`

```swift
struct UnreadNotification: Codable {
    let type: String       // "permission" / "notification" / ...
    let message: String
    let timestamp: Date
}
```

Stored at `~/.meee2/unread/<sessionId>.json`; used to surface a menu bar badge after the GUI has been closed & reopened.

---

## meee2-plugin-kit

Public SDK linked by the app and all plugins. Keep backwards-compatible when possible — if you rename or remove a public symbol, a third-party plugin may already depend on it. See the ABI notes in [ARCHITECTURE.md §13](ARCHITECTURE.md#13-invariants--rules-of-the-house).

### SessionPlugin (base class)

**File** `meee2-plugin-kit/Sources/Meee2PluginKit/SessionPlugin.swift`

```swift
open class SessionPlugin: NSObject, ObservableObject {
    // Identity (override these)
    open var pluginId: String { "" }       // reverse-DNS, e.g. com.meee2.plugin.cursor
    open var displayName: String { "" }
    open var icon: String { "" }           // SF Symbol
    open var themeColor: Color { .blue }
    open var version: String { "1.0.0" }
    open var helpUrl: String? { nil }

    // Error surface
    @Published open var hasError: Bool
    @Published open var lastError: String?

    // Config
    open var config: PluginConfig          // enabled + customSettings

    // Callbacks (set by PluginManager; plugin should call these)
    open var onSessionsUpdated: (([PluginSession]) -> Void)?
    open var onUrgentEvent: ((PluginSession, String, String?) -> Void)?

    // Lifecycle (override)
    open func initialize() -> Bool         // load config
    open func start() -> Bool              // begin monitoring
    open func stop()
    open func cleanup()

    // Session management (override)
    open func getSessions() -> [PluginSession]
    open func refresh()

    // Terminal / urgent (override as needed)
    open func activateTerminal(for session: PluginSession)
    open func clearUrgentEvent(sessionId: String)
}

struct PluginConfig {
    var enabled: Bool = true
    var customSettings: [String: Any] = [:]
}
```

Plugins are loaded as dylibs — see [PLUGIN_DEVELOPMENT.md](PLUGIN_DEVELOPMENT.md) for the `@_cdecl("createPlugin")` factory signature and the `plugin.json` metadata contract.

---

### SessionStatus

**File** `meee2-plugin-kit/Sources/Meee2PluginKit/SessionStatus.swift`

The **single** status enum. Every surface (Island, TUI, CLI, Board) must render via these cases.

| Case | Semantics | Icon (SF / terminal) | Color | Animation |
|---|---|---|---|---|
| `.idle` | Session exists, no active work | `ellipsis.circle` / `○` | gray | none |
| `.thinking` | Model is generating | `brain.head.profile` / 🧠 | blue | pulse |
| `.tooling` | A tool is executing | `wrench.and.screwdriver.fill` / 🔧 | blue | pulse |
| `.active` | Generic "doing something" | `play.circle.fill` / ▶ | blue | pulse |
| `.waitingForUser` | Waiting on a human reply (not a permission) | `hand.raised.fill` / ✋ | orange | bounce |
| `.permissionRequired` | Blocked on a tool permission | `lock.shield.fill` / 🔒 | orange | bounce |
| `.compacting` | Compacting the conversation | `rectangle.compress.vertical` / 📦 | blue | pulse |
| `.completed` | Done, no longer active | `checkmark.circle.fill` / ✅ | gray | none |
| `.dead` | Process gone / crashed | `xmark.circle.fill` / ❌ | red | none |

Additional helpers: `displayName`, `shortDescription`, `description`, `needsUserAction`, `needsBreathing`, `showsRightIcon` / `rightIcon`, `sfSymbolName`.

**Legacy decoding**: `SessionStatus.from(rawString:)` maps old case names (`running`, `waitingInput`, `permissionRequest`, `failed`, `waiting`, `unknown`, snake_case variants) to the current enum. Decoders on disk use this, so renaming a case requires adding the old name to `legacyMap`.

`enum StatusAnimation { case none, pulse, rotate, bounce }` is the animation hint used by views.

---

### PluginSession

**File** `meee2-plugin-kit/Sources/Meee2PluginKit/PluginSession.swift`

UI-facing session model passed from plugins to the app. Built either directly by a plugin's `getSessions()` or by `SessionData.toPluginSession()`.

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | Convention: `"<pluginId>-<sessionId>"` (or just session UUID for `ClaudePlugin`) |
| `pluginId` | `String` | Must match the owning `SessionPlugin.pluginId` |
| `title` | `String` | Usually project name |
| `status` | `SessionStatus` | Already-resolved (not raw hook status) |
| `startedAt` | `Date` | |
| `subtitle` | `String?` | Usually `currentTask` |
| `lastUpdated` | `Date?` | |
| `progress` | `Int?` | 0-100 |
| `errorMessage` | `String?` | |
| `toolName` | `String?` | |
| `cwd` | `String?` | |
| `terminalInfo` | `PluginTerminalInfo?` | For `TerminalJumper` |
| `icon` | `String?` | Override plugin's default icon |
| `accentColor` | `Color?` | Override plugin's theme color |
| `urgentEvent` | `UrgentEventInfo?` | Drives the urgent panel |
| `tasks` | `[SessionTask]?` | Renders the task checklist |
| `usageStats` | `UsageStats?` | Token/cost summary |
| `lastMessage` | `String?` | Short summary |

Computed: `progressText` (`"2/5"` from tasks), `projectName`, `formattedDuration`.

Equality & hashing include `urgentEvent.id` so SwiftUI diffs when a new permission request arrives.

---

### PluginTerminalInfo

```swift
struct PluginTerminalInfo: Hashable, Codable {
    var tty: String?
    var termProgram: String?
    var termBundleId: String?
    var cmuxSocketPath: String?
    var cmuxSurfaceId: String?
    var jumpHandlerId: String?     // plugin-registered custom jumper
}
```

Consumed by `TerminalJumper`; see [ARCHITECTURE.md §11](ARCHITECTURE.md#11-terminal-jumping) for the jump strategy order.

---

### UrgentEventInfo / PermissionDecision

```swift
enum PermissionDecision {
    case allow
    case deny(reason: String?)
}

struct UrgentEventInfo: Identifiable {
    let id: String
    let eventType: String         // "permission" | "notification" | "waitingInput"
    let message: String
    let actionLabel: String?      // e.g. "Approve"
    var respond: ((PermissionDecision) -> Void)?
}
```

The urgent panel in `IslandView` wires its Allow/Deny buttons to `respond(.allow)` / `respond(.deny(reason: ...))`. `ClaudePlugin` uses that callback to invoke `HookSocketServer.respondToPermission(...)`, which writes the decision back to the pending client socket.

`eventType` is a string (not an enum) so plugins can define their own urgent types; the Island renders any unknown type as a generic alert.

---

### SessionTask / TaskStatus

```swift
struct SessionTask: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var status: TaskStatus

    enum TaskStatus: String, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case completed
    }
}
```

`.done` vs `.completed` is intentional: `done` means "you marked it finished within the session", `completed` is reserved for CSM-imported legacy tasks. `BoardDTOBuilder` writes both through `t.status.rawValue` and the web treats them equivalently. Use `TaskStatus.from(csmString:)` when converting from external formats.

---

### UsageStats

```swift
struct UsageStats: Codable, Hashable {
    var turns: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreateTokens: Int = 0
    var cacheReadTokens: Int = 0
    var model: String = ""
}
```

Computed: `totalTokens`, `costUSD` (model-aware — check the file for pricing table), `formattedCost`, `formattedTokens`, `formattedInOut`. Supports `+` for merging.

Produced by `UsageTracker` (reads the transcript), consumed by `BoardDTOBuilder.sessionDTO` and `IslandView`.

---

## Sources/Board

HTTP DTOs — the stable wire format for the Web Board frontend (React, in `web/`). All DTOs are `Encodable` only; the server does not accept JSON bodies for most routes (CLI is the write path).

All dates are ISO 8601 with fractional seconds (`BoardDTOBuilder.iso`).

### StateDTO

`GET /api/state` payload.

```json
{
  "sessions": [SessionDTO, ...],
  "channels": [ChannelDTO, ...]
}
```

### SessionDTO

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | Session UUID |
| `title` | `String` | Session title |
| `project` | `String` | `cwd` or `title` fallback |
| `pluginId` | `String` | |
| `pluginDisplayName` | `String` | From `PluginManager.getPluginInfo(for:)`; falls back to `pluginId` |
| `pluginColor` | `String` | `#RRGGBB`; defaults to `"#808080"` |
| `status` | `String` | `SessionStatus.rawValue` after `TranscriptStatusResolver.resolve(for:)` |
| `inboxPending` | `Int` | `pending + held` messages addressed to this session's aliases |
| `recentMessages` | `[TranscriptEntryDTO]` | Up to 5 entries, oldest → newest. `text` truncated to ~1000 chars |
| `currentTool` | `String?` | May be overridden by `TranscriptStatusResolver.resolveCurrentTool` to `"thinking"` or `null` |
| `costUSD` | `Double?` | `usageStats.costUSD` |
| `startedAt`, `lastActivity` | `String?` | ISO 8601 |
| `usageStats` | `UsageStatsDTO?` | |
| `tasks` | `[TaskDTO]` | Empty array when none |
| `currentTask` | `String?` | |
| `pendingPermissionTool` | `String?` | |
| `pendingPermissionMessage` | `String?` | |
| `ghosttyTerminalId` | `String?` | Diagnostic only |
| `tty` | `String?` | Diagnostic only |
| `termProgram` | `String?` | Diagnostic only |

### UsageStatsDTO / TaskDTO / TranscriptEntryDTO

```swift
struct UsageStatsDTO {
    inputTokens, outputTokens, cacheCreateTokens, cacheReadTokens, turns: Int
    model: String        // empty string when unknown
    costUSD: Double
}

struct TaskDTO {
    id, name: String
    status: String       // TaskStatus.rawValue: "pending" | "in_progress" | "done" | "completed"
}

struct TranscriptEntryDTO {
    role: String         // "user" | "assistant" | "tool" | other
    text: String         // backend-truncated to ~1000 chars
}
```

### ChannelDTO / MemberDTO

```swift
struct ChannelDTO {
    name: String
    mode: String         // ChannelMode.rawValue: "auto" | "intercept" | "paused"
    members: [MemberDTO]
    pendingCount: Int    // pending + held across this channel
    description: String?
    createdAt: String    // ISO 8601
}

struct MemberDTO {
    alias, sessionId: String
}
```

### MessageDTO

```swift
struct MessageDTO {
    id: String
    channel: String
    fromAlias, toAlias: String
    content: String
    replyTo: String?
    status: String         // MessageStatus.rawValue
    createdAt: String
    deliveredAt: String?
    deliveredTo: [String]
    injectedByHuman: Bool
}
```

### ErrorDTO + envelopes

4xx/5xx responses:

```json
{ "error": { "code": "not_found", "message": "no such channel" } }
```

Single-item success envelopes (so the shape is consistent regardless of list vs. item endpoints):

```swift
struct ChannelEnvelope  { channel: ChannelDTO }
struct MessageEnvelope  { message: MessageDTO }
struct MessagesEnvelope { messages: [MessageDTO] }
struct OkEnvelope       { ok: Bool }
struct CardTemplateEnvelope  { template: CardTemplateStore.Entry }
struct CardTemplatesEnvelope { templates: [CardTemplateStore.Entry] }
```

---

## Changing a Schema

If you're adding or renaming a field:

- **Board DTO** — additive changes are fine; the React client ignores unknown fields. For breaking renames, coordinate with `web/src/types.ts` in the same PR.
- **`SessionData`** — additive is fine. Removing or renaming a field is a schema change: bump `SessionData.currentSchemaVersion`, add a migrator, add a regression test with a frozen legacy fixture.
- **`SessionStatus`** — if you rename a case, add the old name to `SessionStatus.legacyMap` so on-disk files and third-party plugins keep decoding.
- **`meee2-plugin-kit` public types** — treat like a public API. Bump the plugin SDK version in `Package.swift` and call it out in the PR description so plugin authors know.
- **Hook JSON** — shared with `Bridge/claude-hook-bridge.sh` and any other hook producers. Coordinate changes in the bridge script at the same time.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the PR checklist that covers these cases.
