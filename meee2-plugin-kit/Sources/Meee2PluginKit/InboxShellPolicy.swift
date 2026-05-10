import Foundation

/// InboxShellPolicy —— 决定一条入站消息呈现给 agent 的样子。
///
/// 在分层模型里这是 Layer 2（agent shell）的策略钩子。Plugin 可以提供自己
/// 的实现来定制：
///   - 是否要给 payload 加前缀（"[from alice]"）让 agent 看到来源
///   - 是否要做内容级 dedup（agent 自己是 application layer，最该懂语义）
///   - 是否直接丢弃（return nil）
///
/// 默认走 `LabeledSenderPolicy`：给 content 前面贴一行来源标签，
/// 让接收方 Claude 一眼就能区分"用户键盘输入" vs "另一个 agent 发的 A2A
/// 消息" vs "operator 通过 Web/CLI 注入的人工消息"。没有这层标签时 Ghostty
/// paste 出来的内容和用户输入完全一样，Claude 没法判断要不要走 send_message
/// 回复，多轮 A2A 通讯就走不下去。
///
/// 标签协议（**meee2 + meee2 共享约定**，跨 host 实现都该遵守）：
///   - agent → agent:    `[meee2 a2a] from @<fromAlias> on #<channel>:\n<content>`
///   - operator → agent: `[meee2 a2a] from operator on #<channel>:\n<content>`
public protocol InboxShellPolicy: Sendable {
    /// 把入站消息（plugin-kit DTO）转成给 agent 的展示文本。
    /// 返回 nil 表示丢弃这条。
    func format(_ envelope: A2AInboundView) -> String?
}

/// 纯透传：agent 看到的就是 envelope.content，没有任何额外信息。
///
/// 仅供 plugin 显式选择——比如 plugin 自己已经在 system prompt 里把"所有
/// 入站文本都视作 A2A"约定死了，不需要标签。**默认 fallback 是
/// `LabeledSenderPolicy`，不是这个**。
public struct PassthroughPolicy: InboxShellPolicy {
    public init() {}
    public func format(_ envelope: A2AInboundView) -> String? {
        envelope.content
    }
}

/// 默认 policy：给 content 贴一行来源标签。
///
/// 设计原则：
///   - 标签独占一行，content 紧跟其后——Claude 在 TUI 里看到首行 `[meee2 a2a]`
///     就知道这是路由进来的、不是用户键盘输入，应当用 `send_message` 回复。
///   - operator 注入（`injectedByHuman == true`）走 `from operator` 而不是
///     `from @<alias>`，因为 operator 在 channel 成员表外，没有稳定的 alias。
///   - 跨 host 复用：meee2 未来如果实现自己的 A2A 推送通道，只要遵守
///     上面 InboxShellPolicy doc 的标签格式，两边 agent 行为就一致。
public struct LabeledSenderPolicy: InboxShellPolicy {
    public init() {}
    public func format(_ envelope: A2AInboundView) -> String? {
        // operator/human-injected messages（Dock / Web / `meee2 msg send --human`）
        // 是用户直接键入，应该和 terminal 里的真键盘输入无差别——不贴前缀。
        // 只有 agent → agent A2A 才需要 `[meee2 a2a] from @<alias>` 标签让接收
        // 方 Claude 知道要走 send_message 回复。
        if envelope.injectedByHuman {
            return envelope.content
        }
        let header = "[meee2 a2a] from @\(envelope.fromAlias) on #\(envelope.channel):"
        return "\(header)\n\(envelope.content)"
    }
}
