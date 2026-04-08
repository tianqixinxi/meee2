import Foundation
import Combine
import SwiftUI
import Meee2PluginKit

/// 状态管理器 - 聚合所有插件的数据
/// 作为 UI 的数据源
public class StatusManager: ObservableObject {
    // MARK: - Published Properties

    /// 所有 sessions (来自所有插件，包括 Claude)
    @Published public var sessions: [PluginSession] = []

    /// 是否有需要用户介入的 session
    @Published public var hasUrgentSession: Bool = false

    /// 系统状态
    @Published public var systemStatus: SystemStatus = .idle

    /// 最新的事件消息
    @Published public var latestMessage: String?

    /// 刘海尺寸 (由 AppDelegate 设置)
    @Published public var notchSize: CGSize = CGSize(width: 150, height: 32)

    // MARK: - Computed Properties

    /// 当前紧急 session 列表 (urgentEvent != nil)
    public var urgentSessions: [PluginSession] {
        sessions.filter { $0.urgentEvent != nil }
    }

    /// 当前第一个紧急 session
    public var currentUrgentSession: PluginSession? {
        urgentSessions.first
    }

    /// 当前紧急消息
    public var currentUrgentMessage: String? {
        currentUrgentSession?.urgentEvent?.message
    }

    // MARK: - Private Properties

    let pluginManager: PluginManager
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
        pluginManager = PluginManager.shared
        setupBindings()
    }

    deinit {
        pluginManager.stopAll()
    }

    // MARK: - Public Methods

    /// 启动监控
    public func start() {
        // 注册 ClaudePlugin (内置插件)
        let claudePlugin = ClaudePlugin()
        pluginManager.register(claudePlugin)

        // 启动所有 plugins
        pluginManager.startAll()

        NSLog("[StatusManager] Started with ClaudePlugin registered")
    }

    /// 停止监控
    public func stop() {
        pluginManager.stopAll()
        NSLog("[StatusManager] Stopped")
    }

    // MARK: - Session Operations

    /// 激活 session 对应的终端
    public func activateTerminal(for session: PluginSession) {
        pluginManager.activateTerminal(for: session)
    }

    /// 响应权限请求
    public func respondToPermission(for session: PluginSession, decision: PermissionDecision) {
        session.urgentEvent?.respond?(decision)
    }

    /// 关闭指定紧急 session
    public func dismissUrgent(sessionId: String) {
        // 通过响应 .deny 来关闭权限请求
        if let session = sessions.first(where: { $0.id == sessionId }),
           let event = session.urgentEvent {
            event.respond?(.deny(reason: "Dismissed by user"))
        }
    }

    // MARK: - Plugin Info

    /// 获取 plugin 信息
    public func getPluginInfo(for pluginId: String) -> (displayName: String, icon: String, themeColor: Color)? {
        pluginManager.getPluginInfo(for: pluginId)
    }

    // MARK: - Private Methods

    private func setupBindings() {
        // 订阅 PluginManager.sessions
        pluginManager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self = self else { return }
                self.sessions = sessions
                self.updateSystemStatus()
                // 通知 AppDelegate 更新状态栏图标
                NotificationCenter.default.post(name: NSNotification.Name("SessionsDidChange"), object: nil)
            }
            .store(in: &cancellables)

        // 检测 urgent 状态
        pluginManager.$sessions
            .map { $0.contains { $0.urgentEvent != nil } }
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasUrgentSession)
    }

    private func updateSystemStatus() {
        if sessions.isEmpty {
            systemStatus = .idle
            return
        }

        if sessions.contains(where: { $0.status == .failed }) {
            systemStatus = .error
            return
        }

        if hasUrgentSession || sessions.contains(where: { $0.status.needsUserAction }) {
            systemStatus = .needsAttention
            return
        }

        systemStatus = .running
    }
}

// MARK: - 时间格式化

extension StatusManager {
    /// 格式化运行时间
    public func formatDuration(_ duration: TimeInterval) -> String {
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