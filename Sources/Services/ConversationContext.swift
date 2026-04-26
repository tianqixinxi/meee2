import Foundation
import Meee2PluginKit

/// ConversationContext —— per-(sessionId, channel) 的对话上下文记忆。
///
/// 主要用途：当 agent 想发回复时，CLI / API 可以默认带上 `--reply-to`，让
/// MessageRouter 把 hopCount + traceId 自然继承下去。Agent 自己不需要管。
///
/// 内存表，进程 lifetime。重启清空——对话自然意义上重启就是新一轮，没问题。
/// 如果未来需要跨重启保持，可以加 disk 持久化；当前用例（同一进程跑期间的
/// reply 链）够了。
///
/// 线程安全：所有访问通过串行队列。
public final class ConversationContext {
    public static let shared = ConversationContext()

    private let queue = DispatchQueue(label: "com.meee2.ConversationContext", qos: .utility)
    private var lastInboundByKey: [String: A2AMessage] = [:]

    private init() {}

    // MARK: - Public API

    /// 记一笔：sessionId 在 channel 上刚收到这条消息。
    /// AgentInboxShell push 成功后调。
    public func recordInbound(sessionId: String, message: A2AMessage) {
        let key = Self.key(sessionId: sessionId, channel: message.channel)
        queue.async { [weak self] in
            self?.lastInboundByKey[key] = message
        }
    }

    /// 查最近收到的入站消息（用来当 reply 默认 parent）。
    public func lastInbound(sessionId: String, channel: String) -> A2AMessage? {
        let key = Self.key(sessionId: sessionId, channel: channel)
        return queue.sync { lastInboundByKey[key] }
    }

    /// 清掉某 session 在某 channel 上的记忆（一般用不到，留给测试 / 排错）
    public func forget(sessionId: String, channel: String) {
        let key = Self.key(sessionId: sessionId, channel: channel)
        queue.async { [weak self] in
            self?.lastInboundByKey.removeValue(forKey: key)
        }
    }

    /// 测试用：全清
    public func reset() {
        queue.sync { lastInboundByKey.removeAll() }
    }

    private static func key(sessionId: String, channel: String) -> String {
        "\(sessionId)|\(channel)"
    }
}
