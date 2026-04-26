import Foundation

/// A2AContext —— plugin（agent runtime）查询 A2A 通讯上下文的统一入口。
///
/// 给 plugin 一个不依赖 host 内部类型的稳定接口：plugin 只看到
/// `A2AInboundView`（裸字段 DTO），不需要知道 `A2AMessage` / `MessageRouter`
/// 的存在。Host 在启动时通过 `register(_ provider:)` 注入实现。
///
/// 典型场景：
///   - Plugin 想做"看到 hopCount > N 就停止回复" → 查 `recentInbound(channel:)`
///     拿当前对话的 hop 链信息
///   - Plugin 想做 dedup → 查最近 inbound 列表对比内容
///   - 任何"agent 自治"策略，都该读这里、不该读 transport 内部
///
/// 注意：这是**只读**接口。要发送回复，plugin 应该走 CLI（`meee2 msg send`）
/// 或者未来加的 outbound 接口。这里不暴露发送，避免 plugin 越层操作 transport。
public struct A2AInboundView: Sendable {
    public let id: String
    /// 对话根 id：同一段对话里的所有消息共享这个 id。
    public let traceId: String
    public let channel: String
    public let fromAlias: String
    public let toAlias: String
    /// 从 traceId 起算经过几跳。0 表示这是对话根。
    public let hopCount: Int
    public let content: String
    public let createdAt: Date
    /// 这条消息是不是人工注入的（operator 通过 Web/CLI 发的）
    public let injectedByHuman: Bool

    public init(
        id: String,
        traceId: String,
        channel: String,
        fromAlias: String,
        toAlias: String,
        hopCount: Int,
        content: String,
        createdAt: Date,
        injectedByHuman: Bool
    ) {
        self.id = id
        self.traceId = traceId
        self.channel = channel
        self.fromAlias = fromAlias
        self.toAlias = toAlias
        self.hopCount = hopCount
        self.content = content
        self.createdAt = createdAt
        self.injectedByHuman = injectedByHuman
    }
}

/// 实际查询能力的提供方协议。Host 实现它（通常用 MessageRouter / AuditLogger /
/// ConversationContext），通过 `A2AContext.register(_:)` 装进 plugin-kit。
public protocol A2AContextProvider: AnyObject, Sendable {
    /// 该 session 在指定 channel 上最近收到的 N 条入站消息（newest-first）
    func recentInbound(sessionId: String, channel: String, limit: Int) -> [A2AInboundView]

    /// 已知 msgId 的 hop 链（按时间顺序，根在前；找不到返回空）
    func hopChain(msgId: String) -> [A2AInboundView]

    /// 当前进程跑在哪个 session 里（CLI / plugin 都可调；可能为 nil）
    func currentSessionId() -> String?
}

/// Plugin 入口。MVP 单例形态：host 启动时调 `A2AContext.register(provider)`，
/// plugin 用 `A2AContext.shared.recentInbound(...)`。
public final class A2AContext: @unchecked Sendable {
    public static let shared = A2AContext()
    private init() {}

    private var provider: A2AContextProvider?
    private let lock = NSLock()

    /// Host 在启动时调一次，注入实现。
    public func register(_ provider: A2AContextProvider) {
        lock.lock(); defer { lock.unlock() }
        self.provider = provider
    }

    private func need() -> A2AContextProvider? {
        lock.lock(); defer { lock.unlock() }
        return provider
    }

    // MARK: - Public Query API

    public func recentInbound(sessionId: String, channel: String, limit: Int = 20) -> [A2AInboundView] {
        need()?.recentInbound(sessionId: sessionId, channel: channel, limit: limit) ?? []
    }

    public func hopChain(msgId: String) -> [A2AInboundView] {
        need()?.hopChain(msgId: msgId) ?? []
    }

    public func currentSessionId() -> String? {
        need()?.currentSessionId()
    }
}
