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
        readGraphStateDef(),
        proposeGraphChangeDef(),
        bindSessionToNodeDef(),
        dispatchNodeSessionDef(),
        attachArtifactToNodeDef(),
        createSubCanvasFromNodeDef(),
        updateNodeLayoutDef(),
        proposeCanvasPatchDef(),
        createSessionDef(),
        createCoordinatorSessionDef(),
        getCoordinationStateDef(),
        sendToSessionDef(),
        broadcastToMembersDef(),
        updateGroupDigestDef(),
        pauseCoordinationDef(),
        resumeCoordinationDef(),
        askCoordinatorDef()
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
        case "read_graph_state":
            return runReadGraphState(args: args, settings: settings)
        case "propose_graph_change":
            return runProposeGraphChange(args: args, settings: settings)
        case "bind_session_to_node":
            return runBindSessionToNode(args: args, settings: settings)
        case "dispatch_node_session":
            return runDispatchNodeSession(args: args, settings: settings)
        case "attach_artifact_to_node":
            return runAttachArtifactToNode(args: args, settings: settings)
        case "create_sub_canvas_from_node":
            return runCreateSubCanvasFromNode(args: args, settings: settings)
        case "update_node_layout":
            return runUpdateNodeLayout(args: args, settings: settings)
        case "propose_canvas_patch":
            return runProposeCanvasPatch(args: args, settings: settings)
        case "create_session":
            return runCreateSession(args: args, settings: settings)
        case "create_coordinator_session":
            return runCreateCoordinatorSession(args: args, settings: settings)
        case "get_coordination_state":
            return runGetCoordinationState(args: args)
        case "send_to_session":
            return runSendToSession(args: args)
        case "broadcast_to_members":
            return runBroadcastToMembers(args: args)
        case "update_group_digest":
            return runUpdateGroupDigest(args: args)
        case "pause_coordination":
            return runPauseCoordination(args: args, paused: true)
        case "resume_coordination":
            return runPauseCoordination(args: args, paused: false)
        case "ask_coordinator":
            return runAskCoordinator(args: args)
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

    // MARK: - Planner graph tools

    private static func readGraphStateDef() -> ToolDef {
        ToolDef(
            name: "read_graph_state",
            description: "Read the current meee2 AI graph: nodes, edges, layout, proposals, artifacts, and events.",
            inputSchema: ["type": "object", "properties": ["canvasId": ["type": "string"]]]
        )
    }

    private static func runReadGraphState(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(state))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func proposeGraphChangeDef() -> ToolDef {
        ToolDef(
            name: "propose_graph_change",
            description: "Create a pending meee2 AI graph proposal. This never applies topology changes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "canvasId": ["type": "string"],
                    "summary": ["type": "string"],
                    "changes": ["type": "array", "items": ["type": "object"]]
                ],
                "required": ["changes"]
            ]
        )
    }

    private static func runProposeGraphChange(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let changes = try decodePlanChanges(args["changes"])
            let proposal = try PlannerBoardBridge.graphChangeProposal(
                summary: stringValue(args["summary"]) ?? "Update meee2 AI graph",
                changes: changes,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(["proposal": proposal]))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func bindSessionToNodeDef() -> ToolDef {
        ToolDef(
            name: "bind_session_to_node",
            description: "Bind an existing session to a graph node. Execution-layer action — applies directly, no proposal.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "canvasId": ["type": "string"],
                    "nodeId": ["type": "string"],
                    "sessionId": ["type": "string"]
                ],
                "required": ["nodeId", "sessionId"]
            ]
        )
    }

    private static func runBindSessionToNode(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let nodeId = try requiredPlannerString(args["nodeId"], name: "nodeId")
            let sessionId = try requiredPlannerString(args["sessionId"], name: "sessionId")
            let state = try PlannerBoardBridge.bindSession(
                nodeId: nodeId,
                sessionId: sessionId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(state))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func dispatchNodeSessionDef() -> ToolDef {
        ToolDef(
            name: "dispatch_node_session",
            description: "Dispatch a graph node to BYOA local, CI agent, or human runner. Execution-layer action — applies directly, no proposal.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "canvasId": ["type": "string"],
                    "nodeId": ["type": "string"],
                    "runner": ["type": "string", "enum": ["byoa-local", "ci-agent", "human"]]
                ],
                "required": ["nodeId"]
            ]
        )
    }

    private static func runDispatchNodeSession(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let nodeId = try requiredPlannerString(args["nodeId"], name: "nodeId")
            let runner = PlannerDispatchRunner(rawValue: stringValue(args["runner"]) ?? "byoa-local") ?? .byoaLocal
            let result = try PlannerBoardBridge.dispatchNode(
                nodeId: nodeId,
                runner: runner,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(result.graph))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func attachArtifactToNodeDef() -> ToolDef {
        ToolDef(
            name: "attach_artifact_to_node",
            description: "Attach an artifact reference to a graph node as evidence. This does not change topology.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "canvasId": ["type": "string"],
                    "nodeId": ["type": "string"],
                    "kind": ["type": "string"],
                    "title": ["type": "string"],
                    "reference": ["type": "string"],
                    "status": ["type": "string"]
                ],
                "required": ["nodeId", "reference"]
            ]
        )
    }

    private static func runAttachArtifactToNode(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let nodeId = try requiredPlannerString(args["nodeId"], name: "nodeId")
            let reference = try requiredPlannerString(args["reference"], name: "reference")
            let kind = PlannerArtifactKind(rawValue: stringValue(args["kind"]) ?? "") ?? .generic
            let state = try PlannerBoardBridge.attachArtifact(
                nodeId: nodeId,
                kind: kind,
                title: stringValue(args["title"]) ?? reference,
                reference: reference,
                status: stringValue(args["status"]) ?? "attached",
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(state))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func createSubCanvasFromNodeDef() -> ToolDef {
        ToolDef(
            name: "create_sub_canvas_from_node",
            description: "Create a sub-canvas container and a pending proposal to link it from a graph node.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "canvasId": ["type": "string"],
                    "nodeId": ["type": "string"],
                    "title": ["type": "string"]
                ],
                "required": ["nodeId"]
            ]
        )
    }

    private static func runCreateSubCanvasFromNode(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        struct SubCanvasToolResponse: Encodable {
            let proposal: PlanProposal
            let subCanvasId: String
        }

        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let nodeId = try requiredPlannerString(args["nodeId"], name: "nodeId")
            let title = stringValue(args["title"]) ?? "Sub-canvas"
            let snapshot = try BoardLayoutStore.shared.createCanvas(name: title, scope: .personal)
            guard let subCanvas = snapshot.canvases.last else {
                return .failure("failed to create sub-canvas")
            }
            let proposal = try PlannerBoardBridge.createSubCanvasProposal(
                nodeId: nodeId,
                subCanvasId: subCanvas.id,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(SubCanvasToolResponse(proposal: proposal, subCanvasId: subCanvas.id)))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func updateNodeLayoutDef() -> ToolDef {
        ToolDef(
            name: "update_node_layout",
            description: "Persist a user-driven graph node layout position. Use only after user/drag interaction.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "canvasId": ["type": "string"],
                    "nodeId": ["type": "string"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "width": ["type": "number"],
                    "height": ["type": "number"]
                ],
                "required": ["nodeId", "x", "y"]
            ]
        )
    }

    private static func runUpdateNodeLayout(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let canvasId = try plannerCanvasId(args: args, settings: settings)
            let nodeId = try requiredPlannerString(args["nodeId"], name: "nodeId")
            let layout = PlannerNodeLayout(
                x: numberValue(args["x"]) ?? 0,
                y: numberValue(args["y"]) ?? 0,
                width: numberValue(args["width"]),
                height: numberValue(args["height"])
            )
            let state = try PlannerBoardBridge.updateNodeLayout(
                nodeId: nodeId,
                layout: layout,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return try .success(jsonPayload(state))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func plannerCanvasId(args: [String: Any], settings: AssistantSettings) throws -> String {
        if let raw = stringValue(args["canvasId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        let requested = settings.canvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requested.isEmpty {
            return requested
        }
        return BoardLayoutStore.shared.snapshot().activeCanvasId
    }

    private static func requiredPlannerString(_ raw: Any?, name: String) throws -> String {
        guard let value = stringValue(raw)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw toolError("\(name) is required")
        }
        return value
    }

    private static func decodePlanChanges(_ raw: Any?) throws -> [PlanChange] {
        guard let raw else { throw toolError("changes is required") }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([PlanChange].self, from: data)
    }

    private static func jsonPayload<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
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
                "user must click Apply. Supported operations include moving/showing " +
                "sessions, notes, frames, connectors, shapes, and labels.",
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
                                "fromSessionId": ["type": "string"],
                                "toSessionId": ["type": "string"],
                                "fromElementId": ["type": "string"],
                                "toElementId": ["type": "string"],
                                "sessionIds": ["type": "array", "items": ["type": "string"]],
                                "title": ["type": "string"],
                                "text": ["type": "string"],
                                "label": ["type": "string"],
                                "shape": ["type": "string"],
                                "direction": ["type": "string"],
                                "stylePreset": ["type": "string"],
                                "x": ["type": "number"],
                                "y": ["type": "number"],
                                "width": ["type": "number"],
                                "height": ["type": "number"],
                                "padding": ["type": "number"]
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
                "Spawn a new local Claude/Codex session and bind it to the current canvas. " +
                "Use mode=global for canvas-level/coordinator work, mode=project for a specific cwd.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "mode": [
                        "type": "string",
                        "description": "'project' or 'global'. Default 'project' when cwd is supplied, otherwise 'global'."
                    ],
                    "provider": [
                        "type": "string",
                        "description": "'claude' or 'codex'. Default 'claude'."
                    ],
                    "cwd": [
                        "type": "string",
                        "description": "Project mode absolute path. `~` is expanded server-side."
                    ],
                    "initialPrompt": [
                        "type": "string",
                        "description": "Optional first instruction injected after the new session appears."
                    ],
                    "layoutHint": [
                        "type": "object",
                        "description": "Optional card placement hint {x,y,width,height} on the current canvas."
                    ],
                    "createIfMissing": [
                        "type": "boolean",
                        "description": "If true, mkdir -p the cwd when missing. Default false for project, true for global."
                    ]
                ],
                "required": []
            ]
        )
    }

    private static func runCreateSession(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        let context: CanvasToolContext?
        do {
            context = try loadCanvasToolContext(settings: settings)
        } catch {
            context = nil
        }
        let rawMode = stringValue(args["mode"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var cwd = stringValue(args["cwd"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mode = createSessionMode(rawMode: rawMode, cwd: cwd)
        let provider = normalizedProvider(stringValue(args["provider"]) ?? stringValue(args["command"]) ?? "claude")
        let command = provider
        if mode == "global" {
            guard let context else {
                return .failure("global session requires a current canvas")
            }
            cwd = context.workspacePath
        }
        guard !cwd.isEmpty else {
            return .failure("missing 'cwd' for project session")
        }
        if cwd.hasPrefix("~") {
            cwd = NSHomeDirectory() + String(cwd.dropFirst(1))
        }
        cwd = (cwd as NSString).standardizingPath

        let createIfMissing = (args["createIfMissing"] as? Bool) ?? (mode == "global")
        let termProgram = args["termProgram"] as? String
        let initialPrompt = stringValue(args["initialPrompt"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let layoutHint = parseLayoutHint(args["layoutHint"])

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

        var spawnIntentId = ""
        if let context {
            do {
                let intent = try BoardLayoutStore.shared.recordSpawnIntent(
                    canvasId: context.canvas.id,
                    cwd: cwd,
                    command: command,
                    provider: provider,
                    purpose: mode,
                    initialPrompt: initialPrompt?.isEmpty == false ? initialPrompt : nil,
                    layoutHint: layoutHint
                )
                spawnIntentId = intent.id
            } catch {
                return .failure("failed to record canvas spawn intent: \(error.localizedDescription)")
            }
        }

        let spawner = SpawnerRouter.forTerminal(termProgram)
        let cwdFinal = cwd
        let commandFinal = command
        Task {
            _ = await spawner.spawn(cwd: cwdFinal, command: commandFinal)
        }

        return .success([
            "ok": true,
            "mode": mode,
            "provider": provider,
            "cwd": cwd,
            "command": command,
            "canvasId": context?.canvas.id ?? "",
            "spawnIntentId": spawnIntentId,
            "note": "Spawn dispatched. Session will appear on the current canvas once meee2 observes it."
        ])
    }

    static func createSessionMode(rawMode: String?, cwd: String) -> String {
        if rawMode == "project" || rawMode == "global" {
            return rawMode!
        }
        return cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "global" : "project"
    }

    private static func createCoordinatorSessionDef() -> ToolDef {
        ToolDef(
            name: "create_coordinator_session",
            description:
                "Create a global coordinator session for selected sessions on the current canvas. " +
                "It spawns a real session, binds it to the canvas, injects a coordinator prompt, " +
                "and returns a canvas patch proposal for grouping/relationship visuals.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "selectedSessionIds": ["type": "array", "items": ["type": "string"]],
                    "provider": ["type": "string", "description": "'claude' or 'codex'. Default 'claude'."],
                    "goal": ["type": "string"],
                    "title": ["type": "string"]
                ],
                "required": ["selectedSessionIds"]
            ]
        )
    }

    private static func runCreateCoordinatorSession(args: [String: Any], settings: AssistantSettings) -> DispatchResult {
        do {
            let context = try loadCanvasToolContext(settings: settings)
            var ids = ((args["selectedSessionIds"] as? [Any]) ?? [])
                .compactMap { stringValue($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if ids.isEmpty {
                ids = settings.selectedElements.compactMap { $0.sessionId }
            }
            ids = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
            guard ids.count >= 2 else {
                return .failure("create_coordinator_session requires at least two selected sessions")
            }

            let live = Dictionary(uniqueKeysWithValues: PluginManager.shared.sessions.map { ($0.id, $0) })
            let missing = ids.filter { live[$0] == nil }
            guard missing.isEmpty else {
                return .failure("selected sessions are not live: \(missing.joined(separator: ", "))")
            }

            let provider = normalizedProvider(stringValue(args["provider"]) ?? "claude")
            let title = stringValue(args["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = stringValue(args["goal"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let layoutHint = coordinatorLayoutHint(sessionIds: ids, layout: context.layout)
            let prompt = coordinatorPrompt(
                title: title?.isEmpty == false ? title! : "Coordinator",
                goal: goal?.isEmpty == false ? goal! : "Coordinate the selected sessions.",
                sessions: ids.compactMap { live[$0] }
            )
            let createResult = runCreateSession(args: [
                "mode": "global",
                "provider": provider,
                "initialPrompt": prompt,
                "layoutHint": [
                    "x": layoutHint.x,
                    "y": layoutHint.y,
                    "width": layoutHint.width ?? 280.0,
                    "height": layoutHint.height ?? 160.0
                ],
                "createIfMissing": true
            ], settings: settings)
            guard case .success(let payload) = createResult else {
                if case .failure(let message) = createResult { return .failure(message) }
                return .failure("failed to create coordinator session")
            }
            let payloadDict = payload as? [String: Any]
            let spawnIntentId = stringValue(payloadDict?["spawnIntentId"]) ?? ""
            let group = try CoordinationStore.shared.createGroup(
                canvasId: context.canvas.id,
                coordinatorSessionId: nil,
                pendingSpawnIntentId: spawnIntentId.isEmpty ? nil : spawnIntentId,
                memberSessionIds: ids,
                goal: goal?.isEmpty == false ? goal! : "Coordinate the selected sessions."
            )
            let coordinatorNodeId = "coordinator-node-\(UUID().uuidString.lowercased())"
            var operations: [[String: Any]] = [
                [
                    "type": "add_shape",
                    "elementId": coordinatorNodeId,
                    "shape": "rectangle",
                    "text": title?.isEmpty == false ? title! : "Coordinator",
                    "x": layoutHint.x,
                    "y": layoutHint.y,
                    "width": layoutHint.width ?? 280.0,
                    "height": layoutHint.height ?? 120.0,
                    "stylePreset": "coordination"
                ]
            ]
            for sid in ids {
                operations.append([
                    "type": "add_connector",
                    "fromElementId": coordinatorNodeId,
                    "toSessionId": sid,
                    "label": "coordinates",
                    "stylePreset": "coordination"
                ])
            }
            operations.append(coordinatorFrameOperation(
                title: title?.isEmpty == false ? "\(title!) group" : "Coordinator group",
                sessionIds: ids,
                layout: context.layout,
                coordinator: layoutHint
            ))

            let patch: [String: Any] = [
                "type": "canvas_patch_proposal",
                "canvasId": context.canvas.id,
                "canvasName": context.canvas.name,
                "summary": "Create coordinator relationship visuals.",
                "operations": operations,
                "operationCount": operations.count,
                "requiresApply": true
            ]

            return .success([
                "ok": true,
                "createdSession": payload,
                "coordinationGroupId": group.id,
                "selectedSessionIds": ids,
                "initialPrompt": prompt,
                "canvasPatchProposal": patch,
                "note": "Coordinator session is spawning. meee2 will maintain compact member digests locally and wake this global coordinator only when action is needed. Apply the patch to add the coordinator node, relationship arrows, and group frame now; the real session card will appear nearby once meee2 observes it."
            ])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func getCoordinationStateDef() -> ToolDef {
        ToolDef(
            name: "get_coordination_state",
            description: "Read local hybrid coordinator groups, member compact digests, and wake events. Does not read channels.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "groupId": ["type": "string"]
                ],
                "required": []
            ]
        )
    }

    private static func runGetCoordinationState(args: [String: Any]) -> DispatchResult {
        let groups = CoordinationStore.shared.snapshot()
        if let groupId = stringValue(args["groupId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupId.isEmpty {
            guard let group = groups.first(where: { $0.id == groupId }) else {
                return .failure("coordination group not found: \(groupId)")
            }
            return .success(coordinationGroupPayload(group))
        }
        return .success(["groups": groups.map(coordinationGroupPayload)])
    }

    private static func sendToSessionDef() -> ToolDef {
        ToolDef(
            name: "send_to_session",
            description: "Send an operator-inbox message to a specific session. Use for coordinator routing; do not use channels.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sessionId": ["type": "string"],
                    "content": ["type": "string"]
                ],
                "required": ["sessionId", "content"]
            ]
        )
    }

    private static func runSendToSession(args: [String: Any]) -> DispatchResult {
        guard let sessionId = stringValue(args["sessionId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return .failure("send_to_session requires sessionId")
        }
        guard let content = stringValue(args["content"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return .failure("send_to_session requires content")
        }
        do {
            try CoordinationStore.shared.sendToSession(sessionId: sessionId, content: content)
            return .success(["ok": true, "sessionId": sessionId])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func broadcastToMembersDef() -> ToolDef {
        ToolDef(
            name: "broadcast_to_members",
            description: "Send a message to all members of a coordination group via each session operator inbox.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "groupId": ["type": "string"],
                    "content": ["type": "string"],
                    "contentBySessionId": ["type": "object", "additionalProperties": ["type": "string"]]
                ],
                "required": ["groupId"]
            ]
        )
    }

    private static func runBroadcastToMembers(args: [String: Any]) -> DispatchResult {
        guard let groupId = stringValue(args["groupId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupId.isEmpty else {
            return .failure("broadcast_to_members requires groupId")
        }
        let content = stringValue(args["content"])
        let contentBySessionId = (args["contentBySessionId"] as? [String: Any] ?? [:])
            .compactMapValues { stringValue($0) }
        do {
            let count = try CoordinationStore.shared.broadcast(
                groupId: groupId,
                content: content,
                contentBySessionId: contentBySessionId
            )
            _ = try CoordinationStore.shared.appendEvent(
                groupId: groupId,
                kind: "route",
                reason: "broadcast_to_members",
                sessionIds: Array(contentBySessionId.keys),
                contextPreview: content ?? ""
            )
            return .success(["ok": true, "delivered": count])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func updateGroupDigestDef() -> ToolDef {
        ToolDef(
            name: "update_group_digest",
            description: "Update a coordination group's compact member digest after coordinator reasoning.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "groupId": ["type": "string"],
                    "sessionId": ["type": "string"],
                    "summary": ["type": "string"],
                    "blockers": ["type": "array", "items": ["type": "string"]],
                    "lastDecision": ["type": "string"],
                    "currentTask": ["type": "string"]
                ],
                "required": ["groupId", "sessionId"]
            ]
        )
    }

    private static func runUpdateGroupDigest(args: [String: Any]) -> DispatchResult {
        guard let groupId = stringValue(args["groupId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              let sessionId = stringValue(args["sessionId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupId.isEmpty, !sessionId.isEmpty else {
            return .failure("update_group_digest requires groupId and sessionId")
        }
        let blockers = (args["blockers"] as? [Any])?.compactMap { stringValue($0) }
        do {
            let group = try CoordinationStore.shared.updateDigest(
                groupId: groupId,
                sessionId: sessionId,
                summary: stringValue(args["summary"]),
                blockers: blockers,
                lastDecision: stringValue(args["lastDecision"]),
                currentTask: stringValue(args["currentTask"])
            )
            return .success(coordinationGroupPayload(group))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func pauseCoordinationDef() -> ToolDef {
        ToolDef(
            name: "pause_coordination",
            description: "Pause automatic coordinator wake-ups for a group. Manual Ask coordinator can still run.",
            inputSchema: [
                "type": "object",
                "properties": ["groupId": ["type": "string"]],
                "required": ["groupId"]
            ]
        )
    }

    private static func resumeCoordinationDef() -> ToolDef {
        ToolDef(
            name: "resume_coordination",
            description: "Resume automatic coordinator wake-ups for a group.",
            inputSchema: [
                "type": "object",
                "properties": ["groupId": ["type": "string"]],
                "required": ["groupId"]
            ]
        )
    }

    private static func runPauseCoordination(args: [String: Any], paused: Bool) -> DispatchResult {
        guard let groupId = stringValue(args["groupId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupId.isEmpty else {
            return .failure("groupId is required")
        }
        do {
            let group = try CoordinationStore.shared.setPaused(groupId: groupId, paused: paused)
            return .success(coordinationGroupPayload(group))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func askCoordinatorDef() -> ToolDef {
        ToolDef(
            name: "ask_coordinator",
            description: "Manually wake a global coordinator with compact group context and member digests.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "groupId": ["type": "string"],
                    "reason": ["type": "string"]
                ],
                "required": ["groupId"]
            ]
        )
    }

    private static func runAskCoordinator(args: [String: Any]) -> DispatchResult {
        guard let groupId = stringValue(args["groupId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupId.isEmpty else {
            return .failure("ask_coordinator requires groupId")
        }
        do {
            try CoordinationStore.shared.manualAsk(
                groupId: groupId,
                reason: stringValue(args["reason"]) ?? "manual Ask coordinator"
            )
            return .success(["ok": true, "groupId": groupId])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func coordinationGroupPayload(_ group: CoordinationGroup) -> [String: Any] {
        [
            "id": group.id,
            "canvasId": group.canvasId,
            "coordinatorSessionId": group.coordinatorSessionId ?? "",
            "pendingSpawnIntentId": group.pendingSpawnIntentId ?? "",
            "memberSessionIds": group.memberSessionIds,
            "mode": group.mode,
            "goal": group.goal,
            "paused": group.paused,
            "memberDigests": group.memberDigests.mapValues { digest in
                [
                    "sessionId": digest.sessionId,
                    "summary": digest.summary,
                    "currentTask": digest.currentTask,
                    "status": digest.status,
                    "blockers": digest.blockers,
                    "lastDecision": digest.lastDecision,
                    "lastTranscriptCursor": digest.lastTranscriptCursor,
                    "lastActivity": digest.lastActivity.map(BoardDTOBuilder.iso) ?? NSNull()
                ] as [String: Any]
            },
            "events": group.events.map { event in
                [
                    "id": event.id,
                    "groupId": event.groupId,
                    "kind": event.kind,
                    "reason": event.reason,
                    "sessionIds": event.sessionIds,
                    "contextPreview": event.contextPreview,
                    "createdAt": BoardDTOBuilder.iso(event.createdAt)
                ] as [String: Any]
            },
            "lastWakeAt": group.lastWakeAt.map(BoardDTOBuilder.iso) ?? NSNull(),
            "lastRoutedAction": group.lastRoutedAction ?? NSNull(),
            "createdAt": BoardDTOBuilder.iso(group.createdAt),
            "updatedAt": BoardDTOBuilder.iso(group.updatedAt)
        ]
    }

    private static func normalizedProvider(_ raw: String) -> String {
        raw.lowercased().contains("codex") ? "codex" : "claude"
    }

    private static func parseLayoutHint(_ raw: Any?) -> BoardLayoutStore.Point? {
        guard let dict = raw as? [String: Any],
              let x = numberValue(dict["x"]),
              let y = numberValue(dict["y"]) else { return nil }
        return BoardLayoutStore.Point(
            x: x,
            y: y,
            width: numberValue(dict["width"]),
            height: numberValue(dict["height"])
        )
    }

    private static func coordinatorLayoutHint(sessionIds: [String], layout: BoardLayoutStore.Layout) -> BoardLayoutStore.Point {
        let points = sessionIds.compactMap { layout.sessions[$0] }
        guard !points.isEmpty else {
            return BoardLayoutStore.Point(x: 0, y: 0, width: 280, height: 160)
        }
        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxX = points.map { $0.x + ($0.width ?? 280) }.max() ?? (minX + 280)
        let x = minX + (maxX - minX) / 2 - 140
        return BoardLayoutStore.Point(x: x, y: minY - 220, width: 280, height: 160)
    }

    private static func coordinatorFrameOperation(
        title: String,
        sessionIds: [String],
        layout: BoardLayoutStore.Layout,
        coordinator: BoardLayoutStore.Point
    ) -> [String: Any] {
        let points = sessionIds.compactMap { layout.sessions[$0] } + [coordinator]
        let padding = 48.0
        guard !points.isEmpty else {
            return [
                "type": "add_frame",
                "sessionIds": sessionIds,
                "title": title,
                "padding": padding,
                "stylePreset": "coordination"
            ]
        }
        let minX = (points.map(\.x).min() ?? 0) - padding
        let minY = (points.map(\.y).min() ?? 0) - padding
        let maxX = (points.map { $0.x + ($0.width ?? 280) }.max() ?? 360) + padding
        let maxY = (points.map { $0.y + ($0.height ?? 160) }.max() ?? 240) + padding
        return [
            "type": "add_frame",
            "title": title,
            "x": minX,
            "y": minY,
            "width": max(120, maxX - minX),
            "height": max(90, maxY - minY),
            "stylePreset": "coordination"
        ]
    }

    private static func coordinatorPrompt(title: String, goal: String, sessions: [PluginSession]) -> String {
        var lines: [String] = [
            "You are \(title), a coordinator session created from meee2 Board.",
            "Goal: \(goal)",
            "",
            "You run in hybrid on-demand mode. meee2 maintains compact member digests locally and wakes you only when a decision, blocker, handoff, or manual Ask requires reasoning.",
            "Coordinate these sessions. Track progress, identify conflicts, summarize next steps, and use send_to_session or broadcast_to_members when delegation is needed.",
            "Do not rely on channel concepts. If you need raw history, explicitly request a targeted transcript deep dive instead of assuming every message is already in context.",
            "",
            "Sessions:"
        ]
        for s in sessions {
            let realSid = rawSessionId(s)
            let preview: String = {
                guard let path = SessionStore.shared.get(realSid)?.transcriptPath else { return "" }
                return TranscriptParser.loadMessages(transcriptPath: path, count: 3)
                    .map { "\($0.role): \($0.text)" }
                    .joined(separator: " | ")
            }()
            lines.append("- id=\(s.id) title=\(s.title) cwd=\(s.cwd ?? "") status=\(statusName(s.status)) latest=\(truncate(preview, to: 600))")
        }
        return lines.joined(separator: "\n")
    }

    private static func rawSessionId(_ session: PluginSession) -> String {
        let prefix = "\(session.pluginId)-"
        return session.id.hasPrefix(prefix) ? String(session.id.dropFirst(prefix.count)) : session.id
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

        func optionalElementId(_ key: String) -> String? {
            guard let id = stringValue(raw[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            return id
        }

        func optionalSessionId(_ key: String) throws -> String? {
            guard let sid = stringValue(raw[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sid.isEmpty else { return nil }
            guard liveSessionIds.contains(sid) else {
                throw toolError("operation \(index) references unknown \(key): \(sid)")
            }
            return sid
        }

        func sessionIds() throws -> [String] {
            guard let rawIds = raw["sessionIds"] as? [Any] else { return [] }
            var out: [String] = []
            for value in rawIds {
                guard let sid = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sid.isEmpty else { continue }
                guard liveSessionIds.contains(sid) else {
                    throw toolError("operation \(index) references unknown sessionId: \(sid)")
                }
                if !out.contains(sid) { out.append(sid) }
            }
            return out
        }

        func stylePreset() -> String? {
            guard let preset = stringValue(raw["stylePreset"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !preset.isEmpty else { return nil }
            let allowed: Set<String> = ["coordination", "review", "dependency", "handoff", "group"]
            return allowed.contains(preset) ? preset : "group"
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
        case "add_frame":
            let ids = try sessionIds()
            if !ids.isEmpty { out["sessionIds"] = ids }
            if let id = optionalElementId("elementId") { out["elementId"] = id }
            if let title = stringValue(raw["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty { out["title"] = truncate(title, to: 160) }
            if let x = numberValue(raw["x"]) { out["x"] = x }
            if let y = numberValue(raw["y"]) { out["y"] = y }
            if let width = numberValue(raw["width"]) { out["width"] = max(1, width) }
            if let height = numberValue(raw["height"]) { out["height"] = max(1, height) }
            if let padding = numberValue(raw["padding"]) { out["padding"] = max(0, min(200, padding)) }
            if ids.isEmpty && (out["x"] == nil || out["y"] == nil || out["width"] == nil || out["height"] == nil) {
                throw toolError("operation \(index) add_frame requires sessionIds or explicit x/y/width/height")
            }
            if let preset = stylePreset() { out["stylePreset"] = preset }
        case "add_connector":
            if let sid = try optionalSessionId("fromSessionId") { out["fromSessionId"] = sid }
            if let sid = try optionalSessionId("toSessionId") { out["toSessionId"] = sid }
            if let id = optionalElementId("fromElementId") { out["fromElementId"] = id }
            if let id = optionalElementId("toElementId") { out["toElementId"] = id }
            guard out["fromSessionId"] != nil || out["fromElementId"] != nil,
                  out["toSessionId"] != nil || out["toElementId"] != nil else {
                throw toolError("operation \(index) add_connector requires from/to endpoints")
            }
            if let label = stringValue(raw["label"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty { out["label"] = truncate(label, to: 120) }
            if let direction = stringValue(raw["direction"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               ["forward", "backward", "none"].contains(direction) { out["direction"] = direction }
            if let preset = stylePreset() { out["stylePreset"] = preset }
        case "add_shape":
            guard let shape = stringValue(raw["shape"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ["rectangle", "ellipse", "diamond"].contains(shape) else {
                throw toolError("operation \(index) add_shape requires shape rectangle|ellipse|diamond")
            }
            out["shape"] = shape
            if let id = optionalElementId("elementId") { out["elementId"] = id }
            out["x"] = try requiredCoordinate("x")
            out["y"] = try requiredCoordinate("y")
            if let width = numberValue(raw["width"]) { out["width"] = max(1, width) }
            if let height = numberValue(raw["height"]) { out["height"] = max(1, height) }
            if let text = stringValue(raw["text"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty { out["text"] = truncate(text, to: 500) }
            if let preset = stylePreset() { out["stylePreset"] = preset }
        case "add_label":
            guard let text = stringValue(raw["text"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw toolError("operation \(index) add_label requires text")
            }
            out["text"] = truncate(text, to: 500)
            if let id = optionalElementId("elementId") { out["elementId"] = id }
            out["x"] = try requiredCoordinate("x")
            out["y"] = try requiredCoordinate("y")
            if let preset = stylePreset() { out["stylePreset"] = preset }
        case "update_element":
            out["elementId"] = try elementId(requiredKnown: false)
            var hasChange = false
            if let text = stringValue(raw["text"]) {
                out["text"] = truncate(text, to: 500)
                hasChange = true
            }
            if let x = numberValue(raw["x"]) { out["x"] = x; hasChange = true }
            if let y = numberValue(raw["y"]) { out["y"] = y; hasChange = true }
            if let width = numberValue(raw["width"]) { out["width"] = max(1, width); hasChange = true }
            if let height = numberValue(raw["height"]) { out["height"] = max(1, height); hasChange = true }
            if let preset = stylePreset() { out["stylePreset"] = preset; hasChange = true }
            guard hasChange else {
                throw toolError("operation \(index) update_element has no changes")
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
