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

    // MARK: - GET /api/state

    static func getState(_ req: HttpRequest) -> HttpResponse {
        let started = Date()
        defer {
            if ProcessInfo.processInfo.environment["MEEE2_PERF_LOG"] == "1" {
                let ms = Date().timeIntervalSince(started) * 1_000
                MLog(String(format: "[Perf][BoardAPI] getState %.1fms", ms))
            }
        }
        // Web UI 不显示 .dead 的 session：Ghostty 终端被关 / 进程已退 / 文件
        // 早被清理的"幽灵卡"。Island + StatusManager 内部仍然能读到 .dead
        // 用来触发 "session ended" 通知，所以只在 BoardDTO 出口过滤，不动
        // PluginManager 的全集。
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
            PlannerSessionRunStateBridge.observeBound(
                sessionId: session.id,
                status: status
            )
        }
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
        guard let canvasId = req.params[":id"], !canvasId.isEmpty else {
            return errorResponse("bad_request", "missing canvas id", status: 400)
        }
        do {
            let run = try PlannerBoardBridge.startRun(
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
    private static func runPlannerRuntimeProposal(
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
                states: preview.states
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
            recordPlannerDispatchIntent(canvasId: canvasId, node: result.dispatchedNode)
            BoardServer.shared.broadcastStateChanged()
            let state = result.graph
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

    static func attachPlannerArtifactToNode(_ req: HttpRequest) -> HttpResponse {
        struct AttachArtifactRequest: Decodable {
            let kind: PlannerArtifactKind?
            let title: String?
            let reference: String
            let status: String?
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
        guard let output = decodeJSONBody(req, as: PlannerNodeOutput.self) else {
            return errorResponse("invalid_json", "body must be a valid node output payload", status: 400)
        }
        do {
            let result = try PlannerBoardBridge.submitNodeOutput(
                nodeId: nodeId,
                output: output,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
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
                states: result.states
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

    private static func mapPlannerCoreError(_ err: PlannerCoreError) -> HttpResponse {
        switch err {
        case .canvasNotFound, .proposalNotFound, .runNotFound:
            return errorResponse("not_found", err.localizedDescription, status: 404)
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
            recordPlannerDispatchIntent(canvasId: canvasId, node: node)
        }
    }

    /// Record the CLI spawn intent for a single dispatched node. Shared by the
    /// proposal-apply path (`recordPlannerDispatchIntents`) and the direct
    /// dispatch endpoint. `ci-agent` / `human` produce no intent
    /// (`spawnsSession` is false for both).
    private static func recordPlannerDispatchIntent(canvasId: String, node: PlanningNode) {
        guard node.workflowRunState == .dispatched else { return }
        guard let dispatch = node.dispatch, dispatch.runner.spawnsSession else { return }
        guard let cwd = try? BoardLayoutStore.shared.workspacePath(canvasId: canvasId) else { return }
        let command = dispatch.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCommand = command?.isEmpty == false
            ? command!
            : (dispatch.runner.spawnCommand ?? "claude")
        let provider = resolvedCommand.lowercased().contains("codex") ? "codex" : "claude"
        // Purpose is tagged with the *step* node id; the session PlanningNode
        // (created alongside the dispatch) `dependsOnNodeIds` this step, so
        // `PlannerSessionRunStateBridge` can resolve step → session.
        _ = try? BoardLayoutStore.shared.recordSpawnIntent(
            canvasId: canvasId,
            cwd: cwd,
            command: resolvedCommand,
            provider: provider,
            purpose: "planner:\(node.id)",
            initialPrompt: plannerDispatchPrompt(for: node),
            layoutHint: nil
        )
    }

    private static func plannerDispatchPrompt(for node: PlanningNode) -> String {
        var lines = [
            "You are executing a meee2 AI planner node.",
            "Node: \(node.title)",
            "Doer: \(node.doerId)",
            "Completion signal: \(node.ioSchema.completionSignal)"
        ]
        if !node.ioSchema.consumes.isEmpty {
            lines.append("Consumes: \(node.ioSchema.consumes.joined(separator: ", "))")
        }
        if !node.ioSchema.produces.isEmpty {
            lines.append("Produces: \(node.ioSchema.produces.joined(separator: ", "))")
        }
        if let gate = node.gate {
            lines.append("Gate: \(gate.label)")
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

    private static func currentBoardSessions() -> [SessionDTO] {
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
        let realSessions = PluginManager.shared.sessions
            .filter { PluginManager.shared.isPluginEnabled($0.pluginId) }
            .filter { $0.status != .dead }
            .filter { session in
                let realSid = session.id.hasPrefix("\(session.pluginId)-")
                    ? String(session.id.dropFirst("\(session.pluginId)-".count))
                    : session.id
                return !archivedDesktopSids.contains(realSid)
            }
            .map { BoardDTOBuilder.sessionDTO($0) }

        // Desktop 的 session 生命周期是"请求级"，所以用 metadata 合成持久展示。
        let realSids: Set<String> = Set(realSessions.map { $0.id })
        let syntheticDesktopSessions: [SessionDTO] = ClaudeDesktopMetadataReader.shared
            .allCliSessionIds()
            .compactMap { cliSid -> SessionDTO? in
                guard PluginManager.shared.isPluginEnabled("com.meee2.plugin.claude") else { return nil }
                guard let m = ClaudeDesktopMetadataReader.shared.lookup(cliSessionId: cliSid),
                      !m.isArchived,
                      !realSids.contains(cliSid) else { return nil }
                return BoardDTOBuilder.syntheticDesktopSessionDTO(metadata: m)
            }
        return realSessions + syntheticDesktopSessions
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
    /// 主要给 dev 测预下载流程用 —— 生产环境靠 24h 调度。
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
    /// 触发 Sparkle 安装流程。如果 SUAutomaticallyUpdate=YES 且后台已经
    /// 下载好新版,这一步会立刻 apply + relaunch(codex-style 体验);
    /// 否则会弹 Sparkle 的标准 modal 让用户确认。具体路径由 Sparkle 自
    /// 决定 —— BoardAPI 这边只发通知,AppDelegate 接住调
    /// SPUStandardUpdaterController.checkForUpdates(_:)。
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
    /// 行为：按 cwd 打开一个新 Ghostty 窗口，并在里面跑 command（默认 "claude"）。
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

        let command = (json["command"] as? String) ?? "claude"
        let termProgram = (json["termProgram"] as? String)
        let createIfMissing = (json["createIfMissing"] as? Bool) ?? false

        return spawnTerminalSession(cwd: cwd, command: command, createIfMissing: createIfMissing, termProgram: termProgram)
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
            command = "claude"
        case "codex":
            command = "codex"
        default:
            return errorResponse("bad_request", "provider must be 'claude' or 'codex'", status: 400)
        }
        let termProgram = json["termProgram"] as? String
        do {
            let cwd = try BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
            try BoardLayoutStore.shared.recordSpawnIntent(
                canvasId: canvasId,
                cwd: cwd,
                command: command,
                provider: provider,
                purpose: "global",
                initialPrompt: nil,
                layoutHint: nil
            )
            return spawnTerminalSession(cwd: cwd, command: command, createIfMissing: true, termProgram: termProgram)
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
        // Ensure dir exists / create if requested
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            if createIfMissing {
                do {
                    try FileManager.default.createDirectory(
                        atPath: cwd,
                        withIntermediateDirectories: true
                    )
                } catch {
                    return errorResponse("mkdir_failed", "mkdir -p failed: \(error.localizedDescription)", status: 500)
                }
            } else {
                return errorResponse("not_found", "cwd does not exist: \(cwd) (pass createIfMissing=true to mkdir)", status: 404)
            }
        }

        let spawner = SpawnerRouter.forTerminal(termProgram)

        // Fire-and-forget async spawn; don't block the HTTP response waiting
        // for AppleScript. Client can poll `/api/state` to see the new session
        // appear once the hook bridge fires its SessionStart.
        //
        // Swift 5.10 的 concurrency diagnostics 禁止 Task 闭包里"写入"或"读取"
        // 外层 `var`。这里：
        //   - `cwd` 是外层 var（~ 展开 / path normalize 会改它），先 snapshot 成
        //     let 常量再捕获
        //   - `outcome` 需要双向（Task 写 / 外层读）→ 放进引用型 box，closure
        //     只改 box 的属性而不是重绑变量，就符合 Sendable 约束
        final class OutcomeBox: @unchecked Sendable {
            var value: SpawnResult?  // nil = pending; non-nil = spawner returned
        }
        let cwdSnapshot = cwd
        let commandSnapshot = command
        let outcomeBox = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let r = await spawner.spawn(cwd: cwdSnapshot, command: commandSnapshot)
            outcomeBox.value = r
            semaphore.signal()
        }
        // Ghostty 开窗 + sleep 400ms + input text 通常 1-2s；长 cmd 经过
        // AppleScript 转义会再慢一点。老的 2s 阈值容易超时返回 "no outcome"
        // 假报错（实际窗口已经开成功）。给 5s。timeout 不算失败：spawner 真
        // 出错会立刻 .failed 并 signal；timeout 时通常 AppleScript 还在跑，
        // SessionStart hook 后续会照常触发，client 通过 /api/state 能看到。
        let waitResult = semaphore.wait(timeout: .now() + 5.0)
        let outcome: SpawnResult
        switch waitResult {
        case .success:
            outcome = outcomeBox.value ?? .success
        case .timedOut:
            NSLog("[BoardAPI] spawnSession: 5s elapsed, outcome unknown — assuming async success")
            outcome = .success
        }

        switch outcome {
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
        do {
            let snapshot = try BoardLayoutStore.shared.createCanvas(name: name, scope: scope)
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
                isDefault: $0.isDefault,
                workspacePath: workspacePath,
                teamId: $0.teamId,
                ownerUserId: $0.ownerUserId,
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

    private static func parseStringArray(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }
}
