import Foundation
import SwiftUI
import Combine
import Meee2PluginKit
import Meee2CommKit

/// Claude Code 插件
/// 将 Claude CLI 的 session 和 hook 管理封装为统一插件
/// 注意：这是一个内置插件，直接访问主 app 的 SessionMonitor 和 HookSocketServer
class ClaudePlugin: SessionPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.meee2.plugin.claude" }
    override var displayName: String { "Claude Code" }
    override var icon: String { "brain.head.profile" }
    override var themeColor: Color { .orange }
    override var version: String { "1.0.0" }
    override var helpUrl: String? { "https://claude.ai/code" }

    // MARK: - 内部组件

    private let sessionMonitor = SessionMonitor()
    private let hookServer = HookSocketServer.shared
    private let sessionStore = SessionStore.shared

    /// Hook 状态缓存 (sessionId -> HookEvent)
    private var hookStates: [String: HookEvent] = [:]
    private let hookStatesLock = NSLock()

    /// 待响应的权限请求 (sessionId -> ClaudePendingPermission)
    private var pendingPermissions: [String: ClaudePendingPermission] = [:]
    private let pendingPermissionsLock = NSLock()

    /// 任务缓存 (sessionId -> [SessionTask])
    private var sessionTasks: [String: [SessionTask]] = [:]
    private let sessionTasksLock = NSLock()

    /// 使用统计缓存 (sessionId -> UsageStats)
    private var sessionUsage: [String: UsageStats] = [:]
    private let sessionUsageLock = NSLock()

    /// hook 驱动的 session 状态缓存 (sessionId -> SessionStatus)
    private var sessionStatuses: [String: SessionStatus] = [:]
    private let sessionStatusesLock = NSLock()

    private struct LastMessageCacheEntry {
        let fileSize: UInt64
        let modifiedAt: TimeInterval
        let value: String?
    }
    private var lastMessageCache: [String: LastMessageCacheEntry] = [:]
    private let lastMessageCacheLock = NSLock()

    /// Hook 带来的 Ghostty terminal id 暂存。
    /// 适用于 SessionStart hook 抢在 PID-scan 创建 SessionData 之前到达的竞态：
    /// 那时 `sessionStore.update(sid)` 是 no-op，ghosttyId 会丢；这里先 buffer，
    /// 等 PID-scan 在 `syncSessions` 里建 record 时再 drain 进 SessionData。
    /// "set-once" 语义同 line ~294：先到先得，避免后续 UserPromptSubmit hook
    /// 在用户已切换焦点时拿到错误 id 把正确值盖掉。
    private var pendingGhosttyTerminalIds: [String: String] = [:]
    private let pendingGhosttyTerminalIdsLock = NSLock()

    private let cwdRemapSkipLogInterval: TimeInterval = 60
    private var cwdRemapSkipLogTimes: [String: Date] = [:]

    /// Combine 订阅
    private var cancellables = Set<AnyCancellable>()

    /// 灵动岛 token 速率监控器。1Hz 采样 sessionUsage 的 (input, output) 总量，
    /// 在监控器内部做"启动后真实新增"差分。持久持有以保证 widget 跟它的
    /// ObservedObject 绑定不断。
    private lazy var tokenRateMonitor: TokenRateMonitor = {
        TokenRateMonitor { [weak self] in
            self?.tokensSnapshot() ?? (0, 0)
        }
    }()

    /// 已 start 标记 — start() 必须 idempotent。AppDelegate 会先启动
    /// ClaudePlugin，再延迟加载外部 plugin 并再次 startAll；不守卫的话 sessionMonitor
    /// 的 .sink {}.store(in: &cancellables) 会**追加一份订阅**，导致
    /// syncToStore + notifySessionsUpdated 每次 session 变化触发两次。
    /// 跟 CodexPlugin 的 isRunning 守卫对齐。
    private var isRunning = false

    // MARK: - 生命周期

    override func initialize() -> Bool {
        return true
    }

    override func start() -> Bool {
        guard !isRunning else {
            NSLog("[ClaudePlugin] start() ignored — already running")
            return true
        }
        isRunning = true

        // 启动 session 文件监控
        sessionMonitor.startMonitoring()

        // 订阅 session 变化
        sessionMonitor.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.syncToStore(sessions)
                self?.notifySessionsUpdated()
            }
            .store(in: &cancellables)

        // 启动 hook server
        hookServer.start(
            onEvent: { [weak self] event in
                self?.handleHookEvent(event)
            },
            onPermissionCompletion: { [weak self] sessionId, toolUseId, outcome in
                self?.handlePermissionCompletion(
                    sessionId: sessionId,
                    toolUseId: toolUseId,
                    outcome: outcome
                )
            }
        )

        // 启动 token 速率采样
        tokenRateMonitor.start()

        NSLog("[ClaudePlugin] Started")
        return true
    }

    override func stop() {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()
        sessionMonitor.stopMonitoring()
        hookServer.stop()
        tokenRateMonitor.stop()
        NSLog("[ClaudePlugin] Stopped")
    }

    // MARK: - Island Widgets

    /// 暴露给 PluginManager / IslandView 的 widget 列表。
    /// `tokenRateMonitor` 是 lazy 单例，每次调用都返回同一个实例，
    /// 满足 IslandWidget 协议要求的"稳定 ObservableObject"约束。
    override var widgets: [IslandWidget] {
        [TokenRateWidget(monitor: tokenRateMonitor)]
    }

    /// 返回当前所有 session 的 (input_tokens 总和, output_tokens 总和)。
    /// cache_read / cache_create 不计——prompt caching 是常数级开销，会把速率压满。
    /// 供 TokenRateMonitor 1Hz 采样。
    private func tokensSnapshot() -> TokenRateMonitor.TokensSnapshot {
        sessionUsageLock.lock()
        defer { sessionUsageLock.unlock() }
        var inSum = 0
        var outSum = 0
        for stats in sessionUsage.values {
            inSum += stats.inputTokens
            outSum += stats.outputTokens
        }
        return (inSum, outSum)
    }

    override func cleanup() {
        stop()
    }

    // MARK: - Session 管理

    override func getSessions() -> [PluginSession] {
        // 从 SessionStore 读取 (单一数据源)
        let sessionData = sessionStore.sessions

        return sessionData.map { data in
            // 转换为 PluginSession
            var session = data.toPluginSession(pluginId: pluginId)

            // 添加 urgentEvent (需要实时状态)
            let sessionId = data.sessionId

            // 获取待响应权限
            var pendingPerm: ClaudePendingPermission?
            pendingPermissionsLock.lock()
            pendingPerm = pendingPermissions[sessionId]
            pendingPermissionsLock.unlock()

            // 获取 hook 状态
            var hookEvent: HookEvent?
            hookStatesLock.lock()
            hookEvent = hookStates[sessionId]
            hookStatesLock.unlock()

            // 设置 urgentEvent
            if let pending = pendingPerm {
                session.urgentEvent = UrgentEventInfo(
                    id: "\(sessionId)-permission",
                    eventType: "permission",
                    message: buildUrgentMessage(from: pending.event),
                    actionLabel: "Approve",
                    respond: { [weak self] decision in
                        self?.respondToPermission(sessionId: sessionId, decision: decision)
                    }
                )
            } else if let hook = hookEvent, hook.event == .stop || hook.event == .sessionEnd {
                // Stop/SessionEnd 事件：显示 urgent panel
                // 如果 hook 有 lastAssistantMessage，使用它；否则从 transcript 获取
                var message: String
                if let lastMsg = hook.lastAssistantMessage, !lastMsg.isEmpty {
                    message = lastMsg
                } else if let transcriptPath = data.transcriptPath {
                    // 从 transcript 获取最后 assistant 消息
                    let msgs = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 5)
                    if let lastAssistant = msgs.last(where: { $0.role == "assistant" }) {
                        message = lastAssistant.text.replacingOccurrences(of: "\n", with: " ")
                    } else {
                        message = "任务完成"
                    }
                } else {
                    message = "任务完成"
                }
                session.urgentEvent = UrgentEventInfo(
                    id: "\(sessionId)-\(hook.event?.rawValue ?? "stop")",
                    eventType: hook.event?.rawValue ?? "stop",
                    message: String(message.prefix(2000)),  // 扩大截断限制以容纳表格
                    actionLabel: nil,
                    respond: nil
                )
            } else if let hook = hookEvent, hook.shouldShowUrgentPanel {
                session.urgentEvent = UrgentEventInfo(
                    id: "\(sessionId)-\(hook.event?.rawValue ?? "event")",
                    eventType: hook.event?.rawValue ?? "notification",
                    message: buildUrgentMessage(from: hook),
                    actionLabel: nil,
                    respond: nil
                )
            }

            return session
        }
    }

    override func refresh() {
        sessionMonitor.refreshSessions()
    }

    // MARK: - 终端跳转

    override func activateTerminal(for session: PluginSession) {
        // 从 session 中提取原始 ID
        let originalId = session.id.hasPrefix("\(pluginId)-")
            ? String(session.id.dropFirst("\(pluginId)-".count))
            : session.id
        NSLog("========== [JUMP FLOW begin] sid=\(originalId.prefix(8)) title=\(session.title) ==========")
        MLog("[ClaudePlugin] activateTerminal called, originalId=\(originalId)")

        // Desktop-backed Claude session → 走 claude:// URL scheme，TerminalManager
        // 对没有 TTY/termProgram 的 desktop session 找不到正确窗口。统一在这里
        // 短路，让 Island / Web Board / 任何 PluginManager.activateTerminal 调用
        // 方拿到一致行为。`transcriptPath` 优先用 SessionStore 里的最新值。
        let transcriptPath = sessionStore.get(originalId)?.transcriptPath
            ?? session.transcriptPath
        if ClaudeDesktopActivator.isDesktopBacked(sid: originalId, transcriptPath: transcriptPath) {
            MLog("[ClaudePlugin] desktop-backed → ClaudeDesktopActivator.activate sid=\(originalId.prefix(8))")
            ClaudeDesktopActivator.activate(sid: originalId)
            return
        }

        // 先尝试从 sessionMonitor 找到完整 session
        if var aiSession = sessionMonitor.sessions.first(where: { $0.id == originalId }) {
            MLog("[ClaudePlugin] Found in sessionMonitor, pid=\(aiSession.pid), termProgram=\(aiSession.termProgram ?? "nil")")
            // sessionMonitor 的 AISession 不含终端信息，从 SessionStore 补充
            if aiSession.termProgram == nil, let sessionData = sessionStore.get(originalId),
               let info = sessionData.terminalInfo {
                aiSession.tty = info.tty
                aiSession.termProgram = info.termProgram
                aiSession.termBundleId = info.termBundleId
                aiSession.cmuxSocketPath = info.cmuxSocketPath
                aiSession.cmuxSurfaceId = info.cmuxSurfaceId
                aiSession.ghosttyTerminalId = sessionData.ghosttyTerminalId
                MLog("[ClaudePlugin] Enriched from SessionStore: tty=\(info.tty ?? "nil"), termProgram=\(info.termProgram ?? "nil"), ghosttyId=\(sessionData.ghosttyTerminalId ?? "nil")")
            }
            enrichTerminalInfoIfMissing(&aiSession, originalId: originalId)
            TerminalManager.smartActivateTerminal(forSession: aiSession)
            return
        }

        // 从 SessionStore 获取 PID 和终端信息
        if let sessionData = sessionStore.get(originalId) {
            let pid = sessionData.pid ?? 0
            let info = sessionData.terminalInfo

            let tempSession = AISession(
                id: originalId,
                pid: pid,
                cwd: sessionData.project,
                startedAt: sessionData.startedAt,
                status: sessionData.status
            )
            var mutableSession = tempSession
            mutableSession.tty = info?.tty
            mutableSession.termProgram = info?.termProgram
            mutableSession.termBundleId = info?.termBundleId
            mutableSession.cmuxSocketPath = info?.cmuxSocketPath
            mutableSession.cmuxSurfaceId = info?.cmuxSurfaceId
            mutableSession.ghosttyTerminalId = sessionData.ghosttyTerminalId
            enrichTerminalInfoIfMissing(&mutableSession, originalId: originalId)
            TerminalManager.smartActivateTerminal(forSession: mutableSession)
            return
        }

        // 最后回退：使用 PluginSession 中的信息
        if let info = session.terminalInfo {
            let tempSession = AISession(
                id: originalId,
                pid: 0,
                cwd: session.cwd ?? "/",
                startedAt: session.startedAt,
                status: session.status
            )
            var mutableSession = tempSession
            mutableSession.tty = info.tty
            mutableSession.termProgram = info.termProgram
            mutableSession.termBundleId = info.termBundleId
            mutableSession.cmuxSocketPath = info.cmuxSocketPath
            mutableSession.cmuxSurfaceId = info.cmuxSurfaceId
            enrichTerminalInfoIfMissing(&mutableSession, originalId: originalId)
            TerminalManager.smartActivateTerminal(forSession: mutableSession)
        }
    }

    /// 清除 session 的 urgentEvent 状态
    override func clearUrgentEvent(sessionId: String) {
        // 从 session 中提取原始 ID
        let originalId = sessionId.hasPrefix("\(pluginId)-")
            ? String(sessionId.dropFirst("\(pluginId)-".count))
            : sessionId

        // 清除 hook 状态
        hookStatesLock.lock()
        hookStates.removeValue(forKey: originalId)
        hookStatesLock.unlock()

        // 清除待响应权限
        pendingPermissionsLock.lock()
        pendingPermissions.removeValue(forKey: originalId)
        pendingPermissionsLock.unlock()

        // 立即通知更新
        notifySessionsUpdated()
    }

    // MARK: - Hook 事件处理

    private func handleHookEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }

        // 更新 hook 状态缓存
        hookStatesLock.lock()
        hookStates[sessionId] = event
        hookStatesLock.unlock()

        if let linkedSurfaceSessionId = SessionTerminalStore.shared.setProviderResumeSessionIdForSurface(
            cmuxSurfaceId: event.cmuxSurfaceId,
            providerResumeSessionId: sessionId
        ) {
            NSLog("[ClaudePlugin] Linked provider session \(sessionId.prefix(8)) to managed surface session \(linkedSurfaceSessionId.prefix(8)) via surface \(event.cmuxSurfaceId ?? "-")")
        }

        // 更新 SessionTerminalStore（用于终端跳转）
        if event.tty != nil || event.termProgram != nil || event.cmuxSocketPath != nil {
            SessionTerminalStore.shared.update(
                sessionId: sessionId,
                tty: event.tty,
                termProgram: event.termProgram,
                termBundleId: event.termBundleId,
                cmuxSocketPath: event.cmuxSocketPath,
                cmuxSurfaceId: event.cmuxSurfaceId,
                cwd: event.cwd ?? "",
                status: event.status ?? "running"
            )
        }

        // Ghostty 原生 terminal ID —— 只在 store 还为空时首次写入（通常发生
        // 在 SessionStart hook，那时 Claude CLI 刚启动、对应 terminal 必然
        // 是前台 tab、bridge 抓到的 id 是正确的）。后续 UserPromptSubmit 等
        // 事件的捕获**不要 overwrite**：那时用户焦点可能在别的 tab，bridge
        // 的 `focused terminal of front window` 拿到的是错的 id，盖掉正确值
        // 会导致"Open terminal"跳到别的 session 的 terminal。
        //
        // 竞态：SessionStart hook 经常抢在 `syncSessions` 的 PID-scan 之前到达，
        // 那时 SessionStore 里还没有这个 sid 的 record，下面的 `update` 直接 no-op。
        // 此时把 gtid 暂存到 `pendingGhosttyTerminalIds`，PID-scan 建 record 时
        // 在 syncSessions 末尾 drain 进 SessionData。
        if let gtid = event.ghosttyTerminalId, !gtid.isEmpty {
            // Collision rejection（默认补丁）：bridge 端的 cwd validation 拦不住
            // "两个 session 同 cwd 同 focused-terminal"这种残留情况，所以再加一道
            // SessionStore 端的检查——已经有别的"活的、不同 tty"的 session 占着
            // 这个 gtid，就拒绝写入，宁可空着走 inbox drain 也不要错配到别的终端。
            let myTty = event.tty ?? ""
            let conflict = sessionStore.sessions.first(where: { other in
                other.sessionId != sessionId
                    && (other.ghosttyTerminalId ?? "") == gtid
                    && (other.terminalInfo?.tty ?? "") != myTty
                    && other.status != .dead && other.status != .completed
            })
            if let conflict = conflict {
                NSLog("[ClaudePlugin] reject ghosttyId=\(gtid.prefix(8)) for sid=\(sessionId.prefix(8)) tty=\(myTty): collision with sid=\(conflict.sessionId.prefix(8)) tty=\(conflict.terminalInfo?.tty ?? "?")")
            } else if sessionStore.exists(sessionId) {
                sessionStore.update(sessionId) { data in
                    if (data.ghosttyTerminalId ?? "").isEmpty {
                        data.ghosttyTerminalId = gtid
                    }
                }
            } else {
                pendingGhosttyTerminalIdsLock.lock()
                if pendingGhosttyTerminalIds[sessionId] == nil {
                    pendingGhosttyTerminalIds[sessionId] = gtid
                }
                pendingGhosttyTerminalIdsLock.unlock()
            }
        }
        // 全 cwd 路径——hook 每次都带 cwd，sticky-empty 写入：第一次有就锁住，
        // 防止后续 hook 在用户 `cd` 后把存的"项目根"改成子目录（aiSession.cwd
        // 来自 transcript 里 SessionStart 的 cwd，更稳定）。
        if let evCwd = event.cwd, !evCwd.isEmpty, sessionStore.exists(sessionId) {
            sessionStore.update(sessionId) { data in
                if (data.cwd ?? "").isEmpty {
                    data.cwd = evCwd
                }
            }
        }
        // iTerm2 native session id：env 里 deterministic，没 race，直接 set-once。
        if let iid = event.iTermSessionId, !iid.isEmpty, sessionStore.exists(sessionId) {
            sessionStore.update(sessionId) { data in
                if (data.iTermSessionId ?? "").isEmpty {
                    data.iTermSessionId = iid
                }
            }
        }
        // Apple Terminal native session id：同上，纯 env 来源
        if let aid = event.appleTerminalSessionId, !aid.isEmpty, sessionStore.exists(sessionId) {
            sessionStore.update(sessionId) { data in
                if (data.appleTerminalSessionId ?? "").isEmpty {
                    data.appleTerminalSessionId = aid
                }
            }
        }

        // 任一 hook 事件到来：立刻让 resolver 的缓存失效，UI 下次读时重算
        TranscriptStatusResolver.invalidate(sessionId: sessionId)

        // 更新精细状态
        ensureSessionStatusInitialized(sessionId: sessionId, event: event)

        // [StateTrace] Hook 层：记录每条事件的进入、字段、前后状态
        sessionStatusesLock.lock()
        let dsBefore = sessionStatuses[sessionId]?.rawValue ?? "nil"
        sessionStatusesLock.unlock()
        let eventName = event.event?.rawValue ?? "nil"
        NSLog("[StateTrace][hook] sid=\(sessionId.prefix(8)) evt=\(eventName) tool=\(event.toolName ?? "-") hookStatusField=\(event.status ?? "-") before=\(dsBefore)")

        // 处理不同类型的事件
        switch event.event {
        case .preToolUse:
            // 工具调用前 - 设置 tooling 状态
            if let toolName = event.toolName {
                sessionStatusesLock.lock()
                sessionStatuses[sessionId] = .tooling
                sessionStatusesLock.unlock()
                MLog("[ClaudePlugin] Tool started: \(toolName)")
            }

        case .postToolUse:
            // 工具调用后 - 可能是 TaskCreate/TaskUpdate
            handleTaskSync(sessionId: sessionId, event: event)

            // 更新使用统计（每次工具调用后 transcript 会更新）
            updateUsageStats(sessionId: sessionId, event: event)

        case .postToolUseFailure:
            // 工具调用失败：跟 PostToolUse 一样跑 task sync + usage，但额外 log
            // 一行 error 标记便于后续 forensics。状态不强制改——hook chain
            // 通常会继续走（Claude 决定重试 or 放弃），下一个 hook 会更新 status。
            handleTaskSync(sessionId: sessionId, event: event)
            updateUsageStats(sessionId: sessionId, event: event)
            let errSnippet = (event.rawData?.prefix(200)).map(String.init) ?? "?"
            NSLog("[ClaudePlugin] PostToolUseFailure sid=\(sessionId.prefix(8)) tool=\(event.toolName ?? "?") raw=\(errSnippet)")

        case .permissionRequest:
            // 权限请求
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .permissionRequired
            sessionStatusesLock.unlock()

            if let toolUseId = event.toolUseId {
                let pending = ClaudePendingPermission(
                    sessionId: sessionId,
                    toolUseId: toolUseId,
                    event: event,
                    receivedAt: Date()
                )
                pendingPermissionsLock.lock()
                pendingPermissions[sessionId] = pending
                pendingPermissionsLock.unlock()
            }

        case .notification:
            // 通知 - 可能等用户输入，也可能是等用户批 tool 权限。
            //
            // 旧实现一刀切设 .waitingForUser，但 Claude Code 的 Notification
            // hook 会**紧跟在 PermissionRequest 之后**发一条同类型 Notification
            // （`notification_type=permission_prompt`，message 形如 "Claude
            // needs your permission to use Bash"），把刚被 PermissionRequest
            // 设的 .permissionRequired 立刻覆盖成 .waitingForUser ——所以灵动
            // 岛/卡片只会闪一下橙色 attention 然后被抹平，UI 上看不到"在等
            // 批权限"的稳定状态。
            //
            // 区分三层信号（任一命中都走 .permissionRequired，否则
            // .waitingForUser）：
            //   1. notification_type == "permission_prompt"（最可靠，Claude
            //      Code 自己给出的标记）
            //   2. pendingPermissions[sid] 还有未批的请求（PermissionRequest
            //      hook 已经到，状态肯定该是 permissionRequired）
            //   3. message 文本含 permission/approve 字样（防御未来 Claude
            //      Code 改版只发 Notification 不发 PermissionRequest）
            let msg = (event.notification ?? "").lowercased()
            let typedPermission = (event.notificationType ?? "") == "permission_prompt"
            let messageLooksLikePermission =
                msg.contains("permission") ||
                msg.contains("approval") ||
                msg.contains("approve")
            pendingPermissionsLock.lock()
            let hasPending = pendingPermissions[sessionId] != nil
            pendingPermissionsLock.unlock()

            sessionStatusesLock.lock()
            if typedPermission || hasPending || messageLooksLikePermission {
                sessionStatuses[sessionId] = .permissionRequired
            } else {
                sessionStatuses[sessionId] = .waitingForUser
            }
            sessionStatusesLock.unlock()

        case .userPromptSubmit:
            // 用户提交输入 - 清除权限请求，开始思考
            pendingPermissionsLock.lock()
            pendingPermissions.removeValue(forKey: sessionId)
            pendingPermissionsLock.unlock()

            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .thinking
            sessionStatusesLock.unlock()

            hookStatesLock.lock()
            hookStates.removeValue(forKey: sessionId)
            hookStatesLock.unlock()

        case .preCompact:
            // 压缩前
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .compacting
            sessionStatusesLock.unlock()

        case .postCompact:
            // 压缩后 - 复位回 idle。否则 .compacting 一直挂着等下一个 user
            // prompt 才被 .thinking 覆盖，UI 上"正在压缩"会持续 N 分钟。
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .idle
            sessionStatusesLock.unlock()

        case .stop:
            // 停止 - 回到 idle
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .idle
            sessionStatusesLock.unlock()

        case .stopFailure:
            // turn 因 API error 收尾——不发 Stop，发 StopFailure。如果不接，
            // 状态会卡在 thinking/tooling 等到 abandoned-session 180s 兜底
            // (assistant tail 的 60s 兜底也只在 transcript 有 assistant entry
            // 时触发，error 出在 first token 前的话连这都没有)。
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .idle
            sessionStatusesLock.unlock()
            NSLog("[ClaudePlugin] StopFailure sid=\(sessionId.prefix(8)) — turn ended with API error, → idle")

        case .cwdChanged:
            // user 在终端 `cd` 之后 hook 带新的 cwd 来 — 直接覆盖（不走
            // sticky-empty）。否则 spawn / open-terminal / project DTO 字段
            // 都用旧 cwd，跟终端实际 pwd 错位。
            if let newCwd = event.cwd, !newCwd.isEmpty {
                sessionStore.update(sessionId) { data in
                    data.cwd = newCwd
                }
                NSLog("[ClaudePlugin] CwdChanged sid=\(sessionId.prefix(8)) → \(newCwd)")
            }

        case .subagentStart:
            // 暂不改 status —— 主 session 仍在跑，subagent 是子进程。日后可能
            // 加 visual indicator (eg. "+1 subagent" badge)；先 log 出来便于
            // debug，避免静默吞。
            NSLog("[ClaudePlugin] SubagentStart sid=\(sessionId.prefix(8))")

        case .subagentStop:
            NSLog("[ClaudePlugin] SubagentStop sid=\(sessionId.prefix(8))")

        case .sessionEnd:
            // 会话结束 - 清理缓存
            hookStatesLock.lock()
            hookStates.removeValue(forKey: sessionId)
            hookStatesLock.unlock()

            pendingPermissionsLock.lock()
            pendingPermissions.removeValue(forKey: sessionId)
            pendingPermissionsLock.unlock()

            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .completed
            sessionStatusesLock.unlock()

            // 更新使用统计
            updateUsageStats(sessionId: sessionId, event: event)

        case .sessionStart:
            // 会话开始
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .idle
            sessionStatusesLock.unlock()

        default:
            break
        }

        sessionStatusesLock.lock()
        let dsAfter = sessionStatuses[sessionId]?.rawValue ?? "nil"
        sessionStatusesLock.unlock()
        NSLog("[StateTrace][hook] sid=\(sessionId.prefix(8)) evt=\(eventName) after=\(dsAfter) (changed=\(dsAfter != dsBefore))")

        // 更新 SessionStore (实时性保障)
        updateSessionInStore(sessionId: sessionId)

        if event.event == .postToolUse || event.event == .postToolUseFailure || event.event == .stop {
            let inserted = SessionArtifactCandidateStore.shared.ingestClaudeHook(event)
            if !inserted.isEmpty {
                MInfo("[ArtifactCandidate] captured \(inserted.count) candidate(s) sid=\(sessionId.prefix(8))")
                BoardServer.shared.broadcastStateChanged()
            }
        }

        // 通知更新 (在更新 SessionStore 之后)
        notifySessionsUpdated()

        // 统一事件总线：任何 hook 都代表一次元数据变动
        SessionEventBus.shared.publish(.sessionMetadataChanged(sessionId: sessionId))

        // 若本次事件带来新 transcript 内容（Stop/PostToolUse/SessionEnd 或带 lastAssistantMessage），再发一个 transcriptAppended
        let hasAssistant = (event.lastAssistantMessage?.isEmpty == false)
        if event.event == .postToolUse || event.event == .stop || event.event == .sessionEnd || hasAssistant {
            SessionEventBus.shared.publish(.transcriptAppended(sessionId: sessionId))
        }

        // 触发音效
        if let eventType = event.event, let soundEvent = eventType.soundEvent {
            if event.suppressesAssistantCompletionSound {
                MDebug("[ClaudePlugin] Suppressed assistant completion sound sid=\(sessionId.prefix(8)) event=\(eventType.rawValue)")
            } else {
                SoundManager.shared.play(event: soundEvent)
            }
        }
    }

    /// 更新单个 session 到 SessionStore (从 Hook 事件触发)
    private func updateSessionInStore(sessionId: String) {
        // 从 SessionStore 获取当前数据
        guard var data = sessionStore.get(sessionId) else {
            // session 不存在，可能还没从 SessionMonitor 同步过来
            return
        }

        // 更新状态
        sessionStatusesLock.lock()
        if let ds = sessionStatuses[sessionId] {
            data.status = ds
        }
        let written = data.status
        sessionStatusesLock.unlock()
        NSLog("[StateTrace][store] sid=\(sessionId.prefix(8)) wrote SessionData.status=\(written.rawValue)")

        // 更新任务
        sessionTasksLock.lock()
        if let tasks = sessionTasks[sessionId] {
            data.tasks = tasks
        }
        sessionTasksLock.unlock()

        // 更新使用统计
        sessionUsageLock.lock()
        if let usage = sessionUsage[sessionId] {
            data.usageStats = usage
        }
        sessionUsageLock.unlock()

        // 更新工具名称、终端信息和 lastMessage
        hookStatesLock.lock()
        if let hook = hookStates[sessionId] {
            if let tool = hook.toolName {
                data.currentTool = tool
            }
            // 更新终端信息 (从 Hook 事件获取) - 只要有一个字段存在就更新
            if hook.tty != nil || hook.termProgram != nil || hook.cmuxSocketPath != nil {
                data.terminalInfo = PluginTerminalInfo(
                    tty: hook.tty,
                    termProgram: hook.termProgram,
                    termBundleId: hook.termBundleId,
                    cmuxSocketPath: hook.cmuxSocketPath,
                    cmuxSurfaceId: hook.cmuxSurfaceId
                )
            }
            // Ghostty 原生 terminal ID — 仅在 SessionStart/UserPromptSubmit 等 hook
            // 里 bridge 会捕获；只要 hook 带来了新值就覆盖（用户可能 --resume 到别的 tab）。
            if let gtid = hook.ghosttyTerminalId, !gtid.isEmpty {
                data.ghosttyTerminalId = gtid
            }
            // 更新 lastMessage（从 hook 的 lastAssistantMessage 或 transcript）
            if let lastAssistantMsg = hook.lastAssistantMessage, !lastAssistantMsg.isEmpty {
                data.lastMessage = String(lastAssistantMsg.prefix(100))
            } else if let transcriptPath = data.transcriptPath {
                // 从 transcript 文件获取最后消息
                let msgs = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 1)
                if let last = msgs.last {
                    let text = last.text.replacingOccurrences(of: "\n", with: " ")
                    data.lastMessage = String(text.prefix(100))
                }
            }
        }
        hookStatesLock.unlock()

        // 更新权限请求状态
        pendingPermissionsLock.lock()
        if let pending = pendingPermissions[sessionId] {
            data.pendingPermissionTool = pending.event.toolName
            data.pendingPermissionMessage = pending.event.permission
        } else {
            data.pendingPermissionTool = nil
            data.pendingPermissionMessage = nil
        }
        pendingPermissionsLock.unlock()

        // 写入 SessionStore
        sessionStore.upsert(data)
    }

    /// 如果该 session 还没有缓存状态，初始化为 idle
    private func ensureSessionStatusInitialized(sessionId: String, event: HookEvent) {
        sessionStatusesLock.lock()
        defer { sessionStatusesLock.unlock() }

        if sessionStatuses[sessionId] == nil {
            sessionStatuses[sessionId] = .idle
        }
    }

    /// 处理任务同步 (TaskCreate/TaskUpdate)
    private func handleTaskSync(sessionId: String, event: HookEvent) {
        guard let toolName = event.toolName else { return }

        switch toolName {
        case "TaskCreate":
            // 创建新任务
            if let toolOutput = event.toolOutputDict,
               let taskId = toolOutput["id"] as? String,
               let toolInput = event.toolInputDict {
                let taskName = toolInput["subject"] as? String ?? toolInput["description"] as? String ?? "unnamed task"

                let task = SessionTask(id: taskId, name: taskName, status: .pending)

                sessionTasksLock.lock()
                if sessionTasks[sessionId] == nil {
                    sessionTasks[sessionId] = []
                }
                sessionTasks[sessionId]?.append(task)
                sessionTasksLock.unlock()

                MLog("[ClaudePlugin] Task created: \(taskName) (\(taskId))")
            }

        case "TaskUpdate":
            // 更新任务状态
            if let toolInput = event.toolInputDict,
               let taskId = toolInput["taskId"] as? String ?? toolInput["task_id"] as? String,
               let newStatus = toolInput["status"] as? String {

                sessionTasksLock.lock()
                if var tasks = sessionTasks[sessionId] {
                    if let index = tasks.firstIndex(where: { $0.id == taskId }) {
                        tasks[index].status = SessionTask.TaskStatus.from(csmString: newStatus)
                        sessionTasks[sessionId] = tasks
                    }
                }
                sessionTasksLock.unlock()

                MLog("[ClaudePlugin] Task updated: \(taskId) -> \(newStatus)")
            }

        default:
            break
        }
    }

    /// 更新使用统计
    private func updateUsageStats(sessionId: String, event: HookEvent) {
        // 从 transcript 获取使用统计
        if let transcriptPath = getTranscriptPath(for: sessionId) {
            let stats = TranscriptParser.getUsageStats(transcriptPath: transcriptPath)
            sessionUsageLock.lock()
            sessionUsage[sessionId] = stats
            sessionUsageLock.unlock()
        }
    }

    /// 获取 transcript 路径
    private func getTranscriptPath(for sessionId: String) -> String? {
        let home = NSHomeDirectory()
        let projectsDir = "\(home)/.claude/projects"

        // 遍历项目目录查找匹配的 transcript 文件
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return nil
        }

        for projectDir in projectDirs {
            let transcriptPath = "\(projectsDir)/\(projectDir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath) {
                return transcriptPath
            }
        }

        return nil
    }

    private func handlePermissionCompletion(
        sessionId: String,
        toolUseId: String,
        outcome: PermissionTerminalOutcome
    ) {
        guard clearPendingPermissionState(sessionId: sessionId, toolUseId: toolUseId) else { return }
        MDebug("[ClaudePlugin] Permission completed sid=\(sessionId.prefix(8)) tool=\(toolUseId.prefix(12)) outcome=\(outcome.rawValue)")
    }

    @discardableResult
    private func clearPendingPermissionState(sessionId: String, toolUseId: String) -> Bool {
        pendingPermissionsLock.lock()
        guard pendingPermissions[sessionId]?.toolUseId == toolUseId else {
            pendingPermissionsLock.unlock()
            return false
        }
        pendingPermissions.removeValue(forKey: sessionId)
        pendingPermissionsLock.unlock()

        sessionStatusesLock.lock()
        if sessionStatuses[sessionId] == .permissionRequired {
            sessionStatuses[sessionId] = .idle
        }
        sessionStatusesLock.unlock()
        notifySessionsUpdated()
        return true
    }

    // MARK: - 权限响应

    private func respondToPermission(sessionId: String, decision: PermissionDecision) {
        pendingPermissionsLock.lock()
        guard let pending = pendingPermissions[sessionId] else {
            pendingPermissionsLock.unlock()
            return
        }
        pendingPermissionsLock.unlock()

        guard clearPendingPermissionState(sessionId: sessionId, toolUseId: pending.toolUseId) else { return }

        // 发送响应
        switch decision {
        case .allow:
            hookServer.respondToPermission(toolUseId: pending.toolUseId, decision: "allow")
        case .deny(let reason):
            hookServer.respondToPermission(toolUseId: pending.toolUseId, decision: "deny", reason: reason)
        }
    }

    // MARK: - 辅助方法

    /// 构建紧急消息
    private func buildUrgentMessage(from event: HookEvent) -> String {
        switch event.event {
        case .permissionRequest:
            let tool = event.toolName ?? "Unknown tool"
            let permission = event.permission ?? "Permission required"

            // 构建 base message
            var message = "**\(tool)**: \(permission)"

            // 添加 toolInput 详情
            if let input = event.toolInput, !input.isEmpty {
                // 尝试解析 JSON 并格式化显示
                if let dict = event.toolInputDict {
                    message += "\n\n**Input:**\n"
                    for (key, value) in dict {
                        let valueStr = formatValue(value)
                        message += "- \(key): \(valueStr)\n"
                    }
                } else {
                    // 非 JSON，直接显示
                    message += "\n\n**Input:** \(input)"
                }
            }

            // 添加 resource 信息
            if let resource = event.resource, !resource.isEmpty {
                message += "\n\n**Resource:** \(resource)"
            }

            return message
        case .notification:
            return event.notification ?? "Notification"
        case .stop, .sessionEnd:
            return event.lastAssistantMessage ?? "Task finished"
        default:
            return event.statusDescription ?? "Needs attention"
        }
    }

    /// 格式化值显示
    private func formatValue(_ value: Any) -> String {
        if let str = value as? String {
            // 截断长字符串
            if str.count > 100 {
                return String(str.prefix(100)) + "..."
            }
            return str
        } else if let dict = value as? [String: Any] {
            // 显示字典的 key 数量
            return "{\(dict.keys.joined(separator: ", "))}"
        } else if let arr = value as? [Any] {
            return "[\(arr.count) items]"
        } else {
            return String(describing: value)
        }
    }

    /// 同步 sessions 到 SessionStore（供 CLI/TUI 使用）
    private func syncToStore(_ sessions: [AISession]) {
        for storeSession in sessionStore.listAll() {
            markRuntimeEndedIfProcessGone(storeSession)
        }

        for aiSession in sessions {
            // 只同步活跃 session 到 SessionStore
            // 死 session 不写入，避免同 project 出现多个历史 session 记录
            if !SessionStore.processAlive(aiSession.pid) {
                continue
            }

            // 检查 hook 状态中是否有真实的 session ID（可能是 --resume 后的新 session）
            // hookStates 中的 session ID 是正确的，而 PID.json 中可能是旧的
            //
            // 两个前提同时满足才做 cwd 回退：
            //   (1) aiSession.id 不在 hookStates 里
            //   (2) aiSession.id 没有对应 transcript 文件（证明它确实是 stale，
            //       而不是刚起来还没发 hook 事件的新 session）
            // 同时：不允许 remap 到一个"已被别的活着 PID 占用"的 sessionId——
            // 多个 Claude CLI 跑在同一个 cwd 时，原逻辑会把它们互相吞并。
            var realSessionId = aiSession.id
            hookStatesLock.lock()
            let idIsKnownToHooks = hookStates[aiSession.id] != nil
            hookStatesLock.unlock()

            if !idIsKnownToHooks {
                let ownTranscript = getTranscriptPath(for: aiSession.id)
                let ownTranscriptExists = ownTranscript
                    .map { FileManager.default.fileExists(atPath: $0) } ?? false

                if !ownTranscriptExists {
                    // 只有自己的 transcript 不存在才怀疑是 stale ID。归属交给
                    // resolveStaleSessionId:优先 surface-id 精确匹配、拒绝无
                    // transcript 的幽灵候选(共 cwd 的同胞/夭折会话),避免把
                    // 节点绑到一个永远 resume 不了的假 id。
                    hookStatesLock.lock()
                    let candidates = hookStates.map { (sid, evt) in
                        ProviderSessionCandidate(sessionId: sid, cwd: evt.cwd ?? "", surfaceId: evt.cmuxSurfaceId)
                    }
                    hookStatesLock.unlock()

                    if let resolved = Self.resolveStaleSessionId(
                        surfaceId: aiSession.cmuxSurfaceId,
                        cwd: aiSession.cwd,
                        candidates: candidates,
                        isClaimedByOther: { candidate in
                            self.sessionStore.sessions.contains(where: {
                                $0.sessionId == candidate
                                    && $0.pid != aiSession.pid
                                    && $0.pid.map { SessionStore.processAlive($0) } == true
                            })
                        },
                        transcriptExists: { self.getTranscriptPath(for: $0) != nil },
                        logSkipped: { self.logSkippedCwdRemap(candidate: $0, aiSession: aiSession) }
                    ) {
                        realSessionId = resolved
                        NSLog("[ClaudePlugin] Remapped stale session ID: \(resolved.prefix(8)) (PID.json had \(aiSession.id.prefix(8)))")
                    }
                }
            }

            // 如果 store 中已有同 PID 的 session，检查 session ID 是否正确
            if let existingPidMatch = sessionStore.sessions.first(where: { $0.pid == aiSession.pid }) {
                // 如果 session ID 不匹配，说明 PID.json 是旧的 --resume session
                // 需要把旧记录迁移到真实 ID，不能 delete/create 丢掉用户状态
                if existingPidMatch.sessionId != realSessionId {
                    NSLog("[ClaudePlugin] Session ID mismatch: store has \(existingPidMatch.sessionId), real is \(realSessionId). Rekeying continuity record.")
                    // Belt-and-suspenders: never freeze a resume target whose
                    // transcript doesn't exist. resolveStaleSessionId already
                    // rejects phantoms during remap, but `realSessionId` may also
                    // be the un-remapped PID-scan id; guard here too so a phantom
                    // can never become a node's permanent (broken) resume id.
                    if Self.isMeee2InternalSessionId(existingPidMatch.sessionId),
                       getTranscriptPath(for: realSessionId) != nil {
                        SessionTerminalStore.shared.setProviderResumeSessionId(
                            sessionId: existingPidMatch.sessionId,
                            providerResumeSessionId: realSessionId
                        )
                    }
                    // 旧 record 上的 ghosttyTerminalId（如果有）属于同一个物理 Ghostty
                    // terminal（同一 PID = 同一 Claude CLI 实例 = 同一 tty）。
                    // 删旧之前先把它 buffer 到 realSessionId 上，避免新 record 失去
                    // 跳转/消息注入能力。
                    if let prevGtid = existingPidMatch.ghosttyTerminalId, !prevGtid.isEmpty {
                        pendingGhosttyTerminalIdsLock.lock()
                        if pendingGhosttyTerminalIds[realSessionId] == nil {
                            pendingGhosttyTerminalIds[realSessionId] = prevGtid
                        }
                        pendingGhosttyTerminalIdsLock.unlock()
                    }
                    moveVolatileSessionCaches(from: existingPidMatch.sessionId, to: realSessionId)
                    _ = sessionStore.rekeySession(existingPidMatch.sessionId, to: realSessionId)
                    // 继续创建新记录（不 continue）
                } else {
                    // session ID 匹配，正常更新
                    let transcriptPath = getTranscriptPath(for: realSessionId)

                    let lastMessage = transcriptPath.flatMap { cachedLastMessage(transcriptPath: $0) }

                    sessionStore.update(existingPidMatch.sessionId) { data in
                        data.project = aiSession.projectName
                        // 全 cwd 路径——spawn / open-in-editor 等需要完整路径的操作走 data.cwd。
                        // aiSession.cwd 拿不到时不要清掉旧值（基本不会发生，aiSession 总是带 cwd）。
                        if !aiSession.cwd.isEmpty {
                            data.cwd = aiSession.cwd
                        }
                        data.startedAt = aiSession.startedAt
                        if aiSession.lastUpdated > data.lastActivity {
                            data.lastActivity = aiSession.lastUpdated
                        }
                        // 不要碰 data.status：SessionMonitor 每 2s 跑一次这条路径，
                        // 如果这里硬写，会把 hook 刚刚设的 .thinking / .tooling 冲掉，
                        // UI 就出现"回复到一半突然 idle"的抖动。
                        // data.status 的权威源是 hook 事件（handleHookEvent）。
                        data.transcriptPath = transcriptPath
                        data.lastMessage = lastMessage
                    }
                    continue
                }
            }

            // 获取 hook 状态（使用真实的 session ID）
            var hookEvent: HookEvent?
            hookStatesLock.lock()
            hookEvent = hookStates[realSessionId]
            hookStatesLock.unlock()

            // 获取 hook 驱动的 session 状态
            var hookDrivenStatus: SessionStatus = aiSession.status
            sessionStatusesLock.lock()
            if let ds = sessionStatuses[realSessionId] {
                hookDrivenStatus = ds
            }
            sessionStatusesLock.unlock()

            // 获取任务
            var tasks: [SessionTask]?
            sessionTasksLock.lock()
            tasks = sessionTasks[realSessionId]
            sessionTasksLock.unlock()

            // 获取使用统计
            var usageStats: UsageStats?
            sessionUsageLock.lock()
            usageStats = sessionUsage[realSessionId]
            sessionUsageLock.unlock()

            // 优先使用 Hook 事件中的终端信息 (更准确)
            // 如果 Hook 事件没有终端信息，使用 AISession 中的
            let tty = hookEvent?.tty ?? aiSession.tty
            let termProgram = hookEvent?.termProgram ?? aiSession.termProgram
            let termBundleId = hookEvent?.termBundleId ?? aiSession.termBundleId
            let cmuxSocketPath = hookEvent?.cmuxSocketPath ?? aiSession.cmuxSocketPath
            let cmuxSurfaceId = hookEvent?.cmuxSurfaceId ?? aiSession.cmuxSurfaceId

            // 构建 SessionData（使用真实的 session ID）
            let transcriptPath = getTranscriptPath(for: realSessionId)

            let lastMessage = transcriptPath.flatMap { cachedLastMessage(transcriptPath: $0) }

            // Drain any buffered ghosttyTerminalId from earlier hook events that
            // arrived before this PID-scan got a chance to materialize the record.
            // Falls back to the latest hookEvent if the buffer is empty.
            pendingGhosttyTerminalIdsLock.lock()
            let bufferedGtid = pendingGhosttyTerminalIds.removeValue(forKey: realSessionId)
            pendingGhosttyTerminalIdsLock.unlock()
            let resolvedGhosttyTerminalId = bufferedGtid ?? hookEvent?.ghosttyTerminalId

            let data = SessionData(
                sessionId: realSessionId,
                project: aiSession.projectName,
                cwd: aiSession.cwd.isEmpty ? nil : aiSession.cwd,
                pid: aiSession.pid,
                ghosttyTerminalId: resolvedGhosttyTerminalId,
                transcriptPath: transcriptPath,
                providerResumeSessionId: AgentLaunchCommand.isLikelyProviderResumeSessionId(realSessionId) ? realSessionId : nil,
                startedAt: aiSession.startedAt,
                lastActivity: aiSession.lastUpdated,
                status: hookDrivenStatus,
                currentTool: aiSession.toolName ?? hookEvent?.toolName,
                description: aiSession.currentTask,
                tasks: tasks ?? [],
                currentTask: aiSession.currentTask,
                terminalInfo: PluginTerminalInfo(
                    tty: tty,
                    termProgram: termProgram,
                    termBundleId: termBundleId,
                    cmuxSocketPath: cmuxSocketPath,
                    cmuxSurfaceId: cmuxSurfaceId
                ),
                usageStats: usageStats,
                lastMessage: lastMessage
            )

            // 写入 SessionStore
            sessionStore.createOrUpdate(data)
        }
    }

    private func logSkippedCwdRemap(candidate: String, aiSession: AISession) {
        let key = "\(candidate)|\(aiSession.pid)|\(aiSession.id)"
        let now = Date()
        if let previous = cwdRemapSkipLogTimes[key],
           now.timeIntervalSince(previous) < cwdRemapSkipLogInterval {
            return
        }
        cwdRemapSkipLogTimes[key] = now
        NSLog("[ClaudePlugin] skip cwd-remap to \(candidate.prefix(8)): claimed by another alive PID (pid=\(aiSession.pid), stale=\(aiSession.id.prefix(8)))")
    }

    private func markRuntimeEndedIfProcessGone(_ storeSession: SessionData) {
        guard let pid = storeSession.pid,
              !SessionStore.processAlive(pid) else {
            return
        }
        let endedStatus: SessionStatus = storeSession.status == .completed ? .completed : .dead
        guard storeSession.status != endedStatus
            || storeSession.currentTool != nil
            || storeSession.pendingPermissionTool != nil
            || storeSession.pendingPermissionMessage != nil else {
            return
        }

        sessionStore.update(storeSession.sessionId) { data in
            data.status = endedStatus
            data.currentTool = nil
            data.pendingPermissionTool = nil
            data.pendingPermissionMessage = nil
        }

        hookStatesLock.lock()
        hookStates.removeValue(forKey: storeSession.sessionId)
        hookStatesLock.unlock()

        pendingPermissionsLock.lock()
        pendingPermissions.removeValue(forKey: storeSession.sessionId)
        pendingPermissionsLock.unlock()

        sessionStatusesLock.lock()
        sessionStatuses.removeValue(forKey: storeSession.sessionId)
        sessionStatusesLock.unlock()

        NSLog("[ClaudePlugin] Preserved ended session \(storeSession.sessionId.prefix(8)); pid \(pid) is gone")
    }

    private func moveVolatileSessionCaches(from oldSessionId: String, to newSessionId: String) {
        guard oldSessionId != newSessionId else { return }

        hookStatesLock.lock()
        if hookStates[newSessionId] == nil {
            hookStates[newSessionId] = hookStates[oldSessionId]
        }
        hookStates.removeValue(forKey: oldSessionId)
        hookStatesLock.unlock()

        pendingPermissionsLock.lock()
        if pendingPermissions[newSessionId] == nil {
            pendingPermissions[newSessionId] = pendingPermissions[oldSessionId]
        }
        pendingPermissions.removeValue(forKey: oldSessionId)
        pendingPermissionsLock.unlock()

        sessionTasksLock.lock()
        if sessionTasks[newSessionId] == nil {
            sessionTasks[newSessionId] = sessionTasks[oldSessionId]
        }
        sessionTasks.removeValue(forKey: oldSessionId)
        sessionTasksLock.unlock()

        sessionUsageLock.lock()
        if sessionUsage[newSessionId] == nil {
            sessionUsage[newSessionId] = sessionUsage[oldSessionId]
        }
        sessionUsage.removeValue(forKey: oldSessionId)
        sessionUsageLock.unlock()

        sessionStatusesLock.lock()
        if sessionStatuses[newSessionId] == nil {
            sessionStatuses[newSessionId] = sessionStatuses[oldSessionId]
        }
        sessionStatuses.removeValue(forKey: oldSessionId)
        sessionStatusesLock.unlock()
    }

    private func notifySessionsUpdated() {
        let sessions = getSessions()
        onSessionsUpdated?(sessions)
    }

    private func cachedLastMessage(transcriptPath: String) -> String? {
        guard let fingerprint = Self.fileFingerprint(path: transcriptPath) else {
            return nil
        }

        lastMessageCacheLock.lock()
        if let cached = lastMessageCache[transcriptPath],
           cached.fileSize == fingerprint.fileSize,
           cached.modifiedAt == fingerprint.modifiedAt {
            lastMessageCacheLock.unlock()
            return cached.value
        }
        lastMessageCacheLock.unlock()

        let value: String?
        let messages = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 1)
        if let last = messages.last {
            let text = last.text.replacingOccurrences(of: "\n", with: " ")
            value = String(text.prefix(100))
        } else {
            value = nil
        }

        lastMessageCacheLock.lock()
        lastMessageCache[transcriptPath] = LastMessageCacheEntry(
            fileSize: fingerprint.fileSize,
            modifiedAt: fingerprint.modifiedAt,
            value: value
        )
        if lastMessageCache.count > 512 {
            lastMessageCache.removeAll(keepingCapacity: true)
        }
        lastMessageCacheLock.unlock()
        return value
    }

    private static func isMeee2InternalSessionId(_ sessionId: String) -> Bool {
        let lower = sessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("claude-internal-") || lower.hasPrefix("codex-internal-")
    }

    /// A candidate CLI (`claude`) session, surfaced from a hook event, that a
    /// stale PID-scanned session might actually be.
    struct ProviderSessionCandidate: Equatable {
        let sessionId: String
        let cwd: String
        let surfaceId: String?
    }

    /// Resolve which provider (CLI) session id a stale internal/PID session
    /// should adopt.
    ///
    /// Root-cause fix: every node's internal session in a canvas runs `claude`
    /// in the SAME managed-workspace cwd, so resolving "which CLI session is
    /// this surface's" by cwd alone is ambiguous — under collision an internal
    /// session can get bound to a *sibling's* (or an aborted/phantom) CLI id.
    /// If that phantom id (no transcript on disk) is then frozen as the resume
    /// target, `claude --resume <id>` fails forever and the node sticks at
    /// "running / needs-response" with no live session.
    ///
    /// This resolver makes attribution deterministic and safe:
    ///  1. Prefer an **exact surface-id match** (now that internal sessions
    ///     export `CMUX_SURFACE_ID`, hooks carry the surface id) over a cwd
    ///     match.
    ///  2. **Never** adopt a candidate whose transcript is missing — that's the
    ///     phantom that permanently breaks resume.
    ///  3. Skip candidates already claimed by another live PID.
    /// Returns `nil` when no trustworthy candidate exists (caller keeps the
    /// original id rather than freezing garbage).
    static func resolveStaleSessionId(
        surfaceId: String?,
        cwd: String,
        candidates: [ProviderSessionCandidate],
        isClaimedByOther: (String) -> Bool,
        transcriptExists: (String) -> Bool,
        logSkipped: (String) -> Void = { _ in }
    ) -> String? {
        func norm(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let mySurface = norm(surfaceId)
        let myCwd = norm(cwd)
        // Exact surface-id matches first (deterministic), then cwd matches.
        let bySurface: [ProviderSessionCandidate] = mySurface == nil ? [] :
            candidates.filter { norm($0.surfaceId) == mySurface }
        let byCwd: [ProviderSessionCandidate] = myCwd == nil ? [] :
            candidates.filter { norm($0.cwd) == myCwd }
        var ordered: [String] = []
        for candidate in bySurface + byCwd where !ordered.contains(candidate.sessionId) {
            ordered.append(candidate.sessionId)
        }
        for candidate in ordered {
            if isClaimedByOther(candidate) { logSkipped(candidate); continue }
            // A candidate without a transcript is a phantom — adopting/freezing
            // it permanently breaks resume. Reject it.
            if !transcriptExists(candidate) { logSkipped(candidate); continue }
            return candidate
        }
        return nil
    }

    private static func fileFingerprint(path: String) -> (fileSize: UInt64, modifiedAt: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }
        return (fileSize, modifiedAt)
    }

    // MARK: - 终端信息现场推导（回退路径）

    /// 当 SessionStore/AISession 缺少 tty 时，走 `ps` 从进程树现场推导，并回写 SessionStore。
    /// 处理历史上 terminal_info 被空数据覆盖的脏数据场景。
    private func enrichTerminalInfoIfMissing(_ aiSession: inout AISession, originalId: String) {
        guard aiSession.tty == nil || aiSession.tty?.isEmpty == true else { return }
        guard aiSession.pid > 0 else {
            MWarn("[ClaudePlugin] Cannot derive terminal info: pid=0 for \(originalId)")
            return
        }

        guard let derived = Self.deriveTerminalInfoLive(forPID: aiSession.pid) else {
            MWarn("[ClaudePlugin] Live-derive failed for pid=\(aiSession.pid) (\(originalId))")
            return
        }

        aiSession.tty = derived.tty
        aiSession.termProgram = derived.termProgram
        aiSession.termBundleId = derived.termBundleId
        MInfo("[ClaudePlugin] Live-derived terminal info for \(originalId): tty=\(derived.tty ?? "nil"), termProgram=\(derived.termProgram ?? "nil")")

        // 回写 SessionStore 供下次快速跳转
        sessionStore.update(originalId) { data in
            data.terminalInfo = derived
        }
    }

    /// 从 pid 现场推导 TTY + 终端应用（走进程树）。失败返回 nil。
    private static func deriveTerminalInfoLive(forPID pid: Int) -> PluginTerminalInfo? {
        guard let rawTTY = runPS(["-o", "tty=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTTY.isEmpty, rawTTY != "??" else {
            return nil
        }

        // 沿 ppid 链最多向上 8 层，匹配已知终端应用
        var termProgram: String?
        var termBundleId: String?
        var currentPid = pid
        for _ in 0..<8 {
            guard let ppidStr = runPS(["-o", "ppid=", "-p", "\(currentPid)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let ppid = Int(ppidStr), ppid > 1 else { break }

            guard let command = runPS(["-o", "command=", "-p", "\(ppid)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { break }

            if command.contains("Ghostty.app") || command.contains("ghostty") {
                termProgram = "ghostty"
                termBundleId = "com.mitchellh.ghostty"
                break
            } else if command.contains("iTerm.app") || command.contains("iTerm2") {
                termProgram = "iTerm.app"
                termBundleId = "com.googlecode.iterm2"
                break
            } else if command.contains("Terminal.app") {
                termProgram = "Apple_Terminal"
                termBundleId = "com.apple.Terminal"
                break
            } else if command.contains("cmux") {
                termProgram = "cmux"
                termBundleId = "cmux"
                break
            }

            currentPid = ppid
        }

        return PluginTerminalInfo(
            tty: rawTTY,
            termProgram: termProgram,
            termBundleId: termBundleId,
            cmuxSocketPath: nil,
            cmuxSurfaceId: nil
        )
    }

    private static func runPS(_ args: [String]) -> String? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 内部类型

/// 待响应的权限请求 (ClaudePlugin 内部)
private struct ClaudePendingPermission {
    let sessionId: String
    let toolUseId: String
    let event: HookEvent
    let receivedAt: Date
}
