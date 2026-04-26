import Foundation
import Meee2PluginKit

/// Host-side `A2AContextProvider` 实现：把 plugin-kit 的查询接口绑到
/// MessageRouter / A2AIdentity 上。App 启动时实例化一次然后
/// `A2AContext.shared.register(_:)` 注入。
public final class A2AContextHostProvider: A2AContextProvider {
    public init() {}

    public func recentInbound(sessionId: String, channel: String, limit: Int) -> [A2AInboundView] {
        // newest-first：listMessages 返回 createdAt 升序，filter 完后倒序，取前 N。
        let candidates = MessageRouter.shared.listMessages(channel: channel)
            .filter { msg in
                // "面向该 session 的入站" = sessionId 是该 channel 某个成员，且
                // toAlias 匹配（"*" 广播 OR 等于成员 alias）。简化做法：直接以
                // deliveredTo 为准（MessageRouter 在 deliverPending 时把实际 fan-out
                // 写进了 deliveredTo），看 alias 是否落进去。
                guard let aliases = ChannelRegistry.shared.get(channel)?.members
                    .filter({ $0.sessionId == sessionId })
                    .map(\.alias) else { return false }
                if msg.fromAlias.isEmpty == false, aliases.contains(msg.fromAlias) { return false }  // 排除自己发的
                return aliases.contains { msg.deliveredTo.contains($0) || msg.toAlias == $0 || msg.toAlias == "*" }
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        return candidates.map(Self.view(of:))
    }

    public func hopChain(msgId: String) -> [A2AInboundView] {
        // 顺着 replyTo 一路往上爬。MessageRouter.get 走 cache，O(1)。
        var chain: [A2AInboundView] = []
        var cursor: String? = msgId
        var seen = Set<String>()
        while let id = cursor, !seen.contains(id) {
            seen.insert(id)
            guard let msg = MessageRouter.shared.get(id) else { break }
            chain.append(Self.view(of: msg))
            cursor = msg.replyTo
        }
        // 根在前
        return chain.reversed()
    }

    public func currentSessionId() -> String? {
        A2AIdentity.currentSessionId()
    }

    // MARK: - mapping

    private static func view(of msg: A2AMessage) -> A2AInboundView {
        A2AInboundView(
            id: msg.id,
            traceId: msg.traceId,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            hopCount: msg.hopCount,
            content: msg.content,
            createdAt: msg.createdAt,
            injectedByHuman: msg.injectedByHuman
        )
    }
}
