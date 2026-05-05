import Foundation
import Combine
import Meee2PluginKit
import Meee2CommKit

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

    /// 上次"push skipped — not resting"日志时刻 + 当时的 effective status，
    /// 避免每 2s sessionMetadataChanged → flush → skip 都 log 一条。规则：
    /// 同 (sid,msgId) 在 effectiveStatus 没变时只 log 第一次；状态翻转或
    /// 60s 时间窗过期再 log。访问须持 queue。
    private var lastSkipLog: [String: (status: SessionStatus, at: Date)] = [:]

    /// 串行化 inFlight 集合 / lastSkipLog 的访问 + Ghostty Task 启停
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

        // 早退保护：如果这条 session 根本拿不到 native terminal id（没 ghostty
        // gtid、没 iTerm sid、也不是 Apple Terminal），那 inbox 里每条消息都
        // 注定 hit "no native id" skip 分支。**不要**逐条 iterate —— 那会变
        // 成每次 sessionMetadataChanged 都 O(N) 跑过 N 条 stale 消息（一条
        // session 留下 5K+ 历史 ops 通知就把 main thread 烧到 60% CPU，灵动
        // 岛 / WebUI 顿挫；见 2026-05-04 现场分析）。
        if let target = Self.deliveryTarget(for: sessionId), !Self.targetHasDispatcher(target) {
            // 用 logSkipNoDispatcher 的同一 throttle key（见 deliverIfResting）。
            logSkipNoDispatcher(sessionId: sessionId, term: target.terminalInfo?.termProgram ?? "", suppressedCount: messages.count)
            return
        }

        for msg in messages {
            deliverIfResting(sessionId: sessionId, message: msg)
        }
    }

    // MARK: - Explicit "Push to Desktop" path

    /// 显式触发：把 inbox 里所有消息通过 ClaudeDesktopInputStream（AppleScript
    /// keystroke）立刻送进 Claude.app 当前 focused 输入框。**只为 explicit
    /// user-initiated push 设计**（webui Dock 的 ⚡ 按钮）—— 默认 inject 流
    /// 不调这个，避免抢焦点。
    ///
    /// 行为：
    ///   1. 拒绝非 Desktop session（CLI 走 typeIn 已经够用）
    ///   2. 串行（ClaudeDesktopInputStream 内部 actor 已经保证）
    ///   3. 每条 keystroke 成功就 removeFromInbox + ConversationContext.recordInbound
    ///   4. 失败的留 inbox 兜底（下个 Stop hook 再 drain）
    /// 返回 (delivered: 成功推送条数, error: nil 全成功 / 描述失败原因)
    @discardableResult
    public func pushDesktopNow(sessionId: String) async -> (delivered: Int, error: String?) {
        guard let target = Self.deliveryTarget(for: sessionId) else {
            return (0, "session not found")
        }
        // 当前不强制 desktop-only —— 但 CLI session 没必要走这条
        // （typeIn 已经无焦干扰直推），caller (BoardAPI) 自己 gate
        let messages = MessageRouter.shared.peekInbox(sessionId: sessionId)
        guard !messages.isEmpty else {
            return (0, nil)
        }

        var delivered = 0
        var lastErr: String?
        for msg in messages {
            // 跟 deliverIfResting 一样走 policy 格式化（[meee2 a2a] 前缀等）
            let policy = Self.snapshotPolicy(for: sessionId)
            let view = Self.inboundView(of: msg)
            guard let payload = policy.format(view) else {
                MessageRouter.shared.removeFromInbox(sessionId: sessionId, messageId: msg.id)
                continue
            }
            do {
                try await ClaudeDesktopInputStream().sendTextThrowing(sid: sessionId, text: payload)
                NSLog("[AgentInboxShell] pushDesktopNow sid=\(sessionId.prefix(8)) msg=\(msg.id) ok=true")
                delivered += 1
                MessageRouter.shared.removeFromInbox(sessionId: sessionId, messageId: msg.id)
                ConversationContext.shared.recordInbound(sessionId: sessionId, message: msg)
            } catch let err as ClaudeDesktopInputStream.SendError {
                NSLog("[AgentInboxShell] pushDesktopNow sid=\(sessionId.prefix(8)) msg=\(msg.id) failed: \(err.errorDescription ?? "")")
                lastErr = err.errorDescription
                // accessibilityNotGranted 是 user-actionable，提示 webui
                // 用专门的 toast；其它错误一条失败就停，避免连环抢焦点。
                break
            } catch {
                NSLog("[AgentInboxShell] pushDesktopNow sid=\(sessionId.prefix(8)) msg=\(msg.id) failed: \(error.localizedDescription)")
                lastErr = error.localizedDescription
                break
            }
            _ = target  // silence warning
        }
        return (delivered, lastErr)
    }

    /// target 是否能选到一个 dispatcher（Ghostty / iTerm / Apple Terminal）。
    /// 与 deliverIfResting 里的判断保持一致 —— 改一处必须改另一处。
    ///
    /// **Desktop 故意不算 dispatcher**：ClaudeDesktopInputStream 虽然存在，
    /// 但它会 activate Claude.app 抢焦点，对"webui 顺手发条消息"这种场景太
    /// 打扰。Desktop session 走既有的 inbox + Stop hook drain 路径
    /// （HookSocketServer.drainResponseForDesktopStop）—— 不立刻送达但不抢
    /// 焦点。InputStream 留给将来的"显式 Push to Desktop"按钮使用。
    private static func targetHasDispatcher(_ target: DeliveryTarget) -> Bool {
        if let g = target.ghosttyTerminalId, !g.isEmpty { return true }
        if let i = target.iTermSessionId, !i.isEmpty { return true }
        let term = (target.terminalInfo?.termProgram ?? "").lowercased()
        let tty = target.terminalInfo?.tty ?? ""
        if !tty.isEmpty,
           term.contains("apple_terminal") || term.contains("apple terminal") || term == "terminal" {
            return true
        }
        return false
    }

    /// 限频版的 "no native id" 日志（沿用 lastSkipLog 的 60s 节流 key）。
    private func logSkipNoDispatcher(sessionId: String, term: String, suppressedCount: Int) {
        let key = "\(sessionId)|__no_dispatcher__"
        let shouldLog: Bool = queue.sync {
            let now = Date()
            if let prev = lastSkipLog[key],
               now.timeIntervalSince(prev.at) < 60 {
                return false
            }
            lastSkipLog[key] = (.idle, now)
            return true
        }
        if shouldLog {
            NSLog("[AgentInboxShell] flush skipped sid=\(sessionId.prefix(8)) — no native id (term=\(term)), \(suppressedCount) msg(s) deferred")
        }
    }

    // MARK: - Private — core push logic

    private struct DeliveryTarget {
        let rawStatus: SessionStatus
        let effectiveStatus: SessionStatus
        let terminalInfo: PluginTerminalInfo?
        let ghosttyTerminalId: String?
        let iTermSessionId: String?
    }

    /// 真正决定要不要把这条消息推到 agent terminal。
    ///
    /// 规则：
    ///   1. session 必须 resting（resolver 维度）—— busy 时跳过，等 Stop 后重试
    ///   2. session 必须有 ghosttyTerminalId —— 没终端没法推
    ///   3. (sessionId, msgId) 已在 push 中 → 跳过（幂等）
    ///   4. 通过 InboxShellPolicy 拿展示文本（默认 LabeledSenderPolicy = 前缀 + envelope.content）
    ///      返回 nil → 丢弃（policy 决定不投）
    ///   5. Ghostty input + send key enter
    ///   6. 成功 → ConversationContext 记一笔 + removeFromInbox + 释放 in-flight
    ///   7. 失败 → 留在 inbox 等下次 flush
    private func deliverIfResting(sessionId: String, message: A2AMessage) {
        guard let target = Self.deliveryTarget(for: sessionId) else {
            MDebug("[AgentInboxShell] push skipped sid=\(sessionId.prefix(8)) msg=\(message.id) — no session target")
            return
        }
        let restingStatuses: Set<SessionStatus> = [.idle, .waitingForUser, .completed]
        guard restingStatuses.contains(target.effectiveStatus) else {
            // Throttle: every 2s sessionMetadataChanged → flushInboxIfResting →
            // 进来都 hit 同样的 skip。只在状态翻转（真有信息）或者 60s 时间窗
            // 过期时打日志，否则就静默。
            let key = "\(sessionId)|\(message.id)"
            let shouldLog: Bool = queue.sync {
                let now = Date()
                if let prev = lastSkipLog[key],
                   prev.status == target.effectiveStatus,
                   now.timeIntervalSince(prev.at) < 60 {
                    return false
                }
                lastSkipLog[key] = (target.effectiveStatus, now)
                return true
            }
            if shouldLog {
                NSLog("[AgentInboxShell] push skipped sid=\(sessionId.prefix(8)) msg=\(message.id) effective=\(target.effectiveStatus.rawValue) (raw=\(target.rawStatus.rawValue)) — not resting")
            }
            return
        }
        // 真的 push 出去时把 lastSkipLog 清理掉，下次再 skip 算"新的一段"。
        queue.sync {
            for k in lastSkipLog.keys where k.hasPrefix("\(sessionId)|") {
                lastSkipLog.removeValue(forKey: k)
            }
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
        // plugin 没装就回落到默认 LabeledSenderPolicy（带 [meee2 a2a] 前缀，
        // 让 Claude 区分用户输入 vs A2A 路由进来的消息）。
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
        // Ghostty (gtid) / iTerm2 (iTermSessionId) / Apple Terminal (tty) /
        // Claude Desktop（entrypoint=claude-desktop 或 metadata 命中）—— 不
        // 命中就放弃直推，留 inbox 让下次 flush 再试或等 Stop hook drain。
        //
        // Desktop 分支放在最后：先优先 native terminal（即便用户也有
        // Claude.app 在跑，meee2 已经知道 cwd 来自终端），只有真没 terminal
        // 信号时才降到 keystroke 路径——避免 keystroke 抢了 Ghostty 用户的
        // 焦点。
        let term = (target.terminalInfo?.termProgram ?? "").lowercased()
        let bareTty = target.terminalInfo?.tty ?? ""
        let dispatch: (() async -> Bool)?
        let pathLabel: String
        if let gid = target.ghosttyTerminalId, !gid.isEmpty {
            dispatch = { await GhosttyInputStream().sendText(terminalId: gid, text: payload) }
            pathLabel = "ghostty"
        } else if let iid = target.iTermSessionId, !iid.isEmpty {
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
            // 与 flushInboxIfResting 早退用同一节流 key —— 单消息直推也吃同一个 60s 配额。
            logSkipNoDispatcher(sessionId: sessionId, term: term, suppressedCount: 1)
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

    private static func deliveryTarget(for sessionId: String) -> DeliveryTarget? {
        if let data = SessionStore.shared.get(sessionId) {
            // resolver 而不是 data.status：避免被早先某条 hook 钉死的 thinking/tooling
            // 永久挡住推送（尽管现实 transcript 尾巴早过 abandoned 阈值）。
            return DeliveryTarget(
                rawStatus: data.status,
                effectiveStatus: TranscriptStatusResolver.resolve(for: data),
                terminalInfo: data.terminalInfo,
                ghosttyTerminalId: data.ghosttyTerminalId,
                iTermSessionId: data.iTermSessionId
            )
        }
        guard let session = snapshotPluginSession(for: sessionId) else {
            return nil
        }
        return DeliveryTarget(
            rawStatus: session.status,
            effectiveStatus: session.status,
            terminalInfo: session.terminalInfo,
            ghosttyTerminalId: nil,
            iTermSessionId: nil
        )
    }

    /// 找接收方 session 对应的 plugin，返回它自定义的 InboxShellPolicy；
    /// 没有就回落到默认 LabeledSenderPolicy（带来源前缀，让 Claude 区分
    /// 用户输入 vs A2A 路由进来的消息——见 InboxShellPolicy.swift）。
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
            guard let session = pluginSessionSnapshotLocked(for: sessionId),
                  let plugin = PluginManager.shared.loadedPlugins[session.pluginId],
                  let custom = plugin.inboxShellPolicy else {
                return LabeledSenderPolicy()
            }
            return custom
        }
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync(execute: read)
    }

    private static func snapshotPluginSession(for sessionId: String) -> PluginSession? {
        let read = { pluginSessionSnapshotLocked(for: sessionId) }
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync(execute: read)
    }

    private static func pluginSessionSnapshotLocked(for sessionId: String) -> PluginSession? {
        PluginManager.shared.sessions.first { pluginSession($0, matches: sessionId, allowPrefix: false) }
            ?? PluginManager.shared.sessions.first { pluginSession($0, matches: sessionId, allowPrefix: true) }
    }

    private static func pluginSession(_ session: PluginSession, matches sessionId: String, allowPrefix: Bool) -> Bool {
        let ids = pluginSessionIds(session)
        if ids.contains(sessionId) { return true }
        guard allowPrefix else { return false }
        return ids.contains { $0.hasPrefix(sessionId) }
    }

    private static func pluginSessionIds(_ session: PluginSession) -> [String] {
        var ids = [session.id]
        let prefix = "\(session.pluginId)-"
        if session.id.hasPrefix(prefix) {
            ids.append(String(session.id.dropFirst(prefix.count)))
        }
        return ids
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

extension AgentInboxShell: InboxPushDelegate {
    /// MessageRouter 的 push delegate 入口:把消息扔给 tryDeliver,
    /// 让 Layer 2 既有的 idle/busy/policy 决策继续生效。
    public func handleInboxPush(sessionId: String, message: A2AMessage) {
        tryDeliver(sessionId: sessionId, message: message)
    }
}
