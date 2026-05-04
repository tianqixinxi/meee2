import Foundation
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

    // MARK: - create_session

    private static func createSessionDef() -> ToolDef {
        ToolDef(
            name: "create_session",
            description:
                "Spawn a new Claude session in a Ghostty terminal at the given cwd. " +
                "Reuses the user's local Claude OAuth (no API key needed). " +
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
