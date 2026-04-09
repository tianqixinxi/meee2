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

    /// 精细状态缓存 (sessionId -> DetailedStatus)
    private var detailedStatuses: [String: DetailedStatus] = [:]
    private let detailedStatusesLock = NSLock()

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

        // 创建临时 AISession 用于跳转
        if let aiSession = sessionMonitor.sessions.first(where: { $0.id == originalId }) {
            TerminalManager.smartActivateTerminal(forSession: aiSession)
        } else if let info = session.terminalInfo {
            // 回退：创建临时 AISession 用于跳转
            let tempSession = AISession(
                id: originalId,
                pid: 0,
                cwd: session.cwd ?? "/",
                startedAt: session.startedAt,
                status: session.status
            )
            // 使用反射或直接设置终端信息
            var mutableSession = tempSession
            mutableSession.tty = info.tty
            mutableSession.termProgram = info.termProgram
            mutableSession.termBundleId = info.termBundleId
            mutableSession.cmuxSocketPath = info.cmuxSocketPath
            mutableSession.cmuxSurfaceId = info.cmuxSurfaceId
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

        // 更新精细状态
        updateDetailedStatus(sessionId: sessionId, event: event)

        // 处理不同类型的事件
        switch event.event {
        case .preToolUse:
            // 工具调用前 - 设置 tooling 状态
            if let toolName = event.toolName {
                detailedStatusesLock.lock()
                detailedStatuses[sessionId] = .tooling
                detailedStatusesLock.unlock()
                MLog("[ClaudePlugin] Tool started: \(toolName)")
            }

        case .postToolUse:
            // 工具调用后 - 可能是 TaskCreate/TaskUpdate
            handleTaskSync(sessionId: sessionId, event: event)

        case .permissionRequest:
            // 权限请求
            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .permissionRequired
            detailedStatusesLock.unlock()

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
            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .waitingForUser
            detailedStatusesLock.unlock()

        case .userPromptSubmit:
            // 用户提交输入 - 清除权限请求，开始思考
            pendingPermissionsLock.lock()
            pendingPermissions.removeValue(forKey: sessionId)
            pendingPermissionsLock.unlock()

            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .thinking
            detailedStatusesLock.unlock()

            hookStatesLock.lock()
            hookStates.removeValue(forKey: sessionId)
            hookStatesLock.unlock()

        case .preCompact:
            // 压缩前
            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .compacting
            detailedStatusesLock.unlock()

        case .stop:
            // 停止 - 回到 idle
            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .idle
            detailedStatusesLock.unlock()

        case .sessionEnd:
            // 会话结束 - 清理缓存
            hookStatesLock.lock()
            hookStates.removeValue(forKey: sessionId)
            hookStatesLock.unlock()

            pendingPermissionsLock.lock()
            pendingPermissions.removeValue(forKey: sessionId)
            pendingPermissionsLock.unlock()

            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .completed
            detailedStatusesLock.unlock()

            // 更新使用统计
            updateUsageStats(sessionId: sessionId, event: event)

        case .sessionStart:
            // 会话开始
            detailedStatusesLock.lock()
            detailedStatuses[sessionId] = .idle
            detailedStatusesLock.unlock()

        default:
            break
        }

        // 更新 SessionStore (实时性保障)
        updateSessionInStore(sessionId: sessionId)

        // 通知更新 (在更新 SessionStore 之后)
        notifySessionsUpdated()

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
        detailedStatusesLock.lock()
        if let ds = detailedStatuses[sessionId] {
            data.detailedStatus = ds
        }
        detailedStatusesLock.unlock()

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

        // 更新工具名称和终端信息
        hookStatesLock.lock()
        if let hook = hookStates[sessionId] {
            if let tool = hook.toolName {
                data.currentTool = tool
            }
            // 更新终端信息 (从 Hook 事件获取)
            if let tty = hook.tty, let termProgram = hook.termProgram {
                data.terminalInfo = PluginTerminalInfo(
                    tty: tty,
                    termProgram: termProgram,
                    termBundleId: hook.termBundleId,
                    cmuxSocketPath: hook.cmuxSocketPath,
                    cmuxSurfaceId: hook.cmuxSurfaceId
                )
            }
        }
        hookStatesLock.unlock()

        // 写入 SessionStore
        sessionStore.upsert(data)
    }

    /// 更新精细状态
    private func updateDetailedStatus(sessionId: String, event: HookEvent) {
        detailedStatusesLock.lock()
        defer { detailedStatusesLock.unlock() }

        // 如果还没有状态，初始化为 idle
        if detailedStatuses[sessionId] == nil {
            detailedStatuses[sessionId] = .idle
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
            return "\(tool): \(permission)"
        case .notification:
            return event.notification ?? "Notification"
        case .stop, .sessionEnd:
            return event.lastAssistantMessage ?? "Task finished"
        default:
            return event.statusDescription ?? "Needs attention"
        }
    }

    /// 同步 sessions 到 SessionStore（供 CLI/TUI 使用）
    private func syncToStore(_ sessions: [AISession]) {
        for aiSession in sessions {
            // 获取 hook 状态
            var hookEvent: HookEvent?
            hookStatesLock.lock()
            hookEvent = hookStates[aiSession.id]
            hookStatesLock.unlock()

            // 获取精细状态
            var detailedStatus: DetailedStatus = .idle
            detailedStatusesLock.lock()
            if let ds = detailedStatuses[aiSession.id] {
                detailedStatus = ds
            }
            detailedStatusesLock.unlock()

            // 获取任务
            var tasks: [SessionTask]? = nil
            sessionTasksLock.lock()
            tasks = sessionTasks[aiSession.id]
            sessionTasksLock.unlock()

            // 获取使用统计
            var usageStats: UsageStats? = nil
            sessionUsageLock.lock()
            usageStats = sessionUsage[aiSession.id]
            sessionUsageLock.unlock()

            // 优先使用 Hook 事件中的终端信息 (更准确)
            // 如果 Hook 事件没有终端信息，使用 AISession 中的
            let tty = hookEvent?.tty ?? aiSession.tty
            let termProgram = hookEvent?.termProgram ?? aiSession.termProgram
            let termBundleId = hookEvent?.termBundleId ?? aiSession.termBundleId
            let cmuxSocketPath = hookEvent?.cmuxSocketPath ?? aiSession.cmuxSocketPath
            let cmuxSurfaceId = hookEvent?.cmuxSurfaceId ?? aiSession.cmuxSurfaceId

            // 构建 SessionData
            let transcriptPath = getTranscriptPath(for: aiSession.id)

            // 加载最后消息
            var lastMessage: String? = nil
            if let path = transcriptPath {
                let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: 1)
                if let last = msgs.last {
                    let prefix: String
                    switch last.role {
                    case "user": prefix = ">"
                    case "assistant": prefix = "◀"
                    case "tool": prefix = "⚡"
                    default: prefix = "·"
                    }
                    // 截断到 100 字符
                    let text = last.text.replacingOccurrences(of: "\n", with: " ")
                    lastMessage = "\(prefix) \(String(text.prefix(100)))"
                }
            }

            let data = SessionData(
                sessionId: aiSession.id,
                project: aiSession.projectName,
                pid: aiSession.pid,
                ghosttyTerminalId: nil,
                transcriptPath: transcriptPath,
                startedAt: aiSession.startedAt,
                lastActivity: aiSession.lastUpdated,
                status: aiSession.status.rawValue,
                detailedStatus: detailedStatus,
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
}

// MARK: - 内部类型

/// 待响应的权限请求 (ClaudePlugin 内部)
private struct ClaudePendingPermission {
    let sessionId: String
    let toolUseId: String
    let event: HookEvent
    let receivedAt: Date
}