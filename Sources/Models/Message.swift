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
public struct A2AMessage: Codable, Identifiable, Sendable {
    /// 消息 ID：格式 "m-" + 8 位十六进制
    public let id: String
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
        channel: String,
        fromAlias: String,
        fromSessionId: String,
        toAlias: String,
        content: String,
        replyTo: String? = nil,
        createdAt: Date = Date(),
        status: MessageStatus = .pending,
        deliveredAt: Date? = nil,
        deliveredTo: [String] = [],
        injectedByHuman: Bool = false
    ) {
        self.id = id
        self.channel = channel
        self.fromAlias = fromAlias
        self.fromSessionId = fromSessionId
        self.toAlias = toAlias
        self.content = content
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.status = status
        self.deliveredAt = deliveredAt
        self.deliveredTo = deliveredTo
        self.injectedByHuman = injectedByHuman
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
