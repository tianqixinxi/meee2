import Foundation
import SwiftUI
import Combine
import Meee2PluginKit

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

    /// Combine 订阅
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 生命周期

    override func initialize() -> Bool {
        return true
    }

    override func start() -> Bool {
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
            onPermissionFailure: { [weak self] sessionId, toolUseId in
                self?.handlePermissionFailure(sessionId: sessionId, toolUseId: toolUseId)
            }
        )

        NSLog("[ClaudePlugin] Started")
        return true
    }

    override func stop() {
        cancellables.removeAll()
        sessionMonitor.stopMonitoring()
        hookServer.stop()
        NSLog("[ClaudePlugin] Stopped")
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
        if let gtid = event.ghosttyTerminalId, !gtid.isEmpty {
            sessionStore.update(sessionId) { data in
                if (data.ghosttyTerminalId ?? "").isEmpty {
                    data.ghosttyTerminalId = gtid
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
            // 通知 - 可能需要等待用户
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .waitingForUser
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

        case .stop:
            // 停止 - 回到 idle
            sessionStatusesLock.lock()
            sessionStatuses[sessionId] = .idle
            sessionStatusesLock.unlock()

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
            SoundManager.shared.play(event: soundEvent)
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

    private func handlePermissionFailure(sessionId: String, toolUseId: String) {
        pendingPermissionsLock.lock()
        pendingPermissions.removeValue(forKey: sessionId)
        pendingPermissionsLock.unlock()
        notifySessionsUpdated()
    }

    // MARK: - 权限响应

    private func respondToPermission(sessionId: String, decision: PermissionDecision) {
        pendingPermissionsLock.lock()
        guard pendingPermissions[sessionId] != nil else {
            pendingPermissionsLock.unlock()
            return
        }
        pendingPermissions.removeValue(forKey: sessionId)
        pendingPermissionsLock.unlock()

        // 发送响应
        switch decision {
        case .allow:
            hookServer.respondToPermissionBySession(sessionId: sessionId, decision: "allow")
        case .deny(let reason):
            hookServer.respondToPermissionBySession(sessionId: sessionId, decision: "deny", reason: reason)
        }

        notifySessionsUpdated()
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
        // 清理 SessionStore 中进程已死亡的 session
        // SessionMonitor 会将死进程标记为 completed，但其 PID.json 文件仍存在于 ~/.claude/sessions/
        // 所以每次 sync 都会看到死 session，需要主动清理
        var sessionsToDelete: [String] = []
        for storeSession in sessionStore.listAll() {
            if let pid = storeSession.pid, !SessionStore.processAlive(pid) {
                sessionsToDelete.append(storeSession.sessionId)
            }
        }

        for sessionIdToDelete in sessionsToDelete {
            sessionStore.delete(sessionIdToDelete)
            // 清理相关缓存
            hookStatesLock.lock()
            hookStates.removeValue(forKey: sessionIdToDelete)
            hookStatesLock.unlock()
            pendingPermissionsLock.lock()
            pendingPermissions.removeValue(forKey: sessionIdToDelete)
            pendingPermissionsLock.unlock()
            sessionTasksLock.lock()
            sessionTasks.removeValue(forKey: sessionIdToDelete)
            sessionTasksLock.unlock()
            sessionUsageLock.lock()
            sessionUsage.removeValue(forKey: sessionIdToDelete)
            sessionUsageLock.unlock()
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
                    // 只有自己的 transcript 不存在才怀疑是 stale ID
                    hookStatesLock.lock()
                    let candidates = hookStates.compactMap { (sid, evt) -> String? in
                        evt.cwd == aiSession.cwd ? sid : nil
                    }
                    hookStatesLock.unlock()

                    for candidate in candidates {
                        // 候选 sid 已经被另一个活着的 PID 占用？那它不是给我的
                        let claimedByOther = sessionStore.sessions.contains(where: {
                            $0.sessionId == candidate
                                && $0.pid != aiSession.pid
                                && $0.pid.map { SessionStore.processAlive($0) } == true
                        })
                        if claimedByOther {
                            NSLog("[ClaudePlugin] skip cwd-remap to \(candidate.prefix(8)): claimed by another alive PID")
                            continue
                        }
                        realSessionId = candidate
                        NSLog("[ClaudePlugin] Remapped stale session ID via cwd: \(candidate.prefix(8)) (PID.json had \(aiSession.id.prefix(8)))")
                        break
                    }
                } else {
                    NSLog("[ClaudePlugin] keep PID.json sid=\(aiSession.id.prefix(8)): transcript exists, not stale")
                }
            }

            // 如果 store 中已有同 PID 的 session，检查 session ID 是否正确
            if let existingPidMatch = sessionStore.sessions.first(where: { $0.pid == aiSession.pid }) {
                // 如果 session ID 不匹配，说明 PID.json 是旧的 --resume session
                // 需要删除旧记录，用真实的 session ID 创建新记录
                if existingPidMatch.sessionId != realSessionId {
                    NSLog("[ClaudePlugin] Session ID mismatch: store has \(existingPidMatch.sessionId), real is \(realSessionId). Deleting old and creating new.")
                    sessionStore.delete(existingPidMatch.sessionId)
                    // 继续创建新记录（不 continue）
                } else {
                    // session ID 匹配，正常更新
                    let transcriptPath = getTranscriptPath(for: realSessionId)

                    var lastMessage: String? = nil
                    if let path = transcriptPath {
                        let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: 1)
                        if let last = msgs.last {
                            let text = last.text.replacingOccurrences(of: "\n", with: " ")
                            lastMessage = String(text.prefix(100))
                        }
                    }

                    sessionStore.update(existingPidMatch.sessionId) { data in
                        data.project = aiSession.projectName
                        data.startedAt = aiSession.startedAt
                        data.lastActivity = aiSession.lastUpdated
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
            var tasks: [SessionTask]? = nil
            sessionTasksLock.lock()
            tasks = sessionTasks[realSessionId]
            sessionTasksLock.unlock()

            // 获取使用统计
            var usageStats: UsageStats? = nil
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

            // 加载最后消息
            var lastMessage: String? = nil
            if let path = transcriptPath {
                let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: 1)
                if let last = msgs.last {
                    // 截断到 100 字符
                    let text = last.text.replacingOccurrences(of: "\n", with: " ")
                    lastMessage = String(text.prefix(100))
                }
            }

            let data = SessionData(
                sessionId: realSessionId,
                project: aiSession.projectName,
                pid: aiSession.pid,
                ghosttyTerminalId: nil,
                transcriptPath: transcriptPath,
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

    private func notifySessionsUpdated() {
        let sessions = getSessions()
        onSessionsUpdated?(sessions)
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
        var termProgram: String? = nil
        var termBundleId: String? = nil
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