import Foundation
import Combine
import SwiftUI
import PeerPluginKit

/// Plugin 管理器
public class PluginManager: ObservableObject {
    public static let shared = PluginManager()

    // MARK: - Published

    /// 所有 plugin sessions
    @Published public var sessions: [PluginSession] = []

    /// 已加载的 plugins
    @Published public var loadedPlugins: [String: SessionPlugin] = [:]

    /// 是否正在加载
    @Published public var isLoading: Bool = true

    /// 错误信息 (pluginId -> errorMessage)
    @Published public var pluginErrors: [String: String] = [:]

    /// 是否有任何错误
    public var hasError: Bool {
        !pluginErrors.isEmpty
    }

    // MARK: - Private

    private let pluginDirectory: URL
    private let dynamicLoader = DynamicPluginLoader()
    private let queue = DispatchQueue(label: "com.peerisland.pluginmanager", qos: .utility)

    // MARK: - Init

    private init() {
        let home = NSHomeDirectory()
        pluginDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".peer-island")
            .appendingPathComponent("plugins")

        try? FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Plugin Registration

    /// 注册内置 plugin
    public func register(_ plugin: SessionPlugin) {
        guard plugin.initialize() else {
            NSLog("[PluginManager] Failed to initialize plugin: \(plugin.pluginId)")
            return
        }

        plugin.onSessionsUpdated = { [weak self] sessions in
            self?.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
        }

        plugin.onUrgentEvent = { [weak self] session, message, action in
            self?.handleUrgentEvent(session: session, message: message, action: action)
        }

        loadedPlugins[plugin.pluginId] = plugin
        NSLog("[PluginManager] Registered plugin: \(plugin.pluginId)")
    }

    /// 启动所有 plugins
    public func startAll() {
        for (pluginId, plugin) in loadedPlugins {
            if plugin.config.enabled {
                _ = plugin.start()  // Result intentionally unused
                NSLog("[PluginManager] Started plugin: \(pluginId)")
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
        let externalPlugins = dynamicLoader.loadAllPlugins()

        for plugin in externalPlugins {
            if plugin.initialize() {
                // 设置回调
                plugin.onSessionsUpdated = { [weak self] sessions in
                    self?.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
                }

                plugin.onUrgentEvent = { [weak self] session, message, action in
                    self?.handleUrgentEvent(session: session, message: message, action: action)
                }

                loadedPlugins[plugin.pluginId] = plugin
                NSLog("[PluginManager] Loaded external plugin: \(plugin.pluginId)")
            } else {
                NSLog("[PluginManager] Failed to initialize external plugin: \(plugin.pluginId)")
            }
        }
    }

    // MARK: - Session Management

    private func handleSessionsUpdated(pluginId: String, sessions: [PluginSession]) {
        DispatchQueue.main.async {
            // 移除该 plugin 的旧 sessions
            self.sessions.removeAll { $0.pluginId == pluginId }
            // 添加新 sessions
            self.sessions.append(contentsOf: sessions)
            // 标记加载完成
            self.isLoading = false
        }
    }

    private func handleUrgentEvent(session: PluginSession, message: String, action: String?) {
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

    // MARK: - Terminal Activation

    /// 激活 session 对应的终端
    public func activateTerminal(for session: PluginSession) {
        guard let plugin = loadedPlugins[session.pluginId] else { return }
        plugin.activateTerminal(for: session)
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