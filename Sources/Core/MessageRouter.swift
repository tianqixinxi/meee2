import Foundation
import Meee2PluginKit

/// MessageRouter 错误
public enum MessageRouterError: Error, CustomStringConvertible {
    case channelNotFound(String)
    case unknownSender(alias: String, channel: String)
    case unknownRecipient(alias: String, channel: String)
    case messageNotFound(String)
    /// 不能修改 delivered / dropped 的消息
    case alreadyTerminal(String)
    /// deliverPending 被自动调用时遇到 paused 频道（除非显式 deliver(id)）
    case channelPaused(String)
    /// 广播 `*` 但把发送方排除后没有任何接收方（channel 只有一个成员且
    /// 正好是发送方 / channel 没有成员）。不再悄悄把消息标成 delivered=[]。
    case emptyRecipients(channel: String)
    /// 一段对话 hop count 超过 MessageRouter.maxHopsHard——传输层级联放大兜底。
    /// 类比 IP TTL：到这里就强制断路，不让 agent 互相递归把磁盘和 Ghostty 打爆。
    case hopLimitExceeded(channel: String, hopCount: Int)

    public var description: String {
        switch self {
        case .channelNotFound(let n): return "channel not found: \(n)"
        case .unknownSender(let a, let c): return "unknown sender alias '\(a)' in channel '\(c)'"
        case .unknownRecipient(let a, let c): return "unknown recipient alias '\(a)' in channel '\(c)'"
        case .messageNotFound(let id): return "message not found: \(id)"
        case .alreadyTerminal(let id): return "message already terminal (delivered/dropped): \(id)"
        case .channelPaused(let c): return "channel is paused: \(c)"
        case .emptyRecipients(let c):
            return "broadcast in channel '\(c)' has no recipients (add another member or pick a specific toAlias)"
        case .hopLimitExceeded(let c, let h):
            return "hop limit exceeded in channel '\(c)' (hopCount=\(h), max=\(MessageRouter.maxHopsHard))"
        }
    }
}

/// MessageRouter - 管理 A2A 消息的投递与人机协同
///
/// 持久化：
///   - 消息信封: ~/.meee2/messages/<channel>/<msg-id>.json
///   - 接收方收件箱: ~/.claude/teams/meee2/inboxes/<sessionId>.json
///     （JSON **数组**，对齐 oh-my-claudecode / Claude Code 原生 Agent Teams
///      约定；人被视为"operator" agent，走同一个 inbox 协议）
/// 线程安全：所有公开方法通过串行 DispatchQueue 同步。
public final class MessageRouter {
    public static let shared = MessageRouter()

    /// 一段对话允许的最大 hop count。超过 → send() throw hopLimitExceeded。
    /// 类比 IP TTL：50 大到不会误伤任何合理工作流（plan-verify-fix 一般 < 20 跳），
    /// 但小到不会让两个 agent 互相递归打爆磁盘 / Ghostty。
    public static let maxHopsHard: Int = 50

    private let fileManager = FileManager.default
    private let baseDir: URL
    private let messagesDir: URL
    private let inboxDir: URL
    private let legacyInboxDir: URL

    /// 内存缓存：msgId -> A2AMessage。所有访问须持 queue
    private var cache: [String: A2AMessage] = [:]

    private let queue = DispatchQueue(label: "com.meee2.message-router", qos: .userInitiated)

    private init() {
        let home = NSHomeDirectory()
        baseDir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        messagesDir = baseDir.appendingPathComponent("messages")
        // 新路径：~/.claude/teams/meee2/inboxes/<sid>.json
        // oh-my-claudecode 和 Claude Code 原生 Agent Teams 都用这个根
        let claudeDir = URL(fileURLWithPath: home).appendingPathComponent(".claude")
        inboxDir = claudeDir
            .appendingPathComponent("teams")
            .appendingPathComponent("meee2")
            .appendingPathComponent("inboxes")
        // 旧路径：用于首次启动迁移 legacy .jsonl 文件
        legacyInboxDir = baseDir.appendingPathComponent("inbox")

        try? fileManager.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        migrateLegacyInboxes()
        loadAll()
        // Push / flush / SessionEventBus 订阅由 AgentInboxShell（Layer 2）负责。
        // 这里 reference 一下确保它的 init 跑过，订阅生效。
        _ = AgentInboxShell.shared
    }

    /// 列出所有有 inbox 文件的 sessionId（给 AgentInboxShell.flushAllInboxes 用）
    public func allInboxSessionIds() -> [String] {
        queue.sync {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: inboxDir,
                includingPropertiesForKeys: nil
            ) else { return [] }
            return entries
                .filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
    }

    /// 一次性把 ~/.meee2/inbox/<sid>.jsonl 转成 ~/.claude/teams/meee2/inboxes/<sid>.json
    /// 转完删除旧文件。重复运行安全（老文件没了就不做事）。
    private func migrateLegacyInboxes() {
        queue.sync {
            guard fileManager.fileExists(atPath: legacyInboxDir.path) else { return }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: legacyInboxDir,
                includingPropertiesForKeys: nil
            ) else { return }
            var migrated = 0
            for oldFile in entries where oldFile.pathExtension == "jsonl" {
                let sid = oldFile.deletingPathExtension().lastPathComponent
                let newFile = inboxDir.appendingPathComponent("\(sid).json")
                guard let content = try? String(contentsOf: oldFile, encoding: .utf8) else { continue }
                let messages = parseJsonl(content)
                if messages.isEmpty {
                    try? fileManager.removeItem(at: oldFile)
                    continue
                }
                // 合并进新文件（如果已有）
                var existing: [A2AMessage] = []
                if fileManager.fileExists(atPath: newFile.path),
                   let data = try? Data(contentsOf: newFile) {
                    existing = (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
                }
                let combined = existing + messages
                if let data = try? jsonArrayEncoder.encode(combined) {
                    try? data.write(to: newFile, options: .atomic)
                    try? fileManager.removeItem(at: oldFile)
                    migrated += messages.count
                }
            }
            if migrated > 0 {
                MLog("[MessageRouter] migrated \(migrated) legacy inbox message(s) → \(inboxDir.path)")
            }
        }
    }

    private var jsonArrayEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private var jsonArrayDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Send

    /// 发送一条消息。
    /// - auto 模式：先以 .pending 持久化，随后同步调用 deliverPending()（MVP 不做延迟）
    /// - intercept / paused 模式：保持 .pending，不自动投递
    @discardableResult
    public func send(
        channel: String,
        fromAlias: String,
        toAlias: String,
        content: String,
        replyTo: String? = nil,
        injectedByHuman: Bool = false
    ) throws -> A2AMessage {
        // 不允许使用通配符作为发送方
        if fromAlias == "*" {
            throw MessageRouterError.unknownSender(alias: "*", channel: channel)
        }

        guard let ch = ChannelRegistry.shared.get(channel) else {
            throw MessageRouterError.channelNotFound(channel)
        }

        // "operator" 作为合成发送方：人从 Web UI 往任意 channel 发消息，
        // operator 不必是 channel 的真 member 也能发。校验条件：必须
        // injectedByHuman=true（agent 不能伪装成 operator）。这样 channel
        // 里只有一个 agent 成员时，operator → agent 也不会踩到 "broadcast
        // 排除自己 → 收件人为空" 的死局。
        let senderSessionId: String
        if fromAlias == "operator" && injectedByHuman {
            senderSessionId = ""  // operator 在 channel member 表外
        } else {
            guard let sender = ch.memberByAlias(fromAlias) else {
                throw MessageRouterError.unknownSender(alias: fromAlias, channel: channel)
            }
            senderSessionId = sender.sessionId
        }

        // 若指定具体接收者，需验证其存在；"*" 表示广播，延迟到投递时再 fan-out
        if toAlias != "*" {
            guard ch.memberByAlias(toAlias) != nil else {
                throw MessageRouterError.unknownRecipient(alias: toAlias, channel: channel)
            }
        } else {
            // 广播预检：把发送方排除掉之后必须还有人，否则 deliverPending
            // 会写一条 status=delivered / deliveredTo=[] 的"死"消息，看起来
            // 送达了其实谁都没收到。宁可在 send 就拒掉。
            let recipients = ch.members.filter { $0.alias != fromAlias }
            if recipients.isEmpty {
                throw MessageRouterError.emptyRecipients(channel: channel)
            }
        }

        // ── traceId / hopCount 计算（envelope 协议字段）──
        // 有 replyTo → 继承 parent 的 traceId，hopCount = parent.hopCount + 1
        // 没 replyTo → 新对话根，traceId = 自己的 id（init 默认会处理），hopCount = 0
        let parentMsg: A2AMessage? = replyTo.flatMap { id in
            queue.sync { cache[id] }
        }
        let derivedTraceId: String? = parentMsg?.traceId
        let derivedHopCount: Int = (parentMsg?.hopCount ?? -1) + 1
        if derivedHopCount > Self.maxHopsHard {
            // 不持久化、不进 cache、不写 inbox。直接 throw + 写一条 dropped
            // audit 让 forensics 能看到曾经有人撞这堵墙。
            AuditLogger.shared.log(AuditEvent(
                event: .dropped,
                msgId: "rejected-hop-overflow",
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                actor: injectedByHuman ? "human" : "agent:\(fromAlias)",
                details: "hop \(derivedHopCount) > max \(Self.maxHopsHard) (replyTo=\(replyTo ?? "?"))"
            ))
            throw MessageRouterError.hopLimitExceeded(channel: channel, hopCount: derivedHopCount)
        }

        let msg = A2AMessage(
            traceId: derivedTraceId,
            channel: channel,
            fromAlias: fromAlias,
            fromSessionId: senderSessionId,
            toAlias: toAlias,
            content: content,
            replyTo: replyTo,
            hopCount: derivedHopCount,
            status: .pending,
            injectedByHuman: injectedByHuman
        )

        try queue.sync {
            try persist(msg)
            cache[msg.id] = msg
        }

        MInfo("[MessageRouter] send \(msg.id) channel=\(channel) \(fromAlias) -> \(toAlias) mode=\(ch.mode.rawValue)")

        // 审计：人工注入发一条 .injected，agent 自发送发一条 .created
        if injectedByHuman {
            AuditLogger.shared.log(AuditEvent(
                event: .injected,
                msgId: msg.id,
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                actor: "human"
            ))
        } else {
            AuditLogger.shared.log(AuditEvent(
                event: .created,
                msgId: msg.id,
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                actor: "agent:\(fromAlias)"
            ))
        }

        // 发消息本身是一次变动：订阅者可借此看到新的 pending 消息
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: channel))

        // 根据频道模式决定是否立即投递
        switch ch.mode {
        case .auto:
            // MVP：无延迟，直接自动投递
            do {
                return try deliverPending(msg.id)
            } catch {
                // 若投递过程中出错（例如频道瞬变为 paused），保留为 pending 状态
                MWarn("[MessageRouter] auto-deliver failed for \(msg.id): \(error)")
                return msg
            }
        case .intercept, .paused:
            return msg
        }
    }

    // MARK: - Query

    /// 列出消息，可按频道 / 状态过滤（按 createdAt 升序）
    public func listMessages(channel: String? = nil, statuses: Set<MessageStatus>? = nil) -> [A2AMessage] {
        queue.sync {
            cache.values
                .filter { msg in
                    if let channel = channel, msg.channel != channel { return false }
                    if let statuses = statuses, !statuses.contains(msg.status) { return false }
                    return true
                }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// 按 ID 获取消息
    public func get(_ id: String) -> A2AMessage? {
        queue.sync { cache[id] }
    }

    // MARK: - Human Actions

    /// 人工挂起
    @discardableResult
    public func hold(_ id: String) throws -> A2AMessage {
        let msg = try mutateNonTerminal(id) { msg in
            msg.status = .held
        }
        AuditLogger.shared.log(AuditEvent(
            event: .held,
            msgId: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            actor: "human"
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: msg.channel))
        return msg
    }

    /// 人工丢弃
    @discardableResult
    public func drop(_ id: String) throws -> A2AMessage {
        let msg = try mutateNonTerminal(id) { msg in
            msg.status = .dropped
        }
        AuditLogger.shared.log(AuditEvent(
            event: .dropped,
            msgId: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            actor: "human"
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: msg.channel))
        return msg
    }

    /// 人工编辑消息正文
    @discardableResult
    public func edit(_ id: String, newContent: String) throws -> A2AMessage {
        // 捕获编辑前长度用于审计（不记录内容 —— 可能含敏感信息）
        let oldLen = queue.sync { cache[id]?.content.count }
        let msg = try mutateNonTerminal(id) { msg in
            msg.content = newContent
        }
        let details = "len old=\(oldLen ?? -1) new=\(newContent.count)"
        AuditLogger.shared.log(AuditEvent(
            event: .edited,
            msgId: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            actor: "human",
            details: details
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: msg.channel))
        return msg
    }

    /// 人工强制投递（绕过 paused 模式）
    @discardableResult
    public func deliver(_ id: String) throws -> A2AMessage {
        try deliverPending(id, force: true)
    }

    // MARK: - Delivery

    /// 自动投递循环 / 人工 deliver() 的核心。解析接收者，追加到收件箱，
    /// 设置 status=.delivered, deliveredAt=now。
    /// - force=true: 允许穿透 .paused 频道
    @discardableResult
    public func deliverPending(_ id: String) throws -> A2AMessage {
        try deliverPending(id, force: false)
    }

    @discardableResult
    private func deliverPending(_ id: String, force: Bool) throws -> A2AMessage {
        // 1) 先在队列内检查与解析，然后释放队列再写 inbox（inbox 写入是独立文件）
        let (msgToDeliver, recipientMembers) = try queue.sync { () -> (A2AMessage, [ChannelMember]) in
            guard var msg = cache[id] else {
                throw MessageRouterError.messageNotFound(id)
            }
            if msg.status == .delivered || msg.status == .dropped {
                throw MessageRouterError.alreadyTerminal(id)
            }
            guard let ch = ChannelRegistry.shared.get(msg.channel) else {
                throw MessageRouterError.channelNotFound(msg.channel)
            }
            // paused 频道：除非 force，否则拒绝
            if ch.mode == .paused && !force {
                throw MessageRouterError.channelPaused(msg.channel)
            }

            // 解析接收者（广播时排除发送方）
            let recipients: [ChannelMember]
            if msg.toAlias == "*" {
                recipients = ch.members.filter { $0.alias != msg.fromAlias }
            } else {
                guard let target = ch.memberByAlias(msg.toAlias) else {
                    throw MessageRouterError.unknownRecipient(alias: msg.toAlias, channel: msg.channel)
                }
                recipients = [target]
            }

            // 更新状态（但收件箱写入放在 queue 外）
            msg.status = .delivered
            msg.deliveredAt = Date()
            msg.deliveredTo = recipients.map { $0.alias }
            try persist(msg)
            cache[id] = msg
            return (msg, recipients)
        }

        // 2) 写入每个接收方的 inbox（JSON 数组追加）
        for member in recipientMembers {
            do {
                try appendToInbox(sessionId: member.sessionId, message: msgToDeliver)
            } catch {
                MWarn("[MessageRouter] appendToInbox failed for \(member.sessionId.prefix(8)): \(error)")
            }
        }

        // 3) 交给 Layer 2 (AgentInboxShell) 决定推送时机 / 方式 / 策略。
        //    Shell 看 resolver 状态 + ghosttyTerminalId + InboxShellPolicy，
        //    busy 的就跳过等 SessionEventBus 兜底。
        for member in recipientMembers where !member.sessionId.isEmpty {
            AgentInboxShell.shared.tryDeliver(sessionId: member.sessionId, message: msgToDeliver)
        }

        MInfo("[MessageRouter] delivered \(id) -> [\(msgToDeliver.deliveredTo.joined(separator: ","))]")

        // 审计：一个 delivered 事件，fan-out 不拆分成多条
        var auditDetails: String?
        if msgToDeliver.toAlias == "*" {
            auditDetails = "fanout=[\(msgToDeliver.deliveredTo.joined(separator: ","))]"
        }
        AuditLogger.shared.log(AuditEvent(
            event: .delivered,
            msgId: msgToDeliver.id,
            channel: msgToDeliver.channel,
            fromAlias: msgToDeliver.fromAlias,
            toAlias: msgToDeliver.toAlias,
            actor: "human",
            details: auditDetails
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msgToDeliver.id, channel: msgToDeliver.channel))
        return msgToDeliver
    }

    // MARK: - Inbox

    /// 读取并清空指定会话的 inbox，返回已解析消息（oldest -> newest）。
    /// 文件缺失时返回空数组。
    public func drainInbox(sessionId: String) -> [A2AMessage] {
        queue.sync {
            let path = inboxPath(sessionId)
            guard fileManager.fileExists(atPath: path.path) else { return [] }

            // 原子化：rename -> read -> delete
            let tmp = path.appendingPathExtension("drain.\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970))")
            do {
                try fileManager.moveItem(at: path, to: tmp)
            } catch {
                MWarn("[MessageRouter] drainInbox rename failed for \(sessionId.prefix(8)): \(error)")
                return []
            }

            defer { try? fileManager.removeItem(at: tmp) }

            guard let data = try? Data(contentsOf: tmp) else { return [] }
            return (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
        }
    }

    /// 只读查看 inbox（不清空），用于人类观察
    public func peekInbox(sessionId: String) -> [A2AMessage] {
        queue.sync {
            let path = inboxPath(sessionId)
            guard fileManager.fileExists(atPath: path.path) else { return [] }
            guard let data = try? Data(contentsOf: path) else { return [] }
            return (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
        }
    }

    /// 直接把一条合成消息写进某会话的 inbox（用于 `msg halt` 等场景）。
    /// 不需要该会话在某个频道中。返回已写入的 A2AMessage。
    ///
    /// 注：这是 legacy 入口。Web UI 发消息已经改走 `send()` + 每 session 的
    /// operator channel（人 = 普通 agent 同路径）；这里保留给 CLI `msg halt`
    /// 和 A2AConnectSheet 等 side-path 使用。
    @discardableResult
    public func injectDirectToInbox(sessionId: String, message: A2AMessage) throws -> A2AMessage {
        try queue.sync {
            try appendToInbox(sessionId: sessionId, message: message)
        }
        SessionEventBus.shared.publish(.messageMutated(id: message.id, channel: message.channel))
        return message
    }

    /// 从 inbox JSON 数组中移除指定 id 的消息，原子写回。
    /// 给 AgentInboxShell push 成功后调用。线程安全（内部走 queue.sync）。
    public func removeFromInbox(sessionId: String, messageId: String) {
        queue.sync { removeFromInboxLocked(sessionId: sessionId, messageId: messageId) }
    }

    /// 实际执行 remove。调用方须持 queue。
    private func removeFromInboxLocked(sessionId: String, messageId: String) {
        let path = inboxPath(sessionId)
        guard fileManager.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              var list = try? jsonArrayDecoder.decode([A2AMessage].self, from: data) else {
            return
        }
        let before = list.count
        list.removeAll { $0.id == messageId }
        if list.count == before { return }
        do {
            if list.isEmpty {
                try fileManager.removeItem(at: path)
            } else {
                let out = try jsonArrayEncoder.encode(list)
                try out.write(to: path, options: .atomic)
            }
        } catch {
            MWarn("[MessageRouter] removeFromInbox failed for \(sessionId.prefix(8))/\(messageId): \(error)")
        }
    }

    /// 返回某 session 对应的 per-session operator channel 名字，确保它存在
    /// 且包含两个约定成员：`operator`（人）和 `session`（这个 session）。
    ///
    /// 这是"人 = agent"统一化的核心：operator 把消息发给 session 用的不是
    /// 一个特殊接口，就是 A2A channel.send 的普通调用——send() → audit →
    /// deliverPending → inbox 路径完整复用。
    ///
    /// Channel 名：`__ops-<sessionId>`（双下划线前缀，BoardDTO 会把这类
    /// 自动创建的 channel 从公开列表里过滤掉，不污染 UI）。
    @discardableResult
    public func ensureOperatorChannel(sessionId: String) throws -> String {
        let name = "__ops-\(sessionId)"
        let reg = ChannelRegistry.shared
        if let existing = reg.get(name) {
            if existing.memberByAlias("operator") == nil {
                _ = try reg.join(channel: name, alias: "operator", sessionId: "")
            }
            if existing.memberByAlias("session") == nil {
                _ = try reg.join(channel: name, alias: "session", sessionId: sessionId)
            }
            return name
        }
        _ = try reg.create(name: name, description: "operator↔session (auto)", mode: .auto)
        _ = try reg.join(channel: name, alias: "operator", sessionId: "")
        _ = try reg.join(channel: name, alias: "session", sessionId: sessionId)
        return name
    }

    // MARK: - Private helpers (most run on queue)

    private func mutateNonTerminal(_ id: String, _ change: (inout A2AMessage) -> Void) throws -> A2AMessage {
        try queue.sync {
            guard var msg = cache[id] else {
                throw MessageRouterError.messageNotFound(id)
            }
            if msg.status == .delivered || msg.status == .dropped {
                throw MessageRouterError.alreadyTerminal(id)
            }
            change(&msg)
            try persist(msg)
            cache[id] = msg
            return msg
        }
    }

    private func channelDir(_ name: String) -> URL {
        messagesDir.appendingPathComponent(name)
    }

    private func messagePath(_ msg: A2AMessage) -> URL {
        channelDir(msg.channel).appendingPathComponent("\(msg.id).json")
    }

    private func inboxPath(_ sessionId: String) -> URL {
        inboxDir.appendingPathComponent("\(sessionId).json")
    }

    /// 原子写入单条消息到磁盘
    private func persist(_ msg: A2AMessage) throws {
        let dir = channelDir(msg.channel)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)

        try data.write(to: messagePath(msg), options: .atomic)
    }

    /// 把一条消息追加到 inbox 的 JSON 数组里。读-改-写；调用方须持 queue。
    ///
    /// 为什么不用 NDJSON append：oh-my-claudecode / Claude Code 原生 Agent
    /// Teams 的约定是 **JSON 数组文件**，agent 按数组读；我们对齐这个约定。
    /// 读-改-写的代价对这种低频操作（人发消息 / A2A 小量消息）完全可以接受。
    private func appendToInbox(sessionId: String, message: A2AMessage) throws {
        let path = inboxPath(sessionId)

        var existing: [A2AMessage] = []
        if fileManager.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path) {
            existing = (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
        }
        existing.append(message)

        let data = try jsonArrayEncoder.encode(existing)
        try data.write(to: path, options: .atomic)
    }

    private func parseJsonl(_ content: String) -> [A2AMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [A2AMessage] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = raw.data(using: .utf8) else { continue }
            if let msg = try? decoder.decode(A2AMessage.self, from: d) {
                out.append(msg)
            } else {
                MWarn("[MessageRouter] failed to decode inbox line (\(raw.count) bytes)")
            }
        }
        return out
    }

    /// 启动时加载已有消息到缓存
    private func loadAll() {
        queue.sync {
            cache.removeAll()
            guard let channelDirs = try? fileManager.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var count = 0
            for chDir in channelDirs {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: chDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let files = try? fileManager.contentsOfDirectory(at: chDir, includingPropertiesForKeys: nil) else { continue }
                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file) else { continue }
                    if let msg = try? decoder.decode(A2AMessage.self, from: data) {
                        cache[msg.id] = msg
                        count += 1
                    }
                }
            }
            MDebug("[MessageRouter] Loaded \(count) message(s)")
        }
    }
}
