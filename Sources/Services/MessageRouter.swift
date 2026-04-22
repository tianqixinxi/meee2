import Foundation

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

    public var description: String {
        switch self {
        case .channelNotFound(let n): return "channel not found: \(n)"
        case .unknownSender(let a, let c): return "unknown sender alias '\(a)' in channel '\(c)'"
        case .unknownRecipient(let a, let c): return "unknown recipient alias '\(a)' in channel '\(c)'"
        case .messageNotFound(let id): return "message not found: \(id)"
        case .alreadyTerminal(let id): return "message already terminal (delivered/dropped): \(id)"
        case .channelPaused(let c): return "channel is paused: \(c)"
        }
    }
}

/// MessageRouter - 管理 A2A 消息的投递与人机协同
///
/// 持久化：
///   - 消息信封: ~/.meee2/messages/<channel>/<msg-id>.json
///   - 接收方收件箱: ~/.meee2/inbox/<sessionId>.jsonl （append-only）
/// 线程安全：所有公开方法通过串行 DispatchQueue 同步。
public final class MessageRouter {
    public static let shared = MessageRouter()

    private let fileManager = FileManager.default
    private let baseDir: URL
    private let messagesDir: URL
    private let inboxDir: URL

    /// 内存缓存：msgId -> A2AMessage。所有访问须持 queue
    private var cache: [String: A2AMessage] = [:]

    private let queue = DispatchQueue(label: "com.meee2.message-router", qos: .userInitiated)

    private init() {
        let home = NSHomeDirectory()
        baseDir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        messagesDir = baseDir.appendingPathComponent("messages")
        inboxDir = baseDir.appendingPathComponent("inbox")

        try? fileManager.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        loadAll()
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
        guard let sender = ch.memberByAlias(fromAlias) else {
            throw MessageRouterError.unknownSender(alias: fromAlias, channel: channel)
        }
        // 若指定具体接收者，需验证其存在；"*" 表示广播，延迟到投递时再 fan-out
        if toAlias != "*" {
            guard ch.memberByAlias(toAlias) != nil else {
                throw MessageRouterError.unknownRecipient(alias: toAlias, channel: channel)
            }
        }

        let msg = A2AMessage(
            channel: channel,
            fromAlias: fromAlias,
            fromSessionId: sender.sessionId,
            toAlias: toAlias,
            content: content,
            replyTo: replyTo,
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

        // 2) 写入每个接收方的 inbox jsonl（append-only）
        for member in recipientMembers {
            do {
                try appendToInbox(sessionId: member.sessionId, message: msgToDeliver)
            } catch {
                MWarn("[MessageRouter] appendToInbox failed for \(member.sessionId.prefix(8)): \(error)")
            }
        }

        MInfo("[MessageRouter] delivered \(id) -> [\(msgToDeliver.deliveredTo.joined(separator: ","))]")

        // 审计：一个 delivered 事件，fan-out 不拆分成多条
        var auditDetails: String? = nil
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

            guard let content = try? String(contentsOf: tmp, encoding: .utf8) else {
                return []
            }
            return parseJsonl(content)
        }
    }

    /// 只读查看 inbox（不清空），用于人类观察
    public func peekInbox(sessionId: String) -> [A2AMessage] {
        queue.sync {
            let path = inboxPath(sessionId)
            guard fileManager.fileExists(atPath: path.path) else { return [] }
            guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            return parseJsonl(content)
        }
    }

    /// 直接把一条合成消息写进某会话的 inbox（用于 `msg halt` 等场景）。
    /// 不需要该会话在某个频道中。返回已写入的 A2AMessage。
    @discardableResult
    public func injectDirectToInbox(sessionId: String, message: A2AMessage) throws -> A2AMessage {
        try queue.sync {
            try appendToInbox(sessionId: sessionId, message: message)
        }
        SessionEventBus.shared.publish(.messageMutated(id: message.id, channel: message.channel))
        return message
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
        inboxDir.appendingPathComponent("\(sessionId).jsonl")
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

    /// 向 inbox jsonl 追加一行（compact JSON）
    /// 注意：调用方须持 queue 以避免并发追加撕裂
    private func appendToInbox(sessionId: String, message: A2AMessage) throws {
        let path = inboxPath(sessionId)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        guard var line = String(data: data, encoding: .utf8) else { return }
        // 去掉可能存在的换行，统一以 "\n" 结尾
        line = line.replacingOccurrences(of: "\n", with: " ")
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } else {
            try bytes.write(to: path, options: .atomic)
        }
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
