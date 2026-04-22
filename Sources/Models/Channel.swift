import Foundation

/// 频道模式 - 决定消息如何流转
public enum ChannelMode: String, Codable, Sendable {
    /// 自动投递：消息先进入 pending（对人类可见），随后自动 deliver
    case auto
    /// 拦截：每条消息必须等待人工批准才能投递
    case intercept
    /// 暂停：所有消息都挂起，直到恢复为止
    case paused
}

/// 频道成员 - 一个会话在某个频道里的具名身份
public struct ChannelMember: Codable, Sendable, Equatable {
    /// 别名，例如 "planner"、"coder-1"。在同一个频道内唯一
    public let alias: String
    /// Claude 会话的完整 UUID
    public let sessionId: String
    /// 加入时间
    public let joinedAt: Date

    public init(alias: String, sessionId: String, joinedAt: Date = Date()) {
        self.alias = alias
        self.sessionId = sessionId
        self.joinedAt = joinedAt
    }
}

/// 频道 - 仅是一组具名成员（"dumb pipe, smart endpoints"）
/// 不区分 pipe / bidir / broadcast / relay —— 语义由 agent 决定
public struct Channel: Codable, Identifiable, Sendable {
    public var id: String { name }

    /// 全局唯一的频道名（由人类指定）
    public var name: String
    /// 成员列表（alias 在 channel 内唯一）
    public var members: [ChannelMember]
    /// 当前投递模式
    public var mode: ChannelMode
    /// 创建时间
    public let createdAt: Date
    /// 可选的描述信息
    public var description: String?

    public init(
        name: String,
        members: [ChannelMember] = [],
        mode: ChannelMode = .auto,
        createdAt: Date = Date(),
        description: String? = nil
    ) {
        self.name = name
        self.members = members
        self.mode = mode
        self.createdAt = createdAt
        self.description = description
    }

    /// 按别名查找成员
    public func memberByAlias(_ alias: String) -> ChannelMember? {
        members.first { $0.alias == alias }
    }

    /// 按 sessionId 查找成员
    public func memberBySessionId(_ sid: String) -> ChannelMember? {
        members.first { $0.sessionId == sid }
    }
}
