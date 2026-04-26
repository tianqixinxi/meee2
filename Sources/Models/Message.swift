import Foundation

/// A2A 消息状态
public enum MessageStatus: String, Codable, Sendable {
    /// 已暂存，对人类可见，等待投递决策
    case pending
    /// 被显式挂起（intercept 模式或 `msg hold`）
    case held
    /// 终态：已推送到接收方的收件箱
    case delivered
    /// 终态：被人类拒绝
    case dropped
}

/// Agent-to-Agent 消息信封 - 持久化为 JSON
///
/// 分层模型：
///   - **envelope** = 这个 struct 除了 `content` 之外的所有字段（id/from/to/
///     traceId/hopCount/replyTo/status/...）。MessageRouter 关心信封：写盘、
///     路由、状态机、hop 限制。`AgentInboxShell` 拆信封并把 payload 推给 agent。
///   - **payload** = `content` 字段。是唯一会真正进 agent 视野的部分。Agent
///     看到的就是它，不看 envelope。
///
/// `traceId` + `hopCount` 是后加的传输层字段，旧 inbox/messages 文件没有；
/// 解码时按默认值兜底（traceId 默认等于 id；hopCount 默认 0），下次持久化
/// 自动回写。
public struct A2AMessage: Codable, Identifiable, Sendable {
    /// 消息 ID：格式 "m-" + 8 位十六进制
    public let id: String
    /// 一段对话的根 id：首条消息 traceId == id；带 replyTo 的继承上家的 traceId。
    /// 用于关联同一对话里的所有消息（hop 链、forensics）。
    public let traceId: String
    /// 所在频道名
    public let channel: String
    /// 发送方别名
    public let fromAlias: String
    /// 发送方 sessionId（完整 UUID）
    public let fromSessionId: String
    /// 接收方别名或 "*" 表示频道广播
    public let toAlias: String
    /// 消息正文（可变：人类可在 pending/held 时编辑）
    public var content: String
    /// 回复的消息 ID
    public let replyTo: String?
    /// 从 traceId 起算经过几跳。直接发起的消息 = 0；reply 的消息 = parent.hopCount + 1。
    /// MessageRouter.send 检查 hopCount > MAX_HOPS 时拒绝（防级联放大）。
    public let hopCount: Int
    /// 创建时间
    public let createdAt: Date
    /// 当前状态
    public var status: MessageStatus
    /// 实际投递时间
    public var deliveredAt: Date?
    /// 实际到达的接收者别名列表
    public var deliveredTo: [String]
    /// 是否由人类通过 `msg inject` 注入
    public let injectedByHuman: Bool

    /// 生成新的消息 ID
    public static func newId() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "m-" + String(hex.prefix(8))
    }

    public init(
        id: String = A2AMessage.newId(),
        traceId: String? = nil,
        channel: String,
        fromAlias: String,
        fromSessionId: String,
        toAlias: String,
        content: String,
        replyTo: String? = nil,
        hopCount: Int = 0,
        createdAt: Date = Date(),
        status: MessageStatus = .pending,
        deliveredAt: Date? = nil,
        deliveredTo: [String] = [],
        injectedByHuman: Bool = false
    ) {
        self.id = id
        // 默认 traceId 等于自己的 id（自己是对话根）
        self.traceId = traceId ?? id
        self.channel = channel
        self.fromAlias = fromAlias
        self.fromSessionId = fromSessionId
        self.toAlias = toAlias
        self.content = content
        self.replyTo = replyTo
        self.hopCount = hopCount
        self.createdAt = createdAt
        self.status = status
        self.deliveredAt = deliveredAt
        self.deliveredTo = deliveredTo
        self.injectedByHuman = injectedByHuman
    }

    // MARK: - Codable (向后兼容旧 envelope)
    //
    // 旧 JSON 文件没有 traceId / hopCount。Codable 默认行为是缺字段直接报错，
    // 这里手写 init(from:) 让缺失值走默认（traceId = id, hopCount = 0），
    // 下次 persist 时新字段就会被写入磁盘，自然完成迁移。

    private enum CodingKeys: String, CodingKey {
        case id, traceId, channel, fromAlias, fromSessionId, toAlias
        case content, replyTo, hopCount, createdAt, status
        case deliveredAt, deliveredTo, injectedByHuman
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.id = id
        self.traceId = (try? c.decode(String.self, forKey: .traceId)) ?? id
        self.channel = try c.decode(String.self, forKey: .channel)
        self.fromAlias = try c.decode(String.self, forKey: .fromAlias)
        self.fromSessionId = try c.decode(String.self, forKey: .fromSessionId)
        self.toAlias = try c.decode(String.self, forKey: .toAlias)
        self.content = try c.decode(String.self, forKey: .content)
        self.replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        self.hopCount = (try? c.decode(Int.self, forKey: .hopCount)) ?? 0
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.status = try c.decode(MessageStatus.self, forKey: .status)
        self.deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        self.deliveredTo = (try? c.decode([String].self, forKey: .deliveredTo)) ?? []
        self.injectedByHuman = (try? c.decode(Bool.self, forKey: .injectedByHuman)) ?? false
    }

    /// 投递到接收方时的渲染格式
    /// A2A 消息：`[a2a from <alias> via <channel>] <content>`
    /// 人类从 Web/CLI 直接注入的消息：不加任何前缀，原样投递
    public func renderForInbox() -> String {
        if injectedByHuman && fromAlias == "__human__" {
            return content
        }
        return "[a2a from \(fromAlias) via \(channel)] \(content)"
    }

    /// 这条消息是否是"人类直接注入"的（从 Web UI / CLI `meee2 send` 发）
    public var isHumanDirect: Bool {
        injectedByHuman && fromAlias == "__human__"
    }
}
