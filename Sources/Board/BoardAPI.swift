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
            case 500: return "Internal Server Error"
            default: return "Error"
            }
        }()
        return jsonResponse(ErrorDTO(code: code, message: message), status: status, reason: reason)
    }

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
        let started = Date()
        defer {
            if ProcessInfo.processInfo.environment["MEEE2_PERF_LOG"] == "1" {
                let ms = Date().timeIntervalSince(started) * 1_000
                MLog(String(format: "[Perf][BoardAPI] getState %.1fms", ms))
            }
        }
        // Web UI 默认只显示 live sessions；completed/dead 记录仍保留在
        // SessionStore 供 history / diagnostic / recovery 使用。
        // 同时过滤 isArchived=true 的 Claude Desktop session：用户已经在
        // desktop 里 archive 的 session，再往 Web UI 上塞会重复污染。
        let sessions = currentBoardSessions()
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

    static func listSessionSurfaces(_ req: HttpRequest) -> HttpResponse {
        struct Envelope: Encodable { let surfaces: [InternalTerminalSurfaceSnapshot] }
        return jsonResponse(Envelope(surfaces: InternalTerminalRuntime.shared.listSnapshots()))
    }

    static func getSessionSurface(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return errorResponse("bad_request", "missing surface id", status: 400)
        }
        guard let snapshot = InternalTerminalRuntime.shared.snapshot(surfaceOrSessionId: id) else {
            return errorResponse("not_found", "surface not found: \(id)", status: 404)
        }
        return jsonResponse(snapshot)
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
        guard InternalTerminalRuntime.shared.close(surfaceOrSessionId: id) else {
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
    ) throws -> InternalTerminalSurfaceSnapshot {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            if createIfMissing {
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            } else {
                throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd does not exist: \(cwd)"])
            }
        }
        let snapshot = try InternalTerminalRuntime.shared.createSurface(
            provider: provider,
            cwd: cwd,
            command: command,
            canvasId: canvasId,
            nodeId: nodeId,
            initialPrompt: initialPrompt,
            preferredSessionId: preferredSessionId
        )
        BoardServer.shared.broadcastStateChanged()
        return snapshot
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
            edges: state.edges
        )
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
            let status = SessionStatus.from(rawString: session.status)
            let boundRecord = PlannerSessionRunStateBridge.observeBound(
                sessionId: session.id,
                status: status
            )
            if boundRecord != nil {
                syncPlannerSessionOutputArtifacts(sessionId: session.id)
            }
        }
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
        guard let outputRef = node.schema.outputs.first(where: { $0.localizedCaseInsensitiveContains("kanban") })
                ?? node.schema.outputs.first else { return }
        guard !existingArtifacts.contains(where: {
            $0.nodeId == node.id && (
                $0.reference == outputRef ||
                $0.reference.caseInsensitiveCompare(outputRef) == .orderedSame
            )
        }) else { return }
        guard let transcriptPath = SessionStore.shared.get(sessionId)?.transcriptPath else { return }
        let entries = FullTranscriptReader.readTail(transcriptPath: transcriptPath, limit: 12)
        guard let latestText = latestVisibleAssistantText(entries),
              let payload = kanbanPayloadFromMarkdownTable(latestText) else { return }
        let artifact = PlannerNodeOutputArtifact(
            kind: .kanban,
            title: outputRef.replacingOccurrences(of: "_", with: " ").capitalized,
            reference: outputRef,
            payload: payload,
            routeTo: []
        )
        let output = PlannerNodeOutput(
            nodeId: node.id,
            status: .done,
            message: PlannerNodeOutputMessage(summary: "Extracted \(kanbanItemCount(payload)) item(s) into \(outputRef).", routeTo: []),
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
            MWarn("[PlannerArtifactSync] fallback sync failed canvas=\(canvasId) node=\(node.id) sid=\(sessionId.prefix(8)): \(error.localizedDescription)")
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
        do {
            syncPlannerSessionOutputArtifacts(canvasId: canvasId)
            let state = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
        do {
            let canvas = try PlannerBoardBridge.setCanvasVisibility(
                body.visibility,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
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
                actorUserId: PlannerPermission.currentActorId()
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
            // instead of calling the adapter/heuristic directly. The runtime
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
            // Runtime timed out — keep the existing heuristic proposal so demo
            // / offline flows still work.
            MLog("[Planner] generatePlannerProposal canvas=\(canvasId) path=fallback-heuristic")
            let proposal = try PlannerBoardBridge.generateProposal(
                goal: goal,
                for: canvasId,
                snapshot: snapshot,
                actorUserId: actorUserId
            )
            return jsonResponse(PlannerProposalEnvelope(proposal: proposal), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// Run the planner agent runtime synchronously (the HTTP handler is sync)
    /// for a proposal-producing event, persist the first proposal, and return
    /// it. Returns `nil` when the runtime timed out (caller falls back to the
    /// heuristic) or when the runtime returned no proposal (e.g. a healthy
    /// graph on `.driftInspection`). A `PlannerCoreError` (RBAC / validation)
    /// is rethrown so the caller maps it to the right HTTP status.
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
            return nil
        }

        if let runtimeError {
            // Validation / RBAC failures are real client errors — surface them.
            if let coreError = runtimeError as? PlannerCoreError {
                throw coreError
            }
            // Runtime infrastructure error — fall back gracefully.
            MWarn("[Planner] planner runtime errored for canvas=\(canvasId): \(runtimeError.localizedDescription)")
            return nil
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
                edges: preview.edges
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
            return jsonResponse(PlannerGraphStateEnvelope(
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

    static func dispatchPlannerNodeSession(_ req: HttpRequest) -> HttpResponse {
        struct DispatchRequest: Decodable {
            let runner: PlannerDispatchRunner?
            let cwd: String?
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
        }
        struct EnsureResponse: Encodable {
            let ok: Bool
            let sessionId: String
            let surfaceId: String
            let cwd: String
            let command: String
            let terminalKind: String
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

            let surface: InternalTerminalSurfaceSnapshot
            var action = "reuse"
            if let sessionId = existingNode.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionId.isEmpty {
                if let existingSurface = InternalTerminalRuntime.shared.snapshot(surfaceOrSessionId: sessionId),
                   isReusableInternalSurface(existingSurface) {
                    surface = existingSurface
                } else {
                    try PlannerPermission.requireNodeUpdate(on: existingNode, access: state.access)
                    let cwd = try explicitSessionCwd(body?.cwd) ?? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
                    let resumeSessionId = providerResumeSessionId(forPlannerSessionId: sessionId)
                    let command = resumeSessionId.map {
                        plannerResumeCommand(for: existingNode, sessionId: $0)
                    }
                        ?? plannerFreshCommand(for: existingNode)
                    let canResume = resumeSessionId != nil
                    action = canResume ? "resume" : "recreate"
                    let preferredSessionId = isProviderResumeSessionId(sessionId) || canResume ? sessionId : nil
                    let provider = AgentLaunchCommand.provider(forCommand: command)
                    surface = try createInternalSessionSurface(
                        provider: provider,
                        cwd: cwd,
                        command: command,
                        createIfMissing: true,
                        canvasId: canvasId,
                        nodeId: nodeId,
                        initialPrompt: canResume ? nil : plannerDispatchPrompt(for: existingNode, canvasId: canvasId, cwd: cwd),
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
                            purpose: "planner:\(nodeId)",
                            status: .active
                        )
                    }
                    BoardServer.shared.broadcastStateChanged()
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
                action: action,
                graph: graphEnvelope(state)
            ), status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("spawn_failed", error.localizedDescription, status: 500)
        }
    }

    private static func isReusableInternalSurface(_ surface: InternalTerminalSurfaceSnapshot) -> Bool {
        surface.status == InternalTerminalLifecycle.starting.rawValue
            || surface.status == InternalTerminalLifecycle.running.rawValue
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            let liveSessions = currentBoardSessions()
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
        if let raw = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any] {
            do {
                try NodeContractValidator.validateRawOutputPayload(raw)
            } catch {
                return errorResponse("invalid_node_output", error.localizedDescription, status: 400)
            }
        }
        guard let output = decodeJSONBody(req, as: PlannerNodeOutput.self) else {
            return errorResponse("invalid_json", "body must be a valid node output payload", status: 400)
        }
        do {
            var result = try PlannerBoardBridge.submitNodeOutput(
                nodeId: nodeId,
                output: output,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            routePlannerOutputMessages(result.routes)
            // ENG-2 / E2.2 + E2.4: spawn terminals for auto-dispatched
            // downstream nodes in the background so the user's focused app
            // stays put. The dispatch state is already persisted by the
            // store (see PlannerBoardBridge.submitNodeOutput), this just
            // materializes the terminal so the session actually runs.
            var autoSpawnStarted = 0
            var autoSpawnSkipped: [String] = []
            var autoSpawnFailed: [String] = []
            for autoNodeId in result.autoDispatchedNodeIds ?? [] {
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
            if let autoIds = result.autoDispatchedNodeIds, !autoIds.isEmpty {
                var parts = ["Auto-started \(autoSpawnStarted) downstream session\(autoSpawnStarted == 1 ? "" : "s")."]
                if !autoSpawnSkipped.isEmpty {
                    parts.append("Skipped \(autoSpawnSkipped.count): \(autoSpawnSkipped.joined(separator: "; ")).")
                }
                if !autoSpawnFailed.isEmpty {
                    parts.append("Failed \(autoSpawnFailed.count): \(autoSpawnFailed.joined(separator: "; ")).")
                }
                result.hint = parts.joined(separator: " ")
                NSLog("[ENG-2][auto-spawn] summary canvas=\(canvasId) candidates=\(autoIds.count) started=\(autoSpawnStarted) skipped=\(autoSpawnSkipped.count) failed=\(autoSpawnFailed.count)")
            }
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(result, status: 201, reason: "Created")
        } catch let err as PlannerCoreError {
            return mapPlannerCoreError(err)
        } catch {
            return errorResponse("planner_error", error.localizedDescription, status: 400)
        }
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
    // These three proxy the desktop board-app's UI-2 and UI-6 calls to
    // meee2-online. They share `OnlineProxy.loadSettings()` for the
    // supabase URL + anon key + teamId/userId stored in
    // `~/.meee2/settings.json` (also mirrored to UserDefaults).
    //
    // 1) POST /api/planner/canvases/:id/nodes/:nodeId/assign
    //      → Supabase RPC `meee2_assign_node`
    // 2) GET  /api/planner/owned-canvases
    //      → Supabase RPC `meee2_list_owned_canvases`
    // 3) GET  /api/cloud/artifact-versions/recent
    //      → meee2-online `/api/v1/artifact-versions?…`

    /// UI-2 · F1.2 — proxy `assignPlannerNode` from the board-app to the
    /// `meee2_assign_node` RPC. The web client posts a JSON body with
    /// `assigneeUserId`, optional `subCanvasName`, and `acceptPrivateUpgrade`;
    /// we forward those as RPC params and stream the JSON response through.
    /// Response shape matches `AssignPlannerNodeResult` in the board-app
    /// `types.ts`.
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
        var payload: [String: Any] = [
            "p_team_id": settings.teamId,
            "p_canvas_id": canvasId,
            "p_node_id": nodeId,
            "p_assignee_user_id": assigneeUserId,
            "p_accept_private_upgrade": body.acceptPrivateUpgrade ?? false
        ]
        if let name = body.subCanvasName, !name.isEmpty {
            payload["p_sub_canvas_name"] = name
        }
        switch OnlineProxy.callRPC(name: "meee2_assign_node", payload: payload, settings: settings) {
        case .success(let data):
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try? writer.write(data)
            }
        case .failure(let err):
            return mapOnlineProxyError(err)
        }
    }

    /// UI-2 · proxy `fetchOwnedCanvases` to `meee2_list_owned_canvases`.
    static func proxyListOwnedCanvases(_ req: HttpRequest) -> HttpResponse {
        let settings = OnlineProxy.loadSettings()
        guard !settings.teamId.isEmpty else {
            return errorResponse("not_connected", "meee2-online not configured (missing teamId)", status: 412)
        }
        let payload: [String: Any] = [
            "p_team_id": settings.teamId,
            "p_user_id": settings.userId
        ]
        switch OnlineProxy.callRPC(name: "meee2_list_owned_canvases", payload: payload, settings: settings) {
        case .success(let data):
            // RPC returns an array; wrap in `{ canvases: [...] }` to match the
            // board-app `fetchOwnedCanvases` envelope.
            if let arr = try? JSONSerialization.jsonObject(with: data) {
                let envelope: [String: Any] = ["canvases": arr]
                if let wrapped = try? JSONSerialization.data(withJSONObject: envelope) {
                    return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                        try? writer.write(wrapped)
                    }
                }
            }
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
        switch OnlineProxy.callOnlineAPI(method: "GET", path: "/api/v1/artifact-versions", query: items) {
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
                        graph: PlannerGraphStateEnvelope(
                            canvas: state.canvas,
                            nodes: state.nodes,
                            states: state.states,
                            proposals: state.proposals,
                            access: state.access,
                            activities: state.activities,
                            events: state.events,
                            artifacts: state.artifacts,
                            edges: state.edges
                        )
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
                graph: PlannerGraphStateEnvelope(
                    canvas: state.canvas,
                    nodes: state.nodes,
                    states: state.states,
                    proposals: state.proposals,
                    access: state.access,
                    activities: state.activities,
                    events: state.events,
                    artifacts: state.artifacts,
                    edges: state.edges
                )
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
            return jsonResponse(PlannerGraphStateEnvelope(
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
                edges: result.edges
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
        case .canvasNotFound, .proposalNotFound, .runNotFound:
            return errorResponse("not_found", err.localizedDescription, status: 404)
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
        let initialPrompt = plannerDispatchPrompt(for: node, canvasId: canvasId, cwd: cwd)
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

    private static func plannerDispatchPrompt(for node: PlanningNode, canvasId: String, cwd: String) -> String {
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
            "- Inline payloads are allowed up to \(inlineLimitKB)KB.",
            "- For larger text/html/json/file output, write the file inside the workspace and submit payload.file.path.",
            "- Meee2 will copy file-backed artifacts into its artifact store; do not depend on the original file path as the long-term artifact.",
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
        let quotedSessionId = shellQuote(sessionId)
        if provider == "codex" {
            return "codex --dangerously-bypass-approvals-and-sandbox resume \(quotedSessionId)"
        }
        return "claude --resume \(quotedSessionId) --dangerously-skip-permissions"
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
        if let mapped = SessionTerminalStore.shared.get(sessionId: sessionId)?.providerResumeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty,
           !AgentLaunchCommand.isMeee2InternalSessionId(mapped) {
            return mapped
        }
        return isProviderResumeSessionId(sessionId) ? sessionId : nil
    }

    private static func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func currentBoardSessions() -> [SessionDTO] {
        _ = InternalTerminalRuntime.shared.restorePersistedSurfaces()
        let archivedDesktopSids: Set<String> = {
            var set = Set<String>()
            for sid in ClaudeDesktopMetadataReader.shared.allCliSessionIds() {
                if let m = ClaudeDesktopMetadataReader.shared.lookup(cliSessionId: sid),
                   m.isArchived {
                    set.insert(sid)
                }
            }
            return set
        }()
        let internalSessions = InternalTerminalRuntime.shared
            .listSnapshots()
            .filter { $0.status != "exited" && $0.status != "failed" }
            .map(BoardDTOBuilder.internalSessionDTO)
        let internalProviderResumeIds = Set(internalSessions.compactMap {
            SessionTerminalStore.shared.get(sessionId: $0.id)?.providerResumeSessionId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let realSessions = PluginManager.shared.sessions
            .filter { PluginManager.shared.isPluginEnabled($0.pluginId) }
            .filter { !$0.status.isHistorical }
            .filter { session in
                let realSid = session.id.hasPrefix("\(session.pluginId)-")
                    ? String(session.id.dropFirst("\(session.pluginId)-".count))
                    : session.id
                return !archivedDesktopSids.contains(realSid)
            }
            .map { BoardDTOBuilder.sessionDTO($0) }
            .filter { !internalProviderResumeIds.contains($0.id) }
            .filter { external in
                !internalSessions.contains { internalSession in
                    boardSession(internalSession, matches: external.id)
                        || boardSession(external, matches: internalSession.id)
                }
            }

        // Desktop 的 session 生命周期是"请求级"，所以用 metadata 合成持久展示。
        let realSids: Set<String> = Set(realSessions.map { $0.id })
        let syntheticDesktopSessions: [SessionDTO] = ClaudeDesktopMetadataReader.shared
            .allCliSessionIds()
            .compactMap { cliSid -> SessionDTO? in
                guard PluginManager.shared.isPluginEnabled("com.meee2.plugin.claude") else { return nil }
                guard let m = ClaudeDesktopMetadataReader.shared.lookup(cliSessionId: cliSid),
                      !m.isArchived,
                      !realSids.contains(cliSid),
                      !internalProviderResumeIds.contains(cliSid),
                      !internalSessions.contains(where: { boardSession($0, matches: cliSid) }) else { return nil }
                return BoardDTOBuilder.syntheticDesktopSessionDTO(metadata: m)
        }
        return internalSessions + realSessions + syntheticDesktopSessions
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
            defaultSyncEnabled: defaults.bool(forKey: "meee2Online"),
            defaultSyncTeamId: defaults.string(forKey: "meee2TeamId") ?? "",
            defaultSyncTeamName: BoardDTOBuilder.meee2DefaultSyncTeamName(),
            teams: BoardDTOBuilder.meee2OnlineTeams(),
            sessionSync: meee2OnlineSessionSyncList()
        ))
    }

    // MARK: - GET /api/team/members

    /// Team member directory — the authoritative identity source the planner
    /// graph keys `ownerAvatarUrlByUserId` / doer avatar lookups by `userId`.
    ///
    /// Data sources, in priority order:
    ///   1. The connected meee2 Online user (current actor) — name + avatar.
    ///   2. Doer ids referenced by planner nodes across every local canvas.
    ///   3. Other users seen via planner activity heartbeats.
    ///
    /// TODO(team): backfill from meee2 Online team members API once available.
    /// meee2 Online DOES expose `GET /api/v1/team/members`, but that route is
    /// cookie/session authenticated (`createClient()` + `auth.getUser()`); the
    /// desktop app only holds the Supabase anon key + a stored `userId`, which
    /// cannot satisfy that route nor read the RLS-protected `meee2_members`
    /// table directly. There is no `meee2_list_team_members` RPC. When such a
    /// remote source exists, merge its `{userId, displayName, avatarUrl, role}`
    /// rows here as the highest-priority layer; the DTO contract is final.
    static func getTeamMembers(_ req: HttpRequest) -> HttpResponse {
        var byUserId: [String: TeamMemberDTO] = [:]

        // (1) The connected meee2 Online user.
        let defaults = UserDefaults.standard
        let connected = defaults.bool(forKey: "meee2Connected")
        let currentUserId = defaults.string(forKey: "meee2UserId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if connected, !currentUserId.isEmpty {
            let userName = defaultString(defaults, key: "meee2UserName", fallback: nil)
            let userEmail = defaultString(defaults, key: "meee2UserEmail", fallback: nil)
            let avatarUrl = defaultString(defaults, key: "meee2UserAvatarUrl", fallback: nil)
            let displayName: String
            if !userName.isEmpty {
                displayName = userName
            } else if !userEmail.isEmpty {
                displayName = userEmail.components(separatedBy: "@").first ?? userEmail
            } else {
                displayName = "meee2 user"
            }
            let teamRole = BoardDTOBuilder.meee2OnlineTeams().first?.role
            byUserId[currentUserId] = TeamMemberDTO(
                userId: currentUserId,
                displayName: displayName,
                avatarUrl: avatarUrl.isEmpty ? nil : avatarUrl,
                role: teamRole
            )
        }

        // (2) Planner-node doers across every local canvas. Identity here is
        // partial (no avatar / no membership role) until the remote source
        // above is wired up.
        let snapshot = BoardLayoutStore.shared.snapshot()
        let actorId = PlannerPermission.currentActorId()
        for canvas in snapshot.canvases {
            guard let state = try? PlannerBoardBridge.canvasState(
                for: canvas.id,
                snapshot: snapshot,
                actorUserId: actorId
            ) else { continue }
            for node in state.nodes {
                let doerId = node.doerId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !doerId.isEmpty, byUserId[doerId] == nil else { continue }
                byUserId[doerId] = TeamMemberDTO(
                    userId: doerId,
                    displayName: doerId,
                    avatarUrl: nil,
                    role: nil
                )
            }
            // (3) Other users seen via planner activity heartbeats.
            for activity in state.activities {
                let uid = activity.userId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty, byUserId[uid] == nil else { continue }
                let name = activity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                byUserId[uid] = TeamMemberDTO(
                    userId: uid,
                    displayName: name.isEmpty ? uid : name,
                    avatarUrl: nil,
                    role: nil
                )
            }
        }

        let members = byUserId.values.sorted { lhs, rhs in
            // Connected user first, then alphabetically by display name.
            if lhs.userId == currentUserId { return true }
            if rhs.userId == currentUserId { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return jsonResponse(TeamMembersEnvelope(members: members))
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

    static func updateUserProfile(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }

        let defaults = UserDefaults.standard
        if let defaultSyncEnabled = json["defaultSyncEnabled"] as? Bool {
            defaults.set(defaultSyncEnabled, forKey: "meee2Online")
        }

        if let sync = json["sessionSync"] as? [String: Any],
           let sessionId = sync["sessionId"] as? String,
           let enabled = sync["enabled"] as? Bool {
            setMeee2OnlineSession(sessionId, enabled: enabled)
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
            carouselInterval: storedDouble(defaults, key: "carouselInterval", fallback: 10)
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

    private static func meee2OnlineSessionSyncList() -> [UserProfileSessionSyncDTO] {
        PluginManager.shared.sessions.sorted {
            if $0.pluginId != $1.pluginId {
                return $0.pluginId < $1.pluginId
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }.map { session in
            let plugin = PluginManager.shared.getPluginInfo(for: session.pluginId)
            return UserProfileSessionSyncDTO(
                sessionId: session.id,
                title: session.title,
                pluginDisplayName: plugin?.displayName ?? session.pluginId,
                project: session.cwd ?? "",
                enabled: isMeee2OnlineSessionEnabled(session.id)
            )
        }
    }

    private static func isMeee2OnlineSessionEnabled(_ sessionId: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "meee2Connected") else { return false }

        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)
        let disabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")
        if !aliases.isDisjoint(with: disabled) { return false }

        if defaults.bool(forKey: "meee2Online") { return true }

        let enabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")
        return !aliases.isDisjoint(with: enabled)
    }

    private static func setMeee2OnlineSession(_ sessionId: String, enabled: Bool) {
        var disabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")
        var explicitlyEnabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")
        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)

        if enabled {
            disabled.subtract(aliases)
            explicitlyEnabled.formUnion(aliases)
        } else {
            disabled.formUnion(aliases)
            explicitlyEnabled.subtract(aliases)
        }

        Meee2OnlinePusher.storeSessionIdSet(disabled, forKey: "meee2DisabledSessionIds")
        Meee2OnlinePusher.storeSessionIdSet(explicitlyEnabled, forKey: "meee2EnabledSessionIds")
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
        let enabledSessionIds = Array(Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds"))
        let disabledSessionIds = Array(Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds"))
        let meee2Settings: [String: Any] = [
            "enabled": true,
            "online": defaults.bool(forKey: "meee2Online"),
            "supabaseUrl": normalizedSupabaseUrl,
            "supabaseKey": defaults.string(forKey: "meee2SupabaseKey") ?? "",
            "teamId": defaults.string(forKey: "meee2TeamId") ?? "",
            "userId": defaults.string(forKey: "meee2UserId") ?? "",
            "userName": defaults.string(forKey: "meee2UserName") ?? "",
            "userEmail": defaults.string(forKey: "meee2UserEmail") ?? "",
            "userAvatarUrl": defaults.string(forKey: "meee2UserAvatarUrl") ?? "",
            "teams": teams,
            "sessionTeamIds": [String: String](),
            "defaultSyncEnabled": defaults.bool(forKey: "meee2Online"),
            "enabledSessionIds": enabledSessionIds,
            "disabledSessionIds": disabledSessionIds,
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
        if let surface = InternalTerminalRuntime.shared.snapshot(surfaceOrSessionId: sid) {
            struct ActivateInternalResponse: Encodable {
                let ok: Bool
                let terminalKind: String
                let surfaceId: String
                let sessionId: String
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
                sessionId: surface.sessionId
            ))
        }
        if let metadataSid = resolveDesktopMetadataSid(sid) {
            ClaudeDesktopActivator.activate(sid: metadataSid)
            return jsonResponse(OkEnvelope(ok: true))
        }
        guard let session = resolvePluginSession(sid) else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }
        PluginManager.shared.activateTerminal(for: session)
        return jsonResponse(OkEnvelope(ok: true))
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
        if InternalTerminalRuntime.shared.close(surfaceOrSessionId: sid) {
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
        if let surface = InternalTerminalRuntime.shared.snapshot(surfaceOrSessionId: sid) {
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

        if InternalTerminalRuntime.shared.writeInput(sessionId: sid, text: content + "\n") {
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
        guard let kind = BoardLayoutStore.CanvasKind(rawValue: rawKind) else {
            return errorResponse("bad_request", "kind must be board, monitor, or template", status: 400)
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

    private static func canvasEnvelope(_ snapshot: BoardLayoutStore.Snapshot) -> CanvasListEnvelope {
        let canvases = snapshot.canvases.map {
            let workspacePath = (try? BoardLayoutStore.shared.workspacePath(canvasId: $0.id)) ?? ""
            return CanvasInfoDTO(
                id: $0.id,
                name: $0.name,
                scope: $0.scope.rawValue,
                kind: ($0.kind ?? .board).rawValue,
                isDefault: $0.isDefault,
                workspacePath: workspacePath,
                teamId: $0.teamId,
                ownerUserId: $0.ownerUserId ?? $0.createdBy,
                remoteId: $0.remoteId,
                remoteVersion: $0.remoteVersion,
                syncStatus: $0.syncStatus,
                dirtySince: $0.dirtySince.map(BoardDTOBuilder.iso),
                lastSyncedAt: $0.lastSyncedAt.map(BoardDTOBuilder.iso),
                lastRemoteUpdatedAt: $0.lastRemoteUpdatedAt.map(BoardDTOBuilder.iso)
            )
        }
        let defaultIds = snapshot.canvases.filter { $0.isDefault }.map { $0.id }
        let layouts: [String: BoardLayoutStore.Layout] = Dictionary(
            uniqueKeysWithValues: snapshot.canvases.map { canvas in
                (canvas.id, BoardLayoutStore.shared.load(canvasId: canvas.id))
            }
        )
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

    /// POST /api/external-sessions/upsert
    /// Body: {
    ///   source: "chatgpt-web" | "claude-web" | "external",
    ///   externalId: string (browser-side conversation id),
    ///   title: string,
    ///   url?: string,
    ///   status: "idle" | "thinking" | "active" | ...,
    ///   recentMessages?: [{role, text, timestamp?}]
    /// }
    /// → { sid, isNew }
    static func upsertExternalSession(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let source = json["source"] as? String, !source.isEmpty,
              let externalId = json["externalId"] as? String, !externalId.isEmpty else {
            return errorResponse("bad_request", "missing source / externalId", status: 400)
        }
        let title = (json["title"] as? String) ?? ""
        let url = json["url"] as? String
        let status = (json["status"] as? String) ?? "idle"

        var msgs: [(role: String, text: String, timestamp: Date?)] = []
        if let rawMsgs = json["recentMessages"] as? [[String: Any]] {
            for m in rawMsgs {
                guard let role = m["role"] as? String,
                      let text = m["text"] as? String else { continue }
                let ts = (m["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:))
                msgs.append((role: role, text: text, timestamp: ts))
            }
        }

        let result = ExternalChatPlugin.shared.upsert(
            source: source,
            externalId: externalId,
            title: title,
            url: url,
            status: status,
            recentMessages: msgs
        )
        BoardServer.shared.broadcastStateChanged()
        return jsonResponse(ExternalSessionUpsertEnvelope(sid: result.sid, isNew: result.isNew))
    }

    /// POST /api/external-sessions/:sid/append-message
    /// Body: { role, text, timestamp? }
    static func appendExternalMessage(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":sid"] else {
            return errorResponse("bad_request", "missing sid", status: 400)
        }
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let role = json["role"] as? String,
              let text = json["text"] as? String else {
            return errorResponse("bad_request", "missing role / text", status: 400)
        }
        let ts = (json["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:))
        let ok = ExternalChatPlugin.shared.appendMessage(sid: sid, role: role, text: text, timestamp: ts)
        if !ok {
            return errorResponse("not_found", "external session not found: \(sid)", status: 404)
        }
        BoardServer.shared.broadcastStateChanged()
        return jsonResponse(OkEnvelope(ok: true))
    }

    /// DELETE /api/external-sessions/:sid
    /// Browser tab closed → drop the session card.
    static func deleteExternalSession(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":sid"] else {
            return errorResponse("bad_request", "missing sid", status: 400)
        }
        let removed = ExternalChatPlugin.shared.remove(sid: sid)
        if !removed {
            return errorResponse("not_found", "external session not found: \(sid)", status: 404)
        }
        BoardServer.shared.broadcastStateChanged()
        return jsonResponse(OkEnvelope(ok: true))
    }

    private struct ExternalSessionUpsertEnvelope: Encodable {
        let sid: String
        let isNew: Bool
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
