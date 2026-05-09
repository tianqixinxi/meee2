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

        // ─── Desktop session 持久化合成 ───
        // Desktop 的 session 生命周期是"请求级"——内嵌 claude 子进程只在用户
        // 发消息时活几秒，结束后退出。ClaudePlugin（hook + PID 文件驱动）会
        // 在子进程退出后把 session 标完成 / 移除，导致 desktop session 在 Web UI
        // 上一闪而过。
        //
        // 解决：用 metadata 文件作为持久化 session 源，对 PluginManager 不知道
        // 的 desktop cliSessionId 合成 SessionDTO。已经在 PluginManager 里活着
        // 的 desktop session（用户刚发消息那几秒）走真实分支不被合成覆盖。
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
        let sessions = realSessions + syntheticDesktopSessions
        // 过滤 "__" 开头的自动频道（每个 session 的 operator channel 等）
        // 不在 UI 里显示，保持 channel 列表干净
        let channels = ChannelRegistry.shared.list()
            .filter { !$0.name.hasPrefix("__") }
            .map { BoardDTOBuilder.channelDTO($0) }
        let state = StateDTO(sessions: sessions, channels: channels)
        return jsonResponse(state)
    }

    // MARK: - GET /api/user-profile

    static func getUserProfile(_ req: HttpRequest) -> HttpResponse {
        let settings = readMeee360Settings()
        let defaults = UserDefaults.standard
        let connected = defaults.bool(forKey: "meee360Connected")
        let userName = connected
            ? defaultString(defaults, key: "meee360UserName", fallback: settings["userName"])
            : ""
        let userEmail = connected
            ? defaultString(defaults, key: "meee360UserEmail", fallback: settings["userEmail"])
            : ""
        let userAvatarUrl = connected
            ? defaultString(defaults, key: "meee360UserAvatarUrl", fallback: settings["userAvatarUrl"])
            : ""
        let displayName: String
        if !userName.isEmpty {
            displayName = userName
        } else if !userEmail.isEmpty {
            displayName = userEmail.components(separatedBy: "@").first ?? userEmail
        } else {
            displayName = connected ? "meee360 user" : "Not connected"
        }

        return jsonResponse(UserProfileDTO(
            connected: connected,
            displayName: displayName,
            userName: userName,
            userEmail: userEmail,
            userAvatarUrl: userAvatarUrl,
            initials: initials(for: displayName, connected: connected),
            dashboardUrl: Meee360Config.appURL(path: "dashboard").absoluteString,
            connectUrl: meee360ConnectUrl().absoluteString
        ))
    }

    static func openMeee360Connect(_ req: HttpRequest) -> HttpResponse {
        NSWorkspace.shared.open(meee360ConnectUrl())
        return jsonResponse(OkEnvelope(ok: true))
    }

    static func openMeee360Dashboard(_ req: HttpRequest) -> HttpResponse {
        NSWorkspace.shared.open(Meee360Config.appURL(path: "dashboard"))
        return jsonResponse(OkEnvelope(ok: true))
    }

    static func openMeee2Settings(_ req: HttpRequest) -> HttpResponse {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("openSettings"), object: nil)
        }
        return jsonResponse(OkEnvelope(ok: true))
    }

    static func disconnectMeee360(_ req: HttpRequest) -> HttpResponse {
        clearMeee360Settings()
        Meee360Pusher.shared.refreshActivation()
        return jsonResponse(OkEnvelope(ok: true))
    }

    private static func readMeee360Settings() -> [String: Any] {
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2/settings.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meee360 = root["meee360"] as? [String: Any] else {
            return [:]
        }
        return meee360
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

    private static func meee360ConnectUrl() -> URL {
        var components = URLComponents(url: Meee360Config.appURL(path: "connect"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback", value: "\(BoardServer.shared.url)/meee360/callback")
        ]
        return components.url!
    }

    private static func clearMeee360Settings() {
        let defaults = UserDefaults.standard
        for key in [
            "meee360Connected",
            "meee360Online",
            "meee360TeamId",
            "meee360TeamName",
            "meee360Teams",
            "meee360SessionTeamIds",
            "meee360UserId",
            "meee360UserName",
            "meee360UserEmail",
            "meee360UserAvatarUrl",
            "meee360SupabaseUrl",
            "meee360SupabaseKey",
            "meee360EnabledSessionIds",
            "meee360DisabledSessionIds"
        ] {
            defaults.removeObject(forKey: key)
        }

        let settings: [String: Any] = [
            "meee360": [
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

    // MARK: - Board Layout

    /// GET /api/board/layout
    /// 200 `{"layout":{"sessions":{sid:{x,y}},"channels":{name:{x,y}},"updatedAt":ISO}}`
    /// 文件不存在时 `sessions` / `channels` 为空对象。
    static func getBoardLayout(_ req: HttpRequest) -> HttpResponse {
        _ = req
        let layout = BoardLayoutStore.shared.load()
        return jsonResponse(BoardLayoutEnvelope(layout: layout))
    }

    /// PUT /api/board/layout
    /// Body: `{"sessions":{sid:{x,y}},"channels":{name:{x,y}}}`
    /// 200 `{"layout":...}` / 400 invalid_json
    static func putBoardLayout(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        let current = BoardLayoutStore.shared.load()
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
            let saved = try BoardLayoutStore.shared.save(layout)
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
            if let x = x, let y = y {
                out[k] = BoardLayoutStore.Point(x: x, y: y)
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
