import Foundation

/// MessageRouter 把消息追加到目标 session 的 inbox 文件后,会同步
/// 通知所有注册过的 push delegate。Delegate 自行决定:
///   - 投递时机(立刻 / 等 session 进入 idle)
///   - 投递通道(终端 paste / WebSocket / 子进程 stdin / HTTP webhook ...)
///   - 是否丢弃(去重 / 限流 / 安全策略)
///
/// 主仓的 `AgentInboxShell` 是默认 delegate(plugin 路径,把消息 paste 到
/// session 所在的 Ghostty 终端)。外部 AI 可以注册自己的 delegate,
/// 不需要写完整 plugin 也能拿到 push 通知。
public protocol InboxPushDelegate: AnyObject {
    /// `sessionId` —— 目标 session 的真实 id(已经按 channel 成员表解析过)。
    /// `message` —— 已持久化、已写入 inbox 的消息;实现方拿到的是 read-only 视图。
    func handleInboxPush(sessionId: String, message: A2AMessage)
}

/// MessageRouter 内部用,把 delegate 数组以 weak 形式持有。
internal struct WeakInboxPushDelegate {
    weak var value: InboxPushDelegate?
    init(_ value: InboxPushDelegate) { self.value = value }
}
