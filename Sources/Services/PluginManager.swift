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

        plugin.onSessionsUpdated = { [weak self] sessions in
            guard let self = self else { return }
            self.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
        }

        plugin.onUrgentEvent = { [weak self] session, message, action in
            guard let self = self else { return }
            self.handleUrgentEvent(session: session, message: message, action: action)
        }

        loadedPlugins[plugin.pluginId] = plugin
        MLog("[PluginManager] Registered plugin: \(plugin.pluginId)")
    }

    /// 启动所有 plugins
    public func startAll() {
        for (pluginId, plugin) in loadedPlugins {
            if plugin.config.enabled {
                _ = plugin.start()  // Result intentionally unused
                MLog("[PluginManager] Started plugin: \(pluginId)")
            }
        }
    }

    /// 停止所有 plugins
    public func stopAll() {
        for plugin in loadedPlugins.values {
            plugin.stop()
        }
    }

    // MARK: - External Plugin Loading

    /// 扫描并加载外部 plugins
    public func loadExternalPlugins() {
        var externalPlugins: [SessionPlugin] = []

        externalPlugins = dynamicLoader.loadAllPlugins()

        // 更新失败插件列表
        DispatchQueue.main.async { [weak self] in
            self?.failedPlugins = self?.dynamicLoader.failedPlugins ?? []
        }

        for plugin in externalPlugins {
            if plugin.initialize() {
                // 设置回调
                plugin.onSessionsUpdated = { [weak self] sessions in
                    guard let self = self else { return }
                    self.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
                }

                plugin.onUrgentEvent = { [weak self] session, message, action in
                    guard let self = self else { return }
                    self.handleUrgentEvent(session: session, message: message, action: action)
                }

                loadedPlugins[plugin.pluginId] = plugin
                MLog("[PluginManager] Loaded external plugin: \(plugin.pluginId)")
            } else {
                MLog("[PluginManager] Failed to initialize external plugin: \(plugin.pluginId)")
            }
        }
    }

    // MARK: - Session Management

    private func handleSessionsUpdated(pluginId: String, sessions: [PluginSession]) {
        MLog("[PluginManager] handleSessionsUpdated called for \(pluginId) with \(sessions.count) sessions")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 移除该 plugin 的旧 sessions
            self.sessions.removeAll { $0.pluginId == pluginId }
            // 添加新 sessions（去重）
            var uniqueSessions: [PluginSession] = []
            var seenIds = Set<String>()
            for session in sessions {
                if !seenIds.contains(session.id) {
                    seenIds.insert(session.id)
                    uniqueSessions.append(session)
                }
            }
            self.sessions.append(contentsOf: uniqueSessions)
            // 统一按 startedAt 排序（最近的在前）
            self.sessions.sort { $0.startedAt > $1.startedAt }
            // 标记加载完成
            self.isLoading = false
            MLog("[PluginManager] Sessions updated, total: \(self.sessions.count)")
        }
    }

    private func handleUrgentEvent(session: PluginSession, message: String, action: String?) {
        MLog("[PluginManager] handleUrgentEvent: \(session.title), message: \(message)")

        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }

            NotificationCenter.default.post(
                name: .pluginUrgentEvent,
                object: nil,
                userInfo: [
                    "session": session,
                    "message": message,
                    "action": action as Any
                ]
            )
            MLog("[PluginManager] Notification posted on main thread")
        }
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

        plugin.clearUrgentEvent(sessionId: sessionId)
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