import Foundation
import Swifter
import Meee2PluginKit

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
        }
    }

    // MARK: - GET /api/state

    static func getState(_ req: HttpRequest) -> HttpResponse {
        let sessions = PluginManager.shared.sessions.map { BoardDTOBuilder.sessionDTO($0) }
        // 过滤 "__" 开头的自动频道（每个 session 的 operator channel 等）
        // 不在 UI 里显示，保持 channel 列表干净
        let channels = ChannelRegistry.shared.list()
            .filter { !$0.name.hasPrefix("__") }
            .map { BoardDTOBuilder.channelDTO($0) }
        let state = StateDTO(sessions: sessions, channels: channels)
        return jsonResponse(state)
    }

    // MARK: - Sessions

    /// POST /api/sessions/:id/activate
    /// 触发对应 session 的终端跳转（等同于 Island 点击卡片的行为）。
    /// Body: 无。响应: {"ok": true} 或 404。
    static func activateSession(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }
        // 在 PluginManager 的 session 列表中用前缀匹配，兼容 short-id
        let sessions = PluginManager.shared.sessions
        let match = sessions.first(where: { $0.id == sid })
            ?? sessions.first(where: { $0.id.hasPrefix(sid) })
        guard let session = match else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }
        PluginManager.shared.activateTerminal(for: session)
        return jsonResponse(OkEnvelope(ok: true))
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

        // 在 PluginManager 的 session 列表中做 short-id 匹配，拿回真实的 sessionId
        let sessions = PluginManager.shared.sessions
        let match = sessions.first(where: { $0.id == sid })
            ?? sessions.first(where: { $0.id.hasPrefix(sid) })
        guard let session = match else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }

        // Claude plugin 把 sessionId 前缀成 "com.meee2.plugin.claude-xxxx"，
        // inbox 文件以原始 sessionId 为 key
        let realSessionId = session.id.hasPrefix("\(session.pluginId)-")
            ? String(session.id.dropFirst("\(session.pluginId)-".count))
            : session.id

        // 统一路径（方案 B 全量）：operator 被看作 per-session 的一个
        // 普通 channel member，走 MessageRouter.send() → audit → deliverPending
        // → inbox 写入；resting session 的 Ghostty push 由 deliverPending
        // 的钩子自动触发（见 MessageRouter.pushToRestingSessionIfNeeded）。
        do {
            let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: realSessionId)
            let written = try MessageRouter.shared.send(
                channel: channelName,
                fromAlias: "operator",
                toAlias: "session",
                content: content,
                injectedByHuman: true
            )
            let status = SessionStore.shared.get(realSessionId)?.status.rawValue ?? "?"
            NSLog("[inject] via channel=\(channelName) msg=\(written.id) sid=\(realSessionId.prefix(8)) status=\(status)")
            BoardServer.shared.broadcastStateChanged()
            return jsonResponse(MessageEnvelope(message: BoardDTOBuilder.messageDTO(written)),
                                status: 201, reason: "Created")
        } catch {
            return errorResponse("bad_request", error.localizedDescription, status: 400)
        }
    }

    /// GET /api/sessions/:id/transcript?limit=...
    /// 返回该 session 的完整 transcript entries（user/assistant），每个
    /// entry 的 blocks 保留原始结构：text / thinking / tool_use / tool_result。
    static func getTranscript(_ req: HttpRequest) -> HttpResponse {
        guard let sid = req.params[":id"] else {
            return errorResponse("bad_request", "missing session id", status: 400)
        }

        // short-id 匹配
        let sessions = PluginManager.shared.sessions
        let match = sessions.first(where: { $0.id == sid })
            ?? sessions.first(where: { $0.id.hasPrefix(sid) })
        guard let session = match else {
            return errorResponse("not_found", "session not found: \(sid)", status: 404)
        }

        // SessionStore 拿 transcriptPath
        let realSessionId = session.id.hasPrefix("\(session.pluginId)-")
            ? String(session.id.dropFirst("\(session.pluginId)-".count))
            : session.id
        let data = SessionStore.shared.get(realSessionId)
        let transcriptPath = data?.transcriptPath

        // 可选 limit —— 最新 N 条（tail）
        var limit: Int? = nil
        if let q = req.queryParams.first(where: { $0.0 == "limit" })?.1,
           let n = Int(q), n > 0 {
            limit = n
        }

        let entries = FullTranscriptReader.read(transcriptPath: transcriptPath, limit: limit)
        return jsonResponse(FullTranscriptEnvelope(entries: entries, sessionId: realSessionId))
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

        let createIfMissing = (json["createIfMissing"] as? Bool) ?? false
        let command = (json["command"] as? String) ?? "claude"
        let termProgram = (json["termProgram"] as? String)

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
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: SpawnResult = .failed(reason: "no outcome")
        Task {
            outcome = await spawner.spawn(cwd: cwd, command: command)
            semaphore.signal()
        }
        // 等最多 2s；Ghostty 开窗一般 200-500ms
        _ = semaphore.wait(timeout: .now() + 2.0)

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
        var statusFilter: Set<MessageStatus>? = nil
        var limit = 50
        for (k, v) in req.queryParams {
            switch k {
            case "status":
                var set = Set<MessageStatus>()
                for token in v.split(separator: ",") {
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
}
