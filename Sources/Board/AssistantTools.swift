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
        getCanvasContextDef(),
        getSessionListDef(),
        getSessionInfoDef(),
        getSessionTranscriptDef(),
        listChannelsDef(),
        getChannelMessagesDef(),
        proposeCanvasPatchDef(),
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

    static func dispatch(
        name: String,
        args: [String: Any],
        enabled: Set<String>?,
        settings: AssistantSettings = AssistantAPI.parseSettings(nil)
    ) -> DispatchResult {
        if let enabled = enabled, !enabled.contains(name) {
            return .failure("tool '\(name)' is disabled in user settings")
        }
        switch name {
        case "get_canvas_context":
            return runGetCanvasContext(args: args, settings: settings)
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
        case "propose_canvas_patch":
            return runProposeCanvasPatch(args: args, settings: settings)
        case "create_session":
            return runCreateSession(args: args)
        default:
            return .failure("unknown tool: \(name)")
        }
    }

    // MARK: - get_canvas_context

    private struct CanvasToolContext {
        let canvas: BoardLayoutStore.Canvas
        let layout: BoardLayoutStore.Layout
        let snapshot: BoardLayoutStore.Snapshot
        let workspacePath: String
    }

    private static func getCanvasContextDef() -> ToolDef {
        ToolDef(
            name: "get_canvas_context",
            description:
                "Read the current canvas context: visible sessions, channel frames, " +
                "layout coordinates, viewport, and simple user note summaries. " +
                "Use this before proposing canvas changes.",
            inputSchema: [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        )
    }

    private static func runGetCanvasContext(args _: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let context = try loadCanvasToolContext(settings: settings)
            let visibleMemberships = context.snapshot.memberships.filter {
                $0.canvasId == context.canvas.id && $0.visible
            }
            let visibleSessionIds = Set(visibleMemberships.map { $0.sessionId })

            var sessions: [[String: Any]] = []
            for s in PluginManager.shared.sessions where s.status != .dead && visibleSessionIds.contains(s.id) {
                var row: [String: Any] = [
                    "id": s.id,
                    "title": s.title,
                    "project": s.cwd ?? "",
                    "plugin": s.pluginId,
                    "pluginDisplayName": PluginManager.shared.getPluginInfo(for: s.pluginId)?.displayName ?? s.pluginId,
                    "status": statusName(s.status),
                    "visible": true
                ]
                if let point = context.layout.sessions[s.id] {
                    row["x"] = point.x
                    row["y"] = point.y
                }
                sessions.append(row)
            }

            var channels: [[String: Any]] = []
            for ch in ChannelRegistry.shared.list() where !ch.name.hasPrefix("__") {
                var row: [String: Any] = [
                    "name": ch.name,
                    "displayName": ch.effectiveDisplayName,
                    "mode": ch.mode.rawValue,
                    "memberCount": ch.members.count,
                    "pendingCount": MessageRouter.shared.listMessages(channel: ch.name, statuses: [.pending, .held]).count
                ]
                if let point = context.layout.channels[ch.name] {
                    row["x"] = point.x
                    row["y"] = point.y
                }
                channels.append(row)
            }

            let viewport: Any
            if let vp = context.layout.viewport {
                viewport = [
                    "scrollX": vp.scrollX,
                    "scrollY": vp.scrollY,
                    "zoom": vp.zoom
                ]
            } else {
                viewport = NSNull()
            }

            let notes = summarizeCanvasNotes(context.layout.userElements)

            return .success([
                "canvas": [
                    "id": context.canvas.id,
                    "name": context.canvas.name,
                    "scope": context.canvas.scope.rawValue,
                    "isDefault": context.canvas.isDefault,
                    "workspacePath": context.workspacePath
                ],
                "viewport": viewport,
                "sessions": sessions,
                "channels": channels,
                "notes": notes,
                "counts": [
                    "sessions": sessions.count,
                    "channels": channels.count,
                    "notes": notes.count
                ]
            ])
        } catch {
            return .failure(error.localizedDescription)
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

    // MARK: - propose_canvas_patch

    private static func proposeCanvasPatchDef() -> ToolDef {
        ToolDef(
            name: "propose_canvas_patch",
            description:
                "Return a structured, low-risk patch proposal for the current canvas. " +
                "This does not apply anything; the UI renders an Apply card and the " +
                "user must click Apply. Only supported operations are move_session, " +
                "move_channel, show_session, hide_session, add_note, update_note.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "Short human-readable summary shown in the Apply card."
                    ],
                    "operations": [
                        "type": "array",
                        "description": "Canvas patch operations. Unknown operation types are rejected.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "type": ["type": "string"],
                                "sessionId": ["type": "string"],
                                "channelName": ["type": "string"],
                                "elementId": ["type": "string"],
                                "text": ["type": "string"],
                                "x": ["type": "number"],
                                "y": ["type": "number"]
                            ],
                            "required": ["type"]
                        ]
                    ]
                ],
                "required": ["operations"]
            ]
        )
    }

    private static func runProposeCanvasPatch(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let context = try loadCanvasToolContext(settings: settings)
            guard let rawOperations = args["operations"] as? [[String: Any]] else {
                return .failure("missing 'operations'")
            }
            guard !rawOperations.isEmpty else {
                return .failure("operations must not be empty")
            }
            guard rawOperations.count <= 50 else {
                return .failure("too many operations; max 50")
            }

            let currentCanvasSessionIds = Set(
                context.snapshot.memberships
                    .filter { $0.canvasId == context.canvas.id && $0.visible }
                    .map { $0.sessionId }
            )
            let liveChannelNames = Set(
                ChannelRegistry.shared.list()
                    .filter { !$0.name.hasPrefix("__") }
                    .map { $0.name }
            )
            let notesById = Set(
                summarizeCanvasNotes(context.layout.userElements)
                    .compactMap { $0["elementId"] as? String }
            )

            var operations: [[String: Any]] = []
            for (idx, raw) in rawOperations.enumerated() {
                let normalized = try normalizeCanvasPatchOperation(
                    raw,
                    index: idx,
                    liveSessionIds: currentCanvasSessionIds,
                    liveChannelNames: liveChannelNames,
                    noteElementIds: notesById
                )
                operations.append(normalized)
            }

            let summaryArg = stringValue(args["summary"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (summaryArg?.isEmpty == false)
                ? summaryArg!
                : "Prepared \(operations.count) canvas change\(operations.count == 1 ? "" : "s")."

            return .success([
                "type": "canvas_patch_proposal",
                "canvasId": context.canvas.id,
                "canvasName": context.canvas.name,
                "summary": summary,
                "operations": operations,
                "operationCount": operations.count,
                "requiresApply": true
            ])
        } catch {
            return .failure(error.localizedDescription)
        }
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

    // MARK: - Canvas tool helpers

    private static func loadCanvasToolContext(settings: AssistantSettings) throws -> CanvasToolContext {
        let snapshot = BoardLayoutStore.shared.snapshot()
        let requested = settings.canvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedId = requested.isEmpty ? snapshot.activeCanvasId : requested
        guard let canvas = snapshot.canvases.first(where: { $0.id == resolvedId }) else {
            throw toolError("canvas not found or not accessible: \(resolvedId)")
        }
        let layout = BoardLayoutStore.shared.load(canvasId: canvas.id)
        let workspacePath = (try? BoardLayoutStore.shared.workspacePath(canvasId: canvas.id)) ?? settings.workspacePath
        return CanvasToolContext(
            canvas: canvas,
            layout: layout,
            snapshot: snapshot,
            workspacePath: workspacePath
        )
    }

    private static func normalizeCanvasPatchOperation(
        _ raw: [String: Any],
        index: Int,
        liveSessionIds: Set<String>,
        liveChannelNames: Set<String>,
        noteElementIds: Set<String>
    ) throws -> [String: Any] {
        guard let type = stringValue(raw["type"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty else {
            throw toolError("operation \(index) missing type")
        }

        func sessionId() throws -> String {
            guard let sid = stringValue(raw["sessionId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sid.isEmpty else {
                throw toolError("operation \(index) missing sessionId")
            }
            guard liveSessionIds.contains(sid) else {
                throw toolError("operation \(index) references unknown sessionId: \(sid)")
            }
            return sid
        }

        func channelName() throws -> String {
            guard let name = stringValue(raw["channelName"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                throw toolError("operation \(index) missing channelName")
            }
            guard liveChannelNames.contains(name) else {
                throw toolError("operation \(index) references unknown channelName: \(name)")
            }
            return name
        }

        func elementId(requiredKnown: Bool) throws -> String {
            guard let id = stringValue(raw["elementId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                throw toolError("operation \(index) missing elementId")
            }
            if requiredKnown, !noteElementIds.contains(id) {
                throw toolError("operation \(index) references unknown note elementId: \(id)")
            }
            return id
        }

        func requiredCoordinate(_ key: String) throws -> Double {
            guard let n = numberValue(raw[key]) else {
                throw toolError("operation \(index) missing numeric \(key)")
            }
            return n
        }

        var out: [String: Any] = ["type": type]
        switch type {
        case "move_session":
            out["sessionId"] = try sessionId()
            out["x"] = try requiredCoordinate("x")
            out["y"] = try requiredCoordinate("y")
        case "move_channel":
            out["channelName"] = try channelName()
            out["x"] = try requiredCoordinate("x")
            out["y"] = try requiredCoordinate("y")
        case "show_session":
            out["sessionId"] = try sessionId()
            if let x = numberValue(raw["x"]) { out["x"] = x }
            if let y = numberValue(raw["y"]) { out["y"] = y }
        case "hide_session":
            out["sessionId"] = try sessionId()
        case "add_note":
            guard let text = stringValue(raw["text"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw toolError("operation \(index) missing text")
            }
            out["text"] = text
            out["x"] = try requiredCoordinate("x")
            out["y"] = try requiredCoordinate("y")
        case "update_note":
            out["elementId"] = try elementId(requiredKnown: !noteElementIds.isEmpty)
            var hasChange = false
            if let text = stringValue(raw["text"]) {
                out["text"] = text
                hasChange = true
            }
            if let x = numberValue(raw["x"]) {
                out["x"] = x
                hasChange = true
            }
            if let y = numberValue(raw["y"]) {
                out["y"] = y
                hasChange = true
            }
            guard hasChange else {
                throw toolError("operation \(index) update_note has no changes")
            }
        default:
            throw toolError("operation \(index) has unsupported type: \(type)")
        }
        return out
    }

    private static func summarizeCanvasNotes(_ elements: [BoardJSONValue]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for value in elements {
            guard out.count < 50,
                  let obj = anyValue(from: value) as? [String: Any],
                  stringValue(obj["type"]) == "text",
                  (obj["isDeleted"] as? Bool) != true else {
                continue
            }
            let text = stringValue(obj["text"]) ?? stringValue(obj["originalText"]) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            var row: [String: Any] = [
                "elementId": stringValue(obj["id"]) ?? "",
                "text": truncate(text, to: 500)
            ]
            if let x = numberValue(obj["x"]) { row["x"] = x }
            if let y = numberValue(obj["y"]) { row["y"] = y }
            out.append(row)
        }
        return out
    }

    private static func anyValue(from value: BoardJSONValue) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func stringValue(_ raw: Any?) -> String? {
        raw as? String
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        let value: Double?
        if let n = raw as? NSNumber {
            value = n.doubleValue
        } else if let d = raw as? Double {
            value = d
        } else if let i = raw as? Int {
            value = Double(i)
        } else {
            value = nil
        }
        guard let n = value, n.isFinite else { return nil }
        return n
    }

    private static func toolError(_ message: String) -> NSError {
        NSError(domain: "AssistantTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
