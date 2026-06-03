import Foundation
import Combine
import SwiftUI
import Meee2PluginKit

/// Plugin 管理器
public class PluginManager: ObservableObject {
    public static let shared = PluginManager()

    // MARK: - Published

    /// 所有 plugin sessions
    @Published public var sessions: [PluginSession] = []

    /// 所有 plugin 注册的灵动岛 widget。IslandView 按 placement 渲染。
    /// 仅在 register / start / setPluginEnabled / stopAll 时聚合一次——widget 内部数据
    /// 反应式更新走它自己的 ObservableObject，不依赖这个数组被重新赋值。
    @Published public var widgets: [IslandWidget] = []

    /// 已加载的 plugins
    @Published public var loadedPlugins: [String: SessionPlugin] = [:]

    /// 加载失败的插件
    @Published public var failedPlugins: [DynamicPluginLoader.FailedPlugin] = []

    /// 是否正在加载
    @Published public var isLoading: Bool = true

    /// 错误信息 (pluginId -> errorMessage)
    @Published public var pluginErrors: [String: String] = [:]

    /// 是否有任何错误
    public var hasError: Bool {
        !pluginErrors.isEmpty || !failedPlugins.isEmpty
    }

    // MARK: - Private

    private let pluginDirectory: URL
    private let dynamicLoader = DynamicPluginLoader()
    private let queue = DispatchQueue(label: "com.meee2.pluginmanager", qos: .utility)

    /// 确保线程安全的锁
    private let sessionsLock = NSLock()

    // MARK: - Init

    private init() {
        // 设置 plugin 日志回调
        pluginLogHandler = { message in
            MLog(message)
        }

        let home = NSHomeDirectory()
        pluginDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".meee2")
            .appendingPathComponent("plugins")

        try? FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Plugin Registration

    /// 注册内置 plugin
    public func register(_ plugin: SessionPlugin) {
        guard plugin.initialize() else {
            MLog("[PluginManager] Failed to initialize plugin: \(plugin.pluginId)")
            return
        }
        applyPersistedEnabledState(to: plugin)

        plugin.onSessionsUpdated = { [weak self] sessions in
            guard let self = self else { return }
            self.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
        }

        plugin.onUrgentEvent = { [weak self] session, message, action in
            MLog("[PluginManager] onUrgentEvent callback invoked for \(session.title)")
            guard let self = self else {
                MLog("[PluginManager] ERROR: self is nil in onUrgentEvent callback!")
                return
            }
            self.handleUrgentEvent(session: session, message: message, action: action)
        }

        loadedPlugins[plugin.pluginId] = plugin
        MLog("[PluginManager] Registered plugin: \(plugin.pluginId)")
        refreshWidgets()
    }

    /// 启动所有 plugins
    public func startAll() {
        for (pluginId, plugin) in loadedPlugins {
            if plugin.config.enabled {
                _ = plugin.start()  // Result intentionally unused
                MLog("[PluginManager] Started plugin: \(pluginId)")
            } else {
                removeSessions(forPluginId: pluginId)
                MLog("[PluginManager] Skipped disabled plugin: \(pluginId)")
            }
        }
        refreshWidgets()
    }

    /// 停止所有 plugins
    public func stopAll() {
        for plugin in loadedPlugins.values {
            plugin.stop()
        }
        refreshWidgets()
    }

    /// 聚合所有启用 plugin 的 widget 列表。@Published 改动只在主线程。
    private func refreshWidgets() {
        let collected: [IslandWidget] = loadedPlugins.values
            .filter { $0.config.enabled }
            .flatMap { $0.widgets }

        if Thread.isMainThread {
            self.widgets = collected
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.widgets = collected
            }
        }
    }

    /// 按 placement 过滤 widget，供 IslandView 用。
    public func widgets(for placement: IslandWidgetPlacement) -> [IslandWidget] {
        widgets.filter { $0.placement == placement }
    }

    // MARK: - External Plugin Loading

    /// 扫描并加载外部 plugins
    public func loadExternalPlugins() {
        MLog("[PluginManager] loadExternalPlugins called")
        var externalPlugins: [SessionPlugin] = []

        externalPlugins = dynamicLoader.loadAllPlugins()
        MLog("[PluginManager] dynamicLoader returned \(externalPlugins.count) plugins")

        // 更新失败插件列表
        DispatchQueue.main.async { [weak self] in
            self?.failedPlugins = self?.dynamicLoader.failedPlugins ?? []
        }

        for plugin in externalPlugins {
            MLog("[PluginManager] Processing external plugin: \(plugin.pluginId)")
            if plugin.initialize() {
                self.applyPersistedEnabledState(to: plugin)
                MLog("[PluginManager] Plugin \(plugin.pluginId) initialized successfully")

                // 设置回调
                plugin.onSessionsUpdated = { [weak self] sessions in
                    guard let self = self else { return }
                    self.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
                }

                plugin.onUrgentEvent = { [weak self] session, message, action in
                    MLog("[PluginManager] onUrgentEvent callback invoked for \(session.title)")
                    guard let self = self else {
                        MLog("[PluginManager] ERROR: self is nil in onUrgentEvent callback!")
                        return
                    }
                    self.handleUrgentEvent(session: session, message: message, action: action)
                }

                loadedPlugins[plugin.pluginId] = plugin
                MLog("[PluginManager] Loaded external plugin: \(plugin.pluginId)")
            } else {
                MLog("[PluginManager] Failed to initialize external plugin: \(plugin.pluginId)")
            }
        }
        refreshWidgets()
    }

    // MARK: - Session Management

    private func handleSessionsUpdated(pluginId: String, sessions: [PluginSession]) {
        MDebug("[PluginManager] handleSessionsUpdated called for \(pluginId) with \(sessions.count) sessions")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.isPluginEnabled(pluginId) else {
                self.sessions.removeAll { $0.pluginId == pluginId }
                MLog("[PluginManager] Ignored sessions from disabled plugin: \(pluginId)")
                return
            }

            // 保存该 plugin 的旧 sessions 的 urgentEvent 状态
            var existingUrgentEvents: [String: UrgentEventInfo] = [:]
            for session in self.sessions where session.pluginId == pluginId {
                if let event = session.urgentEvent {
                    existingUrgentEvents[session.id] = event
                    MDebug("[PluginManager] Preserving urgentEvent for session: \(session.id)")
                }
            }

            // 移除该 plugin 的旧 sessions
            self.sessions.removeAll { $0.pluginId == pluginId }

            // 添加新 sessions，并恢复 urgentEvent
            var uniqueSessions: [PluginSession] = []
            var seenIds = Set<String>()
            for session in sessions {
                if !seenIds.contains(session.id) {
                    seenIds.insert(session.id)
                    var updatedSession = session
                    // 恢复 urgentEvent（如果有）
                    if let existingEvent = existingUrgentEvents[session.id] {
                        updatedSession.urgentEvent = existingEvent
                        MDebug("[PluginManager] Restored urgentEvent for session: \(session.id)")
                    }
                    uniqueSessions.append(updatedSession)
                }
            }
            self.sessions.append(contentsOf: uniqueSessions)

            // 统一按 startedAt 排序（最近的在前）
            self.sessions.sort { $0.startedAt > $1.startedAt }

            // 标记加载完成
            self.isLoading = false
            MDebug("[PluginManager] Sessions updated, total: \(self.sessions.count), urgentEvents preserved: \(existingUrgentEvents.count)")
        }
    }

    private func handleUrgentEvent(session: PluginSession, message: String, action: String?) {
        MLog("[PluginManager] handleUrgentEvent: \(session.title), message: \(message.prefix(50))")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 创建 urgent event info
            let urgentEvent = UrgentEventInfo(
                id: "\(session.id)-urgent",
                eventType: "message",
                message: message,
                actionLabel: action
            )

            // 复制数组，修改后重新赋值（触发 @Published 更新）
            var updatedSessions = self.sessions

            if let index = updatedSessions.firstIndex(where: { $0.id == session.id }) {
                updatedSessions[index].urgentEvent = urgentEvent
                MLog("[PluginManager] Updated urgentEvent for session: \(session.id)")
            } else {
                // session 不存在，添加新的（带 urgentEvent）
                var newSession = session
                newSession.urgentEvent = urgentEvent
                updatedSessions.append(newSession)
                MLog("[PluginManager] Added new session with urgentEvent: \(session.id)")
            }

            // 重新赋值触发 @Published 更新
            self.sessions = updatedSessions
            MLog("[PluginManager] Urgent event processed, sessions count: \(self.sessions.count)")

            // 发送通知（可选，用于其他监听者）
            NotificationCenter.default.post(
                name: .pluginUrgentEvent,
                object: nil,
                userInfo: [
                    "session": session,
                    "message": message,
                    "action": action as Any
                ]
            )
        }
    }

    public func isPluginEnabled(_ pluginId: String) -> Bool {
        if let plugin = loadedPlugins[pluginId] {
            return plugin.config.enabled
        }
        if let stored = UserDefaults.standard.object(forKey: enabledDefaultsKey(pluginId)) as? Bool {
            return stored
        }
        return true
    }

    public func setPluginEnabled(_ pluginId: String, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey(pluginId))
        guard let plugin = loadedPlugins[pluginId] else { return }
        var config = plugin.config
        config.enabled = enabled
        plugin.config = config

        if enabled {
            _ = plugin.start()
            MLog("[PluginManager] Enabled plugin: \(pluginId)")
        } else {
            plugin.stop()
            removeSessions(forPluginId: pluginId)
            MLog("[PluginManager] Disabled plugin: \(pluginId)")
        }
        refreshWidgets()
    }

    private func applyPersistedEnabledState(to plugin: SessionPlugin) {
        let key = enabledDefaultsKey(plugin.pluginId)
        guard let stored = UserDefaults.standard.object(forKey: key) as? Bool else { return }
        var config = plugin.config
        config.enabled = stored
        plugin.config = config
    }

    private func removeSessions(forPluginId pluginId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.sessions.removeAll { $0.pluginId == pluginId }
        }
    }

    private func enabledDefaultsKey(_ pluginId: String) -> String {
        "plugin_\(pluginId)_enabled"
    }

    // MARK: - Terminal Activation

    /// 激活 session 对应的终端
    public func activateTerminal(for session: PluginSession) {
        guard let plugin = loadedPlugins[session.pluginId] else {
            MLog("[PluginManager] Plugin not found for session: \(session.pluginId)")
            return
        }

        plugin.activateTerminal(for: session)
    }

    /// 清除 session 的 urgentEvent 状态
    public func clearUrgentEvent(sessionId: String, pluginId: String) {
        guard let plugin = loadedPlugins[pluginId] else {
            MLog("[PluginManager] Plugin not found: \(pluginId)")
            return
        }

        // 通知 plugin 清除内部状态
        plugin.clearUrgentEvent(sessionId: sessionId)

        // 直接清除 sessions 数组中的 urgentEvent
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            var updatedSessions = self.sessions
            if let index = updatedSessions.firstIndex(where: { $0.id == sessionId }) {
                updatedSessions[index].urgentEvent = nil
                self.sessions = updatedSessions
                MLog("[PluginManager] Cleared urgentEvent in sessions array for: \(sessionId)")
            }
        }
    }

    // MARK: - Plugin Info

    /// 获取 plugin 信息
    func getPluginInfo(for pluginId: String) -> (displayName: String, icon: String, themeColor: Color)? {
        guard let plugin = loadedPlugins[pluginId] else { return nil }
        return (plugin.displayName, plugin.icon, plugin.themeColor)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let pluginUrgentEvent = Notification.Name("pluginUrgentEvent")
}
