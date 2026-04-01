import Foundation
import Combine
import PeerPluginKit

/// 状态管理器 - 聚合 SessionMonitor 和 HookReceiver 的数据
/// 作为 UI 的数据源
public class StatusManager: ObservableObject {
    // MARK: - Published Properties

    /// 所有活跃的 sessions (Claude CLI)
    @Published public var sessions: [AISession] = []

    /// Plugin sessions (Cursor, Copilot, Aider, etc.)
    @Published public var pluginSessions: [PluginSession] = []

    /// 最活跃的 session (显示在紧凑视图)
    @Published public var activeSession: AISession?

    /// 是否有需要用户介入的 session
    @Published public var hasUrgentSession: Bool = false

    /// 当前需要用户介入的 Claude session 列表
    @Published public var urgentSessions: [AISession] = []

    /// 当前需要用户介入的 Plugin session 列表
    @Published public var urgentPluginSessions: [PluginSession] = []

    /// 紧急事件对应的详细信息
    @Published public var urgentMessages: [String: String] = [:]  // sessionId -> message

    /// 紧急事件对应的类型
    @Published public var urgentEventTypes: [String: HookEventType?] = [:]  // sessionId -> eventType

    /// 当前显示的紧急 session（优先显示 Claude，然后 Plugin）
    public var currentUrgentSession: AISession? {
        urgentSessions.first
    }

    public var currentUrgentPluginSession: PluginSession? {
        urgentPluginSessions.first
    }

    public var currentUrgentMessage: String? {
        if let session = currentUrgentSession {
            return urgentMessages[session.id]
        }
        if let session = currentUrgentPluginSession {
            return urgentMessages[session.id]
        }
        return nil
    }

    public var currentUrgentEventType: HookEventType? {
        if let session = currentUrgentSession {
            return urgentEventTypes[session.id] ?? nil
        }
        return nil
    }

    /// 最新的事件消息
    @Published public var latestMessage: String?

    /// 系统状态
    @Published public var systemStatus: SystemStatus = .idle

    /// 刘海尺寸 (由 AppDelegate 设置)
    @Published public var notchSize: CGSize = CGSize(width: 150, height: 32)

    // MARK: - Private Properties

    private var sessionMonitor: SessionMonitor
    private var hookReceiver: HookReceiver
    var pluginManager: PluginManager  // Internal access for UI

    private var cancellables = Set<AnyCancellable>()

    // MARK: - System Status

    public enum SystemStatus {
        case idle          // 无活跃 session
        case running       // 有 session 运行中
        case needsAttention  // 需要用户介入
        case error         // 有错误发生
    }

    // MARK: - Initialization

    public init() {
        sessionMonitor = SessionMonitor()
        hookReceiver = HookReceiver.shared
        pluginManager = PluginManager.shared

        setupBindings()
        setupPluginBindings()
    }

    deinit {
        sessionMonitor.stopMonitoring()
        hookReceiver.stop()
    }

    // MARK: - Public Methods

    /// 启动监控
    public func start() {
        // 启动 session 文件监控
        sessionMonitor.startMonitoring()

        // 启动 hook receiver
        if !hookReceiver.start() {
            NSLog("[StatusManager] Failed to start HookReceiver")
        }

        // 设置 hook 回调
        hookReceiver.onHookReceived = { [weak self] event in
            self?.handleHookEvent(event)
        }

        // 启动 plugins
        pluginManager.startAll()

        NSLog("[StatusManager] Started")
    }

    /// 停止监控
    public func stop() {
        sessionMonitor.stopMonitoring()
        hookReceiver.stop()
        pluginManager.stopAll()
        print("StatusManager stopped")
    }

    /// 跳转到指定 session 的 Terminal（智能跳转）
    func openTerminal(for session: AISession) {
        TerminalManager.smartActivateTerminal(forSession: session)
    }

    /// 跳转到指定 Plugin session 的 Terminal
    func openTerminal(forPluginSession session: PluginSession) {
        pluginManager.activateTerminal(for: session)
    }

    /// 确认权限请求 (发送确认信号)
    func confirmPermission(for session: AISession) {
        // 实际确认操作需要通过其他方式实现
        // 这里只是标记状态更新
        updateSessionStatus(sessionId: session.id, status: .running)
        latestMessage = "已确认权限请求"
    }

    // MARK: - Private Methods

    /// 设置数据绑定
    private func setupBindings() {
        // 监听 session 变化，合并运行时状态
        sessionMonitor.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSessions in
                guard let self = self else { return }
                // 合并状态：保留当前的运行时状态（status, currentTask, toolName）
                self.sessions = self.mergeWithCurrentState(newSessions)
                self.updateActiveSession()
                self.updateSystemStatus()
                // 通知 AppDelegate 更新状态栏图标
                NotificationCenter.default.post(name: NSNotification.Name("SessionsDidChange"), object: nil)
            }
            .store(in: &cancellables)
    }

    /// 设置 Plugin 数据绑定
    private func setupPluginBindings() {
        // 订阅 plugin sessions 变化
        pluginManager.$sessions
            .receive(on: DispatchQueue.main)
            .assign(to: &$pluginSessions)

        // 监听 plugin 紧急事件
        NotificationCenter.default.publisher(for: .pluginUrgentEvent)
            .compactMap { $0.userInfo as? [String: Any] }
            .sink { [weak self] info in
                if let session = info["session"] as? PluginSession,
                   let message = info["message"] as? String {
                    self?.handlePluginUrgentEvent(session: session, message: message)
                }
            }
            .store(in: &cancellables)
    }

    /// 合并新加载的 sessions 和当前运行时状态
    private func mergeWithCurrentState(_ newSessions: [AISession]) -> [AISession] {
        let currentMap = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        return newSessions.map { newSession in
            if let current = currentMap[newSession.id] {
                // 保留运行时状态
                var merged = newSession
                // 如果当前状态是 completed，保持 completed
                if current.status == .completed {
                    merged.status = .completed
                } else {
                    merged.status = current.status
                }
                merged.currentTask = current.currentTask
                merged.toolName = current.toolName
                merged.lastUpdated = current.lastUpdated

                // 合并终端信息（优先使用当前的，因为可能从 hook 更新过）
                merged.tty = current.tty
                merged.termProgram = current.termProgram
                merged.termBundleId = current.termBundleId
                merged.cmuxSocketPath = current.cmuxSocketPath
                merged.cmuxSurfaceId = current.cmuxSurfaceId
                merged.lastActivityTimestamp = current.lastActivityTimestamp

                // 如果当前没有终端信息，尝试从 SessionTerminalStore 补充
                if merged.tty == nil && merged.termProgram == nil {
                    if let storedInfo = SessionTerminalStore.shared.get(sessionId: newSession.id) {
                        merged.tty = storedInfo.tty
                        merged.termProgram = storedInfo.termProgram
                        merged.termBundleId = storedInfo.termBundleId
                        merged.cmuxSocketPath = storedInfo.cmuxSocketPath
                        merged.cmuxSurfaceId = storedInfo.cmuxSurfaceId
                        NSLog("[StatusManager] Restored terminal info from store for session \(newSession.id.prefix(8)): term=\(storedInfo.termProgram ?? "nil")")
                    }
                }

                NSLog("[StatusManager] Merged session \(newSession.id.prefix(8)): status=\(merged.status.rawValue), task=\(current.currentTask ?? "nil"), term=\(merged.termProgram ?? "nil")")
                return merged
            }

            // 新 session，尝试从 SessionTerminalStore 补充终端信息
            var merged = newSession
            if let storedInfo = SessionTerminalStore.shared.get(sessionId: newSession.id) {
                merged.tty = storedInfo.tty
                merged.termProgram = storedInfo.termProgram
                merged.termBundleId = storedInfo.termBundleId
                merged.cmuxSocketPath = storedInfo.cmuxSocketPath
                merged.cmuxSurfaceId = storedInfo.cmuxSurfaceId
                NSLog("[StatusManager] Loaded terminal info from store for new session \(newSession.id.prefix(8)): term=\(storedInfo.termProgram ?? "nil")")
            }

            return merged
        }
    }

    /// 处理 hook 事件
    private func handleHookEvent(_ event: HookEvent) {
        NSLog("[StatusManager] Hook received: \(event.event?.rawValue ?? "unknown"), sessionId: \(event.sessionId ?? "none")")
        NSLog("[StatusManager] Event details - statusDescription: \(event.statusDescription ?? "nil"), inferredStatus: \(event.inferredStatus.rawValue), toolName: \(event.toolName ?? "nil")")
        NSLog("[StatusManager] Current sessions count: \(sessions.count)")

        // 更新对应 session 的状态
        if let sessionId = event.sessionId {
            // 更新 SessionTerminalStore
            SessionTerminalStore.shared.update(
                sessionId: sessionId,
                tty: event.tty,
                termProgram: event.termProgram,
                termBundleId: event.termBundleId,
                cmuxSocketPath: event.cmuxSocketPath,
                cmuxSurfaceId: event.cmuxSurfaceId,
                cwd: event.cwd ?? "",
                status: event.inferredStatus.rawValue
            )

            // 检查 session 是否在列表中
            let sessionExists = sessions.contains(where: { $0.id == sessionId })
            NSLog("[StatusManager] Session \(sessionId) exists in list: \(sessionExists)")

            // 先更新 session 状态（包含终端信息）
            updateSessionStatus(
                sessionId: sessionId,
                status: event.inferredStatus,
                task: event.statusDescription,
                tool: event.toolName,
                terminalInfo: (tty: event.tty, termProgram: event.termProgram, termBundleId: event.termBundleId, cmuxSocketPath: event.cmuxSocketPath, cmuxSurfaceId: event.cmuxSurfaceId)
            )

            // 检查是否需要用户介入，添加到紧急列表
            if event.shouldShowUrgentPanel {
                // 查找或创建 session
                var urgentSession = sessions.first(where: { $0.id == sessionId })
                if urgentSession == nil {
                    // Session 不在列表中，创建一个临时 session
                    NSLog("[StatusManager] Session not in list, creating temporary urgent session")
                    urgentSession = AISession(
                        id: sessionId,
                        pid: 0,
                        cwd: event.cwd ?? "/",
                        startedAt: Date(),
                        status: event.inferredStatus,
                        currentTask: event.statusDescription,
                        toolName: event.toolName
                    )
                }

                if let session = urgentSession {
                    // 如果不在紧急列表中，添加
                    if !urgentSessions.contains(where: { $0.id == sessionId }) {
                        urgentSessions.append(session)
                        NSLog("[StatusManager] Added urgent session: \(session.projectName), total urgent: \(urgentSessions.count)")
                    } else {
                        // 更新已存在的 session
                        if let index = urgentSessions.firstIndex(where: { $0.id == sessionId }) {
                            urgentSessions[index] = session
                        }
                    }

                    // 存储消息和事件类型
                    urgentMessages[sessionId] = buildUrgentMessage(from: event)
                    urgentEventTypes[sessionId] = event.event
                }

                hasUrgentSession = !urgentSessions.isEmpty
                NSLog("[StatusManager] hasUrgentSession: \(hasUrgentSession), urgent count: \(urgentSessions.count)")
            }
        }

        // 设置最新消息
        latestMessage = event.statusDescription

        // 用户提交新的提示时重置状态
        if event.event == .userPromptSubmit {
            clearUrgentSessions()
        }

        // 刷新 sessions
        sessionMonitor.refreshSessions()
    }

    /// 清除所有紧急状态
    private func clearUrgentSessions() {
        urgentSessions.removeAll()
        urgentPluginSessions.removeAll()
        urgentMessages.removeAll()
        urgentEventTypes.removeAll()
        hasUrgentSession = false
    }

    /// 处理 Plugin 紧急事件
    private func handlePluginUrgentEvent(session: PluginSession, message: String) {
        NSLog("[StatusManager] Plugin urgent event: \(session.pluginId), session: \(session.title), message: \(message)")

        // 添加到紧急列表（如果不存在）
        if !urgentPluginSessions.contains(where: { $0.id == session.id }) {
            urgentPluginSessions.append(session)
        }

        // 存储消息
        urgentMessages[session.id] = message
        hasUrgentSession = true
        systemStatus = .needsAttention
        latestMessage = message

        NSLog("[StatusManager] Plugin urgent session added, total urgent: \(urgentSessions.count + urgentPluginSessions.count)")
    }

    /// 关闭指定紧急 session
    func dismissUrgent(sessionId: String) {
        // 先检查 Claude sessions
        if let index = urgentSessions.firstIndex(where: { $0.id == sessionId }) {
            let dismissed = urgentSessions.remove(at: index)
            urgentMessages.removeValue(forKey: dismissed.id)
            urgentEventTypes.removeValue(forKey: dismissed.id)
            NSLog("[StatusManager] Dismissed urgent session: \(dismissed.projectName)")
        }
        // 再检查 Plugin sessions
        else if let index = urgentPluginSessions.firstIndex(where: { $0.id == sessionId }) {
            let dismissed = urgentPluginSessions.remove(at: index)
            urgentMessages.removeValue(forKey: dismissed.id)
            NSLog("[StatusManager] Dismissed urgent plugin session: \(dismissed.title)")
        }

        NSLog("[StatusManager] Remaining urgent: \(urgentSessions.count + urgentPluginSessions.count)")

        // 更新状态
        hasUrgentSession = !urgentSessions.isEmpty || !urgentPluginSessions.isEmpty

        if !hasUrgentSession {
            systemStatus = .running
        }
    }

    /// 关闭当前紧急 session（第一个），显示下一个
    func dismissCurrentUrgent() {
        guard !urgentSessions.isEmpty else { return }

        // 移除第一个
        let dismissed = urgentSessions.removeFirst()
        urgentMessages.removeValue(forKey: dismissed.id)
        urgentEventTypes.removeValue(forKey: dismissed.id)

        NSLog("[StatusManager] Dismissed urgent session: \(dismissed.projectName), remaining: \(urgentSessions.count)")

        // 更新状态
        hasUrgentSession = !urgentSessions.isEmpty

        if urgentSessions.isEmpty {
            // 没有更多紧急事件
            systemStatus = .running
        }
    }

    /// 构建紧急信息展示内容
    private func buildUrgentMessage(from event: HookEvent) -> String {
        switch event.event {
        case .permissionRequest:
            let tool = event.toolName ?? "Unknown tool"
            let permission = event.permission ?? "Permission required"
            return "\(tool): \(permission)"

        case .notification:
            return event.notification ?? "Task completed"

        case .stop, .sessionEnd:
            return event.lastAssistantMessage ?? event.statusDescription ?? "Task finished"

        default:
            return event.statusDescription ?? "Needs attention"
        }
    }

    /// 更新指定 session 的状态 (含终端信息)
    private func updateSessionStatus(
        sessionId: String,
        status: SessionStatus,
        task: String? = nil,
        tool: String? = nil,
        terminalInfo: (tty: String?, termProgram: String?, termBundleId: String?, cmuxSocketPath: String?, cmuxSurfaceId: String?)? = nil
    ) {
        NSLog("[StatusManager] updateSessionStatus called: sessionId=\(sessionId), status=\(status.rawValue), task=\(task ?? "nil"), tool=\(tool ?? "nil")")

        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            let currentStatus = sessions[index].status
            let oldTask = sessions[index].currentTask ?? "nil"

            // 如果当前状态是 completed，只能被 userPromptSubmit 事件改变
            // 其他事件不应该覆盖 completed 状态
            if currentStatus == .completed && status != .completed && status != .thinking {
                NSLog("[StatusManager] Session is completed, ignoring status change to \(status.rawValue)")
                return
            }

            var updated = sessions[index].withStatus(status, task: task, tool: tool)

            // 更新终端信息
            if let info = terminalInfo {
                updated = updated.withTerminalInfo(
                    tty: info.tty,
                    termProgram: info.termProgram,
                    termBundleId: info.termBundleId,
                    cmuxSocketPath: info.cmuxSocketPath,
                    cmuxSurfaceId: info.cmuxSurfaceId
                )
            }

            sessions[index] = updated
            NSLog("[StatusManager] Session updated: \(currentStatus.rawValue) -> \(status.rawValue), task: \(oldTask) -> \(task ?? "nil")")
            updateActiveSession()
            updateSystemStatus()
        } else {
            NSLog("[StatusManager] Session NOT FOUND in sessions list, cannot update")
        }
    }

    /// 更新活跃 session (优先选择需要用户介入的)
    private func updateActiveSession() {
        // 如果已经有紧急 session，保持不变
        guard currentUrgentSession == nil else {
            return
        }

        // 优先选择需要用户介入的 session
        let urgent = sessions.filter { $0.status.needsUserAction }
        if let firstUrgent = urgent.first {
            activeSession = firstUrgent
            return
        }

        // 否则选择最近活跃的 session
        let runningSessions = sessions.filter { $0.status == .running || $0.status == .idle }
        if let running = runningSessions.first {
            activeSession = running
            return
        }

        // 最后选择最近更新的 session
        activeSession = sessions.first
    }

    /// 更新系统状态
    private func updateSystemStatus() {
        if sessions.isEmpty && urgentSessions.isEmpty {
            systemStatus = .idle
            return
        }

        if sessions.contains(where: { $0.status == .failed }) {
            systemStatus = .error
            return
        }

        // 如果有紧急 session，保持 needsAttention 状态
        if !urgentSessions.isEmpty || sessions.contains(where: { $0.status.needsUserAction }) {
            systemStatus = .needsAttention
            return
        }

        systemStatus = .running
    }
}

// MARK: - 时间格式化

extension StatusManager {
    /// 格式化运行时间
    func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.0fs", duration)
        } else if duration < 3600 {
            let minutes = Int(duration / 60)
            return "\(minutes)m"
        } else {
            let hours = Int(duration / 3600)
            let remainingSeconds = duration - TimeInterval(hours * 3600)
            let minutes = Int(remainingSeconds / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}