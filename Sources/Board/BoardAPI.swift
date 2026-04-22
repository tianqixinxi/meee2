import Foundation
import Swifter

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
        let channels = ChannelRegistry.shared.list().map { BoardDTOBuilder.channelDTO($0) }
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
    /// 200 `{"template":Entry}` or 404
    static func getCardTemplate(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"] else {
            return errorResponse("bad_request", "missing template id", status: 400)
        }
        guard CardTemplateStore.isValidId(id) else {
            return mapCardTemplateError(.invalidId(id))
        }
        guard let entry = CardTemplateStore.shared.get(id) else {
            return mapCardTemplateError(.notFound(id))
        }
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
