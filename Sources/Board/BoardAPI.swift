import Foundation
import AppKit
import Swifter
import Meee2PluginKit
import Meee2CommKit

/// BoardAPI —— 所有 REST 路由的处理器
/// 每个处理器返回 HttpResponse；成功时以 `.raw(status, reason, headers, writer)` 发送 JSON。
/// 突变成功后需要调用 `BoardServer.shared.broadcastStateChanged()`（在 BoardServer 里统一触发）。
enum BoardAPI {
    // MARK: - 响应辅助

    enum PlannerRuntimeError: LocalizedError {
        case timedOut(canvasId: String)
        case failed(canvasId: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .timedOut(let canvasId):
                return "Planner runtime timed out for canvas \(canvasId). No local proposal was generated."
            case .failed(let canvasId, let underlying):
                return "Planner runtime failed for canvas \(canvasId): \(underlying.localizedDescription)"
            }
        }
    }

    /// 将 Encodable 作为 JSON body 返回
    static func jsonResponse<T: Encodable>(_ body: T, status: Int = 200, reason: String = "OK") -> HttpResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(body)
            return .raw(status, reason, ["Content-Type": "application/json; charset=utf-8"]) { writer in
                try writer.write(data)
            }
        } catch {
            let fallback = "{\"error\":{\"code\":\"encode_failed\",\"message\":\"\(error.localizedDescription)\"}}"
            let bytes = Array(fallback.utf8)
            return .raw(500, "Internal Server Error", ["Content-Type": "application/json; charset=utf-8"]) { writer in
                try writer.write(bytes)
            }
        }
    }

    /// 错误响应
    static func errorResponse(_ code: String, _ message: String, status: Int) -> HttpResponse {
        let reason: String = {
            switch status {
            case 400: return "Bad Request"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 409: return "Conflict"
            case 502: return "Bad Gateway"
            case 503: return "Service Unavailable"
            case 500: return "Internal Server Error"
            default: return "Error"
            }
        }()
        return jsonResponse(ErrorDTO(code: code, message: message), status: status, reason: reason)
    }

    static let plannerNodeOutputPayloadHelp = [
        "body must be a valid PlannerNodeOutput:",
        "{\"nodeId\":\"...\",\"status\":\"done|blocked|needs_review\",\"message\":{\"summary\":\"...\",\"routeTo\":[\"owner\"]},\"artifacts\":[],\"next\":\"complete|blocked|needs_owner_review\"}.",
        "For artifact outputs, use artifacts[].reference for the output slot from read_node_contract.",
        "artifacts[].payload must be a typed object such as {\"type\":\"json\",\"json\":\"{...}\"}, {\"type\":\"text\",\"text\":\"...\"}, or {\"type\":\"file\",\"file\":{\"path\":\"report.md\",\"mimeType\":\"text/markdown\"}}.",
        "Do not submit a bare string payload, {\"content\":...}, or an artifact_ref wrapper."
    ].joined(separator: " ")

    /// 解析请求 body 为 JSON 字典
    static func parseJSONBody(_ req: HttpRequest) -> [String: Any]? {
        let data = Data(req.body)
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeJSONBody<T: Decodable>(_ req: HttpRequest, as type: T.Type) -> T? {
        let data = Data(req.body)
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// 将 HttpError 映射到 HTTP 状态码
    static func mapChannelError(_ err: ChannelRegistryError) -> HttpResponse {
        switch err {
        case .alreadyExists(let n):
            return errorResponse("already_exists", "channel already exists: \(n)", status: 409)
        case .notFound(let n):
            return errorResponse("not_found", "channel not found: \(n)", status: 404)
        case .aliasTaken(let a):
            return errorResponse("alias_taken", "alias already taken: \(a)", status: 409)
        case .aliasNotFound(let a):
            return errorResponse("alias_not_found", "alias not found: \(a)", status: 404)
        case .invalidName(let n):
            return errorResponse("invalid_name", "invalid channel name: \(n) (allowed: [a-z0-9_-], 1..64 chars)", status: 400)
        case .invalidDisplayName:
            return errorResponse("invalid_display_name", "display name must be 1..100 characters", status: 400)
        }
    }

    static func mapMessageError(_ err: MessageRouterError) -> HttpResponse {
        switch err {
        case .channelNotFound(let n):
            return errorResponse("not_found", "channel not found: \(n)", status: 404)
        case .unknownSender(let a, let c):
            return errorResponse("unknown_sender", "unknown sender alias '\(a)' in channel '\(c)'", status: 400)
        case .unknownRecipient(let a, let c):
            return errorResponse("unknown_recipient", "unknown recipient alias '\(a)' in channel '\(c)'", status: 400)
        case .messageNotFound(let id):
            return errorResponse("not_found", "message not found: \(id)", status: 404)
        case .alreadyTerminal(let id):
            return errorResponse("already_terminal", "message already terminal: \(id)", status: 409)
        case .channelPaused(let c):
            return errorResponse("paused_channel", "channel is paused: \(c)", status: 409)
        case .emptyRecipients(let c):
            return errorResponse(
                "empty_recipients",
                "broadcast in '\(c)' has no recipients after excluding the sender; add another member or pick a specific toAlias",
                status: 400
            )
        case .hopLimitExceeded(let c, let h):
            return errorResponse(
                "hop_limit_exceeded",
                "hop limit exceeded in '\(c)' (hopCount=\(h), max=\(MessageRouter.maxHopsHard))",
                status: 400
            )
        }
    }

    // MARK: - GET /api/system/meee2-mcp-status

    static func getMeee2MCPStatus(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(MCPConfigManager.shared.diagnoseMeee2Server())
    }

    // MARK: - Meee2 agent runtime plugin setup

    static func getMeee2AgentRuntimeStatus(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(Meee2AgentRuntimeInstaller.diagnose())
    }

    static func installMeee2AgentRuntime(_ req: HttpRequest) -> HttpResponse {
        struct InstallRequest: Decodable {
            let target: String?
        }
        let body = decodeJSONBody(req, as: InstallRequest.self)
        let rawTarget = body?.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = rawTarget.isEmpty ? "all" : rawTarget
        guard ["claude", "codex", "all"].contains(target.lowercased()) else {
            return errorResponse("bad_request", "target must be claude, codex, or all", status: 400)
        }
        return jsonResponse(Meee2AgentRuntimeInstaller.install(target: target))
    }

    // MARK: - Local session readiness

    static func getReadiness(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(ReadinessDoctor.diagnose())
    }

    static func repairReadiness(_ req: HttpRequest) -> HttpResponse {
        struct RepairRequest: Decodable {
            let actionId: String?
        }
        let body = decodeJSONBody(req, as: RepairRequest.self)
        guard let actionId = body?.actionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actionId.isEmpty else {
            return errorResponse("bad_request", "actionId is required", status: 400)
        }
        let result = ReadinessDoctor.repair(actionId: actionId)
        return jsonResponse(result, status: result.ok ? 200 : 400, reason: result.ok ? "OK" : "Bad Request")
    }

    static func exportDebug(_ req: HttpRequest) -> HttpResponse {
        do {
            return jsonResponse(try DebugExporter.exportToDefaultLocation())
        } catch {
            return errorResponse("debug_export_failed", error.localizedDescription, status: 500)
        }
    }

    static func getDevPerf(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(BoardPerfProbe.shared.snapshot())
    }

    static func resetDevPerf(_ req: HttpRequest) -> HttpResponse {
        BoardPerfProbe.shared.reset()
        return jsonResponse(BoardPerfProbe.shared.snapshot())
    }

    // MARK: - Privacy: storage stats + delete local data

    static func getStorageStats(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(SystemStorageAPI.gatherStats())
    }

    static func issueDeleteLocalDataToken(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(SystemStorageAPI.issueDeleteToken())
    }

    static func deleteLocalData(_ req: HttpRequest) -> HttpResponse {
        struct DeleteRequest: Decodable {
            let token: String?
        }
        let body = decodeJSONBody(req, as: DeleteRequest.self)
        guard let token = body?.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return errorResponse("bad_request", "token is required", status: 400)
        }
        do {
            return jsonResponse(try SystemStorageAPI.deleteLocalData(token: token))
        } catch let e as SystemStorageAPI.APIError {
            return errorResponse("invalid_token", e.errorDescription ?? "invalid token", status: 400)
        } catch {
            return errorResponse("delete_failed", error.localizedDescription, status: 500)
        }
    }

    // MARK: - GET /api/sessions/intake-diagnostics

    private struct SessionIntakeDiagnosticItem: Encodable {
        let id: String
        let severity: String
        let title: String
        let detail: String
        let sessionId: String?
        let recoveryAction: String?
    }

    private struct SessionIntakeDiagnostics: Encodable {
        let ok: Bool
        let liveSessions: Int
        let storedSessions: Int
        let historicalSessions: Int
        let items: [SessionIntakeDiagnosticItem]
        let checkedAt: String
    }

    static func getSessionIntakeDiagnostics(_ req: HttpRequest) -> HttpResponse {
        let readiness = ReadinessDoctor.diagnose()
        let stored = SessionStore.shared.listAll()
        let pluginSessions = PluginManager.shared.sessions
            .filter { PluginManager.shared.isPluginEnabled($0.pluginId) }
        let livePluginSessions = pluginSessions.filter { !$0.status.isHistorical }
        let liveKeys = Set(livePluginSessions.map(canonicalSessionKey))
        let historical = stored.filter { session in
            session.status.isHistorical || TranscriptStatusResolver.resolve(for: session).isHistorical
        }

        var items: [SessionIntakeDiagnosticItem] = []
        if readiness.requiredFailed > 0 {
            items.append(SessionIntakeDiagnosticItem(
                id: "local-readiness-failing",
                severity: "error",
                title: "Local session readiness is incomplete",
                detail: "\(readiness.requiredFailed) required readiness check(s) are failing before real session intake can be trusted.",
                sessionId: nil,
                recoveryAction: "Open Settings and run the failing readiness recovery actions."
            ))
        }

        if livePluginSessions.isEmpty && readiness.requiredFailed == 0 {
            items.append(SessionIntakeDiagnosticItem(
                id: "no-live-provider-sessions",
                severity: "warn",
                title: "No live provider sessions are visible",
                detail: "meee2 is ready, but no live Claude Code or Codex session is currently being reported by enabled providers.",
                sessionId: nil,
                recoveryAction: "Start or resume a real Claude Code/Codex session, then refresh this view."
            ))
        }

        for session in stored {
            guard !session.status.isHistorical,
                  let pid = session.pid,
                  !SessionStore.processAlive(pid) else { continue }
            items.append(SessionIntakeDiagnosticItem(
                id: "stale-runtime-\(session.sessionId)",
                severity: "warn",
                title: "Stored session has a stale runtime",
                detail: "Session \(String(session.sessionId.prefix(8))) still points at pid \(pid), but that process is gone. The record should be preserved and marked historical.",
                sessionId: session.sessionId,
                recoveryAction: "Refresh sessions; meee2 will keep the record and mark the runtime ended."
            ))
        }

        let storedActiveNotSurfaced = stored.filter { session in
            guard !session.status.isHistorical else { return false }
            return !liveKeys.contains(canonicalSessionKey(pluginId: "com.meee2.plugin.claude", sessionId: session.sessionId))
        }
        for session in storedActiveNotSurfaced.prefix(5) {
            items.append(SessionIntakeDiagnosticItem(
                id: "stored-not-surfaced-\(session.sessionId)",
                severity: "warn",
                title: "Stored session is not in the live provider view",
                detail: "Session \(String(session.sessionId.prefix(8))) is persisted locally but is not currently surfaced by the enabled Claude provider.",
                sessionId: session.sessionId,
                recoveryAction: "Check whether the provider is disabled, the session is archived, or the provider needs refresh."
            ))
        }

        let duplicateLivePids = Dictionary(grouping: stored.compactMap { session -> (Int, String)? in
            guard let pid = session.pid,
                  !session.status.isHistorical,
                  SessionStore.processAlive(pid) else { return nil }
            return (pid, session.sessionId)
        }, by: { $0.0 })
            .filter { $0.value.count > 1 }
        for (pid, entries) in duplicateLivePids.prefix(5) {
            let ids = entries.map { String($0.1.prefix(8)) }.joined(separator: ", ")
            items.append(SessionIntakeDiagnosticItem(
                id: "duplicate-live-pid-\(pid)",
                severity: "error",
                title: "Multiple stored sessions point at one live runtime",
                detail: "pid \(pid) is attached to multiple stored sessions: \(ids). This usually means stale-id recovery should merge instead of duplicate.",
                sessionId: entries.first?.1,
                recoveryAction: "Wait for the next provider refresh; if it persists, capture debug export."
            ))
        }

        if historical.count > 0 && items.isEmpty {
            items.append(SessionIntakeDiagnosticItem(
                id: "historical-records-preserved",
                severity: "info",
                title: "Historical sessions are preserved",
                detail: "\(historical.count) completed or dead session record(s) are retained for continuity and hidden from the default live monitor.",
                sessionId: nil,
                recoveryAction: nil
            ))
        }

        let ok = !items.contains { $0.severity == "error" }
        return jsonResponse(SessionIntakeDiagnostics(
            ok: ok,
            liveSessions: livePluginSessions.count,
            storedSessions: stored.count,
            historicalSessions: historical.count,
            items: items,
            checkedAt: BoardDTOBuilder.iso(Date())
        ))
    }

    // MARK: - GET /api/state

    static func getState(_ req: HttpRequest) -> HttpResponse {
        BoardPerfProbe.shared.measure(
            "api.state",
            title: "GET /api/state",
            category: "api"
        ) {
            // Web UI 默认只显示 live sessions；completed/dead 记录仍保留在
            // SessionStore 供 history / diagnostic / recovery 使用。
            // 同时过滤 isArchived=true 的 Claude Desktop session：用户已经在
            // desktop 里 archive 的 session，再往 Web UI 上塞会重复污染。
            let sessions = BoardSessionSnapshotProvider.currentBoardSessions()
            var spawnCandidates: [BoardLayoutStore.SpawnCandidate] = []
            for session in sessions where !session.project.isEmpty {
                spawnCandidates.append(BoardLayoutStore.SpawnCandidate(
                    sessionId: session.id,
                    cwd: session.project,
                    provider: spawnProvider(from: session),
                    startedAt: parseISODate(session.startedAt)
                ))
            }
            let matchedSpawnIntents = BoardLayoutStore.shared.applySpawnIntents(candidates: spawnCandidates)
            deliverMatchedSpawnPrompts(matchedSpawnIntents)
            feedPlannerSessionRunStates(sessions)
            // 过滤 "__" 开头的自动频道（每个 session 的 operator channel 等）
            // 不在 UI 里显示，保持 channel 列表干净
            let channels = ChannelRegistry.shared.list()
                .filter { !$0.name.hasPrefix("__") }
                .map { BoardDTOBuilder.channelDTO($0) }
            _ = BoardLayoutStore.shared.ensureDefaults(sessionIds: [])
            let groups = CoordinationStore.shared.snapshot().map(BoardDTOBuilder.coordinationGroupDTO)
            let state = StateDTO(sessions: sessions, channels: channels, coordinationGroups: groups)
            return jsonResponse(state)
        }
    }

    private static func spawnProvider(from session: SessionDTO) -> String? {
        let raw = "\(session.pluginId) \(session.pluginDisplayName)".lowercased()
        if raw.contains("codex") { return "codex" }
        if raw.contains("claude") { return "claude" }
        return nil
    }

    private static func normalizedProvider(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("codex") ? "codex" : "claude"
    }

    // MARK: - Internal session terminal surfaces

    private struct BoardSessionSurfaceDTO: Encodable {
        let surfaceId: String
        let sessionId: String
        let provider: String
        let title: String
        let cwd: String
        let command: String
        let canvasId: String?
        let nodeId: String?
        let status: String
        let pid: Int?
        let createdAt: Date
        let updatedAt: Date
        let terminalBackend: String
        let nativeWorkspaceAvailable: Bool
        let openTarget: String
        let fallbackReason: String?

        init(_ surface: TerminalSessionSnapshot) {
            let displayName = surface.provider == "codex" ? "Codex" : "Claude Code"
            self.surfaceId = surface.surfaceId
            self.sessionId = surface.sessionId
            self.provider = surface.provider
            self.title = "\(displayName) - \(URL(fileURLWithPath: surface.cwd).lastPathComponent)"
            self.cwd = surface.cwd
            self.command = surface.command
            self.canvasId = surface.canvasId
            self.nodeId = surface.nodeId
            self.status = surface.status
            self.pid = surface.pid
            self.createdAt = surface.createdAt
            self.updatedAt = surface.updatedAt
            self.terminalBackend = surface.backend.rawValue
            self.nativeWorkspaceAvailable = surface.backend != .external
            self.openTarget = surface.backend == .external ? "external" : "native-workspace"
            self.fallbackReason = surface.fallbackReason
        }
    }

    static func listSessionSurfaces(_ req: HttpRequest) -> HttpResponse {
        struct Envelope: Encodable { let surfaces: [BoardSessionSurfaceDTO] }
        let surfaces = TerminalSessionBackendRegistry.shared
            .listSnapshots()
            .map(BoardSessionSurfaceDTO.init)
        return jsonResponse(Envelope(surfaces: surfaces))
    }

    static func getSessionSurface(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return errorResponse("bad_request", "missing surface id", status: 400)
        }
        guard let snapshot = TerminalSessionBackendRegistry.shared.snapshot(id: id) else {
            return errorResponse("not_found", "surface not found: \(id)", status: 404)
        }
        return jsonResponse(BoardSessionSurfaceDTO(snapshot))
    }

    static func createSessionSurface(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let provider = normalizedProvider((json["provider"] as? String) ?? "claude")
        guard let rawCwd = json["cwd"] as? String, !rawCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorResponse("bad_request", "missing cwd", status: 400)
        }
        do {
            let cwd = try explicitSessionCwd(rawCwd) ?? rawCwd
            let command = AgentLaunchCommand.fullAccessCommand(forProvider: provider)
            let createIfMissing = (json["createIfMissing"] as? Bool) ?? true
            let initialPrompt = (json["initialPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = try createInternalSessionSurface(
                provider: provider,
                cwd: cwd,
                command: command,
                createIfMissing: createIfMissing,
                canvasId: json["canvasId"] as? String,
                nodeId: json["nodeId"] as? String,
                initialPrompt: initialPrompt?.isEmpty == false ? initialPrompt : nil
            )
            return jsonResponse(snapshot, status: 201, reason: "Created")
        } catch {
            return errorResponse("spawn_failed", error.localizedDescription, status: 500)
        }
    }

    static func closeSessionSurface(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return errorResponse("bad_request", "missing surface id", status: 400)
        }
        guard TerminalSessionBackendRegistry.shared.closeSessionIfExists(id: id) else {
            return errorResponse("not_found", "surface not found: \(id)", status: 404)
        }
        BoardServer.shared.broadcastStateChanged()
        return jsonResponse(OkEnvelope(ok: true))
    }

    private static func createInternalSessionSurface(
        provider: String,
        cwd: String,
        command: String,
        createIfMissing: Bool,
        canvasId: String?,
        nodeId: String?,
        initialPrompt: String?,
        preferredSessionId: String? = nil
    ) throws -> TerminalSessionSnapshot {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            if createIfMissing {
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            } else {
                throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd does not exist: \(cwd)"])
            }
        }
        let trimmedPreferredSessionId = preferredSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reusablePreferredSessionId = trimmedPreferredSessionId?.isEmpty == false ? trimmedPreferredSessionId : nil
        let resumeSessionId = reusablePreferredSessionId.flatMap(providerResumeSessionId(forPlannerSessionId:))
        let launchCommand = resumeSessionId.map {
            AgentLaunchCommand.resumeCommand(forProvider: provider, sessionId: $0)
        } ?? command
        let handle = try TerminalSessionBackendRegistry.shared.createSession(
            request: TerminalSessionRequest(
                provider: provider,
                cwd: cwd,
                command: launchCommand,
                canvasId: canvasId,
                nodeId: nodeId,
                // resume 丢弃 initialPrompt:恢复的对话已有上下文,不应重打 dispatch prompt。
                initialPrompt: resumeSessionId == nil ? initialPrompt : nil,
                preferredSessionId: reusablePreferredSessionId
            )
        )
        BoardServer.shared.broadcastStateChanged()
        return handle.snapshot
    }

    private static func graphEnvelope(_ state: PlannerGraphState) -> PlannerGraphStateEnvelope {
        PlannerGraphStateEnvelope(
            canvas: state.canvas,
            nodes: state.nodes,
            states: state.states,
            proposals: state.proposals,
            access: state.access,
            activities: state.activities,
            events: state.events,
            artifacts: state.artifacts,
            edges: state.edges,
            renderProfile: state.renderProfile,
            renderProfileStatus: state.renderProfileStatus,
            renderObjects: state.renderObjects,
            renderRelations: state.renderRelations,
            nodeAssignments: nodeAssignments(for: state),
            canEditInternals: state.access.role == .owner,
            integrationEntities: integrationEntitiesFor(nodes: state.nodes)
        )
    }

    private static func nodeAssignments(for state: PlannerGraphState) -> [NodeAssignmentDTO] {
        let teamId = UserDefaults.standard.string(forKey: "meee2TeamId") ?? ""
        return state.nodes.compactMap { node in
            guard let subCanvasId = node.subCanvasId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !subCanvasId.isEmpty else {
                return nil
            }
            let contract = NodeContractV2.derive(from: node).contract
            return NodeAssignmentDTO(
                sourceCanvasId: state.canvas.id,
                sourceNodeId: node.id,
                assigneeUserId: node.doerId,
                subCanvasId: subCanvasId,
                subCanvasName: subCanvasId,
                frozenIOContract: contract,
                billingTeamId: teamId,
                sessionCountRebound: nil,
                assignedAt: nil
            )
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func urlPath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            if string == "true" { return true }
            if string == "false" { return false }
        }
        return nil
    }

    private static func remoteCanvasDTO(_ raw: [String: Any]?) -> RemoteAssignedCanvasDTO? {
        guard let raw, let id = stringValue(raw["id"]) else { return nil }
        return RemoteAssignedCanvasDTO(
            id: id,
            teamId: stringValue(raw["teamId"]) ?? "",
            name: stringValue(raw["name"]),
            visibility: stringValue(raw["visibility"]),
            ownerUserId: stringValue(raw["ownerUserId"]),
            parentCanvasId: stringValue(raw["parentCanvasId"]),
            parentNodeId: stringValue(raw["parentNodeId"]),
            frozenIOContract: nil
        )
    }

    static func materializeAutoDispatchedSessions(canvasId: String, result: inout PlannerNodeOutputResult) {
        // ENG-2 / E2.2 + E2.4: spawn terminals for auto-dispatched downstream
        // nodes in the background so the user's focused app stays put. The
        // dispatch state is already persisted by the store (see
        // PlannerBoardBridge.submitNodeOutput), this just materializes the
        // terminal so the session actually runs.
        guard let autoIds = result.autoDispatchedNodeIds, !autoIds.isEmpty else { return }
        var autoSpawnStarted = 0
        var autoSpawnSkipped: [String] = []
        var autoSpawnFailed: [String] = []
        for autoNodeId in autoIds {
            guard let node = result.graph.nodes.first(where: { $0.id == autoNodeId }) else {
                autoSpawnSkipped.append("\(autoNodeId): missing node")
                continue
            }
            do {
                let spawnRequest = try recordPlannerDispatchIntent(
                    canvasId: canvasId,
                    node: node,
                    cwdOverride: nil,
                    includeInitialPromptInIntent: false
                )
                guard let spawnReq = spawnRequest else {
                    autoSpawnSkipped.append("\(autoNodeId): no spawn request")
                    continue
                }
                let surface = try createInternalSessionSurface(
                    provider: spawnReq.provider,
                    cwd: spawnReq.cwd,
                    command: spawnReq.command,
                    createIfMissing: true,
                    canvasId: canvasId,
                    nodeId: autoNodeId,
                    initialPrompt: spawnReq.initialPrompt
                )
                _ = PlannerSessionRunStateBridge.observe(
                    sessionId: surface.sessionId,
                    purpose: spawnReq.purpose,
                    status: .active
                )
                autoSpawnStarted += 1
                NSLog("[ENG-2][auto-spawn] node=\(autoNodeId) cwd=\(spawnReq.cwd) surface=\(surface.surfaceId) background=true")
            } catch {
                autoSpawnFailed.append("\(autoNodeId): \(error.localizedDescription)")
                NSLog("[ENG-2][auto-spawn] intent failed node=\(autoNodeId) err=\(error.localizedDescription)")
            }
        }
        var parts = ["Auto-started \(autoSpawnStarted) downstream session\(autoSpawnStarted == 1 ? "" : "s")."]
        if !autoSpawnSkipped.isEmpty {
            parts.append("Skipped \(autoSpawnSkipped.count): \(autoSpawnSkipped.joined(separator: "; ")).")
        }
        if !autoSpawnFailed.isEmpty {
            parts.append("Failed \(autoSpawnFailed.count): \(autoSpawnFailed.joined(separator: "; ")).")
        }
        result.hint = [result.hint, parts.joined(separator: " ")]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")
        NSLog("[ENG-2][auto-spawn] summary canvas=\(canvasId) candidates=\(autoIds.count) started=\(autoSpawnStarted) skipped=\(autoSpawnSkipped.count) failed=\(autoSpawnFailed.count)")
    }

    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func deliverMatchedSpawnPrompts(_ matches: [BoardLayoutStore.MatchedSpawnIntent]) {
        for match in matches {
            // Phase 2 — runState 回流: a spawn intent tagged `planner:<stepId>`
            // has just matched a real session. Bind that session id onto the
            // step's session PlanningNode and seed its run state. This is the
            // only point where the step→sessionId link is known directly.
            if let record = PlannerSessionRunStateBridge.observe(
                sessionId: match.sessionId,
                purpose: match.intent.purpose,
                status: .active
            ) {
                MLog("[BoardAPI] bound planner session sid=\(match.sessionId.prefix(8)) purpose=\(match.intent.purpose ?? "-") canvas=\(record.canvas.id)")
            }
            guard let prompt = match.intent.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else { continue }
            do {
                let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: match.sessionId)
                _ = try MessageRouter.shared.send(
                    channel: channelName,
                    fromAlias: "operator",
                    toAlias: "session",
                    content: prompt,
                    injectedByHuman: true
                )
            } catch {
                MWarn("[BoardAPI] failed to inject spawn initial prompt sid=\(match.sessionId.prefix(8)): \(error)")
            }
        }
    }

    /// Phase 2 — runState 回流: on every state poll, push the current status of
    /// each live session into the planner graph. `observeBound` is keyed by
    /// `sessionId` and no-ops for any session that is not a bound planner
    /// session node, so this is cheap for the common (non-planner) case.
    private static func feedPlannerSessionRunStates(_ sessions: [SessionDTO]) {
        for session in sessions {
            let status = effectiveSessionStatus(for: session)
            let boundRecord = PlannerSessionRunStateBridge.observeBound(
                sessionId: session.id,
                status: status
            )
            if boundRecord != nil {
                syncPlannerSessionOutputArtifacts(sessionId: session.id)
            }
        }
    }

    /// Derive the *interaction* status fed to the planner mirror from the full
    /// DTO — not just the coarse `status` string.
    ///
    /// Root cause this guards against: a bound session can have a permission
    /// prompt pending (`pendingPermissionTool` set) while its resolved `status`
    /// string still reads as a working state (e.g. `.active`/`.thinking` — a
    /// fresh-assistant transcript tail resolves to `.active` "mid-turn"). This
    /// is especially common for ghostty/EXTERNAL sessions, where the
    /// permission/idle-waiting state is carried in `pendingPermissionTool`
    /// rather than baked into the coarse status. `feedPlannerSessionRunStates`
    /// previously read `status` only, so the node stayed `running` ("运行中")
    /// while the session was actually blocked on a human gate.
    ///
    /// Precedence:
    /// 1. A pending permission prompt (`pendingPermissionTool` non-empty)
    ///    dominates → `.permissionRequired` → node `gateWait` (待审核/等反馈),
    ///    regardless of the coarse status. A real permission gate is the
    ///    strongest "ball is in the human's court" signal.
    /// 2. Otherwise fall back to the resolver's `status` mapping, which already
    ///    expresses `.waitingForUser` (Claude finished, waiting on the user) →
    ///    `.awaitingInput` and the working states → `.running`.
    static func effectiveSessionStatus(for session: SessionDTO) -> SessionStatus {
        let baseStatus = SessionStatus.from(rawString: session.status)
        if let pendingTool = session.pendingPermissionTool?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pendingTool.isEmpty {
            return .permissionRequired
        }
        return baseStatus
    }

    private static func syncPlannerSessionOutputArtifacts(sessionId: String? = nil, canvasId: String? = nil) {
        if let sessionId,
           (SessionStore.shared.get(sessionId)?.transcriptPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let snapshot = BoardLayoutStore.shared.snapshot()
        let canvases = snapshot.canvases.filter { canvasId == nil || $0.id == canvasId }
        for canvas in canvases {
            guard let state = try? PlannerBoardBridge.canvasState(
                for: canvas.id,
                snapshot: snapshot,
                actorUserId: PlannerPermission.currentActorId()
            ) else { continue }
            for node in state.nodes where (node.nodeKind ?? .step) == .step {
                guard let boundSessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !boundSessionId.isEmpty,
                      sessionId == nil || sessionId == boundSessionId else { continue }
                syncPlannerSessionOutputArtifact(canvasId: canvas.id, node: node, sessionId: boundSessionId, existingArtifacts: state.artifacts)
            }
        }
    }

    private static func syncPlannerSessionOutputArtifact(
        canvasId: String,
        node: PlanningNode,
        sessionId: String,
        existingArtifacts: [PlannerArtifact]
    ) {
        let outputRefs = node.schema.outputs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !outputRefs.isEmpty else { return }
        guard let transcriptPath = SessionStore.shared.get(sessionId)?.transcriptPath else { return }
        let entries = FullTranscriptReader.readTail(transcriptPath: transcriptPath, limit: 12)
        guard let latestText = latestVisibleAssistantText(entries) else { return }

        if let kanbanRef = outputRefs.first(where: { $0.localizedCaseInsensitiveContains("kanban") }),
           !hasExistingFallbackArtifact(nodeId: node.id, outputRef: kanbanRef, artifacts: existingArtifacts),
           let payload = kanbanPayloadFromMarkdownTable(latestText) {
            submitFallbackSessionArtifact(
                canvasId: canvasId,
                node: node,
                outputRef: kanbanRef,
                kind: .kanban,
                payload: payload,
                summary: "Extracted \(kanbanItemCount(payload)) item(s) into \(kanbanRef)."
            )
            return
        }

        guard let outputRef = outputRefs.first(where: { !$0.localizedCaseInsensitiveContains("kanban") })
                ?? outputRefs.first,
              !hasExistingFallbackArtifact(nodeId: node.id, outputRef: outputRef, artifacts: existingArtifacts),
              let payload = genericSessionArtifactPayload(from: latestText, outputRef: outputRef) else { return }
        submitFallbackSessionArtifact(
            canvasId: canvasId,
            node: node,
            outputRef: outputRef,
            kind: .generic,
            payload: payload,
            summary: "Captured terminal completion text into \(outputRef)."
        )
    }

    private static func submitFallbackSessionArtifact(
        canvasId: String,
        node: PlanningNode,
        outputRef: String,
        kind: PlannerArtifactKind,
        payload: BoardJSONValue,
        summary: String
    ) {
        let artifact = PlannerNodeOutputArtifact(
            kind: kind,
            title: outputRef.replacingOccurrences(of: "_", with: " ").capitalized,
            reference: outputRef,
            payload: payload,
            routeTo: []
        )
        let output = PlannerNodeOutput(
            nodeId: node.id,
            status: .done,
            message: PlannerNodeOutputMessage(summary: summary, routeTo: []),
            artifacts: [artifact],
            next: .complete
        )
        do {
            let result = try PlannerBoardBridge.submitNodeOutput(
                nodeId: node.id,
                output: output,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            routePlannerOutputMessages(result.routes)
            BoardServer.shared.broadcastStateChanged()
        } catch {
            MWarn("[PlannerArtifactSync] fallback sync failed canvas=\(canvasId) node=\(node.id): \(error.localizedDescription)")
        }
    }

    private static func hasExistingFallbackArtifact(
        nodeId: String,
        outputRef: String,
        artifacts: [PlannerArtifact]
    ) -> Bool {
        artifacts.contains { artifact in
            guard artifact.nodeId == nodeId else { return false }
            return artifact.reference == outputRef
                || artifact.reference.caseInsensitiveCompare(outputRef) == .orderedSame
                || artifact.title.caseInsensitiveCompare(outputRef) == .orderedSame
        }
    }

    private static func latestVisibleAssistantText(_ entries: [FullTranscriptEntry]) -> String? {
        for entry in entries.reversed() where entry.type == "assistant" {
            let text = entry.blocks
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !looksLikeLocalCommandEcho($0) }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func looksLikeLocalCommandEcho(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("$ ")
            || trimmed.hasPrefix("❯ ")
            || trimmed.hasPrefix("> ")
            || trimmed.localizedCaseInsensitiveContains("Bash(")
            || trimmed.localizedCaseInsensitiveContains("Read(")
    }

    private static func kanbanPayloadFromMarkdownTable(_ text: String) -> BoardJSONValue? {
        let rows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("|") && $0.hasSuffix("|") }
            .map { line in
                line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        guard rows.count >= 2 else { return nil }
        let header = rows[0].map { $0.lowercased() }
        let bodyRows = rows.dropFirst().filter { row in
            !row.allSatisfy { cell in
                let stripped = cell.replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty
            }
        }
        let titleIndex = header.firstIndex(where: { $0.contains("idea") || $0.contains("title") || $0.contains("name") }) ?? min(1, max(header.count - 1, 0))
        let statusIndex = header.firstIndex(where: { $0.contains("status") })
        let notesIndex = header.firstIndex(where: { $0.contains("note") || $0.contains("description") || $0.contains("summary") })
        var columnsById: [String: String] = [:]
        var items: [BoardJSONValue] = []
        for (index, row) in bodyRows.enumerated() {
            guard row.indices.contains(titleIndex) else { continue }
            let title = row[titleIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let status = statusIndex.flatMap { row.indices.contains($0) ? row[$0] : nil }?
                .replacingOccurrences(of: "📋", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let columnTitle = status?.isEmpty == false ? status! : "Backlog"
            let columnId = slug(columnTitle)
            columnsById[columnId] = columnTitle
            var item: [String: BoardJSONValue] = [
                "id": .string("item-\(index + 1)"),
                "columnId": .string(columnId),
                "title": .string(title),
                "subCanvasId": .null
            ]
            if let notes = notesIndex.flatMap({ row.indices.contains($0) ? row[$0] : nil })?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty, notes != "-" {
                item["description"] = .string(notes)
            }
            items.append(.object(item))
        }
        guard !items.isEmpty else { return nil }
        let columns: [BoardJSONValue] = columnsById
            .sorted { $0.value < $1.value }
            .map { BoardJSONValue.object(["id": .string($0.key), "title": .string($0.value)]) }
        return .object([
            "type": .string("kanban"),
            "version": .number(1),
            "columns": .array(columns),
            "items": .array(items)
        ])
    }

    private static func kanbanItemCount(_ payload: BoardJSONValue) -> Int {
        guard let items = payload.objectValue?["items"],
              case .array(let values) = items else { return 0 }
        return values.count
    }

    static func genericSessionArtifactPayload(from text: String, outputRef: String) -> BoardJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return nil }
        let html = fencedCodeBlock(in: trimmed, languageHints: ["html", "htm"]) ?? (looksLikeHTML(trimmed) ? trimmed : nil)
        let json = fencedCodeBlock(in: trimmed, languageHints: ["json"]) ?? (looksLikeJSONObject(trimmed) ? trimmed : nil)
        let outputHint = outputRef.lowercased()
        let final = looksLikeFinalSessionOutput(trimmed, outputRef: outputRef)
        if outputHint.contains("html") || html != nil {
            guard let html = html ?? extractHTMLFragment(from: trimmed), final || looksLikeHTML(html) else { return nil }
            return .object([
                "type": .string(PlannerArtifactPayloadType.html.rawValue),
                "html": .string(html)
            ])
        }
        if outputHint.contains("json") || json != nil {
            guard let json = json, final || looksLikeJSONObject(json) else { return nil }
            return .object([
                "type": .string(PlannerArtifactPayloadType.json.rawValue),
                "json": .string(json)
            ])
        }
        guard final else { return nil }
        return .object([
            "type": .string(PlannerArtifactPayloadType.text.rawValue),
            "text": .string(trimmed)
        ])
    }

    private static func looksLikeFinalSessionOutput(_ text: String, outputRef: String) -> Bool {
        let lower = text.lowercased()
        let ref = outputRef.lowercased()
        let finalMarkers = [
            "final", "deliverable", "artifact", "output", "result", "completed",
            "ready", "here is", "below is", "summary", "report", "prd", "brief",
            "最终", "产物", "交付", "输出", "结果", "完成", "已完成", "验收", "总结", "如下"
        ]
        let outputHints = [
            "text", "markdown", "doc", "prd", "brief", "summary", "report",
            "copy", "content", "page", "html", "json", "check", "result", "verdict"
        ]
        if finalMarkers.contains(where: { lower.contains($0) }) { return true }
        if outputHints.contains(where: { ref.contains($0) }) && !looksLikeFollowupQuestion(text) { return true }
        return false
    }

    private static func looksLikeFollowupQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let hasQuestionTone = trimmed.hasSuffix("?")
            || trimmed.hasSuffix("？")
            || lower.contains("which ")
            || lower.contains("what ")
            || lower.contains("should i")
            || lower.contains("need ")
            || lower.contains("需要")
            || lower.contains("哪个")
            || lower.contains("是否")
            || lower.contains("吗")
        let hasDeliveryMarker = ["final", "deliverable", "artifact", "产物", "交付", "最终"].contains { lower.contains($0) }
        return hasQuestionTone && !hasDeliveryMarker
    }

    private static func fencedCodeBlock(in text: String, languageHints: [String]) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var capturing = false
        var captured: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !capturing {
                guard trimmed.hasPrefix("```") else { continue }
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if languageHints.contains(where: { language.contains($0) }) {
                    capturing = true
                    captured.removeAll()
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                let body = captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : body
            }
            captured.append(line)
        }
        return nil
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<!doctype html")
            || lower.contains("<html")
            || lower.contains("<body")
            || lower.contains("<section")
            || lower.contains("<main")
    }

    private static func extractHTMLFragment(from text: String) -> String? {
        guard looksLikeHTML(text) else { return nil }
        if let start = text.range(of: "<!doctype", options: [.caseInsensitive])?.lowerBound
            ?? text.range(of: "<html", options: [.caseInsensitive])?.lowerBound
            ?? text.range(of: "<body", options: [.caseInsensitive])?.lowerBound
            ?? text.range(of: "<main", options: [.caseInsensitive])?.lowerBound
            ?? text.range(of: "<section", options: [.caseInsensitive])?.lowerBound {
            return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func looksLikeJSONObject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }

    private static func slug(_ raw: String) -> String {
        let normalized = raw
            .lowercased()
            .map { char in char.isLetter || char.isNumber ? char : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "backlog" : normalized
    }

    // MARK: - Coordination groups

    static func listCoordinationGroups(_ req: HttpRequest) -> HttpResponse {
        jsonResponse(CoordinationGroupsEnvelope(
            groups: CoordinationStore.shared.snapshot().map(BoardDTOBuilder.coordinationGroupDTO)
        ))
    }

    static func syncCoordinationGroup(_ req: HttpRequest) -> HttpResponse {
        guard let groupId = req.params[":id"], !groupId.isEmpty else {
            return errorResponse("bad_request", "missing coordination group id", status: 400)
        }
        do {
            try CoordinationWatcher.shared.syncNow(groupId: groupId)
            let group = try CoordinationStore.shared.group(id: groupId)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CoordinationGroupEnvelope(group: BoardDTOBuilder.coordinationGroupDTO(group)))
        } catch {
            return errorResponse("coordination_error", error.localizedDescription, status: 400)
        }
    }

    static func askCoordinationGroup(_ req: HttpRequest) -> HttpResponse {
        guard let groupId = req.params[":id"], !groupId.isEmpty else {
            return errorResponse("bad_request", "missing coordination group id", status: 400)
        }
        let body = parseJSONBody(req) ?? [:]
        let reason = (body["reason"] as? String) ?? "manual Ask coordinator"
        do {
            try CoordinationStore.shared.manualAsk(groupId: groupId, reason: reason)
            let group = try CoordinationStore.shared.group(id: groupId)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CoordinationGroupEnvelope(group: BoardDTOBuilder.coordinationGroupDTO(group)))
        } catch {
            return errorResponse("coordination_error", error.localizedDescription, status: 400)
        }
    }

    static func pauseCoordinationGroup(_ req: HttpRequest) -> HttpResponse {
        setCoordinationPaused(req, paused: true)
    }

    static func resumeCoordinationGroup(_ req: HttpRequest) -> HttpResponse {
        setCoordinationPaused(req, paused: false)
    }

    private static func setCoordinationPaused(_ req: HttpRequest, paused: Bool) -> HttpResponse {
        guard let groupId = req.params[":id"], !groupId.isEmpty else {
            return errorResponse("bad_request", "missing coordination group id", status: 400)
        }
        do {
            let group = try CoordinationStore.shared.setPaused(groupId: groupId, paused: paused)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CoordinationGroupEnvelope(group: BoardDTOBuilder.coordinationGroupDTO(group)))
        } catch {
            return errorResponse("coordination_error", error.localizedDescription, status: 400)
        }
    }

    static func removeCoordinationMember(_ req: HttpRequest) -> HttpResponse {
        guard let groupId = req.params[":id"], !groupId.isEmpty,
              let sessionId = req.params[":sessionId"], !sessionId.isEmpty else {
            return errorResponse("bad_request", "missing coordination group id or session id", status: 400)
        }
        do {
            let group = try CoordinationStore.shared.removeMember(groupId: groupId, sessionId: sessionId)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CoordinationGroupEnvelope(group: BoardDTOBuilder.coordinationGroupDTO(group)))
        } catch {
            return errorResponse("coordination_error", error.localizedDescription, status: 400)
        }
    }

    // MARK: - Planner core

    static func getPlannerCanvasState(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            reconcilePlannerRunState(canvasId: canvasId)
            syncPlannerSessionOutputArtifacts(canvasId: canvasId)
            let state = try PlannerBoardBridge.canvasState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerCanvasStateEnvelope(
                canvas: state.canvas,
                nodes: state.nodes,
                states: state.states,
                proposals: state.proposals,
                access: state.access,
                activities: state.activities,
                events: state.events,
                artifacts: state.artifacts,
                edges: state.edges
            ))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func getPlannerGraphState(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        return BoardPerfProbe.shared.measure(
            "api.planner.graph",
            title: "GET /planner/:id/graph",
            category: "api",
            detail: "canvas=\(String(canvasId.prefix(24)))"
        ) {
            do {
                reconcilePlannerRunState(canvasId: canvasId)
                syncPlannerSessionOutputArtifacts(canvasId: canvasId)
                let state = try PlannerBoardBridge.graphState(
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: PlannerPermission.currentActorId()
                )
                return jsonResponse(graphEnvelope(state))
            } catch let err as PlannerCoreError {
                return mapPlannerCoreError(err)
            } catch {
                return errorResponse("planner_error", error.localizedDescription, status: 400)
            }
        }
    }

    private struct RenderValuesPatchRequest: Decodable {
        let objects: [String: CanvasRenderObjectValues]?
        let relations: [String: CanvasRenderRelationValues]?
        let renderOnlyObjects: [CanvasObject]?
    }

    static func patchCanvasRenderValues(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: RenderValuesPatchRequest.self) else {
            return errorResponse("invalid_json", "body must be a render values patch", status: 400)
        }
        do {
            _ = try PlannerBoardBridge.store.patchRenderValues(
                canvasId: canvasId,
                objectValues: body.objects ?? [:],
                relationValues: body.relations ?? [:],
                renderOnlyObjects: body.renderOnlyObjects
            )
            let state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func revealCanvasRenderProfile(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            _ = try PlannerBoardBridge.store.renderProfileState(canvasId: canvasId)
            let path = PlannerBoardBridge.store.renderProfilePath(canvasId: canvasId)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return jsonResponse(["path": path])
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// Integration-entity pool for `external` widgets.
    ///
    /// 设计原则(2026-05-29):integration 层只做 schema 定义 + view 渲染,真实数据由
    /// AI session(GitHub / Lark 等 MCP 工具)产出并 attach 成 artifact。前端 view 层
    /// 直接从已 attach 的 artifact 派生 IntegrationEntity(见
    /// `integrations/artifactEntity.ts` + `plannerGraphAdapter`),后端不再伪造样本
    /// 数据。`artifacts` 字段已随 envelope 下发,故此处返回 nil。
    private static func integrationEntitiesFor(nodes: [PlanningNode]) -> [IntegrationEntityDTO]? {
        nil
    }

    /// POST /api/planner/canvases/:id/clear
    ///
    /// Owner-only. Clears the planner graph content for the canvas but keeps
    /// the canvas container and unrelated sessions intact.
    static func clearPlannerCanvasContent(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.clearCanvasContent(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// PATCH /api/planner/canvases/:id/visibility
    ///
    /// Owner-only. Body: `{"visibility": "public" | "private"}`.
    static func setPlannerCanvasVisibility(_ req: HttpRequest) -> HttpResponse {
        struct VisibilityRequest: Decodable {
            let visibility: PlannerCanvasVisibility
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: VisibilityRequest.self) else {
            return errorResponse(
                "invalid_json",
                "body must be {\"visibility\": \"public\"|\"private\"}",
                status: 400
            )
        }
        let settings = OnlineProxy.loadSettings()
        let actorUserId = settings.userId.isEmpty ? PlannerPermission.currentActorId() : settings.userId
        let nextScope: BoardLayoutStore.CanvasScope = body.visibility == .public ? .team : .personal
        let snapshot = BoardLayoutStore.shared.snapshot()
        guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            return errorResponse("not_found", "canvas not found", status: 404)
        }
        guard boardCanvas.scope == .team else {
            return errorResponse("conflict", "publish this canvas to Team before assigning nodes", status: 409)
        }
        guard !boardCanvas.isDefault else {
            return errorResponse("forbidden", "default canvas cannot be published", status: 403)
        }
        if nextScope == .team && settings.teamId.isEmpty {
            return errorResponse("not_connected", "meee2-online not configured (missing teamId)", status: 412)
        }
        do {
            let canvas = try PlannerBoardBridge.setCanvasVisibility(
                body.visibility,
                for: canvasId,
                snapshot: snapshot,
                actorUserId: actorUserId
            )
            _ = try BoardLayoutStore.shared.setCanvasScope(id: canvasId, scope: nextScope)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(PlannerCanvasVisibilityEnvelope(canvas: canvas))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// PATCH /api/planner/canvases/:id/description
    ///
    /// Owner-only. Body: `{"description": "..."}`
    static func setPlannerCanvasDescription(_ req: HttpRequest) -> HttpResponse {
        struct DescriptionRequest: Decodable {
            let description: String
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: DescriptionRequest.self) else {
            return errorResponse(
                "invalid_json",
                "body must be {\"description\": string}",
                status: 400
            )
        }
        do {
            let canvas = try PlannerBoardBridge.setCanvasDescription(
                body.description,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(PlannerCanvasVisibilityEnvelope(canvas: canvas))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func getPlannerWorkspaceMonitor(_ req: HttpRequest) -> HttpResponse {
        do {
            let monitor = try PlannerBoardBridge.workspaceMonitor(
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId(),
                sessions: BoardSessionSnapshotProvider.currentBoardSessions()
            )
            return jsonResponse(PlannerMonitorEnvelope(
                generatedAt: monitor.generatedAt,
                items: monitor.items
            ))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func updatePlannerActivity(_ req: HttpRequest) -> HttpResponse {
        struct ActivityRequest: Decodable {
            let canvasId: String
            let selectedNodeId: String?
            let selectedSessionId: String?
        }

        guard let body = decodeJSONBody(req, as: ActivityRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"canvasId\": String}", status: 400)
        }
        let canvasId = body.canvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            let activity = try PlannerBoardBridge.recordActivity(
                canvasId: canvasId,
                selectedNodeId: body.selectedNodeId,
                selectedSessionId: body.selectedSessionId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerActivityEnvelope(activity: activity))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    // MARK: - Run layer (P1)

    /// POST /api/planner/canvases/:id/runs — start a new workflow run.
    static func startPlannerRun(_ req: HttpRequest) -> HttpResponse {
        struct StartRunRequest: Decodable {
            let title: String?
            let summary: String?
            let responsibleUserId: String?
            let linkedArtifactRefs: [String]?
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        let body = decodeJSONBody(req, as: StartRunRequest.self)
        let title = body?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title?.isEmpty != true else {
            return errorResponse("bad_request", "delivery title is required", status: 400)
        }
        do {
            let run = try PlannerBoardBridge.startRun(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId(),
                title: title,
                summary: body?.summary,
                responsibleUserId: body?.responsibleUserId,
                linkedArtifactRefs: body?.linkedArtifactRefs ?? []
            )
            return jsonResponse(WorkflowRunEnvelope(run: run))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// PATCH /api/planner/canvases/:id/deliveries/:deliveryId/nodes/:nodeId/assignee
    static func updatePlannerDeliveryNodeAssignee(_ req: HttpRequest) -> HttpResponse {
        struct AssigneeRequest: Decodable {
            let assigneeId: String?
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let deliveryId = req.params[":deliveryId"], !deliveryId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas, delivery, or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: AssigneeRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"assigneeId\": String?}", status: 400)
        }
        do {
            let run = try PlannerBoardBridge.updateRunNodeAssignee(
                runId: deliveryId,
                nodeId: nodeId,
                assigneeId: body.assigneeId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(WorkflowRunEnvelope(run: run))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// GET /api/planner/canvases/:id/runs — run history for a canvas.
    static func listPlannerRuns(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            let runs = try PlannerBoardBridge.runs(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(WorkflowRunsEnvelope(runs: runs))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// GET /api/planner/runs/:runId — a single run's full execution state.
    static func getPlannerRun(_ req: HttpRequest) -> HttpResponse {
        guard let runId = req.params[":runId"], !runId.isEmpty else {
            return errorResponse("bad_request", "missing run id", status: 400)
        }
        do {
            let run = try PlannerBoardBridge.run(runId: runId)
            return jsonResponse(WorkflowRunEnvelope(run: run))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/planner/runs/:runId/abort — human-terminate a run.
    static func abortPlannerRun(_ req: HttpRequest) -> HttpResponse {
        guard let runId = req.params[":runId"], !runId.isEmpty else {
            return errorResponse("bad_request", "missing run id", status: 400)
        }
        do {
            let run = try PlannerBoardBridge.abortRun(runId: runId)
            return jsonResponse(WorkflowRunEnvelope(run: run))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func generatePlannerProposal(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let goal = (json["goal"] as? String) ?? ""
        let snapshot = BoardLayoutStore.shared.snapshot()
        let actorUserId = PlannerPermission.currentActorId()
        let settings = AssistantAPI.parseSettings(json["settings"] as? [String: Any])
            .withCanvasDefaults(canvasId: canvasId)

        do {
            // Phase 8: route through the swappable planner agent runtime
            // (PlannerAgentRuntimeRegistry.shared) as a `.userGoal` event,
            // instead of calling the adapter directly. The runtime
            // output is validated again by saveAdapterProposal before it can
            // touch the store, so a swapped-in runtime is still untrusted.
            let context = json["context"] as? String
            if let proposal = try runPlannerRuntimeProposal(
                event: .userGoal(canvasId: canvasId, goal: goal, context: context),
                canvasId: canvasId,
                settings: settings,
                snapshot: snapshot,
                actorUserId: actorUserId
            ) {
                MLog("[Planner] generatePlannerProposal canvas=\(canvasId) path=runtime provider=\(settings.provider.rawValue)")
                return jsonResponse(
                    PlannerProposalEnvelope(proposal: proposal),
                    status: 201,
                    reason: "Created"
                )
            }
            return errorResponse(
                "planner_no_proposal",
                "Planner runtime returned no proposal. No local plan was generated.",
                status: 409
            )
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch let err as PlannerRuntimeError {
            return errorResponse("planner_runtime_unavailable", err.localizedDescription, status: 503)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// Run the planner agent runtime synchronously (the HTTP handler is sync)
    /// for a proposal-producing event, persist the first proposal, and return
    /// it. Returns `nil` only when the runtime returned no proposal (e.g. a
    /// healthy graph on `.driftInspection`). Runtime/provider failures are
    /// surfaced as errors so callers do not create local fallback plans.
    ///
    /// `internal` so the integration recommend-workflow endpoint can reuse it
    /// without duplicating the runtime + save pipeline.
    static func runPlannerRuntimeProposal(
        event: PlannerAgentEvent,
        canvasId: String,
        settings: AssistantSettings,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String?
    ) throws -> PlanProposal? {
        let state = try PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: snapshot,
            actorUserId: actorUserId
        )

        let runtime = PlannerAgentRuntimeRegistry.shared
        let group = DispatchGroup()
        group.enter()
        var outcome: PlannerAgentOutcome?
        var runtimeError: Error?
        Task.detached {
            do {
                outcome = try await runtime.handle(event, state: state, settings: settings)
            } catch {
                runtimeError = error
            }
            group.leave()
        }
        if group.wait(timeout: .now() + 120) == .timedOut {
            MWarn("[Planner] planner runtime timed out for canvas=\(canvasId)")
            throw PlannerRuntimeError.timedOut(canvasId: canvasId)
        }

        if let runtimeError {
            // Validation / RBAC failures are real client errors — surface them.
            if let coreError = runtimeError as? PlannerCoreError {
                throw coreError
            }
            // Runtime infrastructure/provider errors are surfaced. A proposal
            // without the adapter/LLM is not useful.
            MWarn("[Planner] planner runtime errored for canvas=\(canvasId): \(runtimeError.localizedDescription)")
            throw PlannerRuntimeError.failed(canvasId: canvasId, underlying: runtimeError)
        }
        guard let outcome else { return nil }
        guard let proposal = outcome.proposals.first else {
            // Runtime decided no action was needed (e.g. healthy graph).
            MLog("[Planner] planner runtime no-action for canvas=\(canvasId): \(outcome.noActionReason ?? "(no reason)")")
            return nil
        }

        // The runtime is untrusted: re-run full RBAC + validation against the
        // live canvas state before the proposal can be persisted.
        return try PlannerBoardBridge.saveAdapterProposal(
            proposal,
            for: canvasId,
            snapshot: snapshot,
            actorUserId: actorUserId
        )
    }

    static func inspectPlannerDrift(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        let snapshot = BoardLayoutStore.shared.snapshot()
        let actorUserId = PlannerPermission.currentActorId()
        let settings = AssistantAPI.parseSettings(nil)
            .withCanvasDefaults(canvasId: canvasId)
        do {
            // Phase 8: route the drift endpoint through the planner agent
            // runtime as a `.driftInspection` event. A healthy graph yields a
            // nil proposal (same response shape the old driftProposal had).
            let proposal = try runPlannerRuntimeProposal(
                event: .driftInspection(canvasId: canvasId),
                canvasId: canvasId,
                settings: settings,
                snapshot: snapshot,
                actorUserId: actorUserId
            )
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch let err as PlannerRuntimeError {
            return errorResponse("planner_runtime_unavailable", err.localizedDescription, status: 503)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func refinePlannerProposal(_ req: HttpRequest) -> HttpResponse {
        struct RefineRequest: Decodable {
            let nodeId: String
            let reason: String?
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: RefineRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"nodeId\": String, \"reason\": String}", status: 400)
        }
        let nodeId = body.nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing node id", status: 400)
        }
        do {
            let proposal = try PlannerBoardBridge.refineProposal(
                nodeId: nodeId,
                reason: body.reason ?? "",
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// ENG-2 bonus: clean engine path for "refine bound session prompt".
    /// Builds a `refineSessionPrompt` proposal (no schema change), persists
    /// it, and pipes the directive to the node's bound session via the
    /// existing operator-channel inject path so behaviour matches the
    /// ENG-5 workaround but is now first-class / auditable.
    ///
    /// Body: `{"nodeId": String, "directive": String}`
    /// Response: 201 `{"proposal": PlanProposal, "sessionId": String?,
    ///                  "delivered": Bool}`
    static func refineSessionPromptProposal(_ req: HttpRequest) -> HttpResponse {
        struct RefineSessionPromptRequest: Decodable {
            let nodeId: String
            let directive: String?
        }
        struct RefineSessionPromptResponse: Encodable {
            let proposal: PlanProposal
            let sessionId: String?
            let delivered: Bool
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: RefineSessionPromptRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"nodeId\": String, \"directive\": String}", status: 400)
        }
        let nodeId = body.nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing node id", status: 400)
        }
        let directive = body.directive ?? ""
        do {
            let (proposal, sessionId) = try PlannerBoardBridge.refineSessionPromptProposal(
                nodeId: nodeId,
                directive: directive,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            var delivered = false
            if let sid = sessionId,
               let session = resolvePluginSession(sid),
               !directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let targetSessionId = inboxSessionId(for: session)
                do {
                    let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: targetSessionId)
                    _ = try MessageRouter.shared.send(
                        channel: channelName,
                        fromAlias: "operator",
                        toAlias: "session",
                        content: directive,
                        injectedByHuman: true
                    )
                    delivered = true
                    NSLog("[ENG-2][refine-session-prompt] sid=\(targetSessionId.prefix(8)) directive_len=\(directive.count)")
                } catch {
                    NSLog("[ENG-2][refine-session-prompt] inject failed sid=\(sid.prefix(8)) err=\(error.localizedDescription)")
                }
            }
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(
                RefineSessionPromptResponse(proposal: proposal, sessionId: sessionId, delivered: delivered),
                status: 201,
                reason: "Created"
            )
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func applyPlannerProposalPreview(_ req: HttpRequest) -> HttpResponse {
        struct ApplyRequest: Decodable {
            let proposal: PlanProposal
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: ApplyRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"proposal\": PlanProposal}", status: 400)
        }
        do {
            let preview = try PlannerBoardBridge.applyPreview(
                proposal: body.proposal,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerApplyPreviewEnvelope(
                proposal: preview.proposal,
                nodes: preview.nodes,
                states: preview.states,
                edges: preview.edges,
                artifacts: preview.artifacts
            ))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func proposePlannerGraphChange(_ req: HttpRequest) -> HttpResponse {
        struct GraphChangeRequest: Decodable {
            let summary: String?
            let changes: [PlanChange]
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: GraphChangeRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"changes\": [PlanChange]}", status: 400)
        }
        do {
            let proposal = try PlannerBoardBridge.graphChangeProposal(
                summary: body.summary ?? "Update meee2 AI graph",
                changes: body.changes,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func createPlannerDeliveryPipeline(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            let proposal = try PlannerBoardBridge.deliveryPipelineProposal(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func bindPlannerSessionToNode(_ req: HttpRequest) -> HttpResponse {
        struct BindSessionRequest: Decodable {
            let sessionId: String
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: BindSessionRequest.self),
              !body.sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorResponse("invalid_json", "body must be {\"sessionId\": String}", status: 400)
        }
        do {
            // bind-session is an EXECUTION-LAYER action — it applies DIRECTLY,
            // no proposal / owner approval. Returns the updated graph state.
            let state = try PlannerBoardBridge.bindSession(
                nodeId: nodeId,
                sessionId: body.sessionId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func dispatchPlannerNodeSession(_ req: HttpRequest) -> HttpResponse {
        struct DispatchRequest: Decodable {
            let runner: PlannerDispatchRunner?
            let cwd: String?
            let initialPrompt: String?
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        let body = decodeJSONBody(req, as: DispatchRequest.self)
        do {
            // dispatch is an EXECUTION-LAYER action — it applies DIRECTLY,
            // no proposal / owner approval. Sets dispatch + run state, spawns
            // the session node, and records the spawn intent right here.
            let result = try PlannerBoardBridge.dispatchNode(
                nodeId: nodeId,
                runner: body?.runner ?? .claude,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            let spawnRequest = try recordPlannerDispatchIntent(
                canvasId: canvasId,
                node: result.dispatchedNode,
                cwdOverride: body?.cwd,
                initialPromptOverride: body?.initialPrompt,
                includeInitialPromptInIntent: false
            )
            if let spawnRequest {
                do {
                    let surface = try createInternalSessionSurface(
                        provider: spawnRequest.provider,
                        cwd: spawnRequest.cwd,
                        command: spawnRequest.command,
                        createIfMissing: true,
                        canvasId: canvasId,
                        nodeId: nodeId,
                        initialPrompt: spawnRequest.initialPrompt
                    )
                    _ = PlannerSessionRunStateBridge.observe(
                        sessionId: surface.sessionId,
                        purpose: spawnRequest.purpose,
                        status: .active
                    )
                } catch {
                    return errorResponse("spawn_failed", error.localizedDescription, status: 500)
                }
            }
            BoardServer.shared.broadcastStateChanged()
            let state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func ensurePlannerNodeInternalSession(_ req: HttpRequest) -> HttpResponse {
        struct EnsureRequest: Decodable {
            let runner: PlannerDispatchRunner?
            let cwd: String?
            // BUG 1.2 — "打开进展" (open the bound session) passes `openOnly`.
            // In that mode a node whose bound session is no longer live must
            // NOT silently re-spawn a fresh session; we report it ended and let
            // the user re-dispatch. The create/replace flows leave this nil.
            let openOnly: Bool?
        }
        struct EnsureResponse: Encodable {
            let ok: Bool
            let sessionId: String
            let surfaceId: String
            let cwd: String
            let command: String
            let terminalKind: String
            // "native-workspace" for internal surfaces; stale or external
            // bindings are reported as session_ended instead of focused.
            let openTarget: String
            let action: String
            let graph: PlannerGraphStateEnvelope
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        let body = decodeJSONBody(req, as: EnsureRequest.self)
        do {
            var state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            guard let existingNode = state.nodes.first(where: { $0.id == nodeId }) else {
                return errorResponse("not_found", "node not found: \(nodeId)", status: 404)
            }

            let surface: TerminalSessionSnapshot
            var action = "reuse"
            if let sessionId = existingNode.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionId.isEmpty {
                if let existingSurface = TerminalSessionBackendRegistry.shared.snapshot(id: sessionId),
                   isReusableInternalSurface(existingSurface) {
                    // 绑定的会话还活着 → 直接复用并 focus（前端拿到 graph 后会
                    // dispatch meee2:open-session 把终端拉到前台）。
                    surface = existingSurface
                } else {
                    // 绑定的会话已死 → 自愈复活(见 reviveNodeSessionSurface)。
                    let revival = try reviveNodeSessionSurface(
                        canvasId: canvasId,
                        node: existingNode,
                        deadSessionId: sessionId,
                        explicitCwd: body?.cwd,
                        access: state.access
                    )
                    surface = revival.surface
                    action = revival.resumed ? "resume" : "recreate"
                    state = try PlannerBoardBridge.graphState(
                        for: canvasId,
                        snapshot: BoardLayoutStore.shared.snapshot(),
                        actorUserId: PlannerPermission.currentActorId()
                    )
                }
            } else {
                let result = try PlannerBoardBridge.dispatchNode(
                    nodeId: nodeId,
                    runner: body?.runner ?? .claude,
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: PlannerPermission.currentActorId()
                )
                guard let dispatchedNode = result.graph.nodes.first(where: { $0.id == nodeId }) else {
                    return errorResponse("not_found", "node not found after dispatch: \(nodeId)", status: 404)
                }
                guard let spawnRequest = try recordPlannerDispatchIntent(
                    canvasId: canvasId,
                    node: dispatchedNode,
                    cwdOverride: body?.cwd,
                    includeInitialPromptInIntent: false
                ) else {
                    return errorResponse("bad_request", "node runner does not create an internal session", status: 400)
                }
                surface = try createInternalSessionSurface(
                    provider: spawnRequest.provider,
                    cwd: spawnRequest.cwd,
                    command: spawnRequest.command,
                    createIfMissing: true,
                    canvasId: canvasId,
                    nodeId: nodeId,
                    initialPrompt: spawnRequest.initialPrompt
                )
                action = "create"
                _ = PlannerSessionRunStateBridge.observe(
                    sessionId: surface.sessionId,
                    purpose: spawnRequest.purpose,
                    status: .active
                )
                BoardServer.shared.broadcastStateChanged()
                state = try PlannerBoardBridge.graphState(
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: PlannerPermission.currentActorId()
                )
            }

            return jsonResponse(EnsureResponse(
                ok: true,
                sessionId: surface.sessionId,
                surfaceId: surface.surfaceId,
                cwd: surface.cwd,
                command: surface.command,
                terminalKind: "internal",
                openTarget: "native-workspace",
                action: action,
                graph: graphEnvelope(state)
            ), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("spawn_failed", error.localizedDescription, status: 500)
        }
    }

    private static func isReusableInternalSurface(_ surface: TerminalSessionSnapshot) -> Bool {
        surface.status == InternalTerminalLifecycle.starting.rawValue
            || surface.status == InternalTerminalLifecycle.running.rawValue
    }

    /// 死会话自愈(owner 决策 2026-06-01):能拿到 provider resume id 就
    /// `--resume` 找回原对话上下文;拿不到就在同 cwd fresh recreate(优雅降级)。
    /// recreate 出新 id 时把节点重绑到活 surface(allowReplace:死会话的
    /// runState 可能还停在 .running,不放行会被 hasActiveSession 拦成
    /// activeSessionExists、节点永久卡死)。任何需要节点会话活着的入口都走
    /// 同一条复活路径。
    private static func reviveNodeSessionSurface(
        canvasId: String,
        node: PlanningNode,
        deadSessionId: String,
        explicitCwd: String?,
        access: PlannerAccess
    ) throws -> (surface: TerminalSessionSnapshot, resumed: Bool, providerSessionId: String?) {
        try PlannerPermission.requireNodeUpdate(on: node, access: access)
        let cwd = try explicitSessionCwd(explicitCwd) ?? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
        let resumeSessionId = providerResumeSessionId(forPlannerSessionId: deadSessionId)
        let command = resumeSessionId.map {
            plannerResumeCommand(for: node, sessionId: $0)
        }
            ?? plannerFreshCommand(for: node)
        let canResume = resumeSessionId != nil
        let preferredSessionId = isProviderResumeSessionId(deadSessionId) || canResume ? deadSessionId : nil
        let provider = AgentLaunchCommand.provider(forCommand: command)
        let surface = try createInternalSessionSurface(
            provider: provider,
            cwd: cwd,
            command: command,
            createIfMissing: true,
            canvasId: canvasId,
            nodeId: node.id,
            // recreate 用 dispatch prompt 开场;resume 的对话已有上下文,不打扰。
            initialPrompt: canResume ? nil : plannerDispatchPrompt(for: node, canvasId: canvasId, cwd: cwd),
            preferredSessionId: preferredSessionId
        )
        if canResume {
            _ = PlannerSessionRunStateBridge.observeBound(
                sessionId: surface.sessionId,
                status: .active
            )
        } else {
            _ = PlannerSessionRunStateBridge.observe(
                sessionId: surface.sessionId,
                purpose: "planner:\(node.id)",
                status: .active
            )
        }
        if surface.sessionId != deadSessionId {
            _ = try PlannerBoardBridge.bindSession(
                nodeId: node.id,
                sessionId: surface.sessionId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId(),
                allowReplace: true
            )
        }
        BoardServer.shared.broadcastStateChanged()
        return (surface, canResume, resumeSessionId)
    }

    static func abandonPlannerNodeSession(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.abandonNodeSession(
                nodeId: nodeId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func detachPlannerNodeSession(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.detachNodeSession(
                nodeId: nodeId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func resumeClosedPlannerSessions(_ req: HttpRequest) -> HttpResponse {
        struct ResumeClosedSessionsRequest: Decodable {
            let sessionIds: [String]?
        }
        struct ResumedSession: Encodable {
            let sessionId: String
            let surfaceId: String
            let nodeIds: [String]
            let cwd: String
            let command: String
            let terminalKind: String
            let action: String
        }
        struct SkippedSession: Encodable {
            let sessionId: String
            let reason: String
        }
        struct ResumeClosedSessionsEnvelope: Encodable {
            let resumed: [ResumedSession]
            let skipped: [SkippedSession]
        }

        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        let body = decodeJSONBody(req, as: ResumeClosedSessionsRequest.self)
        let requestedSessionIds = Set((body?.sessionIds ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })

        do {
            let state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            let liveSessions = BoardSessionSnapshotProvider.currentBoardSessions()
            let grouped = Dictionary(grouping: state.nodes.compactMap { node -> (String, PlanningNode)? in
                guard let sessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sessionId.isEmpty else { return nil }
                guard requestedSessionIds.isEmpty || requestedSessionIds.contains(sessionId) else { return nil }
                guard plannerNodeNeedsLiveSession(node) else { return nil }
                guard !isPlannerSessionLive(sessionId, in: liveSessions) else { return nil }
                return (sessionId, node)
            }, by: { $0.0 })

            var resumed: [ResumedSession] = []
            var skipped: [SkippedSession] = []
            let cwd = try BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
            for (sessionId, entries) in grouped.sorted(by: { $0.key < $1.key }) {
                let nodes = entries.map(\.1)
                do {
                    for node in nodes {
                        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
                    }
                    let resumeSessionId = providerResumeSessionId(forPlannerSessionId: sessionId)
                    let command = resumeSessionId.map {
                        plannerResumeCommand(for: nodes.first, sessionId: $0)
                    }
                        ?? plannerFreshCommand(for: nodes.first)
                    let canResume = resumeSessionId != nil
                    let action = canResume ? "resume" : "recreate"
                    let preferredSessionId = isProviderResumeSessionId(sessionId) || canResume ? sessionId : nil
                    let provider = AgentLaunchCommand.provider(forCommand: command)
                    let surface = try createInternalSessionSurface(
                        provider: provider,
                        cwd: cwd,
                        command: command,
                        createIfMissing: true,
                        canvasId: canvasId,
                        nodeId: nodes.first?.id,
                        initialPrompt: canResume ? nil : nodes.first.map { plannerDispatchPrompt(for: $0, canvasId: canvasId, cwd: cwd) },
                        preferredSessionId: preferredSessionId
                    )
                    if canResume {
                        _ = PlannerSessionRunStateBridge.observeBound(
                            sessionId: surface.sessionId,
                            status: .active
                        )
                    } else {
                        for node in nodes {
                            _ = PlannerSessionRunStateBridge.observe(
                                sessionId: surface.sessionId,
                                purpose: "planner:\(node.id)",
                                status: .active
                            )
                        }
                    }
                    resumed.append(ResumedSession(
                        sessionId: surface.sessionId,
                        surfaceId: surface.surfaceId,
                        nodeIds: nodes.map(\.id),
                        cwd: surface.cwd,
                        command: surface.command,
                        terminalKind: "internal",
                        action: action
                    ))
                } catch {
                    skipped.append(SkippedSession(sessionId: sessionId, reason: error.localizedDescription))
                }
            }
            if !resumed.isEmpty {
                BoardServer.shared.broadcastStateChanged()
            }
            return jsonResponse(ResumeClosedSessionsEnvelope(resumed: resumed, skipped: skipped))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func attachPlannerArtifactToNode(_ req: HttpRequest) -> HttpResponse {
        struct AttachArtifactRequest: Decodable {
            let kind: PlannerArtifactKind?
            let title: String?
            let reference: String
            let status: String?
            let payload: BoardJSONValue?
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: AttachArtifactRequest.self),
              !body.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorResponse("invalid_json", "body must be {\"reference\": String}", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.attachArtifact(
                nodeId: nodeId,
                kind: body.kind ?? .generic,
                title: body.title ?? body.reference,
                reference: body.reference,
                status: body.status ?? "attached",
                payload: body.payload,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// Direct artifact-layer read — `GET …/artifacts/latest?reference=…|artifactId=…`。
    /// session / 人工脱离节点会话生命周期拉外部对象当前快照(head + payload)。
    static func getLatestPlannerArtifacts(_ req: HttpRequest) -> HttpResponse {
        struct Envelope: Encodable { let artifacts: [PlannerArtifact] }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        let artifactId = req.queryParams.first(where: { $0.0 == "artifactId" })?.1
        let referenceRaw = req.queryParams.first(where: { $0.0 == "reference" })?.1
        let reference = referenceRaw?.removingPercentEncoding ?? referenceRaw
        guard (artifactId?.isEmpty == false) || (reference?.isEmpty == false) else {
            return errorResponse("bad_request", "pass reference or artifactId", status: 400)
        }
        do {
            let artifacts = try PlannerBoardBridge.findArtifacts(
                artifactId: artifactId,
                reference: reference,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(Envelope(artifacts: artifacts))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// Direct artifact-layer write — `POST …/artifacts/update`。账本直改:
    /// 追加版本、前进 head,节点状态机不动。body: {artifactId|reference,
    /// title?, status?, payload?, submittedByKind?}。
    static func updatePlannerArtifact(_ req: HttpRequest) -> HttpResponse {
        struct UpdateArtifactRequest: Decodable {
            let artifactId: String?
            let reference: String?
            let title: String?
            let status: String?
            let payload: BoardJSONValue?
            let submittedByKind: String?
        }
        struct Envelope: Encodable { let updated: [PlannerArtifact] }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: UpdateArtifactRequest.self) else {
            return errorResponse("invalid_json", "body must carry artifactId or reference plus fields to update", status: 400)
        }
        do {
            let updated = try PlannerBoardBridge.updateArtifact(
                artifactId: body.artifactId,
                reference: body.reference,
                title: body.title,
                status: body.status,
                payload: body.payload,
                submittedByKind: PlannerArtifactVersionSubmitterKind(rawValue: body.submittedByKind ?? "human") ?? .human,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(Envelope(updated: updated))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// Direct artifact-layer manual sync — 把写穿契约的手动触发做成一键。
    /// 快照刷新是 reference 级的 sync 动作,不是节点工作(2026-06-11 定,PRD
    /// slug `google-sheets-tracker-template`「刷新路径」):不路由进任何节点的
    /// 工作会话 — 节点 transcript 是该节点的工作账本,簿记式刷新会污染它,还受
    /// 节点会话生命周期与节点级权限面牵制。改为派发**专属轻量 sync 会话**:
    /// 每 reference 至多一条,活着复用、死了重建,不绑节点;节点变更工具在
    /// 命令层禁用(--disallowedTools),「不动节点」靠结构不靠会话自觉。
    /// app 自己仍不碰外部系统(无凭证,integration 层 schema+view 边界),
    /// 核对与回写归 session(get_artifact → 核对外部对象 → update_artifact)。
    static func syncPlannerArtifact(_ req: HttpRequest) -> HttpResponse {
        struct SyncRequest: Decodable {
            let artifactId: String?
            let reference: String?
            /// 可选的人工补充(如「真表现在 12 行」),拼进指令帮会话少跑一步。
            let hint: String?
        }
        struct SyncResponse: Encodable {
            let ok: Bool
            let sessionId: String
            let reference: String
            /// created = 新派发专属会话;reused = 指令打进已有专属会话;
            /// pending = 专属会话仍在启动并执行开场指令,本次点击去重未投递。
            let action: String
            let detail: String
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: SyncRequest.self),
              body.artifactId?.isEmpty == false || body.reference?.isEmpty == false else {
            return errorResponse("invalid_json", "body must carry artifactId or reference", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.canvasState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            let targets = try PlannerBoardBridge.findArtifacts(
                artifactId: body.artifactId,
                reference: body.reference,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            guard let reference = targets.first?.reference else {
                throw PlannerCoreError.artifactNotFound(body.artifactId ?? body.reference ?? "(no selector)")
            }
            // 同步是 artifact 执行面的动作,权限对齐 attach/update:owner 直通;
            // doer 需要共享该 reference 的槽位里有授权给自己的节点。会话路由
            // 本身不再依赖任何节点。
            if state.access.role != .owner {
                let slotNodes = targets.compactMap { target in
                    state.nodes.first(where: { $0.id == target.nodeId })
                }
                let authorized = slotNodes.contains { node in
                    (try? PlannerPermission.requireNodeUpdate(on: node, access: state.access)) != nil
                }
                guard authorized else {
                    throw PlannerCoreError.permissionDenied(
                        action: PlannerPermissionAction.updateAssignedNode.rawValue,
                        role: state.access.role
                    )
                }
            }

            let hint = (body.hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 单行指令:fresh spawn 作 initialPrompt、复用会话走 deliverPrompt,
            // 两条路径最终都是「打字 + Return 键提交」;文本里不要带换行。
            let instruction = "[Artifact 同步会话] 你是 reference = \(reference)(canvasId \(canvasId))的专属快照同步会话,只做账本同步,不做任何节点工作。任务:1) 用 get_artifact 拉当前快照;2) 与外部对象的真实状态核对\(hint.isEmpty ? "" : "(提示:\(hint))");3) 用 update_artifact 回写真实事实(fields.rows/updated/summary 等);表格类对象(google-sheets tab / 多维表格等)还必须把真实行内容写进 fields.values — 二维字符串数组、列序与 fields.header 对齐、最多前 50 行、单格截断 200 字符(快照不带行值的话画布预览只能画空表)。边界:不要 submit_node_output / attach_artifact_to_node / update_artifact_views(工具面已禁用),不要改节点状态或画布上的其它对象;完成后报告核对结果并结束回合。"

            // 投递矩阵 — 专属会话每 reference 至多一条:
            //   provider hook 已链接且 claude 活着 → 指令直接打进它的 PTY
            //                          (空闲立即执行,忙碌则排成下一轮输入)
            //   surface 活着但 hook 未链接(启动窗口内)→ 刚派发还在启动,开场
            //                          指令在就绪门控队列里,此刻再打字会落进
            //                          半渲染的 TUI 而丢失 → 去重
            //   其余 → 收掉旧 pane(如还在),fresh spawn,指令作开场 prompt
            // 「claude 活着」不能用 resolvePluginSession(surfaceId) 判:surface
            // 一建立 recordManagedSession 就造出 .active 的合成 SessionData,
            // 解析得到不证明 hook 注册过。真正的注册证据是 hook 事件把 provider
            // session id 链到 surface(providerResumeSessionIdForManagedSurface),
            // 活着的证据是该 provider 会话未走到 .dead(进程没了)/.completed
            // (sessionEnd,REPL 已退出只剩 shell — 此时打字等于执行乱码命令)。
            let registryKey = artifactSyncSessionKey(canvasId: canvasId, reference: reference)
            let trackedSessionId = artifactSyncSessionId(forKey: registryKey)
            let liveSurface = trackedSessionId.flatMap { TerminalSessionBackendRegistry.shared.snapshot(id: $0) }
            let providerSessionId = trackedSessionId.flatMap(providerResumeSessionIdForManagedSurface)
            let providerSession = providerSessionId.flatMap(resolvePluginSession)
            let claudeAlive = providerSession.map { $0.status != .dead && $0.status != .completed } ?? false
            // spawn 后超时仍未链接 hook = 启动即崩的僵尸 pane;放着会让每次
            // 点击都误判「启动中」,必须收掉重建。
            let bootTimeout: TimeInterval = 120
            let stillBooting = providerSessionId == nil
                && (liveSurface.map { Date().timeIntervalSince($0.createdAt) <= bootTimeout } ?? false)
            let response: SyncResponse
            if let trackedSessionId, let liveSurface, isReusableInternalSurface(liveSurface), claudeAlive {
                // deliverPrompt 而非 writeInput:裸 "\n" 在 agent TUI 的
                // composer 里是插入换行不是提交,指令会一直躺在输入框里。
                switch TerminalSessionBackendRegistry.shared.deliverPrompt(
                    id: trackedSessionId,
                    text: instruction
                ) {
                case .delivered:
                    response = SyncResponse(
                        ok: true,
                        sessionId: trackedSessionId,
                        reference: reference,
                        action: "reused",
                        detail: "同步指令已下达给该 reference 的专属同步会话,完成后卡片自动更新。"
                    )
                case .busy:
                    // 上一条同步指令还在提交窗口里 — 连点去重,不能再打字
                    // (两条文本会被同一个 Return 拼成一条畸形请求)。
                    response = SyncResponse(
                        ok: true,
                        sessionId: trackedSessionId,
                        reference: reference,
                        action: "pending",
                        detail: "上一条同步指令正在提交,本次点击已去重。"
                    )
                case .sessionNotFound:
                    return errorResponse("sync_delivery_failed", "专属同步会话的终端拒绝输入,请重试。", status: 500)
                }
            } else if let trackedSessionId, let liveSurface, isReusableInternalSurface(liveSurface), stillBooting {
                response = SyncResponse(
                    ok: true,
                    sessionId: trackedSessionId,
                    reference: reference,
                    action: "pending",
                    detail: "专属同步会话正在启动并执行同步指令,无需重复触发。"
                )
            } else {
                if let trackedSessionId, liveSurface != nil {
                    _ = TerminalSessionBackendRegistry.shared.closeSessionIfExists(id: trackedSessionId)
                }
                let surface = try createInternalSessionSurface(
                    provider: "claude",
                    cwd: BoardLayoutStore.shared.workspacePath(canvasId: canvasId),
                    command: artifactSyncLaunchCommand(),
                    createIfMissing: true,
                    canvasId: canvasId,
                    // 专属 sync 会话不绑节点:进不了节点账本、不挂节点会话三态,
                    // 也不参与 planner run-state(不调 observe)。
                    nodeId: nil,
                    initialPrompt: instruction
                )
                recordArtifactSyncSession(surface.sessionId, forKey: registryKey)
                response = SyncResponse(
                    ok: true,
                    sessionId: surface.sessionId,
                    reference: reference,
                    action: "created",
                    detail: "已派发专属同步会话,完成后卡片自动更新。"
                )
            }
            NSLog("[ArtifactSync] reference=\(reference) -> session=\(response.sessionId.prefix(12)) action=\(response.action)")
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(response)
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    // MARK: - Artifact sync 专属会话注册表

    /// (canvasId, reference) → 专属 sync 会话 id。进程内存即可:app 重启后旧
    /// surface 已不在,下一次同步自然 fresh spawn,无需持久化。
    private static let artifactSyncSessionsLock = NSLock()
    private static var artifactSyncSessions: [String: String] = [:]

    private static func artifactSyncSessionKey(canvasId: String, reference: String) -> String {
        "\(canvasId)|\(reference)"
    }

    private static func artifactSyncSessionId(forKey key: String) -> String? {
        artifactSyncSessionsLock.lock()
        defer { artifactSyncSessionsLock.unlock() }
        return artifactSyncSessions[key]
    }

    private static func recordArtifactSyncSession(_ sessionId: String, forKey key: String) {
        artifactSyncSessionsLock.lock()
        defer { artifactSyncSessionsLock.unlock() }
        artifactSyncSessions[key] = sessionId
    }

    /// sync 会话的启动命令:full-access 基础上在命令层禁用节点变更工具。两套
    /// 同名 MCP 注册(meee2 插件 / app 自注册)都要覆盖,漏一套等于没禁。
    private static func artifactSyncLaunchCommand() -> String {
        let banned = ["submit_node_output", "attach_artifact_to_node", "update_artifact_views"]
        let rules = banned
            .flatMap { ["mcp__meee2__\($0)", "mcp__plugin_meee2_meee2__\($0)"] }
            .map { "\"\($0)\"" }
            .joined(separator: " ")
        return AgentLaunchCommand.fullAccessCommand(forProvider: "claude") + " --disallowedTools \(rules)"
    }

    static func updatePlannerArtifactViews(_ req: HttpRequest) -> HttpResponse {
        struct UpdateArtifactViewsRequest: Decodable {
            let artifactId: String?
            let reference: String?
            let views: [PlannerArtifactView]?
            let deleteViewIds: [String]?
        }
        struct Envelope: Encodable { let updated: [PlannerArtifact] }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: UpdateArtifactViewsRequest.self),
              body.artifactId?.isEmpty == false || body.reference?.isEmpty == false else {
            return errorResponse("invalid_json", "body must carry artifactId or reference plus views/deleteViewIds", status: 400)
        }
        do {
            let updated = try PlannerBoardBridge.updateArtifactViews(
                artifactId: body.artifactId,
                reference: body.reference,
                views: body.views ?? [],
                deleteViewIds: body.deleteViewIds ?? [],
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(Envelope(updated: updated))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func bindPlannerNodeInput(_ req: HttpRequest) -> HttpResponse {
        struct BindInputRequest: Decodable {
            let input: String
            let reference: String
            let kind: ContextSource.Kind?
            let title: String?
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: BindInputRequest.self),
              !body.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorResponse("invalid_json", "body must be {\"input\": String, \"reference\": String}", status: 400)
        }
        let input = body.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = body.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTitle = body.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = ContextSource(
            kind: body.kind ?? inferContextSourceKind(reference: reference, title: input),
            title: sourceTitle?.isEmpty == false ? sourceTitle! : input,
            reference: reference
        )
        do {
            let state = try PlannerBoardBridge.bindNodeInput(
                nodeId: nodeId,
                input: input,
                source: source,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func updatePlannerNodeStatus(_ req: HttpRequest) -> HttpResponse {
        struct UpdateStatusRequest: Decodable {
            let status: PlanningNodeStatus
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: UpdateStatusRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"status\": PlanningNodeStatus}", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.updateNodeStatus(
                nodeId: nodeId,
                status: body.status,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func updatePlannerNodeGate(_ req: HttpRequest) -> HttpResponse {
        struct UpdateGateRequest: Decodable {
            let executionMode: ExecutionMode
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: UpdateGateRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"executionMode\":\"human\"|\"auto\"}", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.updateNodeGate(
                nodeId: nodeId,
                executionMode: body.executionMode,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func updatePlannerNodeSchedule(_ req: HttpRequest) -> HttpResponse {
        struct UpdateScheduleRequest: Decodable {
            let enabled: Bool
            let intervalSeconds: Int?
            let prompt: String?
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: UpdateScheduleRequest.self) else {
            return errorResponse("invalid_json", "body must be {\"enabled\": Bool, \"intervalSeconds\"?: Int, \"prompt\"?: String}", status: 400)
        }
        let schedule: PlannerNodeSchedule?
        if body.enabled {
            schedule = PlannerNodeSchedule(
                enabled: true,
                intervalSeconds: max(60, body.intervalSeconds ?? 900),
                prompt: body.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                lastSentAt: nil,
                nextRunAt: Date().addingTimeInterval(TimeInterval(max(60, body.intervalSeconds ?? 900)))
            )
        } else {
            schedule = nil
        }
        do {
            let state = try PlannerBoardBridge.updateNodeSchedule(
                nodeId: nodeId,
                schedule: schedule,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func deletePlannerNode(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.deleteNode(
                nodeId: nodeId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func getPlannerNodeContract(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        do {
            let contract = try PlannerBoardBridge.nodeContract(
                nodeId: nodeId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(contract)
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func submitPlannerNodeOutput(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        // ENG-1: reject v1-style payloads (replace_strategy / output.kind:
        // increment) before they decode into a v2-shaped model, so adapters
        // fail loudly with an actionable error instead of silently dropping
        // the offending fields.
        var bodyData = Data(req.body)
        if let raw = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            do {
                try NodeContractValidator.validateRawOutputPayload(raw)
            } catch {
                return errorResponse("invalid_node_output", error.localizedDescription, status: 400)
            }
            // Part D — 可配置节点状态(spec §5): 在 decode 前解析动态 `state`。校验它在
            // 该节点 stateSchema 内、据 kind 映射成引擎 outcome,并把 status 注入 body ——
            // 这样纯 `state`(省略 status)的提交也能 decode(PlannerNodeOutput 要求 status),
            // 自定义态节点可只凭 state 完成(PR#112 review)。缺省 schema 省略 state →
            // 走 status 原逻辑(向后兼容)。校验失败返回 agent 自纠。
            if let stateId = (raw["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !stateId.isEmpty {
                let schema = (try? PlannerBoardBridge.canvasState(
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: PlannerPermission.currentActorId()
                ))?.nodes.first(where: { $0.id == nodeId })?.effectiveStateSchema ?? .default
                guard let def = schema.def(forStateId: stateId) else {
                    let allowed = schema.states.map { $0.id }.joined(separator: ", ")
                    return errorResponse("invalid_node_output", "state '\(stateId)' is not in this node's stateSchema; allowed: \(allowed)", status: 400)
                }
                guard let mapped = def.submittableStatus else {
                    return errorResponse("invalid_node_output", "state '\(stateId)' (kind \(def.kind.rawValue)) is not a submittable terminal/gating state", status: 400)
                }
                var patched = raw
                patched["status"] = mapped.rawValue
                if let reserialized = try? JSONSerialization.data(withJSONObject: patched) {
                    bodyData = reserialized
                }
            }
        }
        let outputDecoder = JSONDecoder()
        outputDecoder.dateDecodingStrategy = .iso8601
        guard !bodyData.isEmpty,
              let output = try? outputDecoder.decode(PlannerNodeOutput.self, from: bodyData) else {
            return errorResponse("invalid_json", plannerNodeOutputPayloadHelp, status: 400)
        }
        do {
            // Capture the pre-submit node.status so we can detect the
            // ready → terminal-attempt transition below. The store keeps
            // node.status in sync with explicit output.status, but agents
            // sometimes leave a ready node behind when their attempt has
            // already reached a done terminal — this is the auto-done rule.
            let preSnapshot = BoardLayoutStore.shared.snapshot()
            let preStatus: PlanningNodeStatus? = (try? PlannerBoardBridge.canvasState(
                for: canvasId,
                snapshot: preSnapshot,
                actorUserId: PlannerPermission.currentActorId()
            ))?.nodes.first(where: { $0.id == nodeId })?.status
            var result = try PlannerBoardBridge.submitNodeOutput(
                nodeId: nodeId,
                output: output,
                for: canvasId,
                snapshot: preSnapshot,
                actorUserId: PlannerPermission.currentActorId()
            )
            // Auto-done rule (decision locked 2026-05-28): if the node was
            // `ready` before this submit and the resulting attempt landed in
            // the `done` terminal state, force node.status = .done in place.
            // Other pre-states (draft / blocked / already done) are left
            // alone — only `ready` is the "agent finishing its turn" entry
            // point. We update directly through the bridge's static path
            // (no proposal flow) to mirror the existing attempt-commit code
            // path that already runs inside `submitNodeOutput`.
            if preStatus == .ready,
               let postNode = result.graph.nodes.first(where: { $0.id == nodeId }),
               postNode.workflowRunState == .done,
               postNode.status != .done {
                if let regraphed = try? PlannerBoardBridge.updateNodeStatus(
                    nodeId: nodeId,
                    status: .done,
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: PlannerPermission.currentActorId()
                ) {
                    result.graph = regraphed
                    NSLog("[planner][auto-done] node=\(nodeId) canvas=\(canvasId) preStatus=ready attempt=done → status=done")
                }
            }
            routePlannerOutputMessages(result.routes)
            materializeAutoDispatchedSessions(canvasId: canvasId, result: &result)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(result, status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func runCanvasSceneAction(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        struct Body: Decodable {
            var actionId: String
            var userRole: String?
            var controlledPlayerId: String?
            var autoRun: Bool?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: Data(req.body)),
              !body.actionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorResponse("invalid_json", "body must be {\"actionId\":\"...\"}", status: 400)
        }
        do {
            let actor = PlannerPermission.currentActorId()
            let snapshot = BoardLayoutStore.shared.snapshot()
            let state = try PlannerBoardBridge.canvasState(for: canvasId, snapshot: snapshot, actorUserId: actor)
            let record = try PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvasId)
            guard let scene = state.canvas.sceneSpec,
                  scene.kind == "poker-table",
                  scene.orchestration == nil || scene.orchestration?.kind == "poker-rules-v1" else {
                return errorResponse("unsupported_scene_action", "only poker-rules-v1 scene actions are supported", status: 400)
            }
            guard let dealerNodeId = scene.orchestration?.stateNodeId
                    ?? scene.artifactBindings.first(where: { $0.id == "game-state" })?.nodeId
                    ?? scene.nodeAnchors.first(where: { $0.id == "dealer" || $0.role == "dealer" })?.nodeId else {
                return errorResponse("invalid_scene", "poker scene is missing Dealer state binding", status: 400)
            }
            switch body.actionId {
            case "start-game":
                try configurePokerRoleNodes(
                    canvasId: canvasId,
                    scene: scene,
                    userRole: body.userRole ?? "observer",
                    controlledPlayerId: body.controlledPlayerId
                )
                let role = normalizedPokerUserRole(body.userRole)
                let controlled = normalizedPokerPlayerId(body.controlledPlayerId)
                let autoRun = body.autoRun ?? true
                let gameState = pokerInitialGameState(userRole: role, controlledPlayerId: controlled, autoRun: autoRun)
                let actionLog: BoardJSONValue = .object([
                    "actionLog": .array([
                        .string("Rules Orchestrator 初始化牌局"),
                        .string("Blind posted: 50 / 100"),
                        .string("下一行动: Ada")
                    ])
                ])
                var result = try submitPokerSystemState(
                    canvasId: canvasId,
                    dealerNodeId: dealerNodeId,
                    summary: "Rules Orchestrator started Poker Table",
                    gameState: gameState,
                    actionLog: actionLog,
                    actorUserId: actor
                )
                materializeAutoDispatchedSessions(canvasId: canvasId, result: &result)
                BoardServer.shared.broadcastStateChanged()
                return jsonResponse(result, status: 201, reason: "Created")
            case "pause-auto", "resume-auto", "step":
                let currentState = latestPokerSceneState(
                    artifactVersions: record.artifactVersions,
                    nodeId: dealerNodeId,
                    reference: scene.orchestration?.stateReference ?? "game-state.json"
                )
                let patch: BoardJSONValue
                let summary: String
                if body.actionId == "step" {
                    patch = try pokerStepStatePatch(
                        canvasId: canvasId,
                        scene: scene,
                        artifacts: state.artifacts,
                        currentState: currentState
                    )
                    summary = "Rules Orchestrator applied player action"
                } else {
                    let autoRun = body.actionId == "resume-auto"
                    let status = body.actionId == "resume-auto" ? "auto-running" : "paused"
                    patch = mergeBoardJSONObjects(currentState, BoardJSONValue.object([
                        "setup": BoardJSONValue.object(["autoRun": BoardJSONValue.bool(autoRun)]),
                        "orchestrationStatus": BoardJSONValue.string(status),
                        "actionLog": BoardJSONValue.array([
                            BoardJSONValue.string("Rules Orchestrator \(status)"),
                            BoardJSONValue.string("下一步由当前行动者节点产出 Player Action Artifact")
                        ])
                    ]))
                    summary = "Rules Orchestrator \(status)"
                }
                var result = try submitPokerSystemState(
                    canvasId: canvasId,
                    dealerNodeId: dealerNodeId,
                    summary: summary,
                    gameState: patch,
                    actionLog: .object(["actionLog": patch.objectValue?["actionLog"] ?? .array([])]),
                    actorUserId: actor
                )
                materializeAutoDispatchedSessions(canvasId: canvasId, result: &result)
                BoardServer.shared.broadcastStateChanged()
                return jsonResponse(result, status: 201, reason: "Created")
            default:
                return errorResponse("unsupported_scene_action", "unsupported poker scene action '\(body.actionId)'", status: 400)
            }
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    private static func configurePokerRoleNodes(
        canvasId: String,
        scene: CanvasSceneSpec,
        userRole: String,
        controlledPlayerId: String?
    ) throws {
        let role = normalizedPokerUserRole(userRole)
        let controlled = normalizedPokerPlayerId(controlledPlayerId)
        let playerAnchors = scene.nodeAnchors.filter { $0.role == "player" }
        for anchor in playerAnchors {
            let shouldBeHuman = role == "player" && normalizedPokerPlayerId(anchor.id) == controlled
            _ = try PlannerBoardBridge.store.updateNodeGate(
                canvasId: canvasId,
                nodeId: anchor.nodeId,
                executionMode: shouldBeHuman ? .human : .auto
            )
        }
        if let dealer = scene.nodeAnchors.first(where: { $0.role == "dealer" }) {
            _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: canvasId, nodeId: dealer.nodeId, executionMode: .auto)
        }
        if let gm = scene.nodeAnchors.first(where: { $0.id == "gm" || $0.role == "approval" }) {
            _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: canvasId, nodeId: gm.nodeId, executionMode: .human)
        }
    }

    private static func submitPokerSystemState(
        canvasId: String,
        dealerNodeId: String,
        summary: String,
        gameState: BoardJSONValue,
        actionLog: BoardJSONValue,
        actorUserId: String?
    ) throws -> PlannerNodeOutputResult {
        _ = try PlannerBoardBridge.store.updateNodeGate(
            canvasId: canvasId,
            nodeId: dealerNodeId,
            executionMode: .auto
        )
        let output = PlannerNodeOutput(
            nodeId: dealerNodeId,
            status: .done,
            message: PlannerNodeOutputMessage(summary: summary, routeTo: []),
            artifacts: [
                PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "game-state.json",
                    reference: "game-state.json",
                    payload: sceneJSONPayload(gameState),
                    routeTo: []
                ),
                PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "action-log.json",
                    reference: "action-log.json",
                    payload: sceneJSONPayload(actionLog),
                    routeTo: []
                )
            ],
            next: .complete,
            forceNewVersion: true
        )
        return try PlannerBoardBridge.submitNodeOutput(
            nodeId: dealerNodeId,
            output: output,
            for: canvasId,
            snapshot: BoardLayoutStore.shared.snapshot(),
            actorUserId: actorUserId,
            submittedByKind: .system,
            submittedBy: "Rules Orchestrator"
        )
    }

    private static func latestPokerSceneState(
        artifactVersions: [PlannerArtifactVersion],
        nodeId: String,
        reference: String
    ) -> BoardJSONValue {
        var state: BoardJSONValue = .object([:])
        for version in artifactVersions
            .filter({ $0.nodeId == nodeId && $0.payloadRef == reference })
            .sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let payload = version.payloadInline else { continue }
            let patch: BoardJSONValue
            if case .object(let object) = payload,
               let sceneState = object["sceneState"] {
                patch = sceneState
            } else {
                patch = payload
            }
            state = mergeBoardJSONObjects(state, patch)
        }
        return state
    }

    private static func pokerStepStatePatch(
        canvasId: String,
        scene: CanvasSceneSpec,
        artifacts: [PlannerArtifact],
        currentState: BoardJSONValue
    ) throws -> BoardJSONValue {
        guard case .object(let stateObject) = currentState else {
            throw PlannerCoreError.invalidNodeOutput("Poker Rules Orchestrator needs an object game-state.json before step.")
        }
        let nextActor = stateObject["nextActor"]?.stringValue
            ?? stateObject["nextAction"]?.stringValue
            ?? ""
        let playerId = normalizedPokerPlayerId(nextActor)
        guard let playerId else {
            throw PlannerCoreError.invalidNodeOutput("Poker Rules Orchestrator cannot step: nextActor '\(nextActor)' is not a player.")
        }
        guard let playerAnchor = scene.nodeAnchors.first(where: { normalizedPokerPlayerId($0.id) == playerId || normalizedPokerPlayerId($0.label) == playerId }) else {
            throw PlannerCoreError.invalidNodeOutput("Poker Rules Orchestrator cannot find node anchor for player '\(playerId)'.")
        }
        let reference = "\(playerId)-action.json"
        let action = try latestPokerPlayerAction(
            canvasId: canvasId,
            artifacts: artifacts,
            nodeId: playerAnchor.nodeId,
            reference: reference
        )
        guard (action["playerId"]?.stringValue ?? playerId).lowercased() == playerId else {
            throw PlannerCoreError.invalidNodeOutput("Poker action artifact '\(reference)' does not belong to current actor '\(playerId)'.")
        }
        let actionName = (action["action"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["fold", "call", "raise", "check"].contains(actionName) else {
            throw PlannerCoreError.invalidNodeOutput("Poker action artifact '\(reference)' must use action fold/call/raise/check.")
        }
        let amount = action["amount"]?.intValue ?? 0
        return applyPokerAction(
            state: currentState,
            playerId: playerId,
            action: actionName,
            amount: max(0, amount)
        )
    }

    private static func latestPokerPlayerAction(
        canvasId: String,
        artifacts: [PlannerArtifact],
        nodeId: String,
        reference: String
    ) throws -> [String: BoardJSONValue] {
        guard let artifact = artifacts
            .filter({ $0.nodeId == nodeId && $0.reference == reference })
            .sorted(by: { $0.createdAt < $1.createdAt })
            .last else {
            throw PlannerCoreError.invalidNodeOutput("Poker Rules Orchestrator is waiting for \(reference).")
        }
        if let payload = artifact.payload,
           let action = try pokerActionObject(from: payload, canvasId: canvasId, fallbackReference: reference) {
            return action
        }
        throw PlannerCoreError.invalidNodeOutput("Poker action artifact '\(reference)' is missing a typed JSON payload.")
    }

    private static func pokerActionObject(
        from payload: BoardJSONValue,
        canvasId: String,
        fallbackReference: String
    ) throws -> [String: BoardJSONValue]? {
        guard case .object(let object) = payload else { return nil }
        if object["action"] != nil {
            return object
        }
        if let json = object["json"]?.stringValue,
           let decoded = boardJSONValueFromJSONString(json)?.objectValue {
            return decoded
        }
        if let sceneState = object["sceneState"]?.objectValue,
           sceneState["action"] != nil {
            return sceneState
        }
        if let ref = object["reference"]?.stringValue ?? object["filename"]?.stringValue,
           ref == fallbackReference,
           let decoded = try pokerActionObjectFromWorkspace(canvasId: canvasId, reference: ref) {
            return decoded
        }
        return nil
    }

    private static func pokerActionObjectFromWorkspace(canvasId: String, reference: String) throws -> [String: BoardJSONValue]? {
        guard !reference.contains("/"), !reference.contains("\\") else { return nil }
        let workspace = try BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
        let url = URL(fileURLWithPath: workspace).appendingPathComponent(reference)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try? JSONDecoder().decode(BoardJSONValue.self, from: data).objectValue
    }

    private static func boardJSONValueFromJSONString(_ json: String) -> BoardJSONValue? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BoardJSONValue.self, from: data)
    }

    private static func applyPokerAction(
        state: BoardJSONValue,
        playerId: String,
        action: String,
        amount: Int
    ) -> BoardJSONValue {
        guard case .object(var object) = state else { return state }
        let playerOrder = ["ada", "bruno", "mina"]
        let displayName = playerId.prefix(1).uppercased() + playerId.dropFirst()
        var pot = object["pot"]?.intValue ?? 0
        var folded = Set<String>()
        let nextPlayer = playerOrder.drop { $0 != playerId }.dropFirst().first
        if case .array(let players)? = object["players"] {
            object["players"] = .array(players.map { value in
                guard case .object(var player) = value,
                      let id = player["id"]?.stringValue?.lowercased() else {
                    return value
                }
                if player["status"]?.stringValue == "folded" {
                    folded.insert(id)
                }
                if id == playerId {
                    if action == "fold" {
                        player["status"] = .string("folded")
                        folded.insert(id)
                    } else {
                        let spend = action == "check" ? 0 : amount
                        if spend > 0 {
                            let stack = max(0, (player["stack"]?.intValue ?? 0) - spend)
                            player["stack"] = .number(Double(stack))
                            pot += spend
                        }
                        player["status"] = .string("acted")
                    }
                } else if id == nextPlayer {
                    player["status"] = .string("to-act")
                } else if player["status"]?.stringValue != "folded" {
                    player["status"] = .string("waiting")
                }
                return .object(player)
            })
        }
        let eligibleNext = playerOrder.drop { $0 != playerId }.dropFirst().first { !folded.contains($0) }
        object["pot"] = .number(Double(pot))
        object["nextActor"] = eligibleNext.map(BoardJSONValue.string) ?? .string("dealer")
        object["nextAction"] = .string(eligibleNext.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Dealer")
        object["orchestrationStatus"] = .string(eligibleNext == nil ? "street-complete" : "auto-running")
        if eligibleNext == nil {
            object["legalActions"] = .array([])
            object["handStatus"] = .string("street-complete")
        }
        var log = object["actionLog"]?.arrayValue ?? []
        let amountLabel = amount > 0 ? " \(amount)" : ""
        log.append(.string("\(displayName) \(action)\(amountLabel)"))
        if let next = eligibleNext {
            log.append(.string("下一行动: \(next.prefix(1).uppercased() + next.dropFirst())"))
        } else {
            log.append(.string("本轮行动完成，等待 Dealer 推进下一阶段"))
        }
        object["actionLog"] = .array(log)
        return .object(object)
    }

    private static func mergeBoardJSONObjects(_ base: BoardJSONValue, _ patch: BoardJSONValue) -> BoardJSONValue {
        guard case .object(var baseObject) = base,
              case .object(let patchObject) = patch else {
            return patch
        }
        for (key, value) in patchObject {
            if let existing = baseObject[key] {
                baseObject[key] = mergeBoardJSONObjects(existing, value)
            } else {
                baseObject[key] = value
            }
        }
        return .object(baseObject)
    }

    private static func sceneJSONPayload(_ sceneState: BoardJSONValue) -> BoardJSONValue {
        .object([
            "type": .string("json"),
            "sceneState": sceneState
        ])
    }

    private static func normalizedPokerUserRole(_ raw: String?) -> String {
        let value = (raw ?? "observer").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "gm", "player", "all-ai", "observer":
            return value
        default:
            return "observer"
        }
    }

    private static func normalizedPokerPlayerId(_ raw: String?) -> String? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["ada", "bruno", "mina"].contains(value) ? value : nil
    }

    private static func pokerInitialGameState(
        userRole: String,
        controlledPlayerId: String?,
        autoRun: Bool
    ) -> BoardJSONValue {
        .object([
            "setup": .object([
                "started": .bool(true),
                "userRole": .string(userRole),
                "controlledPlayerId": controlledPlayerId.map(BoardJSONValue.string) ?? .null,
                "autoRun": .bool(autoRun)
            ]),
            "phase": .string("Pre-flop"),
            "pot": .number(150),
            "nextActor": .string("ada"),
            "nextAction": .string("Ada"),
            "communityCards": .array([.string("??"), .string("??"), .string("??"), .string("??"), .string("??")]),
            "legalActions": .array([.string("fold"), .string("call"), .string("raise")]),
            "handStatus": .string("in-progress"),
            "orchestrationStatus": .string(autoRun ? "auto-running" : "paused"),
            "players": .array([
                .object(["id": .string("dealer"), "name": .string("Dealer / Table State"), "stack": .number(0), "status": .string("system"), "seat": .string("top"), "holeCards": .array([])]),
                .object(["id": .string("ada"), "name": .string("Ada"), "style": .string("紧凶型"), "stack": .number(950), "status": .string("to-act"), "seat": .string("left"), "holeCards": .array([.string("As"), .string("Ks")])]),
                .object(["id": .string("bruno"), "name": .string("Bruno"), "style": .string("诈唬型"), "stack": .number(870), "status": .string("waiting"), "seat": .string("right"), "holeCards": .array([.string("Qh"), .string("Js")])]),
                .object(["id": .string("mina"), "name": .string("Mina"), "style": .string("保守观察"), "stack": .number(1020), "status": .string("waiting"), "seat": .string("bottom"), "holeCards": .array([.string("9c"), .string("9d")])])
            ]),
            "actionLog": .array([
                .string("Rules Orchestrator 初始化牌局"),
                .string("Blind posted: 50 / 100"),
                .string("下一行动: Ada")
            ]),
            "rulesMode": .string("phase/order/card-uniqueness assisted; no side-pot engine")
        ])
    }

    static func getPlannerArtifactContent(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let artifactId = req.params[":artifactId"], !artifactId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or artifact id", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.canvasState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            guard let artifact = state.artifacts.first(where: { $0.id == artifactId }) else {
                return errorResponse("not_found", "artifact not found", status: 404)
            }
            let content = try PlannerArtifactStorage.content(for: artifact)
            return jsonResponse(content)
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    // MARK: - UI-1 (ENG-3) · Artifact version chain endpoints
    //
    // The web Board reads the append-only version history through these
    // routes. `reference` is the logical artifact slot (PlannerArtifact
    // .reference / NodeContractOutput.name). The Swift store keys slots by
    // canvasId+nodeId+normalized(reference), matching ENG-3 semantics.

    static func listPlannerArtifactVersions(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        let referenceRaw = req.queryParams.first(where: { $0.0 == "reference" })?.1
        let reference = referenceRaw?.removingPercentEncoding ?? referenceRaw ?? ""
        guard !reference.isEmpty else {
            return errorResponse("bad_request", "reference query parameter is required", status: 400)
        }
        do {
            let versions = try PlannerBoardBridge.listArtifactVersions(
                canvasId: canvasId,
                nodeId: nodeId,
                reference: reference,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            // Newest-first, mirroring the Supabase view's order.
            let sorted = versions.sorted(by: { $0.createdAt > $1.createdAt })
            struct Envelope: Encodable { let versions: [PlannerArtifactVersion] }
            return jsonResponse(Envelope(versions: sorted))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func getPlannerArtifactVersion(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let versionId = req.params[":versionId"], !versionId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or version id", status: 400)
        }
        do {
            guard let version = try PlannerBoardBridge.getArtifactVersion(
                canvasId: canvasId,
                versionId: versionId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            ) else {
                return errorResponse("not_found", "version not found", status: 404)
            }
            return jsonResponse(version)
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    // MARK: - Wave 1-3 integration · OnlineProxy routes
    //
    // These proxy the desktop board-app's UI-2 and UI-6 calls to
    // meee2-online. They share `OnlineProxy.loadSettings()` for the
    // online API token + teamId/userId stored in `~/.meee2/settings.json`
    // (also mirrored to UserDefaults).
    //
    // 1) POST /api/planner/canvases/:id/nodes/:nodeId/assign
    //      → meee2-online API `.../assign`
    // 2) GET  /api/planner/owned-canvases
    //      → meee2-online API `.../owned-canvases`
    // 3) GET  /api/cloud/artifact-versions/recent
    //      → meee2-online `/api/v1/artifact-versions?…`

    /// UI-2 · F1.2 — assign a node through meee2-online's user-scoped API.
    /// The local graph is updated only after the online transaction succeeds
    /// so the desktop stays aligned with the server's single-owner contract.
    static func proxyAssignPlannerNode(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        let settings = OnlineProxy.loadSettings()
        guard !settings.teamId.isEmpty else {
            return errorResponse("not_connected", "meee2-online not configured (missing teamId)", status: 412)
        }
        struct AssignBody: Decodable {
            let assigneeUserId: String?
            let subCanvasName: String?
            let acceptPrivateUpgrade: Bool?
        }
        let body: AssignBody = (try? JSONDecoder().decode(AssignBody.self, from: Data(req.body)))
            ?? AssignBody(assigneeUserId: nil, subCanvasName: nil, acceptPrivateUpgrade: nil)
        guard let assigneeUserId = body.assigneeUserId, !assigneeUserId.isEmpty else {
            return errorResponse("bad_request", "assigneeUserId is required", status: 400)
        }

        let snapshot = BoardLayoutStore.shared.snapshot()
        guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            return errorResponse("not_found", "canvas not found", status: 404)
        }

        let state: PlannerGraphState
        let node: PlanningNode
        do {
            state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: snapshot,
                actorUserId: settings.userId.isEmpty ? PlannerPermission.currentActorId() : settings.userId
            )
            guard let found = state.nodes.first(where: { $0.id == nodeId }) else {
                return errorResponse("not_found", "node not found", status: 404)
            }
            node = found
            guard state.access.role == .owner else {
                return errorResponse("forbidden", "only the canvas owner can assign nodes", status: 403)
            }
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }

        let frozenContract = NodeContractV2.derive(from: node).contract
        let frozenContractObject = jsonObject(frozenContract) ?? [:]
        var payload: [String: Any] = [
            "assigneeUserId": assigneeUserId,
            "acceptPrivateUpgrade": body.acceptPrivateUpgrade ?? false,
            "frozenIOContract": frozenContractObject
        ]
        if let name = body.subCanvasName, !name.isEmpty {
            payload["subCanvasName"] = name
        }
        let remoteCanvasId = boardCanvas.remoteId ?? canvasId
        let path = "/api/v1/team/\(urlPath(settings.teamId))/planner/canvases/\(urlPath(remoteCanvasId))/nodes/\(urlPath(nodeId))/assign"
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return errorResponse("bad_request", "failed to encode assign payload", status: 400)
        }
        switch OnlineProxy.callOnlineAPI(method: "POST", path: path, body: bodyData, settings: settings) {
        case .success(let data):
            guard let remote = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let assignmentObject = remote["assignment"] as? [String: Any],
                  let subCanvasId = stringValue(assignmentObject["subCanvasId"]) else {
                return errorResponse("bad_gateway", "meee2-online assign response missing assignment", status: 502)
            }
            do {
                let proposal = try PlannerBoardBridge.createSubCanvasProposal(
                    nodeId: nodeId,
                    subCanvasId: subCanvasId,
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: settings.userId.isEmpty ? PlannerPermission.currentActorId() : settings.userId
                )
                _ = try PlannerBoardBridge.approveProposal(
                    proposalId: proposal.id,
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: settings.userId.isEmpty ? PlannerPermission.currentActorId() : settings.userId
                )
                _ = try PlannerBoardBridge.applyProposal(
                    proposalId: proposal.id,
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: settings.userId.isEmpty ? PlannerPermission.currentActorId() : settings.userId
                )
                let graph = try PlannerBoardBridge.graphState(
                    for: canvasId,
                    snapshot: BoardLayoutStore.shared.snapshot(),
                    actorUserId: settings.userId.isEmpty ? PlannerPermission.currentActorId() : settings.userId
                )
                BoardServer.shared.broadcastStateChanged()
                let assignment = NodeAssignmentDTO(
                    sourceCanvasId: canvasId,
                    sourceNodeId: nodeId,
                    assigneeUserId: assigneeUserId,
                    subCanvasId: subCanvasId,
                    subCanvasName: stringValue(assignmentObject["subCanvasName"]) ?? subCanvasId,
                    frozenIOContract: frozenContract,
                    billingTeamId: settings.teamId,
                    sessionCountRebound: intValue(assignmentObject["sessionCountRebound"]),
                    assignedAt: stringValue(assignmentObject["assignedAt"])
                )
                return jsonResponse(AssignPlannerNodeResultEnvelope(
                    assignment: assignment,
                    visibilityUpgraded: boolValue(remote["visibilityUpgraded"]) ?? (state.canvas.visibility == .private),
                    parentCanvas: remoteCanvasDTO(remote["parentCanvas"] as? [String: Any]),
                    subCanvas: remoteCanvasDTO(remote["subCanvas"] as? [String: Any]),
                    graph: graphEnvelope(graph)
                ))
            } catch let err as PlannerCoreError {
                return mapPlannerCoreError(err)
            } catch {
                return errorResponse("planner_error", error.localizedDescription, status: 400)
            }
        case .failure(let err):
            return mapOnlineProxyError(err)
        }
    }

    /// UI-2 · proxy `fetchOwnedCanvases` to the meee2-online team API.
    static func proxyListOwnedCanvases(_ req: HttpRequest) -> HttpResponse {
        let settings = OnlineProxy.loadSettings()
        guard !settings.teamId.isEmpty else {
            return errorResponse("not_connected", "meee2-online not configured (missing teamId)", status: 412)
        }
        let path = "/api/v1/team/\(urlPath(settings.teamId))/planner/owned-canvases"
        switch OnlineProxy.callOnlineAPI(method: "GET", path: path, settings: settings) {
        case .success(let data):
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try? writer.write(data)
            }
        case .failure(let err):
            return mapOnlineProxyError(err)
        }
    }

    /// UI-6 · proxy `fetchRecentArtifactVersions` to meee2-online's
    /// `/api/v1/artifact-versions` endpoint. The caller passes
    /// `teamId`, `canvasId`, `windowMs`; we translate `windowMs` to a
    /// `since=<iso>` query param per the upstream spec. The board-app
    /// accepts a `{ versions: [...] }` envelope.
    static func proxyRecentArtifactVersions(_ req: HttpRequest) -> HttpResponse {
        let qp = Dictionary(uniqueKeysWithValues: req.queryParams.map { ($0.0, $0.1) })
        let teamId = (qp["teamId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let canvasId = (qp["canvasId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let windowMs = Int(qp["windowMs"] ?? "") ?? 60_000
        guard !teamId.isEmpty, !canvasId.isEmpty else {
            return errorResponse("bad_request", "teamId and canvasId are required", status: 400)
        }
        let sinceDate = Date(timeIntervalSinceNow: -Double(windowMs) / 1000.0)
        let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        var items: [URLQueryItem] = [
            URLQueryItem(name: "teamId", value: teamId),
            URLQueryItem(name: "canvasId", value: canvasId),
            URLQueryItem(name: "since", value: isoFormatter.string(from: sinceDate))
        ]
        if let limit = qp["limit"] { items.append(URLQueryItem(name: "limit", value: limit)) }
        switch OnlineProxy.callOnlineAPI(
            method: "GET",
            path: "/api/v1/team/\(urlPath(teamId))/artifact-versions/recent",
            query: items.filter { $0.name != "teamId" }
        ) {
        case .success(let data):
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try? writer.write(data)
            }
        case .failure(let err):
            return mapOnlineProxyError(err)
        }
    }

    /// Map OnlineProxy errors to JSON error responses with appropriate
    /// HTTP status codes. Surfaces upstream status when available.
    private static func mapOnlineProxyError(_ err: OnlineProxy.ProxyError) -> HttpResponse {
        switch err {
        case .missingSettings(let key):
            return errorResponse("not_connected", "meee2-online not configured (missing \(key))", status: 412)
        case .badURL:
            return errorResponse("bad_request", "invalid upstream URL", status: 400)
        case .transport(let underlying):
            return errorResponse("upstream_unavailable", underlying.localizedDescription, status: 502)
        case .http(let status, let body):
            // Pass through upstream body if it's already JSON; otherwise wrap.
            if (try? JSONSerialization.jsonObject(with: body)) != nil {
                return HttpResponse.raw(status, "Upstream", ["Content-Type": "application/json"]) { writer in
                    try? writer.write(body)
                }
            }
            let text = String(data: body, encoding: .utf8) ?? ""
            return errorResponse("upstream_error", text.isEmpty ? "upstream returned \(status)" : text, status: status)
        }
    }

    /// UI-1 · Re-run a gate node by appending a new artifact version for the
    /// same slot. We take the latest version's payload (or, if none exists,
    /// fall back to the node's most recent artifact) and resubmit through
    /// `submitNodeOutput` with `forceNewVersion: true`. This keeps the rerun
    /// path narrow: the server-side append guarantees a new version row and
    /// fires the standard broadcast so other clients see it within 2s.
    static func rerunPlannerNode(_ req: HttpRequest) -> HttpResponse {
        struct RerunRequest: Decodable {
            let reference: String?
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        let body = decodeJSONBody(req, as: RerunRequest.self)
        do {
            let snapshot = BoardLayoutStore.shared.snapshot()
            let actor = PlannerPermission.currentActorId()
            let state = try PlannerBoardBridge.canvasState(
                for: canvasId,
                snapshot: snapshot,
                actorUserId: actor
            )
            guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
                return errorResponse("not_found", "node not found", status: 404)
            }
            // Locate the slot to rerun. Caller may pin a specific reference;
            // otherwise pick the most recent artifact attached to the node.
            let candidates = state.artifacts.filter { $0.nodeId == nodeId }
            let pickedArtifact: PlannerArtifact?
            if let requested = body?.reference?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
                // P1 (Codex review): when caller pins a specific reference,
                // refuse to silently fall back to latest — a typoed reference
                // would otherwise rerun the wrong slot.
                guard let match = candidates.first(where: { $0.reference == requested }) else {
                    return errorResponse(
                        "artifact_slot_not_found",
                        "requested reference \"\(requested)\" not found on this node",
                        status: 404
                    )
                }
                pickedArtifact = match
            } else {
                pickedArtifact = candidates.sorted(by: { $0.createdAt > $1.createdAt }).first
            }
            guard let artifact = pickedArtifact else {
                return errorResponse(
                    "no_artifact",
                    "node has no existing artifact to re-run; submit a first output before re-running",
                    status: 409
                )
            }
            let rerunArtifact = PlannerNodeOutputArtifact(
                kind: artifact.kind,
                title: artifact.title,
                reference: artifact.reference,
                payload: artifact.payload,
                routeTo: []
            )
            // Mirror the previous run's terminal disposition: if the node is
            // already done, keep it done; otherwise treat the rerun as needing
            // owner review (matches the "re-run this" UX where the user wants
            // to look at the output again).
            let rerunStatus: PlannerNodeOutputStatus = node.status == .done ? .done : .needsReview
            let rerunNext: PlannerNodeOutputNext = node.status == .done ? .complete : .needsOwnerReview
            let output = PlannerNodeOutput(
                nodeId: nodeId,
                status: rerunStatus,
                message: nil,
                artifacts: [rerunArtifact],
                next: rerunNext,
                forceNewVersion: true
            )
            let result = try PlannerBoardBridge.submitNodeOutput(
                nodeId: nodeId,
                output: output,
                for: canvasId,
                snapshot: snapshot,
                actorUserId: actor
            )
            routePlannerOutputMessages(result.routes)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(result, status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func createPlannerSubCanvasFromNode(_ req: HttpRequest) -> HttpResponse {
        struct CreateSubCanvasRequest: Decodable {
            let title: String?
            let scope: String?
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        let body = decodeJSONBody(req, as: CreateSubCanvasRequest.self)
        let scope: BoardLayoutStore.CanvasScope = body?.scope == "team" ? .team : .personal
        do {
            let subCanvasName = (body?.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Sub-canvas"
            let snapshot = try BoardLayoutStore.shared.createCanvas(name: subCanvasName, scope: scope)
            guard let subCanvas = snapshot.canvases.first(where: { $0.name == subCanvasName }) ?? snapshot.canvases.last else {
                return errorResponse("planner_error", "failed to create sub-canvas", status: 400)
            }
            let proposal = try PlannerBoardBridge.createSubCanvasProposal(
                nodeId: nodeId,
                subCanvasId: subCanvas.id,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func openKanbanItemSubCanvas(_ req: HttpRequest) -> HttpResponse {
        struct OpenKanbanItemRequest: Decodable {
            let title: String?
            let scope: String?
            let existingSubCanvasId: String?
        }
        struct OpenKanbanItemResponse: Encodable {
            let subCanvasId: String
            let action: String
            let message: String
            let graph: PlannerGraphStateEnvelope
        }
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let artifactId = req.params[":artifactId"], !artifactId.isEmpty,
              let itemId = req.params[":itemId"], !itemId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id, artifact id, or item id", status: 400)
        }
        let body = decodeJSONBody(req, as: OpenKanbanItemRequest.self)
        let scope: BoardLayoutStore.CanvasScope = body?.scope == "team" ? .team : .personal
        do {
            let existingSubCanvasId = body?.existingSubCanvasId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingSubCanvasId, !existingSubCanvasId.isEmpty {
                let snapshot = BoardLayoutStore.shared.snapshot()
                if snapshot.canvases.contains(where: { $0.id == existingSubCanvasId }) {
                    let state = try PlannerBoardBridge.graphState(
                        for: canvasId,
                        snapshot: snapshot,
                        actorUserId: PlannerPermission.currentActorId()
                    )
                    return jsonResponse(OpenKanbanItemResponse(
                        subCanvasId: existingSubCanvasId,
                        action: "opened",
                        message: "Opened existing sub-canvas.",
                        graph: graphEnvelope(state)
                    ))
                }
            }
            let title = (body?.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Kanban item"
            let snapshot = try BoardLayoutStore.shared.createCanvas(name: title, scope: scope)
            guard let subCanvas = snapshot.canvases.first(where: { $0.id == snapshot.activeCanvasId }) else {
                return errorResponse("planner_error", "failed to create sub-canvas", status: 400)
            }
            let state = try PlannerBoardBridge.bindKanbanItemSubCanvas(
                artifactId: artifactId,
                itemId: itemId,
                subCanvasId: subCanvas.id,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(OpenKanbanItemResponse(
                subCanvasId: subCanvas.id,
                action: existingSubCanvasId?.isEmpty == false ? "replaced_missing" : "created",
                message: existingSubCanvasId?.isEmpty == false
                    ? "Previous sub-canvas was missing; created and linked a new one."
                    : "Created and linked a sub-canvas.",
                graph: graphEnvelope(state)
            ), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func updatePlannerNodeLayout(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let nodeId = req.params[":nodeId"], !nodeId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or node id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: PlannerNodeLayout.self) else {
            return errorResponse("invalid_json", "body must be PlannerNodeLayout", status: 400)
        }
        do {
            let state = try PlannerBoardBridge.updateNodeLayout(
                nodeId: nodeId,
                layout: body,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(graphEnvelope(state))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func approvePlannerProposal(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let proposalId = req.params[":proposalId"], !proposalId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or proposal id", status: 400)
        }
        do {
            let proposal = try PlannerBoardBridge.approveProposal(
                proposalId: proposalId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func applyPlannerProposal(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let proposalId = req.params[":proposalId"], !proposalId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or proposal id", status: 400)
        }
        do {
            let result = try PlannerBoardBridge.applyProposal(
                proposalId: proposalId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            recordPlannerDispatchIntents(canvasId: canvasId, proposal: result.proposal, nodes: result.nodes)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(PlannerApplyPreviewEnvelope(
                proposal: result.proposal,
                nodes: result.nodes,
                states: result.states,
                edges: result.edges,
                artifacts: result.artifacts
            ))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func rejectPlannerProposal(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"], !canvasId.isEmpty,
              let proposalId = req.params[":proposalId"], !proposalId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id or proposal id", status: 400)
        }
        do {
            let proposal = try PlannerBoardBridge.rejectProposal(
                proposalId: proposalId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal))
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    static func mapPlannerCoreError(_ err: PlannerCoreError) -> HttpResponse {
        switch err {
        case .canvasNotFound, .proposalNotFound, .runNotFound,
             .dataSourceNotFound, .edgeNotFound, .monitorCardNotFound,
             .artifactNotFound:
            return errorResponse("not_found", err.localizedDescription, status: 404)
        case .monitorSpecReplaceGuard:
            return errorResponse("monitor_spec_replace_guard", err.localizedDescription, status: 409)
        case .plannerStateUnreadable:
            return errorResponse("planner_state_unreadable", err.localizedDescription, status: 409)
        case .monitorClearNotAllowed:
            return errorResponse("monitor_clear_not_allowed", err.localizedDescription, status: 409)
        case .permissionDenied:
            return errorResponse("forbidden", err.localizedDescription, status: 403)
        case .proposalNotApproved,
             .canvasMismatch,
             .emptyProposalChanges,
             .invalidPlannerProposalJSON,
             .missingNodeForAdd,
             .missingNodeId,
             .nodeNotFound,
             .updateNodeNoFields,
             .crossCanvasNodeReference,
             .unknownNodeKind,
             .unknownChangeKind,
             .invalidNodeOutput:
            return errorResponse("planner_error", err.localizedDescription, status: 400)
        case .activeSessionExists:
            return errorResponse("active_session_exists", err.localizedDescription, status: 409)
        case .sessionKindNoLongerCreatable:
            // epsilon (session-hide): addNode validator rejects new
            // session-kind nodes. Surface a distinct error code so the
            // UI / agent can suggest the step + dispatch.runner=claude
            // migration rather than treating it as a generic 400.
            return errorResponse("session_kind_no_longer_creatable", err.localizedDescription, status: 400)
        case .applyRejected:
            // 方向 A:apply 委托 sidecar 时 governance 校验拒绝(引用完整性 / 事务原子 / footgun)。
            return errorResponse("apply_rejected", err.localizedDescription, status: 422)
        }
    }

    private static func recordPlannerDispatchIntents(canvasId: String, proposal: PlanProposal, nodes: [PlanningNode]) {
        let changedNodeIds = Set(proposal.changes.compactMap { change in
            change.nodeId ?? change.node?.id
        })
        for node in nodes where changedNodeIds.contains(node.id) && node.workflowRunState == .dispatched {
            _ = try? recordPlannerDispatchIntent(canvasId: canvasId, node: node, cwdOverride: nil)
        }
    }

    private struct PlannerDispatchSpawnRequest {
        let cwd: String
        let command: String
        let provider: String
        let purpose: String
        let initialPrompt: String
    }

    /// Record the CLI spawn intent for a single dispatched node. Shared by the
    /// proposal-apply path (`recordPlannerDispatchIntents`) and the direct
    /// dispatch endpoint. `ci-agent` / `human` produce no intent
    /// (`spawnsSession` is false for both).
    private static func recordPlannerDispatchIntent(
        canvasId: String,
        node: PlanningNode,
        cwdOverride: String?,
        initialPromptOverride: String? = nil,
        includeInitialPromptInIntent: Bool = true
    ) throws -> PlannerDispatchSpawnRequest? {
        guard node.workflowRunState == .dispatched else { return nil }
        guard let dispatch = node.dispatch, dispatch.runner.spawnsSession else { return nil }
        let cwd = try explicitSessionCwd(cwdOverride) ?? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
        let storedCommand = dispatch.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCommand = storedCommand?.isEmpty == false
            ? storedCommand!
            : (dispatch.runner.spawnCommand ?? "claude")
        let launch = AgentLaunchCommand.normalize(
            command: rawCommand,
            fallbackProvider: dispatch.runner.rawValue
        )
        let command = AgentLaunchCommand.commandRequestsResume(launch.command)
            ? AgentLaunchCommand.fullAccessCommand(forProvider: launch.provider)
            : launch.command
        // Purpose is tagged with the *step* node id; the session PlanningNode
        // (created alongside the dispatch) `dependsOnNodeIds` this step, so
        // `PlannerSessionRunStateBridge` can resolve step → session.
        let purpose = "planner:\(node.id)"
        let basePrompt = plannerDispatchPrompt(for: node, canvasId: canvasId, cwd: cwd)
        let scenePrompt = initialPromptOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPrompt = scenePrompt?.isEmpty == false
            ? "\(basePrompt)\n\nScene action:\n\(scenePrompt!)"
            : basePrompt
        try BoardLayoutStore.shared.recordSpawnIntent(
            canvasId: canvasId,
            cwd: cwd,
            command: command,
            provider: launch.provider,
            purpose: purpose,
            initialPrompt: includeInitialPromptInIntent ? initialPrompt : nil,
            layoutHint: nil
        )
        return PlannerDispatchSpawnRequest(
            cwd: cwd,
            command: command,
            provider: launch.provider,
            purpose: purpose,
            initialPrompt: initialPrompt
        )
    }

    // internal (was private) so the PRD-pipeline E2E test can assert criterion 2:
    // dispatch generates a non-empty default prompt carrying the node protocol.
    static func plannerDispatchPrompt(for node: PlanningNode, canvasId: String, cwd: String) -> String {
        let inlineLimitKB = PlannerArtifactStorage.inlinePayloadLimitBytes / 1024
        let artifactTypes = PlannerArtifactPayloadType.allCases.map(\.rawValue).joined(separator: ", ")
        var lines = [
            "You are executing a meee2 planner node. This prompt is generated by meee2 runtime rules.",
            "",
            "Identity:",
            "- canvasId: \(canvasId)",
            "- nodeId: \(node.id)",
            "- node: \(node.title)",
            "- workspace: \(cwd)",
            "- doer: \(node.doerId)",
            "",
            "Skill:",
            "- Use the Meee2 Skill if this runtime has it installed.",
            "",
            "Required protocol:",
            "1. First call the Meee2 MCP tool read_node_contract with this canvasId and nodeId.",
            "2. Do the node work using the contract as the source of truth.",
            "3. Finish by calling submit_node_output with the same canvasId and nodeId.",
            "4. Do not rely on terminal text, markdown summaries, or files alone to update the canvas.",
            "5. If the client shows namespaced tool names, use mcp__meee2__read_node_contract and mcp__meee2__submit_node_output.",
            "",
            "Completion signal:",
            "- \(node.schema.goal)",
            "",
            "Artifact submission rules:",
            "- Supported payload.type values: \(artifactTypes).",
            "- If read_node_contract says output.payload_kind=artifact_ref, submit artifacts[] and put the expected output slot name in artifact.reference; do not submit an artifact_ref wrapper.",
            "- Canonical inline payload examples: {\"type\":\"json\",\"json\":\"{...}\"}, {\"type\":\"text\",\"text\":\"...\"}, {\"type\":\"html\",\"html\":\"<main>...</main>\"}. Do not use a bare string or {\"content\":...} as artifact payload.",
            "- Inline payloads are allowed up to \(inlineLimitKB)KB.",
            "- For larger text/html/json/file output, write the file inside the workspace and submit payload.file.path.",
            "- Meee2 will copy file-backed artifacts into its artifact store; do not depend on the original file path as the long-term artifact.",
            "- submit_node_output is the final writeback for the attempt. attach_artifact_to_node is only for interim evidence and does not complete the node.",
            "- If this node is blocked, call submit_node_output with status blocked and include the concrete blocker in message.summary.",
            "",
            "External tools:",
            "- If the node requires an external system such as Lark, GitHub, Linear, or a database, use the relevant available MCP/tool for that system.",
            "- Regardless of external tools used, structured planner results must be written back through Meee2 MCP.",
            "- If the node contract needs different inputs, outputs, artifact slots, gates, or task requirements, ask for a planner graph change through Meee2 rather than only editing local notes."
        ]
        if !node.schema.inputs.isEmpty {
            lines.append("")
            lines.append("Expected inputs:")
            for input in node.schema.inputs {
                lines.append("- \(input)")
            }
        }
        if !node.schema.outputs.isEmpty {
            lines.append("")
            lines.append("Expected outputs:")
            for output in node.schema.outputs {
                lines.append("- \(output)")
            }
        }
        let inputBindings = node.contextSources.filter { source in
            node.schema.inputs.contains { $0.caseInsensitiveCompare(source.title) == .orderedSame }
        }
        if !inputBindings.isEmpty {
            lines.append("")
            lines.append("Input bindings:")
            for source in inputBindings {
                lines.append("- \(source.title): \(source.reference)")
            }
        } else if !node.contextSources.isEmpty {
            lines.append("")
            lines.append("Context sources:")
            for source in node.contextSources {
                lines.append("- \(source.title): \(source.reference)")
            }
        }
        if let gate = node.gate {
            lines.append("")
            lines.append("Gate:")
            lines.append("- \(gate.label)")
        }
        return lines.joined(separator: "\n")
    }

    private static func routePlannerOutputMessages(_ routes: [PlannerOutputRoute]) {
        for route in routes {
            guard let sessionId = route.targetSessionId,
                  let message = plannerOutputMessage(route: route) else { continue }
            do {
                let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: sessionId)
                _ = try MessageRouter.shared.send(
                    channel: channelName,
                    fromAlias: "operator",
                    toAlias: "session",
                    content: message,
                    injectedByHuman: false
                )
            } catch {
                MWarn("[PlannerOutput] route to session \(sessionId.prefix(8)) failed: \(error.localizedDescription)")
            }
        }
    }

    private static func plannerOutputMessage(route: PlannerOutputRoute) -> String? {
        var lines: [String] = []
        if let routedMessage = route.routedMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !routedMessage.isEmpty {
            lines.append(routedMessage)
        }
        if !route.artifactRefs.isEmpty {
            lines.append("Artifacts:")
            for ref in route.artifactRefs {
                lines.append("- \(ref)")
            }
        }
        guard !lines.isEmpty else { return nil }
        return [
            "Planner routed upstream output to this node.",
            "",
            lines.joined(separator: "\n"),
            "",
            "Use read_node_contract before continuing, then submit_node_output when this node is complete or blocked."
        ].joined(separator: "\n")
    }

    /// BUG 1.1 — demote stale "running" nodes whose bound session no longer
    /// exists. Computes the live session set once and hands a matcher closure to
    /// the planner store. Called right before every canvas/graph read so the UI
    /// never shows `running` for a session that died while the app was closed.
    private static func reconcilePlannerRunState(canvasId: String) {
        let liveSessions = BoardSessionSnapshotProvider.currentBoardSessions()
        _ = try? PlannerBoardBridge.store.reconcileRunStateAgainstLiveSessions(
            canvasId: canvasId,
            isLive: { sessionId in isPlannerSessionLive(sessionId, in: liveSessions) }
        )
    }

    private static func plannerNodeNeedsLiveSession(_ node: PlanningNode) -> Bool {
        if node.schedule?.enabled == true { return true }
        if node.status == .done || node.workflowRunState == .done { return false }
        return true
    }

    private static func isPlannerSessionLive(_ sessionId: String, in sessions: [SessionDTO]) -> Bool {
        sessions.contains { session in
            guard boardSession(session, matches: sessionId) else { return false }
            if SessionStatus.from(rawString: session.status).isHistorical { return false }
            if let surfaceStatus = session.surfaceStatus?.lowercased(),
               surfaceStatus == "exited" || surfaceStatus == "failed" {
                return false
            }
            return true
        }
    }

    private static func boardSession(_ session: SessionDTO, matches sessionId: String) -> Bool {
        let needle = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        var candidates = [session.id]
        let prefix = "\(session.pluginId)-"
        if session.id.hasPrefix(prefix) {
            candidates.append(String(session.id.dropFirst(prefix.count)))
        }
        return candidates.contains { candidate in
            candidate == needle
                || candidate.hasSuffix("-\(needle)")
                || needle.hasSuffix("-\(candidate)")
        }
    }

    private static func plannerResumeCommand(for node: PlanningNode?, sessionId: String) -> String {
        let command = node?.dispatch?.command ?? node?.dispatch?.runner.spawnCommand ?? ""
        let provider = AgentLaunchCommand.provider(forCommand: command.isEmpty ? node?.dispatch?.runner.rawValue ?? "claude" : command)
        if AgentLaunchCommand.isMeee2InternalSessionId(sessionId) {
            return AgentLaunchCommand.fullAccessCommand(forProvider: provider)
        }
        return AgentLaunchCommand.resumeCommand(forProvider: provider, sessionId: sessionId)
    }

    private static func plannerFreshCommand(for node: PlanningNode?) -> String {
        let rawCommand = node?.dispatch?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = node?.dispatch?.runner.spawnCommand ?? AgentLaunchCommand.fullAccessCommand(forProvider: node?.dispatch?.runner.rawValue ?? "claude")
        let launch = AgentLaunchCommand.normalize(
            command: rawCommand?.isEmpty == false ? rawCommand! : fallback,
            fallbackProvider: node?.dispatch?.runner.rawValue ?? "claude"
        )
        if AgentLaunchCommand.commandRequestsResume(launch.command) {
            return AgentLaunchCommand.fullAccessCommand(forProvider: launch.provider)
        }
        return launch.command
    }

    private static func isProviderResumeSessionId(_ sessionId: String) -> Bool {
        AgentLaunchCommand.isLikelyProviderResumeSessionId(sessionId)
    }

    private static func providerResumeSessionId(forPlannerSessionId sessionId: String) -> String? {
        providerResumeSessionIdForManagedSurface(sessionId)
            ?? (isProviderResumeSessionId(sessionId) ? sessionId : nil)
    }

    private static func providerResumeSessionIdForManagedSurface(_ sessionId: String) -> String? {
        if let mapped = SessionTerminalStore.shared.get(sessionId: sessionId)?.providerResumeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty,
           !AgentLaunchCommand.isMeee2InternalSessionId(mapped) {
            return mapped
        }
        return nil
    }

    private static func canonicalSessionKey(_ session: PluginSession) -> String {
        canonicalSessionKey(pluginId: session.pluginId, sessionId: session.id)
    }

    private static func canonicalSessionKey(pluginId: String, sessionId: String) -> String {
        let prefix = "\(pluginId)-"
        let rawId = sessionId.hasPrefix(prefix)
            ? String(sessionId.dropFirst(prefix.count))
            : sessionId
        return "\(pluginId)::\(rawId)"
    }

    private static func explicitSessionCwd(_ raw: String?) throws -> String? {
        var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("~") {
            value = NSHomeDirectory() + String(value.dropFirst(1))
        }
        let normalized = (value as NSString).standardizingPath
        guard normalized.hasPrefix("/") else {
            throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd must be an absolute path"])
        }
        guard normalized != "/" && normalized != NSHomeDirectory() else {
            throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd is too broad"])
        }
        return normalized
    }

    // MARK: - GET /api/user-profile

    static func getUserProfile(_ req: HttpRequest) -> HttpResponse {
        let settings = readMeee2OnlineSettings()
        let defaults = UserDefaults.standard
        let connected = defaults.bool(forKey: "meee2Connected")
        let userName = connected
            ? defaultString(defaults, key: "meee2UserName", fallback: settings["userName"])
            : ""
        let userEmail = connected
            ? defaultString(defaults, key: "meee2UserEmail", fallback: settings["userEmail"])
            : ""
        let userAvatarUrl = connected
            ? defaultString(defaults, key: "meee2UserAvatarUrl", fallback: settings["userAvatarUrl"])
            : ""
        let userId = connected
            ? defaultString(defaults, key: "meee2UserId", fallback: settings["userId"])
            : "local-user"
        let displayName: String
        if !userName.isEmpty {
            displayName = userName
        } else if !userEmail.isEmpty {
            displayName = userEmail.components(separatedBy: "@").first ?? userEmail
        } else {
            displayName = connected ? "meee2 user" : "Not connected"
        }

        return jsonResponse(UserProfileDTO(
            connected: connected,
            userId: userId,
            displayName: displayName,
            userName: userName,
            userEmail: userEmail,
            userAvatarUrl: userAvatarUrl,
            initials: initials(for: displayName, connected: connected),
            dashboardUrl: Meee2OnlineConfig.appURL(path: "dashboard").absoluteString,
            connectUrl: meee2ConnectUrl().absoluteString,
            teams: BoardDTOBuilder.meee2OnlineTeams()
        ))
    }

    // MARK: - GET /api/team/members

    /// Team member directory for assignment and Team UI. This endpoint must
    /// only expose real meee2 Online team members; planner doer/activity ids
    /// are local execution identities and are not assignable people.
    static func getTeamMembers(_ req: HttpRequest) -> HttpResponse {
        let settings = OnlineProxy.loadSettings()
        guard !settings.teamId.isEmpty else {
            return jsonResponse(TeamMembersEnvelope(members: []))
        }

        let path = "/api/v1/team/\(urlPath(settings.teamId))/members"
        switch OnlineProxy.callOnlineAPI(method: "GET", path: path, settings: settings) {
        case .success(let data):
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["members"] as? [[String: Any]] else {
                return errorResponse("bad_gateway", "meee2-online team members response is invalid", status: 502)
            }
            let members = rows.compactMap { row -> TeamMemberDTO? in
                guard let userId = stringValue(row["userId"]) else { return nil }
                return TeamMemberDTO(
                    userId: userId,
                    displayName: stringValue(row["displayName"]) ?? userId,
                    email: stringValue(row["email"]),
                    avatarUrl: stringValue(row["avatarUrl"]),
                    role: stringValue(row["role"]),
                    publicCanvasCount: intValue(row["publicCanvasCount"]),
                    lastCanvasUpdatedAt: stringValue(row["lastCanvasUpdatedAt"])
                )
            }
            return jsonResponse(TeamMembersEnvelope(members: members))
        case .failure(let err):
            return mapOnlineProxyError(err)
        }
    }

    static func openMeee2OnlineConnect(_ req: HttpRequest) -> HttpResponse {
        NSWorkspace.shared.open(meee2ConnectUrl())
        return jsonResponse(OkEnvelope(ok: true))
    }

    static func openMeee2OnlineDashboard(_ req: HttpRequest) -> HttpResponse {
        NSWorkspace.shared.open(Meee2OnlineConfig.appURL(path: "dashboard"))
        return jsonResponse(OkEnvelope(ok: true))
    }

    // MARK: - GET/PATCH /api/app-settings

    static func getAppSettings(_ req: HttpRequest) -> HttpResponse {
        return jsonResponse(appSettingsDTO())
    }

    static func updateAppSettings(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }

        let defaults = UserDefaults.standard
        var didChangeIslandVisibility = false
        var didChangeScreenSelection = false

        if let theme = json["theme"] as? String, ["system", "light", "dark"].contains(theme) {
            defaults.set(theme, forKey: "meee2.theme")
        }
        if let locale = json["locale"] as? String, ["en", "zh-CN"].contains(locale) {
            defaults.set(locale, forKey: "meee2.locale")
        }
        if let showIsland = json["showIsland"] as? Bool {
            let previous = defaults.object(forKey: "showIsland") as? Bool ?? true
            defaults.set(showIsland, forKey: "showIsland")
            didChangeIslandVisibility = previous != showIsland
        }
        if let selectedScreenId = json["selectedScreenId"] as? String,
           !selectedScreenId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let previous = defaults.string(forKey: "selectedScreenId") ?? "builtin"
            defaults.set(selectedScreenId, forKey: "selectedScreenId")
            didChangeScreenSelection = previous != selectedScreenId
        }
        if let autoExpandEnabled = json["autoExpandEnabled"] as? Bool {
            defaults.set(autoExpandEnabled, forKey: "autoExpandEnabled")
        }
        if let autoCloseInterval = numeric(json["autoCloseInterval"]) {
            defaults.set(clamp(autoCloseInterval, min: 3, max: 30), forKey: "autoCloseInterval")
        }
        if let showSessionInCompact = json["showSessionInCompact"] as? Bool {
            defaults.set(showSessionInCompact, forKey: "showSessionInCompact")
        }
        if let carouselInterval = numeric(json["carouselInterval"]) {
            defaults.set(clamp(carouselInterval, min: 3, max: 30), forKey: "carouselInterval")
        }
        if let quickOpenShortcut = json["quickOpenShortcut"] as? String {
            guard let shortcut = QuickOpenShortcut(rawValue: quickOpenShortcut) else {
                return errorResponse("invalid_shortcut", "quickOpenShortcut is not a supported key combination", status: 400)
            }
            let current = QuickOpenShortcut.current
            if shortcut == current {
                QuickOpenShortcut.setCurrentConflictWarning(QuickOpenShortcut.currentConflictWarning)
            } else {
                QuickOpenShortcut.setCurrentConflictWarning(QuickOpenShortcut.conflictWarning(for: shortcut))
            }
            QuickOpenShortcut.current = shortcut
        }

        DispatchQueue.main.async {
            if didChangeIslandVisibility {
                NotificationCenter.default.post(name: Notification.Name("islandVisibilityChanged"), object: nil)
            }
            if didChangeScreenSelection {
                NotificationCenter.default.post(name: Notification.Name("screenSelectionChanged"), object: nil)
            }
        }

        return jsonResponse(appSettingsDTO())
    }

    static func openMeee2Settings(_ req: HttpRequest) -> HttpResponse {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("openSettings"), object: nil)
        }
        return jsonResponse(OkEnvelope(ok: true))
    }

    static func e2eSyncTeamCanvases(_ req: HttpRequest) -> HttpResponse {
        _ = req
        guard ProcessInfo.processInfo.environment["MEEE2_E2E"] == "1" else {
            return errorResponse("not_found", "E2E routes are disabled", status: 404)
        }
        let ok = Meee2OnlinePusher.shared.syncTeamCanvasesForE2E()
        guard ok else {
            return errorResponse("sync_timeout", "team canvas sync did not finish before timeout", status: 503)
        }
        return jsonResponse(canvasEnvelope(BoardLayoutStore.shared.snapshot()))
    }

    static func e2eUpsertSession(_ req: HttpRequest) -> HttpResponse {
        guard ProcessInfo.processInfo.environment["MEEE2_E2E"] == "1" else {
            return errorResponse("not_found", "E2E routes are disabled", status: 404)
        }
        guard let sessionId = req.params[":id"], !sessionId.isEmpty else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }

        let now = Date()
        let status = SessionStatus.from(rawString: (json["status"] as? String) ?? "active")
        let transcriptPath = e2eTranscriptPath(sessionId: sessionId)
        var session = SessionStore.shared.get(sessionId) ?? SessionData(
            sessionId: sessionId,
            project: (json["project"] as? String) ?? "E2E Session",
            cwd: (json["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
            transcriptPath: transcriptPath,
            startedAt: now,
            lastActivity: now,
            status: status
        )
        session.project = (json["project"] as? String) ?? session.project
        session.cwd = (json["cwd"] as? String) ?? session.cwd
        session.transcriptPath = transcriptPath
        session.status = status
        session.currentTool = json["currentTool"] as? String
        session.currentTask = json["currentTask"] as? String
        session.lastMessage = json["lastMessage"] as? String
        session.lastActivity = now

        SessionStore.shared.upsert(session)
        if let syncError = Meee2OnlinePusher.shared.syncSessionForE2E(sessionId: sessionId) {
            return errorResponse("sync_failed", syncError, status: 503)
        }
        return jsonResponse(OkEnvelope(ok: true))
    }

    static func e2eAppendSessionMessage(_ req: HttpRequest) -> HttpResponse {
        guard ProcessInfo.processInfo.environment["MEEE2_E2E"] == "1" else {
            return errorResponse("not_found", "E2E routes are disabled", status: 404)
        }
        guard let sessionId = req.params[":id"], !sessionId.isEmpty else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let role = (json["role"] as? String) ?? "assistant"
        let text = (json["text"] as? String) ?? ""
        guard !text.isEmpty else {
            return errorResponse("bad_request", "missing text", status: 400)
        }

        do {
            try appendE2ETranscriptLine(sessionId: sessionId, role: role, text: text)
            if SessionStore.shared.get(sessionId) == nil {
                let now = Date()
                SessionStore.shared.upsert(SessionData(
                    sessionId: sessionId,
                    project: "E2E Session",
                    cwd: FileManager.default.currentDirectoryPath,
                    transcriptPath: e2eTranscriptPath(sessionId: sessionId),
                    startedAt: now,
                    lastActivity: now,
                    status: .active,
                    lastMessage: text
                ))
            } else {
                SessionStore.shared.update(sessionId) { session in
                    session.transcriptPath = e2eTranscriptPath(sessionId: sessionId)
                    session.lastMessage = text
                    session.lastActivity = Date()
                }
            }
            SessionEventBus.shared.publish(.transcriptAppended(sessionId: sessionId))
            if let syncError = Meee2OnlinePusher.shared.syncSessionForE2E(sessionId: sessionId) {
                return errorResponse("sync_failed", syncError, status: 503)
            }
            return jsonResponse(OkEnvelope(ok: true))
        } catch {
            return errorResponse("internal_error", error.localizedDescription, status: 500)
        }
    }

    private static func e2eTranscriptPath(sessionId: String) -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent("e2e-transcripts", isDirectory: true)
        return base.appendingPathComponent("\(sessionId).jsonl").path
    }

    private static func appendE2ETranscriptLine(sessionId: String, role: String, text: String) throws {
        let path = e2eTranscriptPath(sessionId: sessionId)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "type": role,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": [
                "role": role,
                "content": [["type": "text", "text": text]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = Data(data)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    static func updateUserProfile(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }

        let ignoredLegacyKeys = ["defaultSyncEnabled", "sessionSync"]
        if ignoredLegacyKeys.contains(where: { json.keys.contains($0) }) {
            MWarn("[BoardAPI] Ignored legacy user-profile session sync patch")
        }
        persistMeee2OnlineSettings()
        Meee2OnlinePusher.shared.refreshActivation()
        return getUserProfile(req)
    }

    static func disconnectMeee2Online(_ req: HttpRequest) -> HttpResponse {
        clearMeee2OnlineSettings()
        Meee2OnlinePusher.shared.refreshActivation()
        return jsonResponse(OkEnvelope(ok: true))
    }

    private static func appSettingsDTO() -> AppSettingsDTO {
        let defaults = UserDefaults.standard
        return AppSettingsDTO(
            theme: validTheme(defaults.string(forKey: "meee2.theme")),
            locale: validLocale(defaults.string(forKey: "meee2.locale")),
            devMode: appDevMode(),
            showIsland: defaults.object(forKey: "showIsland") as? Bool ?? true,
            selectedScreenId: defaults.string(forKey: "selectedScreenId") ?? "builtin",
            availableScreens: availableScreenDTOs(),
            autoExpandEnabled: defaults.object(forKey: "autoExpandEnabled") as? Bool ?? true,
            autoCloseInterval: storedDouble(defaults, key: "autoCloseInterval", fallback: 8),
            showSessionInCompact: defaults.object(forKey: "showSessionInCompact") as? Bool ?? true,
            carouselInterval: storedDouble(defaults, key: "carouselInterval", fallback: 10),
            quickOpenShortcut: QuickOpenShortcut.current.rawValue,
            quickOpenShortcutLabel: QuickOpenShortcut.current.menuDisplayName,
            quickOpenShortcutConflict: QuickOpenShortcut.currentConflictWarning
        )
    }

    private static func appDevMode() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func availableScreenDTOs() -> [AppSettingsScreenDTO] {
        NSScreen.screens.map { screen in
            AppSettingsScreenDTO(
                id: screen.isBuiltinDisplay ? "builtin" : screen.screenId,
                name: screen.displayName,
                hasNotch: screen.notchSize != .zero
            )
        }
    }

    private static func validTheme(_ value: String?) -> String {
        guard let value, ["system", "light", "dark"].contains(value) else { return "system" }
        return value
    }

    private static func validLocale(_ value: String?) -> String {
        guard let value, ["en", "zh-CN"].contains(value) else { return "en" }
        return value
    }

    private static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        default:
            return nil
        }
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    private static func storedDouble(_ defaults: UserDefaults, key: String, fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    private static func readMeee2OnlineSettings() -> [String: Any] {
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2/settings.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meee2 = root["meee2"] as? [String: Any] else {
            return [:]
        }
        return meee2
    }

    private static func stringSetting(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func defaultString(_ defaults: UserDefaults, key: String, fallback: Any?) -> String {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? stringSetting(fallback) : value
    }

    private static func initials(for displayName: String, connected: Bool) -> String {
        guard connected else { return "?" }
        let parts = displayName.split { ch in
            ch == " " || ch == "." || ch == "_" || ch == "-" || ch == "@"
        }
        let value = parts.prefix(2).compactMap { $0.first?.uppercased() }.joined()
        return value.isEmpty ? "U" : value
    }

    private static func meee2ConnectUrl() -> URL {
        var components = URLComponents(url: Meee2OnlineConfig.appURL(path: "connect"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback", value: "\(BoardServer.shared.url)/meee2/callback")
        ]
        return components.url!
    }

    private static func clearMeee2OnlineSettings() {
        let defaults = UserDefaults.standard
        for key in [
            "meee2Connected",
            "meee2Online",
            "meee2TeamId",
            "meee2TeamName",
            "meee2Teams",
            "meee2SessionTeamIds",
            "meee2UserId",
            "meee2UserName",
            "meee2UserEmail",
            "meee2UserAvatarUrl",
            "meee2SupabaseUrl",
            "meee2SupabaseKey",
            "meee2OnlineBaseUrl",
            "meee2OnlineAccessToken",
            "meee2OnlineRefreshToken",
            "meee2EnabledSessionIds",
            "meee2DisabledSessionIds"
        ] {
            defaults.removeObject(forKey: key)
        }

        let settings: [String: Any] = [
            "meee2": [
                "enabled": false,
                "online": false,
                "teams": [],
                "sessionTeamIds": [:],
                "defaultSyncEnabled": false,
                "enabledSessionIds": [],
                "disabledSessionIds": [],
                "machineId": Host.current().name ?? "unknown",
                "sessionKey": "claude-\(ProcessInfo.processInfo.processIdentifier)"
            ]
        ]
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".meee2")
        let file = dir.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func persistMeee2OnlineSettings() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "meee2Connected") else { return }
        let rawSupabaseUrl = defaults.string(forKey: "meee2SupabaseUrl") ?? ""
        let normalizedSupabaseUrl = (rawSupabaseUrl.removingPercentEncoding ?? rawSupabaseUrl)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let teams: [[String: Any]] = BoardDTOBuilder.meee2OnlineTeams().map { team in
            return [
                "id": team.id,
                "name": team.name,
                "role": team.role ?? ""
            ]
        }
        let meee2Settings: [String: Any] = [
            "enabled": true,
            "online": defaults.bool(forKey: "meee2Connected"),
            "supabaseUrl": normalizedSupabaseUrl,
            "supabaseKey": defaults.string(forKey: "meee2SupabaseKey") ?? "",
            "onlineBaseUrl": defaults.string(forKey: "meee2OnlineBaseUrl") ?? "",
            "accessToken": defaults.string(forKey: "meee2OnlineAccessToken") ?? "",
            "refreshToken": defaults.string(forKey: "meee2OnlineRefreshToken") ?? "",
            "teamId": defaults.string(forKey: "meee2TeamId") ?? "",
            "userId": defaults.string(forKey: "meee2UserId") ?? "",
            "userName": defaults.string(forKey: "meee2UserName") ?? "",
            "userEmail": defaults.string(forKey: "meee2UserEmail") ?? "",
            "userAvatarUrl": defaults.string(forKey: "meee2UserAvatarUrl") ?? "",
            "teams": teams,
            "sessionTeamIds": [String: String](),
            "defaultSyncEnabled": false,
            "enabledSessionIds": [],
            "disabledSessionIds": [],
            "machineId": Host.current().name ?? "unknown",
            "sessionKey": "claude-\(ProcessInfo.processInfo.processIdentifier)"
        ]
        let settings: [String: Any] = ["meee2": meee2Settings]

        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".meee2")
        let file = dir.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Automations

    static func listAutomations(_ req: HttpRequest) -> HttpResponse {
        return jsonResponse(AutomationsEnvelope(
            templates: AutomationStore.shared.templates,
            automations: AutomationStore.shared.list()
        ))
    }

    static func createAutomation(_ req: HttpRequest) -> HttpResponse {
        guard let body = parseJSONBody(req) else {
            return errorResponse("invalid_json", "expected JSON body", status: 400)
        }
        do {
            let automation = try AutomationStore.shared.create(input: body)
            return jsonResponse(AutomationEnvelope(automation: automation), status: 201, reason: "Created")
        } catch AutomationStoreError.validation(let message) {
            return errorResponse("validation_error", message, status: 400)
        } catch {
            return errorResponse("automation_store_error", error.localizedDescription, status: 500)
        }
    }

    static func deleteAutomation(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing automation id", status: 400)
        }
        do {
            try AutomationStore.shared.delete(id: id)
            return jsonResponse(OkEnvelope(ok: true))
        } catch AutomationStoreError.notFound {
            return errorResponse("not_found", "automation not found: \(id)", status: 404)
        } catch {
            return errorResponse("automation_store_error", error.localizedDescription, status: 500)
        }
    }

    static func runAutomation(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing automation id", status: 400)
        }
        guard let automation = AutomationStore.shared.get(id: id) else {
            return errorResponse("not_found", "automation not found: \(id)", status: 404)
        }
        let body = parseJSONBody(req) ?? [:]
        let settings = AssistantAPI.parseSettings(body["settings"] as? [String: Any])
        let startedAt = BoardDTOBuilder.iso(Date())

        let group = DispatchGroup()
        group.enter()
        var output = ""
        var runError: String?
        Task.detached {
            let result = await AssistantAPI.runAutomation(
                title: automation.title,
                prompt: automation.prompt,
                settings: settings
            )
            output = result.output
            runError = result.error
            group.leave()
        }
        if group.wait(timeout: .now() + 180) == .timedOut {
            runError = "automation timed out after 180 seconds"
        }

        do {
            let envelope = try AutomationStore.shared.recordRun(
                automationId: id,
                status: runError == nil ? "succeeded" : "failed",
                output: output,
                error: runError,
                startedAt: startedAt
            )
            return jsonResponse(envelope)
        } catch {
            return errorResponse("automation_store_error", error.localizedDescription, status: 500)
        }
    }

    // MARK: - Sessions

    /// POST /api/sessions/:id/activate
    /// 触发对应 session 的终端跳转（等同于 Island 点击卡片的行为）。
    /// Body: 无。响应: {"ok": true} 或 404。
    ///
    /// 两种情况：
    /// (1) Synthetic Desktop session — 子进程已退出但 metadata 文件还在，
    ///     PluginManager 里查不到 → 直接走 ClaudeDesktopActivator。
    /// (2) Live plugin session — 交给 PluginManager.activateTerminal。
    ///     ClaudePlugin 内部会自己识别 Desktop-backed 然后短路到同一个
    ///     ClaudeDesktopActivator，所以 Island 点击同一个 session 行为一致。
    static func activateSession(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        if let surface = TerminalSessionBackendRegistry.shared.snapshot(id: sid) {
            struct ActivateInternalResponse: Encodable {
                let ok: Bool
                let terminalKind: String
                let surfaceId: String
                let sessionId: String
                let terminalBackend: String
                let nativeWorkspaceAvailable: Bool
                let openTarget: String
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("meee2.openBoardSession"),
                    object: nil,
                    userInfo: [
                        "sessionId": surface.sessionId,
                        "surfaceId": surface.surfaceId
                    ]
                )
            }
            return jsonResponse(ActivateInternalResponse(
                ok: true,
                terminalKind: "internal",
                surfaceId: surface.surfaceId,
                sessionId: surface.sessionId,
                terminalBackend: (TerminalSessionBackendMetadata.kind(forSessionId: surface.sessionId) ?? surface.backend).rawValue,
                nativeWorkspaceAvailable: true,
                openTarget: "native-workspace"
            ))
        }
        return errorResponse("not_found", "managed session not found: \(sid)", status: 404)
    }

    /// DELETE /api/sessions/:id
    /// SIGTERM 真实进程并清掉 SessionStore 记录。
    ///
    /// 失败语义（前端会拿 errorCode 翻译成"请你自己手动关"toast）:
    ///   - no_pid          → 该 session 没 pid（Desktop / Cowork / external chat）
    ///   - not_found       → sid 没匹配上
    ///   - kill_failed     → kill() 系统调用挂了（罕见，errno 会带回去）
    /// 注意：进程已经死了但 card 还在的情况不算失败 —— 直接清记录返回 ok。
    static func closeSession(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        if TerminalSessionBackendRegistry.shared.closeSessionIfExists(id: sid) {
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CloseEnvelope(ok: true, alreadyDead: false))
        }
        // SessionStore 同时支持 full-id 和单一前缀匹配，跟 inject / activate 一致
        let resolved: SessionData? = {
            if let s = SessionStore.shared.get(sid) { return s }
            let matches = SessionStore.shared.listAll().filter { $0.sessionId.hasPrefix(sid) }
            return matches.count == 1 ? matches[0] : nil
        }()
        guard let session = resolved else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }
        guard let pid = session.pid else {
            // Desktop / Cowork / external —— meee2 不持有 pid，必须用户自己回宿主 app 关
            return errorResponse(
                "no_pid",
                "this session has no controllable process — close it from its host app",
                status: 409
            )
        }
        // 进程已经走了：kill(pid, 0) 返回 -1 / ESRCH。直接清掉 lingering card 算成功
        if kill(pid_t(pid), 0) != 0 {
            SessionStore.shared.delete(session.sessionId)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CloseEnvelope(ok: true, alreadyDead: true))
        }
        // SIGTERM —— 让 Claude CLI 有机会 flush transcript / 退出 raw mode 再退出。
        // 不用 SIGKILL：终端会留下乱码 + 没机会 cleanup。
        let r = kill(pid_t(pid), SIGTERM)
        if r != 0 {
            let err = String(cString: strerror(errno))
            return errorResponse("kill_failed", "SIGTERM failed: \(err)", status: 500)
        }
        SessionStore.shared.delete(session.sessionId)
        BoardServer.shared.broadcastStateChanged()
        MLog("[BoardAPI] Closed session \(session.sessionId.prefix(8)) (SIGTERM pid \(pid))")
        return jsonResponse(CloseEnvelope(ok: true, alreadyDead: false))
    }

    private struct CloseEnvelope: Encodable {
        let ok: Bool
        let alreadyDead: Bool
    }

    static func updateSessionControl(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let json = parseJSONBody(req),
              let action = (json["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return errorResponse("bad_request", "missing action", status: 400)
        }
        let state: SessionControlState
        switch action {
        case "hide":
            state = .hidden
        case "archive":
            state = .archived
        case "restore":
            state = .active
        default:
            return errorResponse("bad_request", "action must be hide, archive, or restore", status: 400)
        }
        let resolvedId = resolveSessionControlId(sid) ?? sid
        let record = SessionControlStore.shared.setState(sessionId: resolvedId, state: state)
        BoardServer.shared.broadcastStateChanged()
        struct SessionControlEnvelope: Encodable {
            let ok: Bool
            let record: SessionControlRecord
        }
        return jsonResponse(SessionControlEnvelope(ok: true, record: record))
    }

    static func respondToSessionPermission(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let json = parseJSONBody(req),
              let rawDecision = (json["decision"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return errorResponse("bad_request", "missing decision", status: 400)
        }
        guard let session = resolvePluginSession(sid) else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }
        guard let event = session.urgentEvent, event.eventType == "permission", event.respond != nil else {
            return errorResponse("no_pending_permission", "session has no pending permission request", status: 409)
        }
        switch rawDecision {
        case "allow":
            event.respond?(.allow)
        case "deny":
            let reason = (json["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            event.respond?(.deny(reason: reason?.isEmpty == true ? nil : reason))
        default:
            return errorResponse("bad_request", "decision must be allow or deny", status: 400)
        }
        BoardServer.shared.broadcastStateChanged()
        return jsonResponse(OkEnvelope(ok: true))
    }

    private static func resolveSessionControlId(_ sid: String) -> String? {
        if let surface = TerminalSessionBackendRegistry.shared.snapshot(id: sid) {
            return surface.sessionId
        }
        if let metadataSid = resolveDesktopMetadataSid(sid) {
            return metadataSid
        }
        if let session = resolvePluginSession(sid) {
            return inboxSessionId(for: session)
        }
        if let stored = SessionStore.shared.get(sid) {
            return stored.sessionId
        }
        let matches = SessionStore.shared.listAll().filter { $0.sessionId.hasPrefix(sid) }
        return matches.count == 1 ? matches[0].sessionId : nil
    }

    static func listMemoryRecords(_ req: HttpRequest) -> HttpResponse {
        let scope = queryValue(req, name: "scope") ?? "session"
        guard let subjectId = queryValue(req, name: "subjectId"),
              !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errorResponse("bad_request", "subjectId is required", status: 400)
        }
        struct MemoryListEnvelope: Encodable {
            let records: [SessionMemoryRecord]
        }
        return jsonResponse(MemoryListEnvelope(records: SessionMemoryStore.shared.list(scope: scope, subjectId: subjectId)))
    }

    static func createMemoryRecord(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let scope = ((json["scope"] as? String) ?? "session").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let subjectId = (json["subjectId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subjectId.isEmpty else {
            return errorResponse("bad_request", "subjectId is required", status: 400)
        }
        guard let content = (json["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return errorResponse("bad_request", "content is required", status: 400)
        }
        let kind = ((json["kind"] as? String) ?? "note").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = ((json["source"] as? String) ?? "operator").trimmingCharacters(in: .whitespacesAndNewlines)
        let evidenceRef = (json["evidenceRef"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        struct MemoryEnvelope: Encodable {
            let record: SessionMemoryRecord
        }
        let record = SessionMemoryStore.shared.create(
            scope: scope.isEmpty ? "session" : scope,
            subjectId: subjectId,
            kind: kind.isEmpty ? "note" : kind,
            content: content,
            source: source.isEmpty ? "operator" : source,
            evidenceRef: evidenceRef?.isEmpty == true ? nil : evidenceRef
        )
        return jsonResponse(MemoryEnvelope(record: record), status: 201, reason: "Created")
    }

    static func updateMemoryRecord(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing memory id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let content = (json["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return errorResponse("bad_request", "content is required", status: 400)
        }
        let kind = (json["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = SessionMemoryStore.shared.update(id: id, content: content, kind: kind) else {
            return errorResponse("not_found", "memory record not found: \(id)", status: 404)
        }
        struct MemoryEnvelope: Encodable {
            let record: SessionMemoryRecord
        }
        return jsonResponse(MemoryEnvelope(record: record))
    }

    static func deleteMemoryRecord(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing memory id", status: 400)
        }
        guard SessionMemoryStore.shared.delete(id: id) else {
            return errorResponse("not_found", "memory record not found: \(id)", status: 404)
        }
        return jsonResponse(OkEnvelope(ok: true))
    }

    private static func queryValue(_ req: HttpRequest, name: String) -> String? {
        req.queryParams.first(where: { $0.0 == name })?.1
    }

    /// short-id / full-id 匹配 Claude Desktop metadata 索引。命中即说明
    /// 该 sid 是 desktop 起的 session（不一定在 PluginManager 里）。
    /// 返回完整 cliSessionId（前端可能传 short-id）。
    private static func resolveDesktopMetadataSid(_ sid: String) -> String? {
        let all = ClaudeDesktopMetadataReader.shared.allCliSessionIds()
        if all.contains(sid) { return sid }
        return all.first(where: { $0.hasPrefix(sid) })
    }

    /// Plugin sessions may expose a host-facing id (`com.meee2.plugin.codex-...`)
    /// while the underlying runtime exposes a raw id (`CODEX_THREAD_ID`). Match
    /// both forms so local APIs work with either Board ids or raw runtime ids.
    private static func resolvePluginSession(_ sid: String) -> PluginSession? {
        let sessions = PluginManager.shared.sessions
        return sessions.first(where: { pluginSession($0, matches: sid, allowPrefix: false) })
            ?? sessions.first(where: { pluginSession($0, matches: sid, allowPrefix: true) })
    }

    private static func pluginSession(_ session: PluginSession, matches sid: String, allowPrefix: Bool) -> Bool {
        let ids = pluginSessionIds(session)
        if ids.contains(sid) { return true }
        guard allowPrefix else { return false }
        return ids.contains { $0.hasPrefix(sid) }
    }

    private static func pluginSessionIds(_ session: PluginSession) -> [String] {
        var ids = [session.id]
        let prefix = "\(session.pluginId)-"
        if session.id.hasPrefix(prefix) {
            ids.append(String(session.id.dropFirst(prefix.count)))
        }
        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    /// Inbox keys follow the visible PluginSession id for non-Claude plugins
    /// (notably Codex). Claude's historical inbox key is the raw CLI session id.
    private static func inboxSessionId(for session: PluginSession) -> String {
        let claudePluginId = "com.meee2.plugin.claude"
        let prefix = "\(session.pluginId)-"
        if session.pluginId == claudePluginId, session.id.hasPrefix(prefix) {
            return String(session.id.dropFirst(prefix.count))
        }
        return session.id
    }

    private static func inboxSessionIds(for session: PluginSession) -> [String] {
        var ids = [inboxSessionId(for: session)]
        ids.append(contentsOf: pluginSessionIds(session))
        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private static func resolveInboxSessionIds(_ sid: String) -> [String]? {
        if let session = resolvePluginSession(sid) {
            return inboxSessionIds(for: session)
        }
        if SessionStore.shared.get(sid) != nil {
            return [sid]
        }
        let matches = SessionStore.shared.listAll().filter { $0.sessionId.hasPrefix(sid) }
        if matches.count == 1 {
            return [matches[0].sessionId]
        }
        if MessageRouter.shared.allInboxSessionIds().contains(sid) {
            return [sid]
        }
        return nil
    }

    /// POST /api/sessions/:id/inject
    /// 直接向某个 session 的 inbox 注入一条 human 消息。消息会在下一个
    /// Stop hook 到达时由 HookSocketServer 拦截并塞给 Claude 作为下一轮输入。
    /// Body: {"content": "..."}; 响应: {"message": MessageDTO}
    static func injectToSession(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let content = json["content"] as? String, !content.isEmpty else {
            return errorResponse("bad_request", "missing or empty 'content'", status: 400)
        }

        if TerminalSessionBackendRegistry.shared.writeInput(id: sid, data: Data((content + "\n").utf8)) {
            struct InternalInjectEnvelope: Encodable {
                let message: MessageDTO?
                let delivery: String?
            }
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(
                InternalInjectEnvelope(message: nil, delivery: nil),
                status: 201,
                reason: "Created"
            )
        }

        // Desktop synthetic session（PluginManager 不知道、只剩 metadata）没法
        // 立刻 deliver——子进程已退，没 Stop hook 可以触发 inline drain。明确报错。
        if resolveDesktopMetadataSid(sid) != nil
            && resolvePluginSession(sid) == nil {
            return errorResponse(
                "unsupported_for_desktop",
                "inject is only supported for live CLI / hook-driven sessions; this Desktop session has no running subprocess to deliver to",
                status: 400
            )
        }

        guard let session = resolvePluginSession(sid) else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }

        let targetSessionId = inboxSessionId(for: session)

        // 统一路径（方案 B 全量）：operator 被看作 per-session 的一个
        // 普通 channel member，走 MessageRouter.send() → audit → deliverPending
        // → inbox 写入；resting session 的 Ghostty push 由 deliverPending
        // 的钩子自动触发（见 MessageRouter.pushToRestingSessionIfNeeded）。
        do {
            let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: targetSessionId)
            let written = try MessageRouter.shared.send(
                channel: channelName,
                fromAlias: "operator",
                toAlias: "session",
                content: content,
                injectedByHuman: true
            )
            let sessionData = SessionStore.shared.get(targetSessionId)
            let status = sessionData?.status.rawValue ?? session.status.rawValue
            NSLog("[inject] via channel=\(channelName) msg=\(written.id) sid=\(targetSessionId.prefix(8)) status=\(status)")
            BoardServer.shared.broadcastStateChanged()

            // Delivery semantics 提示：Desktop session 没 terminal，立刻
            // typeIn 走不通——只能等 Stop hook 把 inbox drain 进 block-
            // decision reason。session 处于 idle 时尤其需要提醒：Stop 不
            // 会自己 fire，消息会一直 queued 直到用户在 Desktop 里继续。
            let isDesktop = ClaudeDesktopActivator.isDesktopBacked(
                sid: targetSessionId,
                transcriptPath: sessionData?.transcriptPath
            )
            let delivery: String? = isDesktop ? "queued_until_next_turn" : nil

            return jsonResponse(
                MessageEnvelope(
                    message: BoardDTOBuilder.messageDTO(written),
                    delivery: delivery
                ),
                status: 201,
                reason: "Created"
            )
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/sessions/:id/push-now
    /// 显式 "Push to Desktop" —— 把 content（如有）写进 inbox，然后立刻调
    /// AgentInboxShell.pushDesktopNow 把 inbox 通过 AppleScript keystroke
    /// 注入 Claude.app 当前 focused 输入框。会抢焦点，所以必须用户主动触
    /// 发（webui Dock 的 ⚡ 按钮）—— 默认 inject path 不走这条。
    ///
    /// Body: {"content": "..."}（可空：如果 inbox 已有 pending msg，content
    ///                         为空就只 drain 现有的）
    /// 响应: {"delivered": N, "message": MessageDTO?, "error": "..."?}
    static func pushToDesktopNow(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let session = resolvePluginSession(sid) else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }
        let targetSessionId = inboxSessionId(for: session)
        let sessionData = SessionStore.shared.get(targetSessionId)
        let isDesktop = ClaudeDesktopActivator.isDesktopBacked(
            sid: targetSessionId,
            transcriptPath: sessionData?.transcriptPath
        )
        guard isDesktop else {
            return errorResponse(
                "not_desktop",
                "push-now only applies to Claude Desktop sessions; CLI sessions deliver immediately via terminal typeIn",
                status: 400
            )
        }

        // 可选 content：写 inbox。空 content = 只 drain 现有 pending。
        var injectedMsg: MessageDTO?
        if let json = parseJSONBody(req),
           let content = json["content"] as? String, !content.isEmpty {
            do {
                let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: targetSessionId)
                let written = try MessageRouter.shared.send(
                    channel: channelName,
                    fromAlias: "operator",
                    toAlias: "session",
                    content: content,
                    injectedByHuman: true
                )
                injectedMsg = BoardDTOBuilder.messageDTO(written)
            } catch {
                return errorResponse("bad_request", error.localizedDescription, status: 400)
            }
        }

        // Drain 通过 keystroke。同步阻塞这条 HTTP request 的 thread —— 用
        // semaphore 等 Task 完成。webui 用户体验：点 ⚡ 后 ~2s 看到 toast，
        // 期间 Claude.app 弹起 + 输入框出现文字 + 自动回车。
        let sem = DispatchSemaphore(value: 0)
        var delivered = 0
        var error: String?
        Task {
            let result = await AgentInboxShell.shared.pushDesktopNow(sessionId: targetSessionId)
            delivered = result.delivered
            error = result.error
            sem.signal()
        }
        // 最多等 15s（resume + activate + keystroke + tail delay 约 2s/条，
        // 留余量）。超时返回 partial 结果让 user 知道。
        _ = sem.wait(timeout: .now() + 15.0)

        BoardServer.shared.broadcastStateChanged()
        // 把 error string 翻成 webui 可路由的 errorCode：
        //   accessibility_denied → webui 提示 + 一键开 System Settings
        //   claude_not_running   → 用户开 Claude.app 重试
        //   其它                  → 普通 toast
        let errorCode: String? = {
            guard let err = error else { return nil }
            if err.contains("Accessibility") || err.contains("不允许发送按键") {
                return "accessibility_denied"
            }
            if err.contains("Claude.app is not running") || err.contains("claude_not_running") {
                return "claude_not_running"
            }
            return "keystroke_failed"
        }()
        let payload = PushNowResponse(
            delivered: delivered,
            message: injectedMsg,
            error: error,
            errorCode: errorCode
        )
        return jsonResponse(payload)
    }

    /// POST /api/system/open-accessibility-settings
    /// 把 user 弹去 System Settings → Privacy & Security → Accessibility 页。
    /// 用 NSWorkspace + 已知的 prefpane URL（macOS 13+ 通用）。
    static func openAccessibilitySettings(_ req: HttpRequest) -> HttpResponse {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            // x-apple.systempreferences 是 macOS 13+ 的 anchor URL scheme。
            // anchor `Privacy_Accessibility` 直接跳到 Accessibility 子页。
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        return jsonResponse(OkEnvelope(ok: true))
        #else
        return errorResponse("unsupported", "open-accessibility-settings is macOS only", status: 501)
        #endif
    }

    private struct WhoamiResponse: Encodable {
        /// 系统短用户名（NSUserName，等价于 `whoami`）—— sidebar 底部默认显示这个
        let username: String
        /// 系统全名（NSFullUserName，"Account 用户全名" 字段）—— 可空字符串
        let fullName: String
        /// 主机名（用于 LAN 场景区分多台机器）
        let hostname: String
    }

    /// GET /api/whoami
    /// sidebar 底部用户行展示用 —— 绑定运行 meee2 的系统用户身份。
    /// 没参数,无副作用,客户端拉一次缓存即可。
    static func getWhoami(_ req: HttpRequest) -> HttpResponse {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return jsonResponse(WhoamiResponse(
            username: NSUserName(),
            fullName: NSFullUserName(),
            hostname: host
        ))
    }

    private struct VersionResponse: Encodable {
        let current: String
        let latest: String?
        let hasUpdate: Bool
        let isChecking: Bool
        let lastError: String?
        /// codex-style "pill only when ready to instant-install" 信号。
        /// AppDelegate 把 SilentInstallUserDriver.isReadyToInstall 桥过来。
        /// 生产 UI 只在 `isStaged=true` 时渲染 pill,保证用户点击就秒重启。
        let isStaged: Bool
        /// 当前 staged 包的版本号(showUpdateFound 时 Sparkle 给的)。
        /// 用于 dev e2e 测试"staged 过时"场景:对比 latest != stagedVersion 时
        /// 用户点 pill 应该 discard + fresh check。
        let stagedVersion: String?
    }

    /// GET /api/version
    /// board webui 顶部 "Update" pill 的数据源。读 VersionChecker.shared
    /// 当前 cache(AppDelegate 启动时已经 startBackgroundCheck,每 6h 刷一次),
    /// 不在 request 路径上做网络拉取。webui 想强制刷的话走 POST
    /// /api/version/check。
    static func getVersion(_ req: HttpRequest) -> HttpResponse {
        let v = VersionChecker.shared
        return jsonResponse(VersionResponse(
            current: v.currentVersion,
            latest: v.latestVersion,
            hasUpdate: v.hasUpdate,
            isChecking: v.isChecking,
            lastError: v.lastError,
            isStaged: SparkleStagedBridge.snapshot(),
            stagedVersion: SparkleStagedBridge.stagedVersion()
        ))
    }

    /// POST /api/_dev/override-latest?version=0.4.99
    /// **DEV-ONLY** 测试入口:手动 override VersionChecker.shared.latestVersion。
    /// 假造"远端出了更新版"场景,验证用户点 pill 时 driver 会 discard 旧 staged
    /// 包并 fresh check。重启 app 或下次 background check 会自然覆盖回真实值。
    /// 不传 version → clear override + 阻塞等 fresh fetch 完成,这样 e2e
    /// 脚本立刻 assert latest 不会拿到 nil。
    static func devOverrideLatest(_ req: HttpRequest) -> HttpResponse {
        let version = req.queryParams.first(where: { $0.0 == "version" })?.1
        let v = version?.isEmpty == false ? version : nil
        if v == nil {
            // Clear path:同步等 fetch 完成
            let sem = DispatchSemaphore(value: 0)
            Task {
                await VersionChecker.shared.checkForUpdate()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 30)
        } else {
            VersionChecker.shared.devOverrideLatest(v)
        }
        return jsonResponse(OkEnvelope(ok: true))
    }

    private struct PillClickPlan: Encodable {
        /// "instant_install"(staged 包是最新,会秒装)/ "discard_and_recheck"
        /// (staged 过时,会 discard 旧 reply 起 fresh check)/ "fresh_check"
        /// (没 staged 包,跑 user-initiated check)。
        let plan: String
        let stagedVersion: String?
        let latestVersion: String?
    }

    /// GET /api/_dev/pill-click-plan
    /// **DEV-ONLY** dry-run:不真触发 install,只报告"如果现在点 pill 会走哪条路径"。
    /// e2e 测试用 —— 验证逻辑不引发 side effect(scenario 5 用这个,不再真触发
    /// install 让 Sparkle 重新装 0.4.1)。
    static func devPillClickPlan(_ req: HttpRequest) -> HttpResponse {
        let staged = SparkleStagedBridge.stagedVersion()
        let latest = VersionChecker.shared.latestVersion
        let plan: String
        if let s = staged, s == latest {
            plan = "instant_install"
        } else if staged != nil {
            plan = "discard_and_recheck"
        } else {
            plan = "fresh_check"
        }
        return jsonResponse(PillClickPlan(plan: plan, stagedVersion: staged, latestVersion: latest))
    }

    /// POST /api/version/check
    /// 强制重新拉一次 appcast.xml,然后 200 返回最新 cache。webui pill 点
    /// 一下 refresh 用。
    static func checkVersion(_ req: HttpRequest) -> HttpResponse {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await VersionChecker.shared.checkForUpdate()
            sem.signal()
        }
        // 30s timeout cap —— appcast 是 raw.githubusercontent CDN,正常 <1s
        _ = sem.wait(timeout: .now() + 30)
        return getVersion(req)
    }

    /// POST /api/update/check-in-background
    /// Silent 触发 Sparkle 跑一次完整 background cycle:fetch appcast →
    /// 下载 DMG → 验 EdDSA → stage 到本地。不弹任何 UI。下载完成后再调
    /// /api/update/install 才会一次到位 "Install and Relaunch"。
    /// 主要给 dev 测预下载流程用 —— 生产环境靠 Sparkle 的 1h 本地轮询和
    /// 启动后主动 background check。
    static func checkUpdateInBackground(_ req: HttpRequest) -> HttpResponse {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("meee2.checkForUpdatesInBackground"),
                object: nil
            )
        }
        return jsonResponse(OkEnvelope(ok: true))
        #else
        return errorResponse("unsupported", "background update check is macOS only", status: 501)
        #endif
    }

    /// POST /api/update/install
    /// 触发 Sparkle 安装流程。如果后台已经下载并 staged 最新版,这一步
    /// 会立刻 apply + relaunch(codex-style 体验);否则 AppDelegate 会跑
    /// user-initiated checkForUpdates 下载并安装当前最新版。BoardAPI 这边
    /// 只发通知,不直接 import Sparkle。
    static func installUpdate(_ req: HttpRequest) -> HttpResponse {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("meee2.checkForUpdates"),
                object: nil
            )
        }
        return jsonResponse(OkEnvelope(ok: true))
        #else
        return errorResponse("unsupported", "update install is macOS only", status: 501)
        #endif
    }

    private struct PushNowResponse: Encodable {
        let delivered: Int
        let message: MessageDTO?
        let error: String?
        /// 给 webui 区分错误类型用：`accessibility_denied` → 触发"open Settings"
        /// 链接；其它错误只显示 toast。nil = 成功 / 没特殊处理需要。
        let errorCode: String?
    }

    /// GET /api/sessions/:id/transcript?limit=...
    /// 返回该 session 的完整 transcript entries（user/assistant），每个
    /// entry 的 blocks 保留原始结构：text / thinking / tool_use / tool_result。
    static func getTranscript(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }

        // 优先 PluginManager 匹配（CLI 和"刚活过的 desktop"都在这里）
        let match = resolvePluginSession(sid)

        // PluginManager 没找到就 fallback 到 desktop metadata。
        // metadata.transcriptPath 已经解析好了
        // （~/.claude/projects/<encoded-host-cwd>/<sid>.jsonl）。
        if match == nil, let metadataSid = resolveDesktopMetadataSid(sid),
           let m = ClaudeDesktopMetadataReader.shared.lookup(cliSessionId: metadataSid) {
            var limit: Int?
            if let q = req.queryParams.first(where: { $0.0 == "limit" })?.1,
               let n = Int(q), n > 0 {
                limit = n
            }
            let entries = m.transcriptPath.map {
                FullTranscriptReader.read(transcriptPath: $0, limit: limit)
            } ?? []
            return jsonResponse(FullTranscriptEnvelope(entries: entries, sessionId: metadataSid))
        }

        guard let session = match else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }

        let realSessionId = pluginSessionIds(session).last ?? session.id
        let data = SessionStore.shared.get(realSessionId) ?? SessionStore.shared.get(session.id)
        let transcriptPath = data?.transcriptPath ?? session.transcriptPath

        // 可选 limit —— 最新 N 条（tail）
        var limit: Int?
        if let q = req.queryParams.first(where: { $0.0 == "limit" })?.1,
           let n = Int(q), n > 0 {
            limit = n
        }

        let entries = FullTranscriptReader.read(transcriptPath: transcriptPath, limit: limit)
        return jsonResponse(FullTranscriptEnvelope(entries: entries, sessionId: realSessionId))
    }

    /// GET /api/sessions/:id/inbox?drain=true
    /// Reads the delivered direct inbox file for a session. `drain=true`
    /// consumes the messages after returning them; Codex needs this because it
    /// has no Claude Stop hook to consume the JSON inbox file for it.
    static func getSessionInbox(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        guard let inboxSids = resolveInboxSessionIds(sid) else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }

        let drain = req.queryParams.contains { key, value in
            key == "drain" && ["1", "true", "yes"].contains((value.removingPercentEncoding ?? value).lowercased())
        }
        let messages = inboxSids
            .flatMap { drain
                ? MessageRouter.shared.drainInbox(sessionId: $0)
                : MessageRouter.shared.peekInbox(sessionId: $0)
            }
            .reduce(into: [A2AMessage]()) { out, msg in
                guard !out.contains(where: { $0.id == msg.id }) else { return }
                out.append(msg)
            }
            .sorted { $0.createdAt < $1.createdAt }
        if drain, !messages.isEmpty {
            BoardServer.shared.broadcastStateChanged()
        }
        return jsonResponse(MessagesEnvelope(messages: messages.map { BoardDTOBuilder.messageDTO($0) }))
    }

    /// POST /api/sessions/spawn
    /// Body: `{"cwd": "/abs/or/~path", "command": "claude", "createIfMissing": false, "termProgram": "ghostty"}`
    /// 行为：按 cwd 打开一个新 Ghostty 窗口，并在里面跑 command（默认 Claude full-access mode）。
    /// 用 Claude Code 现有的 OAuth（`~/.claude/`）——新起的 `claude` 进程会直接读。
    static func spawnSession(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard var cwd = json["cwd"] as? String, !cwd.isEmpty else {
            return errorResponse("bad_request", "missing 'cwd'", status: 400)
        }

        // ~ 展开
        if cwd.hasPrefix("~") {
            let home = NSHomeDirectory()
            cwd = home + String(cwd.dropFirst(1))
        }
        // 转 URL-绝对路径
        cwd = (cwd as NSString).standardizingPath

        let launch = AgentLaunchCommand.normalize(
            command: (json["command"] as? String) ?? "",
            fallbackProvider: "claude"
        )
        let command = launch.command
        let termProgram = (json["termProgram"] as? String)
        let createIfMissing = (json["createIfMissing"] as? Bool) ?? false

        if (json["terminalMode"] as? String)?.lowercased() == "external" {
            return spawnTerminalSession(cwd: cwd, command: command, createIfMissing: createIfMissing, termProgram: termProgram)
        }
        do {
            let surface = try createInternalSessionSurface(
                provider: launch.provider,
                cwd: cwd,
                command: command,
                createIfMissing: createIfMissing,
                canvasId: nil,
                nodeId: nil,
                initialPrompt: nil
            )
            struct SpawnResp: Encodable {
                let ok: Bool
                let cwd: String
                let command: String
                let sessionId: String
                let surfaceId: String
                let terminalKind: String
            }
            return jsonResponse(SpawnResp(
                ok: true,
                cwd: cwd,
                command: command,
                sessionId: surface.sessionId,
                surfaceId: surface.surfaceId,
                terminalKind: "internal"
            ), status: 201, reason: "Created")
        } catch {
            return errorResponse("spawn_failed", error.localizedDescription, status: 500)
        }
    }

    /// POST /api/canvases/:id/sessions/spawn-global
    /// Body: `{"provider": "claude" | "codex", "termProgram": "ghostty"}`
    /// 行为：在当前 canvas 的 meee2-managed workspace 里启动 provider 对应的 session。
    static func spawnGlobalSession(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"] else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        let json = parseJSONBody(req) ?? [:]
        let provider = ((json["provider"] as? String) ?? "claude").lowercased()
        let command: String
        switch provider {
        case "claude":
            command = AgentLaunchCommand.fullAccessCommand(forProvider: "claude")
        case "codex":
            command = AgentLaunchCommand.fullAccessCommand(forProvider: "codex")
        default:
            return errorResponse("bad_request", "provider must be 'claude' or 'codex'", status: 400)
        }
        let termProgram = json["termProgram"] as? String
        do {
            let cwd = try explicitSessionCwd(json["cwd"] as? String) ?? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
            try BoardLayoutStore.shared.recordSpawnIntent(
                canvasId: canvasId,
                cwd: cwd,
                command: command,
                provider: provider,
                purpose: "global",
                initialPrompt: nil,
                layoutHint: nil
            )
            if (json["terminalMode"] as? String)?.lowercased() == "external" {
                return spawnTerminalSession(cwd: cwd, command: command, createIfMissing: true, termProgram: termProgram)
            }
            let surface = try createInternalSessionSurface(
                provider: provider,
                cwd: cwd,
                command: command,
                createIfMissing: true,
                canvasId: canvasId,
                nodeId: nil,
                initialPrompt: nil
            )
            struct SpawnResp: Encodable {
                let ok: Bool
                let cwd: String
                let command: String
                let sessionId: String
                let surfaceId: String
                let terminalKind: String
            }
            return jsonResponse(SpawnResp(
                ok: true,
                cwd: cwd,
                command: command,
                sessionId: surface.sessionId,
                surfaceId: surface.surfaceId,
                terminalKind: "internal"
            ), status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    private static func spawnTerminalSession(
        cwd rawCwd: String,
        command: String,
        createIfMissing: Bool,
        termProgram: String?
    ) -> HttpResponse {
        let cwd = rawCwd
        switch startTerminalSession(cwd: cwd, command: command, createIfMissing: createIfMissing, termProgram: termProgram) {
        case .success:
            BoardServer.shared.broadcastStateChanged()
            struct SpawnResp: Encodable {
                let ok: Bool
                let cwd: String
                let command: String
            }
            return jsonResponse(SpawnResp(ok: true, cwd: cwd, command: command), status: 201, reason: "Created")
        case .failed(let reason):
            return errorResponse("spawn_failed", reason, status: 500)
        }
    }

    static func startTerminalSession(
        cwd: String,
        command: String,
        createIfMissing: Bool,
        termProgram: String?,
        createInBackground: Bool = false
    ) -> SpawnResult {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            if createIfMissing {
                do {
                    try FileManager.default.createDirectory(
                        atPath: cwd,
                        withIntermediateDirectories: true
                    )
                } catch {
                    return .failed(reason: "mkdir -p failed: \(error.localizedDescription)")
                }
            } else {
                return .failed(reason: "cwd does not exist: \(cwd) (pass createIfMissing=true to mkdir)")
            }
        }

        let spawner = SpawnerRouter.forTerminal(termProgram)
        final class OutcomeBox: @unchecked Sendable {
            var value: SpawnResult?
        }
        let outcomeBox = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            // ENG-2 / E2.4: thread the no-steal-focus flag down to the
            // spawner. GhosttySpawner skips `activate` when in background.
            // Default `false` keeps explicit user-clicked "open terminal"
            // bringing Ghostty to the front, which is what they expect.
            let result = await spawner.spawn(cwd: cwd, command: command, createInBackground: createInBackground)
            outcomeBox.value = result
            semaphore.signal()
        }
        switch semaphore.wait(timeout: .now() + 5.0) {
        case .success:
            return outcomeBox.value ?? .success
        case .timedOut:
            NSLog("[BoardAPI] startTerminalSession: 5s elapsed, outcome unknown — assuming async success")
            return .success
        }
    }

    // MARK: - Channels

    /// POST /api/channels
    /// Body: {"name":"review","mode":"auto|intercept|paused","description":"..."}
    static func createChannel(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let name = json["name"] as? String else {
            return errorResponse("bad_request", "missing 'name'", status: 400)
        }
        let modeStr = (json["mode"] as? String) ?? "auto"
        guard let mode = ChannelMode(rawValue: modeStr) else {
            return errorResponse("bad_request", "invalid mode: \(modeStr)", status: 400)
        }
        let description = json["description"] as? String
        do {
            let channel = try ChannelRegistry.shared.create(name: name, description: description, mode: mode)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(ChannelEnvelope(channel: BoardDTOBuilder.channelDTO(channel)),
                                status: 201, reason: "Created")
        } catch let err as ChannelRegistryError {
            return mapChannelError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// DELETE /api/channels/:name
    static func deleteChannel(_ req: HttpRequest) -> HttpResponse {
        guard let name = req.params[":name"] else {
            return errorResponse("bad_request", "missing channel name", status: 400)
        }
        do {
            try ChannelRegistry.shared.delete(name)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(OkEnvelope(ok: true))
        } catch let err as ChannelRegistryError {
            return mapChannelError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/channels/:name/members
    /// Body: {"alias":"alice","sessionId":"abc..."}
    static func addMember(_ req: HttpRequest) -> HttpResponse {
        guard let name = req.params[":name"] else {
            return errorResponse("bad_request", "missing channel name", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let alias = json["alias"] as? String,
              let sessionId = json["sessionId"] as? String else {
            return errorResponse("bad_request", "missing 'alias' or 'sessionId'", status: 400)
        }
        do {
            let channel = try ChannelRegistry.shared.join(channel: name, alias: alias, sessionId: sessionId)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(ChannelEnvelope(channel: BoardDTOBuilder.channelDTO(channel)),
                                status: 201, reason: "Created")
        } catch let err as ChannelRegistryError {
            return mapChannelError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// DELETE /api/channels/:name/members/:alias
    static func removeMember(_ req: HttpRequest) -> HttpResponse {
        guard let name = req.params[":name"], let alias = req.params[":alias"] else {
            return errorResponse("bad_request", "missing channel name or alias", status: 400)
        }
        do {
            let channel = try ChannelRegistry.shared.leave(channel: name, alias: alias)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(ChannelEnvelope(channel: BoardDTOBuilder.channelDTO(channel)))
        } catch let err as ChannelRegistryError {
            return mapChannelError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/channels/:name/rename
    /// Body: {"displayName":"..."} — 传 null/空串/省略 → 清掉 displayName
    /// 退回展示 canonical name。canonical name 本身保持不变（issue #24）。
    static func renameChannel(_ req: HttpRequest) -> HttpResponse {
        guard let name = req.params[":name"] else {
            return errorResponse("bad_request", "missing channel name", status: 400)
        }
        // 允许 body 为空对象（视作清掉 displayName）
        let json = parseJSONBody(req) ?? [:]
        let displayName = json["displayName"] as? String
        do {
            let channel = try ChannelRegistry.shared.rename(name, displayName: displayName)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(ChannelEnvelope(channel: BoardDTOBuilder.channelDTO(channel)))
        } catch let err as ChannelRegistryError {
            return mapChannelError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/channels/:name/mode
    /// Body: {"mode":"auto|intercept|paused"}
    static func setChannelMode(_ req: HttpRequest) -> HttpResponse {
        guard let name = req.params[":name"] else {
            return errorResponse("bad_request", "missing channel name", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let modeStr = json["mode"] as? String,
              let mode = ChannelMode(rawValue: modeStr) else {
            return errorResponse("bad_request", "invalid or missing 'mode'", status: 400)
        }
        do {
            let channel = try ChannelRegistry.shared.setMode(name, mode: mode)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(ChannelEnvelope(channel: BoardDTOBuilder.channelDTO(channel)))
        } catch let err as ChannelRegistryError {
            return mapChannelError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    // MARK: - Messages

    /// POST /api/messages/send
    /// Body: {channel, fromAlias, toAlias, content, replyTo?, injectedByHuman?}
    static func sendMessage(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let channel = json["channel"] as? String,
              let fromAlias = json["fromAlias"] as? String,
              let toAlias = json["toAlias"] as? String,
              let content = json["content"] as? String else {
            return errorResponse("bad_request", "missing required fields (channel/fromAlias/toAlias/content)", status: 400)
        }
        let replyTo = json["replyTo"] as? String
        let injected = (json["injectedByHuman"] as? Bool) ?? false

        do {
            let msg = try MessageRouter.shared.send(
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                content: content,
                replyTo: replyTo,
                injectedByHuman: injected
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(MessageEnvelope(message: BoardDTOBuilder.messageDTO(msg)),
                                status: 201, reason: "Created")
        } catch let err as MessageRouterError {
            return mapMessageError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/messages/:id/hold
    static func holdMessage(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing message id", status: 400)
        }
        do {
            let msg = try MessageRouter.shared.hold(id)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(MessageEnvelope(message: BoardDTOBuilder.messageDTO(msg)))
        } catch let err as MessageRouterError {
            return mapMessageError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/messages/:id/deliver
    static func deliverMessage(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing message id", status: 400)
        }
        do {
            let msg = try MessageRouter.shared.deliver(id)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(MessageEnvelope(message: BoardDTOBuilder.messageDTO(msg)))
        } catch let err as MessageRouterError {
            return mapMessageError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/messages/:id/drop
    static func dropMessage(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing message id", status: 400)
        }
        do {
            let msg = try MessageRouter.shared.drop(id)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(MessageEnvelope(message: BoardDTOBuilder.messageDTO(msg)))
        } catch let err as MessageRouterError {
            return mapMessageError(err)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// GET /api/channels/:name/messages?status=pending,held,delivered&limit=50
    /// newest first, 默认 limit=50
    static func listMessages(_ req: HttpRequest) -> HttpResponse {
        guard let name = req.params[":name"] else {
            return errorResponse("bad_request", "missing channel name", status: 400)
        }
        // 未知频道返回 404（保持 API 合约一致）
        guard ChannelRegistry.shared.get(name) != nil else {
            return errorResponse("not_found", "channel not found: \(name)", status: 404)
        }

        // 解析 query params
        var statusFilter: Set<MessageStatus>?
        var limit = 50
        for (k, v) in req.queryParams {
            switch k {
            case "status":
                // Swifter 不会 percent-decode query value，所以 web 端用
                // URLSearchParams 编码出来的 `pending%2Cheld` 在这里是一整个
                // token，split(",") 得到 ["pending%2Cheld"] → MessageStatus
                // rawValue 全 nil → statusFilter 留空 → listMessages 返回
                // 全部消息（包含 delivered）。SessionDetail 的 inbox section
                // 因此会把已 delivered 的消息也当 pending 渲染。先 decode 再 split。
                let decoded = v.removingPercentEncoding ?? v
                var set = Set<MessageStatus>()
                for token in decoded.split(separator: ",") {
                    if let s = MessageStatus(rawValue: String(token)) {
                        set.insert(s)
                    }
                }
                if !set.isEmpty { statusFilter = set }
            case "limit":
                if let n = Int(v), n > 0 { limit = min(n, 500) }
            default:
                break
            }
        }

        // listMessages 返回 createdAt 升序；我们要 newest first，所以 reverse
        var msgs = MessageRouter.shared.listMessages(channel: name, statuses: statusFilter)
        msgs.reverse()
        if msgs.count > limit {
            msgs = Array(msgs.prefix(limit))
        }
        let dtos = msgs.map { BoardDTOBuilder.messageDTO($0) }
        return jsonResponse(MessagesEnvelope(messages: dtos))
    }

    // MARK: - Card Templates

    /// 将 CardTemplateError 映射到 HTTP 响应
    static func mapCardTemplateError(_ err: CardTemplateError) -> HttpResponse {
        switch err {
        case .invalidId(let id):
            return errorResponse("invalid_id", "invalid template id: '\(id)' (allowed: [a-z0-9][a-z0-9-]{0,63})", status: 400)
        case .notFound(let id):
            return errorResponse("not_found", "template not found: \(id)", status: 404)
        case .tooLarge:
            return errorResponse("too_large", "template source exceeds \(CardTemplateStore.maxSourceBytes) bytes", status: 413)
        }
    }

    /// GET /api/card-templates
    /// 200 `{"templates":[Entry, ...]}` newest-first
    static func listCardTemplates(_ req: HttpRequest) -> HttpResponse {
        let entries = CardTemplateStore.shared.list()
        return jsonResponse(CardTemplatesEnvelope(templates: entries))
    }

    /// GET /api/card-templates/:id
    /// 总是 200：有条目返回 `{"template":Entry}`，没条目返回 `{"template":null}`。
    /// 原来用 404 — 但 "找不到 entry" 是正常路径（客户端回退 bundled default），
    /// 每次轮询都在浏览器 console 吼一声 Failed to load resource 太噪。
    static func getCardTemplate(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        guard CardTemplateStore.isValidId(id) else {
            return mapCardTemplateError(.invalidId(id))
        }
        let entry = CardTemplateStore.shared.get(id)
        return jsonResponse(CardTemplateEnvelope(template: entry))
    }

    /// PUT /api/card-templates/:id
    /// Body: `{"source":"..."}`
    /// 200 `{"template":Entry}` / 400 invalid_id / 413 too_large
    static func putCardTemplate(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let source = json["source"] as? String else {
            return errorResponse("bad_request", "missing 'source' (string)", status: 400)
        }
        do {
            let entry = try CardTemplateStore.shared.save(id, source: source)
            // 事件总线已触发 debounced broadcast；这里再直接踢一次 WS 以降低感知延迟
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(CardTemplateEnvelope(template: entry))
        } catch let err as CardTemplateError {
            return mapCardTemplateError(err)
        } catch {
            return errorResponse("internal_error", error.localizedDescription, status: 500)
        }
    }

    /// DELETE /api/card-templates/:id
    /// 200 `{"ok":true}` / 404
    static func deleteCardTemplate(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        do {
            try CardTemplateStore.shared.delete(id)
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(OkEnvelope(ok: true))
        } catch let err as CardTemplateError {
            return mapCardTemplateError(err)
        } catch {
            return errorResponse("internal_error", error.localizedDescription, status: 500)
        }
    }

    // MARK: - Canvases

    static func listCanvases(_ req: HttpRequest) -> HttpResponse {
        _ = req
        return jsonResponse(canvasEnvelope(BoardLayoutStore.shared.snapshot()))
    }

    static func createCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let name = json["name"] as? String else {
            return errorResponse("bad_request", "missing canvas name", status: 400)
        }
        guard let rawScope = json["scope"] as? String,
              let scope = BoardLayoutStore.CanvasScope(rawValue: rawScope) else {
            return errorResponse("bad_request", "scope must be personal or team", status: 400)
        }
        let rawKind = (json["kind"] as? String) ?? BoardLayoutStore.CanvasKind.board.rawValue
        guard rawKind != "template",
              let kind = BoardLayoutStore.CanvasKind(rawValue: rawKind) else {
            return errorResponse("bad_request", "kind must be board or monitor", status: 400)
        }
        do {
            let snapshot = try BoardLayoutStore.shared.createCanvas(name: name, scope: scope, kind: kind)
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    static func updateCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        do {
            let snapshot = try BoardLayoutStore.shared.updateCanvas(
                id: id,
                name: json["name"] as? String,
                active: json["active"] as? Bool
            )
            return jsonResponse(canvasEnvelope(snapshot))
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    static func deleteCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            let snapshot = try BoardLayoutStore.shared.deleteCanvas(id: id)
            return jsonResponse(canvasEnvelope(snapshot))
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    static func addSessionToCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"] else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let sessionId = json["sessionId"] as? String, !sessionId.isEmpty else {
            return errorResponse("bad_request", "missing sessionId", status: 400)
        }
        do {
            let snapshot = try BoardLayoutStore.shared.addSession(sessionId, to: canvasId)
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    static func removeSessionFromCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"],
              let sessionId = req.params[":sessionId"] else {
            return errorResponse("bad_request", "missing canvas id or session id", status: 400)
        }
        do {
            let snapshot = try BoardLayoutStore.shared.removeSession(sessionId, from: canvasId)
            return jsonResponse(canvasEnvelope(snapshot))
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    static func resolveCanvasConflict(_ req: HttpRequest) -> HttpResponse {
        guard let canvasId = req.params[":id"] else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let choice = (json["choice"] as? String) ?? ""
        do {
            let snapshot = try BoardLayoutStore.shared.resolveTeamCanvasConflict(
                canvasId: canvasId,
                useRemote: choice == "remote"
            )
            return jsonResponse(canvasEnvelope(snapshot))
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    // MARK: - Canvas templates (Chunk F · Official templates / Demo canvases)

    static let canvasTemplateTags = [
        "engineering", "code-review", "release", "monitor", "workflow",
        "recap", "research", "design", "ops", "demo", "scene", "travel", "game"
    ]

    /// GET /api/templates — returns the unified template catalog:
    /// official builtin templates plus visible team/private template canvases.
    static func listCanvasTemplates(_ req: HttpRequest) -> HttpResponse {
        _ = req
        let actor = BoardLayoutStore.shared.currentActorContext()
        let official = CanvasTemplateRegistry.all.map { template -> CanvasTemplateDTO in
            officialTemplateDTO(template)
        }
        let custom = BoardLayoutStore.shared.snapshot().canvases
            .filter { $0.templateMetadata != nil }
            .compactMap { canvas -> CanvasTemplateDTO? in
                customTemplateDTO(canvas, actor: actor)
            }
        // canvas-script(Part F)模板 —— 从 meee2-online sidecar 拉(env 配了才有,失败静默)。
        let canvasScript = fetchSidecarTemplates()
        return jsonResponse(CanvasTemplatesEnvelope(
            templates: official + custom + canvasScript,
            tags: canvasTemplateTags
        ))
    }

    private static func officialTemplateDTO(_ template: CanvasTemplate) -> CanvasTemplateDTO {
        let preview = officialTemplateRenderPreview(template)
        return CanvasTemplateDTO(
            id: template.id,
            name: template.name,
            description: template.description,
            icon: template.icon,
            source: "official",
            kind: template.kind.rawValue,
            defaultCanvasKind: template.kind.rawValue,
            category: "official",
            tags: tagsForOfficialTemplate(template),
            ownerUserId: nil,
            ownerName: "meee2",
            version: 1,
            readOnly: true,
            canEdit: false,
            canReplace: false,
            defaultNodesCount: template.defaultNodes.count,
            updatedAt: nil,
            defaultNodes: template.defaultNodes.map(templateNodeDTO(_:)),
            sceneSpec: template.sceneSpec,
            renderProfile: preview.profile,
            renderObjects: preview.objects,
            renderRelations: preview.relations
        )
    }

    private static func customTemplateDTO(
        _ canvas: BoardLayoutStore.Canvas,
        actor: (userId: String, teamId: String)
    ) -> CanvasTemplateDTO? {
        let ownerId = canvas.ownerUserId ?? canvas.createdBy ?? "local-user"
        if canvas.scope == .personal && ownerId != actor.userId {
            return nil
        }
        if canvas.scope == .team,
           let teamId = canvas.teamId,
           !teamId.isEmpty,
           actor.teamId != teamId {
            return nil
        }
        let metadata = templateMetadata(for: canvas)
        let canEdit = ownerId == actor.userId
        let count = PlannerBoardBridge.store.reusableNodeCount(canvasId: canvas.id)
        let renderProfile = try? PlannerBoardBridge.store.renderProfileState(canvasId: canvas.id).profile
        let renderPreview = customTemplateRenderPreview(canvasId: canvas.id)
        return CanvasTemplateDTO(
            id: canvas.id,
            name: canvas.name,
            description: metadata.description,
            icon: metadata.icon,
            source: canvas.scope == .team ? "team" : "private",
            kind: metadata.defaultCanvasKind.rawValue,
            defaultCanvasKind: metadata.defaultCanvasKind.rawValue,
            category: canvas.scope == .team ? "team" : "private",
            tags: metadata.tags,
            ownerUserId: ownerId,
            ownerName: displayName(forUserId: ownerId),
            version: metadata.version,
            readOnly: false,
            canEdit: canEdit,
            canReplace: canEdit,
            defaultNodesCount: count,
            updatedAt: metadata.updatedAt,
            defaultNodes: [],
            sceneSpec: PlannerBoardBridge.store.reusableSceneSpec(canvasId: canvas.id),
            renderProfile: renderProfile,
            renderObjects: renderPreview.objects,
            renderRelations: renderPreview.relations
        )
    }

    private static func officialTemplateRenderPreview(
        _ template: CanvasTemplate
    ) -> (profile: CanvasRenderProfile, objects: [CanvasObject], relations: [CanvasRelation]) {
        let canvasId = template.id
        let ownerId = "meee2"
        let profile = CanvasTemplateRegistry.materializeRenderProfile(template: template, canvasId: canvasId)
        let canvas = PlanningCanvas(
            id: canvasId,
            ownerId: ownerId,
            title: template.name,
            plannerContext: template.description,
            sceneSpec: CanvasTemplateRegistry.materializeSceneSpec(template: template, canvasId: canvasId)
        )
        let nodes = CanvasTemplateRegistry.materializeNodes(
            template: template,
            canvasId: canvasId,
            ownerId: ownerId
        )
        let resolved = CanvasRenderResolver.resolve(
            record: PlannerStore.CanvasRecord(canvas: canvas, nodes: nodes, proposals: []),
            profile: profile
        )
        return (profile, resolved.objects, resolved.relations)
    }

    private static func customTemplateRenderPreview(
        canvasId: String
    ) -> (objects: [CanvasObject], relations: [CanvasRelation]) {
        guard let state = try? PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: BoardLayoutStore.shared.snapshot(),
            actorUserId: PlannerPermission.currentActorId()
        ) else {
            return ([], [])
        }
        return (state.renderObjects, state.renderRelations)
    }

    private static func templateNodeDTO(_ spec: TemplateNodeSpec) -> CanvasTemplateNodeSpecDTO {
        CanvasTemplateNodeSpecDTO(
            title: spec.title,
            description: spec.description,
            status: spec.status,
            doerId: spec.doerId,
            positionHint: spec.positionHint,
            widget: spec.widget
        )
    }

    private static func tagsForOfficialTemplate(_ template: CanvasTemplate) -> [String] {
        var tags = Set([template.category])
        switch template.id {
        case "code-review":
            tags.formUnion(["engineering", "code-review", "workflow"])
        case "release-checklist":
            tags.formUnion(["engineering", "release", "workflow"])
        case "overnight-recap":
            tags.formUnion(["team", "recap", "ops"])
        case "team-control-tower":
            tags.formUnion(["team", "monitor", "ops"])
        case "engineering-refactor":
            tags.formUnion(["engineering", "workflow"])
        case "coding-orchestration":
            tags.formUnion(["engineering", "workflow"])
        case "npc-canvas":
            tags.formUnion(["demo", "design"])
        case "travel-squad":
            tags.formUnion(["demo", "travel", "scene"])
        case "poker-table":
            tags.formUnion(["demo", "game", "scene"])
        default:
            tags.insert("workflow")
        }
        return canvasTemplateTags.filter { tags.contains($0) }
    }

    private static func templateMetadata(for canvas: BoardLayoutStore.Canvas) -> BoardLayoutStore.TemplateMetadata {
        canvas.templateMetadata ?? BoardLayoutStore.TemplateMetadata(
            description: "",
            icon: "sparkles",
            tags: ["workflow"],
            defaultCanvasKind: .board,
            version: 1,
            createdFromCanvasId: nil,
            updatedBy: canvas.createdBy,
            updatedAt: canvas.updatedAt
        )
    }

    private static func displayName(forUserId ownerId: String) -> String {
        let defaults = UserDefaults.standard
        let currentId = defaults.string(forKey: "meee2UserId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ownerId == currentId || (ownerId == "local-user" && currentId.isEmpty) {
            let name = defaultString(defaults, key: "meee2UserName", fallback: nil)
            if !name.isEmpty { return name }
            let email = defaultString(defaults, key: "meee2UserEmail", fallback: nil)
            if !email.isEmpty { return email.components(separatedBy: "@").first ?? email }
            return "You"
        }
        return ownerId
    }

    private static func requireEditableTemplate(
        _ templateId: String
    ) throws -> (canvas: BoardLayoutStore.Canvas, metadata: BoardLayoutStore.TemplateMetadata, actor: (userId: String, teamId: String)) {
        let actor = BoardLayoutStore.shared.currentActorContext()
        guard let canvas = BoardLayoutStore.shared.snapshot().canvases.first(where: { $0.id == templateId }),
              canvas.templateMetadata != nil else {
            throw NSError(domain: "BoardAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: "template not found: \(templateId)"])
        }
        let ownerId = canvas.ownerUserId ?? canvas.createdBy ?? "local-user"
        guard ownerId == actor.userId else {
            throw NSError(domain: "BoardAPI", code: 403, userInfo: [NSLocalizedDescriptionKey: "only the template owner can edit this template"])
        }
        return (canvas, templateMetadata(for: canvas), actor)
    }

    private static func planningCanvas(
        for canvas: BoardLayoutStore.Canvas,
        title: String? = nil,
        context: String? = nil
    ) -> PlanningCanvas {
        PlanningCanvas(
            id: canvas.id,
            ownerId: canvas.ownerUserId ?? canvas.createdBy ?? "local-user",
            title: title ?? canvas.name,
            plannerContext: context ?? "canvas:\(canvas.id)",
            visibility: canvas.scope == .team ? .public : .private
        )
    }

    private static func normalizedTemplateTags(_ raw: [String]?) -> [String] {
        let allowed = Set(canvasTemplateTags)
        let tags = (raw ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { allowed.contains($0) }
        return Array(NSOrderedSet(array: tags)) as? [String] ?? []
    }

    private static func normalizedTemplateIcon(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "sparkles" : value
    }

    private static func normalizedTemplateDescription(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func canvasKind(from raw: String?, fallback: BoardLayoutStore.CanvasKind = .board) -> BoardLayoutStore.CanvasKind {
        guard let raw,
              raw != "template",
              let kind = BoardLayoutStore.CanvasKind(rawValue: raw) else {
            return fallback
        }
        return kind
    }

    private struct TemplateCreateRequest: Decodable {
        let canvasId: String?
        let name: String?
        let description: String?
        let scope: String?
        let tags: [String]?
        let icon: String?
        let defaultCanvasKind: String?
    }

    private struct TemplateApplyRequest: Decodable {
        let name: String?
        let scope: String?
        let adaptationPrompt: String?
    }

    private struct TemplateReplaceRequest: Decodable {
        let canvasId: String?
        let name: String?
        let description: String?
        let scope: String?
        let tags: [String]?
        let icon: String?
        let defaultCanvasKind: String?
    }

    /// POST /api/templates/:id/apply — body `{ name, scope }`.
    /// Materialize a canvas from either an official builtin template or a user
    /// template canvas.
    static func applyCanvasTemplate(_ req: HttpRequest) -> HttpResponse {
        guard let templateId = req.params[":id"]?.removingPercentEncoding else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: TemplateApplyRequest.self) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let name = body.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return errorResponse("bad_request", "missing canvas name", status: 400)
        }
        let rawScope = body.scope ?? "personal"
        guard let scope = BoardLayoutStore.CanvasScope(rawValue: rawScope) else {
            return errorResponse("bad_request", "scope must be personal or team", status: 400)
        }

        let adaptationPrompt = body.adaptationPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        // canvas-script 模板(id 前缀 cs:)走 sidecar instantiate → governance apply。
        if templateId.hasPrefix("cs:") {
            return applyCanvasScriptTemplate(String(templateId.dropFirst(3)), name: name, scope: scope)
        }
        if let template = CanvasTemplateRegistry.get(templateId) {
            return applyOfficialCanvasTemplate(
                template,
                name: name,
                scope: scope,
                adaptationPrompt: adaptationPrompt?.isEmpty == false ? adaptationPrompt : nil
            )
        }
        return applyCustomCanvasTemplate(
            templateId,
            name: name,
            scope: scope,
            adaptationPrompt: adaptationPrompt?.isEmpty == false ? adaptationPrompt : nil
        )
    }

    private static func applyOfficialCanvasTemplate(
        _ template: CanvasTemplate,
        name: String,
        scope: BoardLayoutStore.CanvasScope,
        adaptationPrompt: String?
    ) -> HttpResponse {
        do {
            let snapshot = try BoardLayoutStore.shared.createCanvas(
                name: name,
                scope: scope,
                kind: template.kind
            )
            let canvasId = snapshot.activeCanvasId
            guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
                return errorResponse("internal", "freshly created canvas missing from snapshot", status: 500)
            }
            let ownerId = boardCanvas.ownerUserId ?? boardCanvas.createdBy ?? "local-owner"
            let planning = PlanningCanvas(
                id: boardCanvas.id,
                ownerId: ownerId,
                title: boardCanvas.name,
                plannerContext: templatePlannerContext(template.id, adaptationPrompt: adaptationPrompt),
                sceneSpec: CanvasTemplateRegistry.materializeSceneSpec(
                    template: template,
                    canvasId: canvasId
                )
            )
            let seedNodes = CanvasTemplateRegistry.materializeNodes(
                template: template,
                canvasId: canvasId,
                ownerId: ownerId
            )
            _ = try PlannerBoardBridge.store.record(for: planning, seedNodes: [])
            _ = try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: seedNodes)
            try PlannerBoardBridge.store.writeRenderProfile(
                CanvasTemplateRegistry.materializeRenderProfile(template: template, canvasId: canvasId),
                canvasId: canvasId
            )
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    private static func applyCustomCanvasTemplate(
        _ templateId: String,
        name: String,
        scope: BoardLayoutStore.CanvasScope,
        adaptationPrompt: String?
    ) -> HttpResponse {
        let actor = BoardLayoutStore.shared.currentActorContext()
        guard let templateCanvas = BoardLayoutStore.shared.snapshot().canvases.first(where: { $0.id == templateId }),
              templateCanvas.templateMetadata != nil,
              customTemplateDTO(templateCanvas, actor: actor) != nil else {
            return errorResponse("not_found", "template not found: \(templateId)", status: 404)
        }
        let metadata = templateMetadata(for: templateCanvas)
        do {
            let snapshot = try BoardLayoutStore.shared.createCanvas(
                name: name,
                scope: scope,
                kind: metadata.defaultCanvasKind
            )
            let canvasId = snapshot.activeCanvasId
            guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
                return errorResponse("internal", "freshly created canvas missing from snapshot", status: 500)
            }
            _ = try PlannerBoardBridge.store.cloneReusableTemplateContent(
                from: templateId,
                to: planningCanvas(
                    for: boardCanvas,
                    context: templatePlannerContext(
                        "\(templateId):version:\(metadata.version)",
                        adaptationPrompt: adaptationPrompt
                    )
                )
            )
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    private static func templatePlannerContext(_ templateRef: String, adaptationPrompt: String?) -> String {
        guard let prompt = adaptationPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return "template:\(templateRef)"
        }
        return "template:\(templateRef)\nadaptation:\(prompt)"
    }

    // MARK: - canvas-script 模板(Part F,经 meee2-online sidecar)

    private struct SidecarTemplateItem: Decodable {
        let id: String
        let title: String
        let nodeCount: Int
        let edgeCount: Int
        let cardCount: Int
    }
    private struct SidecarTemplatesEnvelope: Decodable {
        let templates: [SidecarTemplateItem]
    }
    private struct SidecarInstantiateResponse: Decodable {
        struct Proposal: Decodable {
            let canvasId: String
            let summary: String
            let changes: [PlanChange]
        }
        let proposal: Proposal
    }

    private static func sidecarBaseURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let configured = env[HTTPPlannerAgentRuntime.runtimeUrlEnvVar]?.trimmingCharacters(in: .whitespaces)
        // env 未设 → 默认本地 dev sidecar(`pnpm runtime:sidecar` 的 :18890)。没 sidecar 时
        // 本地连接秒拒、上层静默 [],省去用户每次手动配 env 才能看到 canvas-script 模板。
        let raw = (configured?.isEmpty == false) ? configured! : "http://127.0.0.1:18890"
        return URL(string: raw)
    }

    /// 同步打 sidecar(BoardAPI handler 都是同步的);失败返回 (nil, 0)。
    private static func sidecarSyncRequest(_ request: URLRequest) -> (Data?, Int) {
        var out: (Data?, Int) = (nil, 0)
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sema.signal() }
            out = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
        _ = sema.wait(timeout: .now() + 12)
        return out
    }

    /// 从 sidecar 拉 canvas-script 模板,映射成 CanvasTemplateDTO(id 前缀 cs: 避免与
    /// builtin 撞名)。env 未配 / 不可达 → 静默返回 [](不拖垮模板库)。
    private static func fetchSidecarTemplates() -> [CanvasTemplateDTO] {
        guard let base = sidecarBaseURL() else { return [] }
        var req = URLRequest(url: base.appendingPathComponent("api/planner/runtime/templates"), timeoutInterval: 5)
        req.httpMethod = "GET"
        let (data, status) = sidecarSyncRequest(req)
        guard let data, (200..<300).contains(status),
              let env = try? JSONDecoder().decode(SidecarTemplatesEnvelope.self, from: data) else { return [] }
        return env.templates.map { item in
            CanvasTemplateDTO(
                id: "cs:" + item.id,
                name: item.title,
                description: "canvas-script 模板 · \(item.nodeCount) 节点 / \(item.edgeCount) 边",
                icon: "sparkles",
                source: "canvas-script",
                kind: "board",
                defaultCanvasKind: "board",
                category: "canvas-script",
                tags: ["canvas-script"],
                ownerUserId: nil,
                ownerName: "meee2 · canvas-script",
                version: 1,
                readOnly: true,
                canEdit: false,
                canReplace: false,
                defaultNodesCount: item.nodeCount,
                updatedAt: nil,
                defaultNodes: [],
                sceneSpec: nil,
                renderProfile: nil,
                renderObjects: [],
                renderRelations: []
            )
        }
    }

    /// canvas-script 模板实例化:建空 canvas → sidecar instantiate 拿 remap 好的 proposal
    /// → graph-change + approve + apply(走 governance,复用 PlannerStore.applyProposal)。
    private static func applyCanvasScriptTemplate(
        _ templateId: String,
        name: String,
        scope: BoardLayoutStore.CanvasScope
    ) -> HttpResponse {
        guard let base = sidecarBaseURL() else {
            return errorResponse("unavailable", "canvas-script sidecar 未配置(MEEE2_PLANNER_RUNTIME_URL)", status: 503)
        }
        // 先建空 canvas;createCanvas 之后任一步失败都回滚删除,避免 sidecar 瞬时故障 /
        // decode / apply 失败留下一张空 canvas(codex P2)。
        let snapshot: BoardLayoutStore.Snapshot
        do {
            snapshot = try BoardLayoutStore.shared.createCanvas(name: name, scope: scope, kind: .board)
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
        let canvasId = snapshot.activeCanvasId
        func rollback(_ response: HttpResponse) -> HttpResponse {
            _ = try? BoardLayoutStore.shared.deleteCanvas(id: canvasId)
            return response
        }
        guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            return rollback(errorResponse("internal", "freshly created canvas missing from snapshot", status: 500))
        }
        do {
            // planningCanvas(for:) 按 scope 设 visibility(team → .public);手动 init 会漏掉,
            // 导致 team 模板存成 .private、其他成员 canViewCanvas 看不到这张图(codex P2)。
            let planning = planningCanvas(for: boardCanvas, context: "canvas-script:\(templateId)")
            _ = try PlannerBoardBridge.store.record(for: planning, seedNodes: [])

            var req = URLRequest(
                url: base.appendingPathComponent("api/planner/runtime/templates/\(templateId)/instantiate"),
                timeoutInterval: 12
            )
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["canvasId": canvasId])
            let (data, status) = sidecarSyncRequest(req)
            guard let data, (200..<300).contains(status) else {
                return rollback(errorResponse("sidecar_error", "instantiate 失败(status \(status))", status: 502))
            }
            let decoded = try JSONDecoder().decode(SidecarInstantiateResponse.self, from: data)

            let proposal = try PlannerBoardBridge.graphChangeProposal(
                summary: decoded.proposal.summary,
                changes: decoded.proposal.changes,
                for: canvasId,
                snapshot: snapshot,
                actorUserId: planning.ownerId
            )
            _ = try PlannerBoardBridge.approveProposal(
                proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: planning.ownerId
            )
            _ = try PlannerBoardBridge.applyProposal(
                proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: planning.ownerId
            )
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch {
            return rollback(errorResponse("bad_request", error.localizedDescription, status: 400))
        }
    }

    static func createTemplateFromCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let body = decodeJSONBody(req, as: TemplateCreateRequest.self) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let sourceCanvasId = body.canvasId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceCanvasId.isEmpty else {
            return errorResponse("bad_request", "canvasId is required", status: 400)
        }
        let snapshot = BoardLayoutStore.shared.snapshot()
        guard let source = snapshot.canvases.first(where: { $0.id == sourceCanvasId }) else {
            return errorResponse("not_found", "canvas not found: \(sourceCanvasId)", status: 404)
        }
        let name = body.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return errorResponse("bad_request", "template name is required", status: 400)
        }
        let rawScope = body.scope ?? "personal"
        guard let scope = BoardLayoutStore.CanvasScope(rawValue: rawScope) else {
            return errorResponse("bad_request", "scope must be personal or team", status: 400)
        }
        let actor = BoardLayoutStore.shared.currentActorContext()
        let metadata = BoardLayoutStore.TemplateMetadata(
            description: normalizedTemplateDescription(body.description),
            icon: normalizedTemplateIcon(body.icon),
            tags: normalizedTemplateTags(body.tags),
            defaultCanvasKind: canvasKind(from: body.defaultCanvasKind, fallback: source.kind ?? .board),
            version: 1,
            createdFromCanvasId: sourceCanvasId,
            updatedBy: actor.userId,
            updatedAt: Date()
        )
        do {
            let created = try BoardLayoutStore.shared.createCanvas(
                name: name,
                scope: scope,
                kind: metadata.defaultCanvasKind,
                templateMetadata: metadata
            )
            let templateId = created.activeCanvasId
            guard let templateCanvas = created.canvases.first(where: { $0.id == templateId }) else {
                return errorResponse("internal", "freshly created template missing from snapshot", status: 500)
            }
            _ = try PlannerBoardBridge.store.cloneReusableTemplateContent(
                from: sourceCanvasId,
                to: planningCanvas(for: templateCanvas, context: "template:\(templateId):version:1")
            )
            return jsonResponse(canvasEnvelope(created), status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    static func createTemplateEditDraft(_ req: HttpRequest) -> HttpResponse {
        guard let templateId = req.params[":id"]?.removingPercentEncoding else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        do {
            let editable = try requireEditableTemplate(templateId)
            let draftName = "\(editable.canvas.name) draft"
            let created = try BoardLayoutStore.shared.createCanvas(
                name: draftName,
                scope: .personal,
                kind: editable.metadata.defaultCanvasKind,
                draftOfTemplateId: templateId
            )
            let draftId = created.activeCanvasId
            guard let draftCanvas = created.canvases.first(where: { $0.id == draftId }) else {
                return errorResponse("internal", "freshly created draft missing from snapshot", status: 500)
            }
            _ = try PlannerBoardBridge.store.cloneReusableTemplateContent(
                from: templateId,
                to: planningCanvas(for: draftCanvas, context: "template-draft:\(templateId):version:\(editable.metadata.version)")
            )
            return jsonResponse(canvasEnvelope(created), status: 201, reason: "Created")
        } catch {
            let status = (error as NSError).code == 403 ? 403 : 400
            return errorResponse(status == 403 ? "forbidden" : "bad_request", error.localizedDescription, status: status)
        }
    }

    static func replaceTemplateFromCanvas(_ req: HttpRequest) -> HttpResponse {
        guard let templateId = req.params[":id"]?.removingPercentEncoding else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: TemplateReplaceRequest.self) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let sourceCanvasId = body.canvasId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceCanvasId.isEmpty else {
            return errorResponse("bad_request", "canvasId is required", status: 400)
        }
        do {
            let editable = try requireEditableTemplate(templateId)
            var metadata = editable.metadata
            let previous = BoardLayoutStore.TemplateRevision(
                version: metadata.version,
                name: editable.canvas.name,
                description: metadata.description,
                replacedFromCanvasId: metadata.replacedFromCanvasId,
                replacedAt: Date(),
                replacedBy: editable.actor.userId
            )
            metadata.description = body.description.map { normalizedTemplateDescription($0) } ?? metadata.description
            metadata.icon = body.icon.map { normalizedTemplateIcon($0) } ?? metadata.icon
            if body.tags != nil { metadata.tags = normalizedTemplateTags(body.tags) }
            metadata.defaultCanvasKind = canvasKind(from: body.defaultCanvasKind, fallback: metadata.defaultCanvasKind)
            metadata.version += 1
            metadata.replacedFromCanvasId = sourceCanvasId
            metadata.updatedBy = editable.actor.userId
            metadata.updatedAt = Date()
            metadata.revisions.append(previous)

            let nextName = body.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = try BoardLayoutStore.shared.updateTemplateMetadata(
                id: templateId,
                name: nextName?.isEmpty == false ? nextName : nil,
                scope: body.scope.flatMap(BoardLayoutStore.CanvasScope.init(rawValue:)),
                metadata: metadata
            )
            guard let templateCanvas = updated.canvases.first(where: { $0.id == templateId }) else {
                return errorResponse("internal", "template missing after metadata update", status: 500)
            }
            _ = try PlannerBoardBridge.store.replaceReusableTemplateContent(
                templateCanvasId: templateId,
                from: sourceCanvasId,
                targetCanvas: planningCanvas(for: templateCanvas, context: "template:\(templateId):version:\(metadata.version)")
            )
            return jsonResponse(canvasEnvelope(BoardLayoutStore.shared.snapshot()))
        } catch {
            let status = (error as NSError).code == 403 ? 403 : 400
            return errorResponse(status == 403 ? "forbidden" : "bad_request", error.localizedDescription, status: status)
        }
    }

    static func updateTemplateMetadata(_ req: HttpRequest) -> HttpResponse {
        guard let templateId = req.params[":id"]?.removingPercentEncoding else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        guard let body = decodeJSONBody(req, as: TemplateReplaceRequest.self) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        do {
            let editable = try requireEditableTemplate(templateId)
            var metadata = editable.metadata
            metadata.description = body.description.map { normalizedTemplateDescription($0) } ?? metadata.description
            metadata.icon = body.icon.map { normalizedTemplateIcon($0) } ?? metadata.icon
            if body.tags != nil { metadata.tags = normalizedTemplateTags(body.tags) }
            metadata.defaultCanvasKind = canvasKind(from: body.defaultCanvasKind, fallback: metadata.defaultCanvasKind)
            metadata.updatedBy = editable.actor.userId
            metadata.updatedAt = Date()
            let name = body.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let scope = body.scope.flatMap(BoardLayoutStore.CanvasScope.init(rawValue:))
            let snapshot = try BoardLayoutStore.shared.updateTemplateMetadata(
                id: templateId,
                name: name?.isEmpty == false ? name : nil,
                scope: scope,
                metadata: metadata
            )
            return jsonResponse(canvasEnvelope(snapshot))
        } catch {
            let status = (error as NSError).code == 403 ? 403 : 400
            return errorResponse(status == 403 ? "forbidden" : "bad_request", error.localizedDescription, status: status)
        }
    }

    // MARK: - Claude Code workflows

    static func listClaudeWorkflows(_ req: HttpRequest) -> HttpResponse {
        _ = req
        let scan = ClaudeWorkflowLibrary.shared.scan()
        return jsonResponse(ClaudeWorkflowListEnvelope(
            root: scan.root.path,
            workflows: scan.workflows.map(claudeWorkflowDTO(_:)),
            error: scan.error
        ))
    }

    static func importClaudeWorkflow(_ req: HttpRequest) -> HttpResponse {
        guard let workflowId = req.params[":id"]?.removingPercentEncoding else {
            return errorResponse("bad_request", "missing workflow id", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawScope = (json["scope"] as? String) ?? "personal"
        guard let scope = BoardLayoutStore.CanvasScope(rawValue: rawScope) else {
            return errorResponse("bad_request", "scope must be personal or team", status: 400)
        }

        do {
            let snapshot = try ClaudeWorkflowImporter().importWorkflow(
                id: workflowId,
                name: name,
                scope: scope
            )
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch let error as ClaudeWorkflowLibraryError {
            switch error {
            case .notFound:
                return errorResponse("not_found", error.localizedDescription, status: 404)
            case .tooLarge, .invalidSource, .unreadable, .unsupportedFileType:
                return errorResponse("bad_request", error.localizedDescription, status: 400)
            case .aiParseFailed:
                return errorResponse("workflow_import_failed", error.localizedDescription, status: 500)
            }
        } catch {
            return errorResponse("workflow_import_failed", error.localizedDescription, status: 500)
        }
    }

    static func importUploadedClaudeWorkflow(_ req: HttpRequest) -> HttpResponse {
        struct UploadRequest: Decodable {
            let filename: String?
            let source: String?
            let name: String?
            let scope: String?
        }

        guard let body = decodeJSONBody(req, as: UploadRequest.self) else {
            return errorResponse(
                "invalid_json",
                "body must be {\"filename\": String, \"source\": String, \"name\"?: String, \"scope\"?: \"personal\" | \"team\"}",
                status: 400
            )
        }
        let filename = body.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !filename.isEmpty else {
            return errorResponse("bad_request", "filename is required", status: 400)
        }
        guard let source = body.source else {
            return errorResponse("bad_request", "source is required", status: 400)
        }
        let name = body.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawScope = body.scope ?? "personal"
        guard let scope = BoardLayoutStore.CanvasScope(rawValue: rawScope) else {
            return errorResponse("bad_request", "scope must be personal or team", status: 400)
        }

        do {
            let snapshot = try ClaudeWorkflowImporter().importUploadedWorkflow(
                filename: filename,
                source: source,
                name: name,
                scope: scope
            )
            return jsonResponse(canvasEnvelope(snapshot), status: 201, reason: "Created")
        } catch let error as ClaudeWorkflowLibraryError {
            switch error {
            case .notFound:
                return errorResponse("not_found", error.localizedDescription, status: 404)
            case .tooLarge, .invalidSource, .unreadable, .unsupportedFileType:
                return errorResponse("bad_request", error.localizedDescription, status: 400)
            case .aiParseFailed:
                return errorResponse("workflow_import_failed", error.localizedDescription, status: 500)
            }
        } catch {
            return errorResponse("workflow_import_failed", error.localizedDescription, status: 500)
        }
    }

    private static func claudeWorkflowDTO(_ workflow: ClaudeWorkflowFile) -> ClaudeWorkflowDTO {
        ClaudeWorkflowDTO(
            id: workflow.id,
            name: workflow.name,
            commandName: workflow.commandName,
            description: workflow.description,
            phases: workflow.phases.map {
                ClaudeWorkflowPhaseDTO(title: $0.title, detail: $0.detail)
            },
            path: workflow.path,
            sizeBytes: workflow.sizeBytes,
            modifiedAt: workflow.modifiedAt,
            preview: workflow.preview,
            readable: workflow.readable,
            error: workflow.error
        )
    }

    private static func canvasEnvelope(_ snapshot: BoardLayoutStore.Snapshot) -> CanvasListEnvelope {
        let parentRefs = PlannerStore.shared.canvasParentRefs()
        let workspacePaths = BoardLayoutStore.shared.loadAllWorkspacePaths()
        let canvases = snapshot.canvases.map { canvas -> CanvasInfoDTO in
            let parentRef = parentRefs[canvas.id]
            return CanvasInfoDTO(
                id: canvas.id,
                name: canvas.name,
                scope: canvas.scope.rawValue,
                visibility: plannerCanvasVisibility(canvas, snapshot: snapshot),
                kind: (canvas.kind ?? .board).rawValue,
                isDefault: canvas.isDefault,
                workspacePath: workspacePaths[canvas.id] ?? "",
                parentCanvasId: parentRef?.parentCanvasId,
                parentNodeId: parentRef?.parentNodeId,
                teamId: canvas.teamId,
                ownerUserId: canvas.ownerUserId ?? canvas.createdBy,
                remoteId: canvas.remoteId,
                remoteVersion: canvas.remoteVersion,
                syncStatus: canvas.syncStatus,
                dirtySince: canvas.dirtySince.map(BoardDTOBuilder.iso),
                lastSyncedAt: canvas.lastSyncedAt.map(BoardDTOBuilder.iso),
                lastRemoteUpdatedAt: canvas.lastRemoteUpdatedAt.map(BoardDTOBuilder.iso),
                conflictRemoteVersion: canvas.conflictRemoteVersion,
                conflictRemoteDeleted: canvas.conflictRemoteDeleted,
                draftOfTemplateId: canvas.draftOfTemplateId
            )
        }
        let defaultIds = snapshot.canvases.filter { $0.isDefault }.map { $0.id }
        let layouts: [String: BoardLayoutStore.Layout] = BoardLayoutStore.shared.loadAllLayouts()
        let memberships = snapshot.memberships.map {
            CanvasSessionMembershipDTO(
                canvasId: $0.canvasId,
                sessionId: $0.sessionId,
                visible: $0.visible,
                layout: layouts[$0.canvasId]?.sessions[$0.sessionId]
            )
        }
        return CanvasListEnvelope(
            canvases: canvases,
            activeCanvasId: snapshot.activeCanvasId,
            defaultCanvasIds: defaultIds,
            memberships: memberships
        )
    }

    private static func plannerCanvasVisibility(
        _ canvas: BoardLayoutStore.Canvas,
        snapshot: BoardLayoutStore.Snapshot
    ) -> String {
        guard (canvas.kind ?? .board) != .monitor else {
            return canvas.scope == .team ? "public" : "private"
        }
        return canvas.scope == .team ? "public" : "private"
    }

    private static func canvasId(from req: HttpRequest) -> String? {
        req.queryParams.first(where: { $0.0 == "canvasId" })?.1.removingPercentEncoding
    }

    // MARK: - Board Layout

    /// GET /api/board/layout
    /// 200 `{"layout":{"sessions":{sid:{x,y}},"channels":{name:{x,y}},"updatedAt":ISO}}`
    /// 文件不存在时 `sessions` / `channels` 为空对象。
    static func getBoardLayout(_ req: HttpRequest) -> HttpResponse {
        let layout = BoardLayoutStore.shared.load(canvasId: canvasId(from: req))
        return jsonResponse(BoardLayoutEnvelope(layout: layout))
    }

    /// PUT /api/board/layout
    /// Body: `{"sessions":{sid:{x,y}},"channels":{name:{x,y}}}`
    /// 200 `{"layout":...}` / 400 invalid_json
    static func putBoardLayout(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let selectedCanvasId = canvasId(from: req)
        let current = BoardLayoutStore.shared.load(canvasId: selectedCanvasId)
        let sessions = parsePointMap(json["sessions"])
        let channels = parsePointMap(json["channels"])
        let layout = BoardLayoutStore.Layout(
            sessions: json.keys.contains("sessions") ? sessions : current.sessions,
            channels: json.keys.contains("channels") ? channels : current.channels,
            viewport: json.keys.contains("viewport") ? parseViewport(json["viewport"]) : current.viewport,
            userElements: json.keys.contains("userElements") ? parseJSONValueArray(json["userElements"]) : current.userElements,
            dismissedSids: json.keys.contains("dismissedSids") ? parseStringArray(json["dismissedSids"]) : current.dismissedSids,
            unreadSids: json.keys.contains("unreadSids") ? parseStringArray(json["unreadSids"]) : current.unreadSids,
            updatedAt: Date()
        )
        do {
            let saved = try BoardLayoutStore.shared.save(layout, canvasId: selectedCanvasId)
            // 不直接 broadcast：BoardLayoutStore.save 已经 publish .boardLayoutChanged，
            // BoardServer 订阅会 debounce 200ms 后 broadcastStateChanged。
            // 之前这里又调一次直接广播，每次 PUT 触发 2 次 WS 推送（一次直接 +
            // 一次 debounced）。
            return jsonResponse(BoardLayoutEnvelope(layout: saved))
        } catch {
            return errorResponse("internal_error", error.localizedDescription, status: 500)
        }
    }

    // MARK: - External Chat Sessions (browser extension push)

    static func upsertExternalSession(_ req: HttpRequest) -> HttpResponse {
        return retiredExternalSessionResponse(req)
    }

    static func appendExternalMessage(_ req: HttpRequest) -> HttpResponse {
        return retiredExternalSessionResponse(req)
    }

    static func deleteExternalSession(_ req: HttpRequest) -> HttpResponse {
        return retiredExternalSessionResponse(req)
    }

    private static func retiredExternalSessionResponse(_ req: HttpRequest) -> HttpResponse {
        _ = req
        return errorResponse(
            "external_sessions_retired",
            "External session ingestion has been retired. meee2 now manages only sessions it creates.",
            status: 410
        )
    }

    /// `{key: {x,y}}` → `[key: Point]`，容错解析：未知 shape 视为空。
    private static func parsePointMap(_ raw: Any?) -> [String: BoardLayoutStore.Point] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: BoardLayoutStore.Point] = [:]
        for (k, v) in dict {
            guard let obj = v as? [String: Any] else { continue }
            let x = (obj["x"] as? NSNumber)?.doubleValue ?? (obj["x"] as? Double)
            let y = (obj["y"] as? NSNumber)?.doubleValue ?? (obj["y"] as? Double)
            let width = (obj["width"] as? NSNumber)?.doubleValue ?? (obj["width"] as? Double)
            let height = (obj["height"] as? NSNumber)?.doubleValue ?? (obj["height"] as? Double)
            if let x = x, let y = y {
                out[k] = BoardLayoutStore.Point(x: x, y: y, width: width, height: height)
            }
        }
        return out
    }

    private static func parseViewport(_ raw: Any?) -> BoardLayoutStore.Viewport? {
        guard let obj = raw as? [String: Any] else { return nil }
        let scrollX = (obj["scrollX"] as? NSNumber)?.doubleValue ?? (obj["scrollX"] as? Double)
        let scrollY = (obj["scrollY"] as? NSNumber)?.doubleValue ?? (obj["scrollY"] as? Double)
        let zoom = (obj["zoom"] as? NSNumber)?.doubleValue ?? (obj["zoom"] as? Double)
        guard let scrollX = scrollX, let scrollY = scrollY, let zoom = zoom else { return nil }
        return BoardLayoutStore.Viewport(scrollX: scrollX, scrollY: scrollY, zoom: zoom)
    }

    private static func parseJSONValueArray(_ raw: Any?) -> [BoardJSONValue] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap(BoardJSONValue.fromAny)
    }

    private static func inferContextSourceKind(reference: String, title: String) -> ContextSource.Kind {
        let normalized = "\(title) \(reference)".lowercased()
        if normalized.hasPrefix("artifact:") || normalized.contains("artifact://") {
            return .artifact
        }
        if normalized.hasPrefix("repo:") || normalized.hasPrefix("git:") || normalized.contains("github.com") {
            return .repository
        }
        if normalized.contains("lark") || normalized.contains("feishu") || normalized.contains("doc") {
            return .document
        }
        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") {
            return .web
        }
        return .document
    }

    private static func parseStringArray(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }
}
