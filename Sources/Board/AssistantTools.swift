import Foundation
import Meee2CommKit
import Meee2PluginKit

/// Catalog of "tools" the global assistant can call against meee2 state.
/// One handler per tool, exposed to LLMs via the OpenAI / Anthropic
/// function-calling format and to local `claude -p` via the same dispatcher
/// (no MCP detour — the local provider routes tool requests through here
/// directly so all three providers share one code path).
///
/// The list is intentionally small + read-leaning. Anything that mutates
/// state (currently just `create_session`) is its own deliberate action;
/// callers can disable any tool per-request via `enabledTools`.
///
/// All handlers are synchronous (cheap reads) except `create_session`,
/// which kicks off a Ghostty spawn that finishes async; we still return a
/// synchronous OK so the LLM can move on while the new session shows up
/// in the next `/api/state` tick.
enum AssistantTools {

    // MARK: - Catalog

    static let all: [ToolDef] = [
        getSessionListDef(),
        getSessionInfoDef(),
        getSessionTranscriptDef(),
        listChannelsDef(),
        getChannelMessagesDef(),
        createSessionDef()
    ]

    static let allNames: Set<String> = Set(all.map { $0.name })

    static func filter(_ enabled: Set<String>?) -> [ToolDef] {
        guard let enabled = enabled else { return all }
        return all.filter { enabled.contains($0.name) }
    }

    // MARK: - Dispatch

    enum DispatchResult {
        /// Tool ran; payload is a JSON-encodable value to feed back into the
        /// LLM as a `tool_result`.
        case success(Any)
        /// Tool errored cleanly; LLM should be told and may recover.
        case failure(String)
    }

    static func dispatch(name: String, args: [String: Any], enabled: Set<String>?) -> DispatchResult {
        if let enabled = enabled, !enabled.contains(name) {
            return .failure("tool '\(name)' is disabled in user settings")
        }
        switch name {
        case "get_session_list":
            return runGetSessionList(args: args)
        case "get_session_info":
            return runGetSessionInfo(args: args)
        case "get_session_transcript":
            return runGetSessionTranscript(args: args)
        case "list_channels":
            return runListChannels(args: args)
        case "get_channel_messages":
            return runGetChannelMessages(args: args)
        case "create_session":
            return runCreateSession(args: args)
        default:
            return .failure("unknown tool: \(name)")
        }
    }

    // MARK: - get_session_list

    private static func getSessionListDef() -> ToolDef {
        ToolDef(
            name: "get_session_list",
            description:
                "List all live Claude / Codex / etc. sessions visible on the board. " +
                "Returns id, title, project, plugin, status, lastActivity. " +
                "Optional filters narrow the result.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "status": [
                        "type": "string",
                        "description": "Filter by session status (e.g. 'idle', 'thinking', 'tooling')."
                    ],
                    "plugin": [
                        "type": "string",
                        "description": "Filter by plugin id (e.g. 'com.meee2.plugin.claude')."
                    ],
                    "project": [
                        "type": "string",
                        "description": "Substring-match against the session's project (cwd basename)."
                    ]
                ]
            ]
        )
    }

    private static func runGetSessionList(args: [String: Any]) -> DispatchResult {
        let statusFilter = (args["status"] as? String)?.lowercased()
        let pluginFilter = args["plugin"] as? String
        let projectFilter = args["project"] as? String

        var rows: [[String: Any]] = []
        for s in PluginManager.shared.sessions where s.status != .dead {
            if let pf = pluginFilter, s.pluginId != pf { continue }
            if let sf = statusFilter, statusName(s.status).lowercased() != sf { continue }
            if let proj = projectFilter,
               !(s.cwd ?? "").lowercased().contains(proj.lowercased()) {
                continue
            }
            rows.append([
                "id": s.id,
                "title": s.title,
                "project": s.cwd ?? "",
                "plugin": s.pluginId,
                "pluginDisplayName": PluginManager.shared.getPluginInfo(for: s.pluginId)?.displayName ?? s.pluginId,
                "status": statusName(s.status),
                "lastActivity": s.lastUpdated.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ])
        }
        return .success(["sessions": rows, "total": rows.count])
    }

    // MARK: - get_session_info

    private static func getSessionInfoDef() -> ToolDef {
        ToolDef(
            name: "get_session_info",
            description:
                "Fetch a session's full state: title, project, plugin, status, model, " +
                "and the last N transcript entries (default 10). Use this after " +
                "`get_session_list` finds a candidate id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sessionId": [
                        "type": "string",
                        "description": "Session id (full or unique prefix)."
                    ],
                    "transcriptLimit": [
                        "type": "number",
                        "description": "How many recent transcript entries to include. Default 10, max 50."
                    ]
                ],
                "required": ["sessionId"]
            ]
        )
    }

    private static func runGetSessionInfo(args: [String: Any]) -> DispatchResult {
        guard let sidArg = args["sessionId"] as? String, !sidArg.isEmpty else {
            return .failure("missing 'sessionId'")
        }
        let limit = min(50, max(1, (args["transcriptLimit"] as? Int) ?? 10))

        // Resolve full sid via PluginManager (host id or raw id, with prefix
        // tolerance the BoardAPI helpers already implement).
        let session = PluginManager.shared.sessions.first { s in
            s.id == sidArg || s.id.hasSuffix("-\(sidArg)") || s.id.hasPrefix(sidArg)
        }
        guard let s = session else {
            return .failure("session not found: \(sidArg)")
        }

        // Recent transcript entries: re-use TranscriptParser if we have a
        // path; otherwise return an empty array — the rest of the metadata
        // is still useful.
        let realSid: String = {
            let prefix = "\(s.pluginId)-"
            return s.id.hasPrefix(prefix) ? String(s.id.dropFirst(prefix.count)) : s.id
        }()
        var entries: [[String: Any]] = []
        if let path = SessionStore.shared.get(realSid)?.transcriptPath {
            let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: limit)
            for m in msgs {
                entries.append([
                    "role": m.role,
                    "text": m.text
                ])
            }
        }

        return .success([
            "id": s.id,
            "title": s.title,
            "project": s.cwd ?? "",
            "plugin": s.pluginId,
            "pluginDisplayName": PluginManager.shared.getPluginInfo(for: s.pluginId)?.displayName ?? s.pluginId,
            "status": statusName(s.status),
            "model": s.usageStats?.model ?? "",
            "transcript": entries
        ])
    }

    // MARK: - Caps shared by content tools
    //
    // 16KB matches what TranscriptStatusResolver reads off-disk for tail
    // analysis; resolver itself uses 4KB but the whole rationale is "small
    // enough that LLM context stays manageable, big enough to be useful for a
    // human-readable summary." Caller can request more entries but we always
    // stop early once we cross the byte budget.
    private static let _contentEntryHardLimit = 200
    private static let _contentBytesHardLimit = 16 * 1024
    private static let _contentTextPreviewBytes = 1_000

    // MARK: - get_session_transcript

    private static func getSessionTranscriptDef() -> ToolDef {
        ToolDef(
            name: "get_session_transcript",
            description:
                "Read the recent transcript of a session for content-level questions " +
                "(\"summarise what this session is doing\", \"what did the user ask?\"). " +
                "Returns role + text + tool name per entry; raw tool input/output is " +
                "summarised to a short preview, never returned in full.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sessionId": [
                        "type": "string",
                        "description": "Session id (full or unique prefix)."
                    ],
                    "limit": [
                        "type": "number",
                        "description": "How many recent entries to read. Default 50, hard cap 200 (and ~16KB total)."
                    ],
                    "sinceTs": [
                        "type": "string",
                        "description": "Optional ISO8601 timestamp; only entries strictly newer than this are returned."
                    ]
                ],
                "required": ["sessionId"]
            ]
        )
    }

    private static func runGetSessionTranscript(args: [String: Any]) -> DispatchResult {
        guard let sidArg = args["sessionId"] as? String, !sidArg.isEmpty else {
            return .failure("missing 'sessionId'")
        }
        let limit = clampLimit(args["limit"], default: 50, hardCap: _contentEntryHardLimit)
        let sinceDate = (args["sinceTs"] as? String).flatMap(Self.parseISO8601)

        let session = PluginManager.shared.sessions.first { s in
            s.id == sidArg || s.id.hasSuffix("-\(sidArg)") || s.id.hasPrefix(sidArg)
        }
        guard let s = session else {
            return .failure("session not found: \(sidArg)")
        }

        let path = resolveTranscriptPath(for: s)
        guard let p = path else {
            return .success([
                "sessionId": s.id,
                "entries": [] as [Any],
                "total": 0,
                "truncated": false,
                "note": "session has no transcript path yet"
            ])
        }

        // FullTranscriptReader is canonical for assistant-facing content (it
        // dedupes last-prompt, drops local-command echo, and labels injected
        // user messages). Anything content-level should go through it.
        let raw = FullTranscriptReader.readTail(transcriptPath: p, limit: limit)
        var entries: [[String: Any]] = []
        var bytes = 0
        var truncated = false
        for entry in raw {
            if let since = sinceDate, let ts = entry.timestamp.flatMap(Self.parseISO8601) {
                if ts <= since { continue }
            }
            let row = redactedTranscriptEntry(entry)
            // Rough byte estimate via JSON serialization — hard cap keeps
            // pathological transcripts from blowing the LLM's context.
            if let data = try? JSONSerialization.data(withJSONObject: row) {
                if bytes + data.count > _contentBytesHardLimit && !entries.isEmpty {
                    truncated = true
                    break
                }
                bytes += data.count
            }
            entries.append(row)
            if entries.count >= limit { break }
        }

        return .success([
            "sessionId": s.id,
            "entries": entries,
            "total": entries.count,
            "truncated": truncated
        ])
    }

    /// Strip raw tool input / full tool output before exposing to assistant.
    /// Assistant only needs to know "Bash was called" or "Read on /etc/hosts",
    /// not the full bytes — those are leaked content the user might not
    /// expect a global assistant to see.
    private static func redactedTranscriptEntry(_ entry: FullTranscriptEntry) -> [String: Any] {
        var blocks: [[String: Any]] = []
        for b in entry.blocks {
            switch b.type {
            case "text", "thinking":
                blocks.append([
                    "type": b.type,
                    "text": truncate(b.text ?? "", to: _contentTextPreviewBytes)
                ])
            case "tool_use":
                var row: [String: Any] = [
                    "type": "tool_use",
                    "toolName": b.toolName ?? ""
                ]
                if let inputJSON = b.toolInputJSON {
                    row["inputPreview"] = truncate(inputJSON, to: 200)
                }
                blocks.append(row)
            case "tool_result":
                blocks.append([
                    "type": "tool_result",
                    "outputPreview": truncate(b.toolResultText ?? "", to: 200),
                    "outputTruncated": b.toolResultTruncated ?? false
                ])
            default:
                blocks.append(["type": b.type])
            }
        }
        return [
            "id": entry.id,
            "role": entry.type,
            "timestamp": entry.timestamp ?? "",
            "blocks": blocks
        ]
    }

    private static func resolveTranscriptPath(for s: PluginSession) -> String? {
        // Prefer SessionStore (Claude path — it gets fresher updates from the
        // hook bridge); fall back to whatever the plugin self-reported.
        let realSid: String = {
            let prefix = "\(s.pluginId)-"
            return s.id.hasPrefix(prefix) ? String(s.id.dropFirst(prefix.count)) : s.id
        }()
        if let path = SessionStore.shared.get(realSid)?.transcriptPath, !path.isEmpty {
            return path
        }
        return s.transcriptPath
    }

    // MARK: - list_channels

    private static func listChannelsDef() -> ToolDef {
        ToolDef(
            name: "list_channels",
            description:
                "List all A2A channels visible on this machine. Returns name, " +
                "displayName, mode, member count, and pending-message count per channel. " +
                "Use before `get_channel_messages` to find the right channel id.",
            inputSchema: [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        )
    }

    private static func runListChannels(args _: [String: Any]) -> DispatchResult {
        var rows: [[String: Any]] = []
        for ch in ChannelRegistry.shared.list() {
            let pendingCount = MessageRouter.shared
                .listMessages(channel: ch.name, statuses: [.pending, .held])
                .count
            rows.append([
                "name": ch.name,
                "displayName": ch.effectiveDisplayName,
                "mode": ch.mode.rawValue,
                "memberCount": ch.members.count,
                "members": ch.members.map { ["alias": $0.alias, "sessionId": $0.sessionId] },
                "pendingCount": pendingCount,
                "createdAt": ISO8601DateFormatter().string(from: ch.createdAt)
            ])
        }
        return .success(["channels": rows, "total": rows.count])
    }

    // MARK: - get_channel_messages

    private static func getChannelMessagesDef() -> ToolDef {
        ToolDef(
            name: "get_channel_messages",
            description:
                "Read recent messages on an A2A channel for content-level questions " +
                "(\"summarise today's ops channel\"). Returns id, fromAlias, toAlias, status, " +
                "createdAt, and a truncated content preview. Newest entries last.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "channelId": [
                        "type": "string",
                        "description": "Channel name (the canonical id, not displayName). Use list_channels to discover."
                    ],
                    "limit": [
                        "type": "number",
                        "description": "How many recent messages to return. Default 30, hard cap 200 (and ~16KB total)."
                    ],
                    "sinceTs": [
                        "type": "string",
                        "description": "Optional ISO8601 timestamp; only messages strictly newer than this are returned."
                    ]
                ],
                "required": ["channelId"]
            ]
        )
    }

    private static func runGetChannelMessages(args: [String: Any]) -> DispatchResult {
        guard let cid = args["channelId"] as? String, !cid.isEmpty else {
            return .failure("missing 'channelId'")
        }
        guard ChannelRegistry.shared.get(cid) != nil else {
            return .failure("channel not found: \(cid)")
        }
        let limit = clampLimit(args["limit"], default: 30, hardCap: _contentEntryHardLimit)
        let sinceDate = (args["sinceTs"] as? String).flatMap(Self.parseISO8601)

        // listMessages returns ascending; we want recent-N, so take the suffix
        // *after* sinceTs filtering.
        var all = MessageRouter.shared.listMessages(channel: cid, statuses: nil)
        if let since = sinceDate {
            all = all.filter { $0.createdAt > since }
        }
        let tail = Array(all.suffix(limit))

        let iso = ISO8601DateFormatter()
        var rows: [[String: Any]] = []
        var bytes = 0
        var truncated = false
        for m in tail {
            let row: [String: Any] = [
                "id": m.id,
                "channel": m.channel,
                "fromAlias": m.fromAlias,
                "toAlias": m.toAlias,
                "status": m.status.rawValue,
                "createdAt": iso.string(from: m.createdAt),
                "deliveredAt": m.deliveredAt.map { iso.string(from: $0) } ?? "",
                "injectedByHuman": m.injectedByHuman,
                "content": truncate(m.content, to: _contentTextPreviewBytes),
                "contentTruncated": m.content.utf8.count > _contentTextPreviewBytes
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row) {
                if bytes + data.count > _contentBytesHardLimit && !rows.isEmpty {
                    truncated = true
                    break
                }
                bytes += data.count
            }
            rows.append(row)
        }

        return .success([
            "channelId": cid,
            "messages": rows,
            "total": rows.count,
            "truncated": truncated
        ])
    }

    // MARK: - Shared helpers for content tools

    private static func clampLimit(_ raw: Any?, default def: Int, hardCap: Int) -> Int {
        let n: Int
        if let i = raw as? Int { n = i } else if let d = raw as? Double { n = Int(d) } else { n = def }
        return min(hardCap, max(1, n))
    }

    /// Truncate a string to at most `bytes` UTF-8 bytes, appending `…` when
    /// cut. Operates on Character boundaries so we never split a grapheme.
    private static func truncate(_ s: String, to bytes: Int) -> String {
        if s.utf8.count <= bytes { return s }
        var out = ""
        var taken = 0
        for ch in s {
            let chBytes = String(ch).utf8.count
            if taken + chBytes > bytes { break }
            out.append(ch)
            taken += chBytes
        }
        return out + "…"
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - create_session

    private static func createSessionDef() -> ToolDef {
        ToolDef(
            name: "create_session",
            description:
                "Spawn a new local session in a Ghostty terminal at the given cwd. " +
                "Reuses the user's local CLI auth (no API key needed). " +
                "Set createIfMissing=true to mkdir -p the cwd if absent.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "cwd": [
                        "type": "string",
                        "description": "Absolute path. `~` is expanded server-side."
                    ],
                    "command": [
                        "type": "string",
                        "description": "Command to run in the new terminal. Default 'claude'."
                    ],
                    "createIfMissing": [
                        "type": "boolean",
                        "description": "If true, mkdir -p the cwd when missing. Default false."
                    ]
                ],
                "required": ["cwd"]
            ]
        )
    }

    private static func runCreateSession(args: [String: Any]) -> DispatchResult {
        guard var cwd = args["cwd"] as? String, !cwd.isEmpty else {
            return .failure("missing 'cwd'")
        }
        if cwd.hasPrefix("~") {
            cwd = NSHomeDirectory() + String(cwd.dropFirst(1))
        }
        cwd = (cwd as NSString).standardizingPath

        let createIfMissing = (args["createIfMissing"] as? Bool) ?? false
        let command = (args["command"] as? String) ?? "claude"
        let termProgram = args["termProgram"] as? String

        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            if createIfMissing {
                do {
                    try FileManager.default.createDirectory(
                        atPath: cwd,
                        withIntermediateDirectories: true
                    )
                } catch {
                    return .failure("mkdir failed: \(error.localizedDescription)")
                }
            } else {
                return .failure("cwd does not exist: \(cwd) (pass createIfMissing=true to mkdir)")
            }
        }

        // Fire-and-forget — same pattern as BoardAPI.spawnSession's async
        // path. The new claude process will register itself via SessionStart
        // hook within a few seconds and show up on the board.
        let spawner = SpawnerRouter.forTerminal(termProgram)
        // Swift 6 strict concurrency 不允许 @Sendable closure 捕获 var；
        // snapshot 到 let 再喂给 Task。
        let cwdFinal = cwd
        let commandFinal = command
        Task {
            _ = await spawner.spawn(cwd: cwdFinal, command: commandFinal)
        }

        return .success([
            "ok": true,
            "cwd": cwd,
            "command": command,
            "note": "Spawn dispatched. Session will appear in get_session_list within a few seconds."
        ])
    }

    // MARK: - Status helper (mirrors BoardDTO mapping but flat enough for tools)

    private static func statusName(_ s: SessionStatus) -> String {
        switch s {
        case .active: return "active"
        case .thinking: return "thinking"
        case .tooling: return "tooling"
        case .idle: return "idle"
        case .waitingForUser: return "waitingForUser"
        case .permissionRequired: return "permissionRequired"
        case .completed: return "completed"
        case .compacting: return "compacting"
        case .dead: return "dead"
        }
    }
}

/// Tool definition shared across providers.
struct ToolDef {
    let name: String
    let description: String
    /// JSON Schema fragment (`type: object`, `properties: {…}`, `required: […]`).
    /// Stored as `[String: Any]` so we can serialize directly to whatever
    /// shape the upstream provider expects (OpenAI's `parameters`,
    /// Anthropic's `input_schema`, or our local-claude bridge).
    let inputSchema: [String: Any]
}
