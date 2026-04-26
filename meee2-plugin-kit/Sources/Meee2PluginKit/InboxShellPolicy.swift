import Foundation

/// InboxShellPolicy —— 决定一条入站消息呈现给 agent 的样子。
///
/// 在分层模型里这是 Layer 2（agent shell）的策略钩子。Plugin 可以提供自己
/// 的实现来定制：
///   - 是否要给 payload 加前缀（"[from alice]"）让 agent 看到来源
///   - 是否要做内容级 dedup（agent 自己是 application layer，最该懂语义）
///   - 是否直接丢弃（return nil）
///
/// MVP 默认 `PassthroughPolicy`：只把 envelope.content 透传，任何 envelope
/// 元数据都不暴露给 agent——这是端到端原则的最小实现，所有"是否要 from
/// 前缀 / 是否冗余" 都让 agent 自己看 audit log 或 `A2AContext` 自取。
public protocol InboxShellPolicy: Sendable {
    /// 把入站消息（plugin-kit DTO）转成给 agent 的展示文本。
    /// 返回 nil 表示丢弃这条。
    func format(_ envelope: A2AInboundView) -> String?
}

/// 默认 policy：纯透传。Agent 看到的就是 envelope.content，没有任何额外信息。
public struct PassthroughPolicy: InboxShellPolicy {
    public init() {}
    public func format(_ envelope: A2AInboundView) -> String? {
        envelope.content
    }
}
