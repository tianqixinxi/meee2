import Foundation
import Combine
import Meee2PluginKit

/// AgentInboxShell —— Layer 2 of the messaging stack.
///
/// 三层模型：
///   - Layer 1 (transport): `MessageRouter` 管 envelope 持久化、状态机、路由
///   - **Layer 2 (this)**: 解信封、应用传输策略（hop limit、in-flight 幂等）、
///                          决定如何把 payload 呈现给 agent、推到 agent 入口
///   - Layer 3 (agent): Claude TUI / 别的 agent runtime，只看到 payload
///
/// 实现细节：当前唯一的 agent 入口是 Ghostty terminal（通过 `input text` +
/// `send key "enter"`）。Shell 监听 SessionEventBus 的状态变化（resting 翻
/// 转、首次注册），加上 MessageRouter 在 `appendToInbox` 后的直接调用，
/// 双触发覆盖"刚到的消息"+"等待已久的消息"两种场景。
///
/// 幂等：`(sessionId, msgId)` 已在 push 中就跳过——必要的。Plugin 每秒一次
/// `sessionMetadataChanged` 会让 `flushInboxIfResting` 看到 push 还没结束的
/// 旧 msg 又开一个 Task，没幂等就会双推。
public final class AgentInboxShell {
    public static let shared = AgentInboxShell()

    /// 正在 Ghostty 推送的 (sessionId|msgId) 集合。访问须持 queue。
    private var inFlightPushes: Set<String> = []

    /// 串行化 inFlight 集合的访问 + Ghostty Task 启停
    private let queue = DispatchQueue(label: "com.meee2.AgentInboxShell", qos: .userInitiated)

    /// SessionEventBus 订阅（resting 翻转时主动 flush）
    private var busSubscription: AnyCancellable?

    private init() {
        // 启动延迟 1.5s 全扫一次：覆盖"上次进程关掉时还没消费的消息"。
        // 延后到 .async 是因为 init 阶段 SessionStore / PluginManager 可能
        // 还没完成首次 load，sessionId → ghosttyTerminalId 关系拿不到。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.flushAllInboxes()
        }
        subscribeToSessionEvents()
    }

    // MARK: - Public API

    /// 单条消息刚被 router 写入 inbox 后调用。立即尝试推。
    /// 如果 session busy，会跳过；下次 sessionMetadataChanged 触发的 flush 会兜底。
    public func tryDeliver(sessionId: String, message: A2AMessage) {
        deliverIfResting(sessionId: sessionId, message: message)
    }

    /// 扫所有 inbox 文件，逐 session flush。启动 + 偶尔手动救场用。
    public func flushAllInboxes() {
        let sids = MessageRouter.shared.allInboxSessionIds()
        for sid in sids {
            flushInboxIfResting(sessionId: sid)
        }
    }

    /// 如果 session 是 resting + 有 ghostty terminal，把 inbox 里的每条消息
    /// 跑一遍 deliverIfResting（push 成功会自动 removeFromInbox）。
    /// 重复调用安全（busy / 已在 in-flight 都直接返回）。
    public func flushInboxIfResting(sessionId: String) {
        let messages = MessageRouter.shared.peekInbox(sessionId: sessionId)
        guard !messages.isEmpty else { return }
        for msg in messages {
            deliverIfResting(sessionId: sessionId, message: msg)
        }
    }

    // MARK: - Private — core push logic

    /// 真正决定要不要把这条消息推到 agent terminal。
    ///
    /// 规则：
    ///   1. session 必须 resting（resolver 维度）—— busy 时跳过，等 Stop 后重试
    ///   2. session 必须有 ghosttyTerminalId —— 没终端没法推
    ///   3. (sessionId, msgId) 已在 push 中 → 跳过（幂等）
    ///   4. 通过 InboxShellPolicy 拿展示文本（默认 PassthroughPolicy = envelope.content）
    ///      返回 nil → 丢弃（policy 决定不投）
    ///   5. Ghostty input + send key enter
    ///   6. 成功 → ConversationContext 记一笔 + removeFromInbox + 释放 in-flight
    ///   7. 失败 → 留在 inbox 等下次 flush
    private func deliverIfResting(sessionId: String, message: A2AMessage) {
        guard let data = SessionStore.shared.get(sessionId) else { return }
        // resolver 而不是 data.status：避免被早先某条 hook 钉死的 thinking/tooling
        // 永久挡住推送（尽管现实 transcript 尾巴早过 abandoned 阈值）。
        let effectiveStatus = TranscriptStatusResolver.resolve(for: data)
        let restingStatuses: Set<SessionStatus> = [.idle, .waitingForUser, .completed]
        guard restingStatuses.contains(effectiveStatus) else {
            NSLog("[AgentInboxShell] push skipped sid=\(sessionId.prefix(8)) effective=\(effectiveStatus.rawValue) (raw=\(data.status.rawValue)) — not resting")
            return
        }

        let msgId = message.id
        let key = "\(sessionId)|\(msgId)"
        let alreadyInFlight: Bool = queue.sync {
            if inFlightPushes.contains(key) { return true }
            inFlightPushes.insert(key)
            return false
        }
        if alreadyInFlight {
            NSLog("[AgentInboxShell] push dedup sid=\(sessionId.prefix(8)) msg=\(msgId) — already in flight")
            return
        }

        // 走 policy 决定展示文本。优先看接收方所在 plugin 自己的 policy，
        // plugin 没装就回落到默认 PassthroughPolicy（纯透传 content）。
        // PluginManager.sessions / loadedPlugins 是 main-thread 写入的
        // @Published 集合；从 background queue 读它们 == data race。snapshot
        // 一次到 local var 再走逻辑。
        let policy: InboxShellPolicy = Self.snapshotPolicy(for: sessionId)
        let view = Self.inboundView(of: message)
        guard let payload = policy.format(view) else {
            // policy 决定丢弃 → 同样从 inbox 移除（避免每次 flush 又见一次）
            NSLog("[AgentInboxShell] policy dropped sid=\(sessionId.prefix(8)) msg=\(msgId)")
            queue.async { [weak self] in
                self?.inFlightPushes.remove(key)
                MessageRouter.shared.removeFromInbox(sessionId: sessionId, messageId: msgId)
            }
            return
        }

        // 选 terminal dispatcher：按 termProgram + 已捕获的 native session id 选路径。
        // Ghostty (gtid) / iTerm2 (iTermSessionId) / Apple Terminal (tty)。三个都不
        // 满足就放弃直推，留 inbox 让下次 flush 再试或等 Stop hook drain。
        let term = (data.terminalInfo?.termProgram ?? "").lowercased()
        let bareTty = data.terminalInfo?.tty ?? ""
        let dispatch: (() async -> Bool)?
        let pathLabel: String
        if let gid = data.ghosttyTerminalId, !gid.isEmpty {
            dispatch = { await GhosttyInputStream().sendText(terminalId: gid, text: payload) }
            pathLabel = "ghostty"
        } else if let iid = data.iTermSessionId, !iid.isEmpty {
            dispatch = { await ITerm2InputStream().sendText(terminalId: iid, text: payload) }
            pathLabel = "iterm2"
        } else if term.contains("apple_terminal") || term.contains("apple terminal") || term == "terminal" {
            guard !bareTty.isEmpty else {
                NSLog("[AgentInboxShell] push skipped sid=\(sessionId.prefix(8)) — Apple Terminal but no tty")
                queue.async { [weak self] in self?.inFlightPushes.remove(key) }
                return
            }
            let ttyForCapture = bareTty
            dispatch = { await AppleTerminalInputStream().sendText(tty: ttyForCapture, text: payload) }
            pathLabel = "apple-terminal"
        } else {
            NSLog("[AgentInboxShell] push skipped sid=\(sessionId.prefix(8)) — no native id (term=\(term))")
            queue.async { [weak self] in self?.inFlightPushes.remove(key) }
            return
        }

        Task { [weak self] in
            let ok = await dispatch!()
            NSLog("[AgentInboxShell] push sid=\(sessionId.prefix(8)) msg=\(msgId) ok=\(ok) (\(pathLabel))")
            self?.queue.async {
                self?.inFlightPushes.remove(key)
                if ok {
                    MessageRouter.shared.removeFromInbox(sessionId: sessionId, messageId: msgId)
                    ConversationContext.shared.recordInbound(sessionId: sessionId, message: message)
                }
            }
        }
    }

    // MARK: - Plugin policy lookup

    /// 找接收方 session 对应的 plugin，返回它自定义的 InboxShellPolicy；
    /// 没有就回落到默认 PassthroughPolicy。
    ///
    /// 必须 main-sync：PluginManager 的 `@Published var sessions` 和
    /// `loadedPlugins: [String: SessionPlugin]` 都是 main-thread 上写入和
    /// 读取的（SwiftUI binding + @MainActor 隐含约束）。从 AgentInboxShell.queue
    /// 这种 background queue 直接遍历 = Swift 集合的 data race。snapshot 一次。
    ///
    /// 死锁风险：如果 deliverIfResting 自己已经在 main 上跑，main.sync 会死锁。
    /// 实际调用路径：(a) MessageRouter.send 在 caller 线程跑（CLI / API
    /// handler thread，从来不是 main）；(b) AgentInboxShell init 的 1.5s 后
    /// 全 flush（global utility queue）；(c) SessionEventBus subscription
    /// （Combine 默认 sink 在 publish 线程，PluginManager 是 main → 这里**会**
    /// 走 main）。所以加 isMainThread 分支：在 main 上直接读，否则 main.sync。
    private static func snapshotPolicy(for sessionId: String) -> InboxShellPolicy {
        let read: () -> InboxShellPolicy = {
            guard let session = PluginManager.shared.sessions.first(where: { $0.id == sessionId })
                ?? PluginManager.shared.sessions.first(where: { $0.id.hasPrefix(sessionId) }),
                  let plugin = PluginManager.shared.loadedPlugins[session.pluginId],
                  let custom = plugin.inboxShellPolicy else {
                return PassthroughPolicy()
            }
            return custom
        }
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync(execute: read)
    }

    /// A2AMessage（host 类型）→ A2AInboundView（plugin-kit DTO）。
    /// Policy 在 plugin-kit 一侧，只能见 DTO，不见 host 内部类型。
    private static func inboundView(of msg: A2AMessage) -> A2AInboundView {
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

    // MARK: - SessionEventBus 订阅

    private func subscribeToSessionEvents() {
        busSubscription = SessionEventBus.shared.publisher
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .sessionMetadataChanged(let sid), .sessionAdded(let sid):
                    self.flushInboxIfResting(sessionId: sid)
                default:
                    break
                }
            }
    }
}
