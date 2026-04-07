import Foundation
import Combine
import SwiftUI
import PeerPluginKit

/// 插件注册中心
/// 替代原有的 PluginManager，管理所有 AI 插件的注册、生命周期和会话聚合
public class PluginRegistry: ObservableObject {
    public static let shared = PluginRegistry()

    // MARK: - Published

    /// 已注册的插件
    @Published public var plugins: [String: AIPlugin] = [:]

    /// 所有插件的会话聚合
    @Published public var allSessions: [Session] = []

    /// 是否正在加载
    @Published public var isLoading: Bool = true

    // MARK: - Private

    private let dynamicLoader = DynamicPluginLoader()
    private let pluginDirectory: URL

    // MARK: - Init

    private init() {
        pluginDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peer-island")
            .appendingPathComponent("plugins")
        try? FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 注册

    /// 注册内置插件
    public func registerBuiltin() {
        register(ClaudePlugin())
        // CursorPlugin 通过 loadExternalPlugins() 动态加载
        // (它编译为独立 .dylib，不能直接在 PeerIslandKit 中引用)
    }

    /// 注册单个插件
    public func register(_ plugin: AIPlugin) {
        guard plugin.initialize() else {
            NSLog("[PluginRegistry] Failed to initialize: \(plugin.pluginId)")
            return
        }

        plugin.onSessionsUpdated = { [weak self] sessions in
            self?.handleSessionsUpdated(pluginId: plugin.pluginId, sessions: sessions)
        }

        plugin.onUrgentEvent = { [weak self] session, event in
            self?.handleUrgentEvent(session: session, event: event)
        }

        plugins[plugin.pluginId] = plugin
        NSLog("[PluginRegistry] Registered: \(plugin.pluginId)")
    }

    /// 加载外部 .dylib 插件
    public func loadExternalPlugins() {
        // 旧 SessionPlugin 格式的外部插件暂时通过兼容层加载
        // TODO: Phase 6 时迁移外部插件到 AIPlugin
        isLoading = false
    }

    // MARK: - 生命周期

    public func startAll() {
        for (pluginId, plugin) in plugins where plugin.config.enabled {
            _ = plugin.start()
            NSLog("[PluginRegistry] Started: \(pluginId)")
        }
    }

    public func stopAll() {
        for plugin in plugins.values {
            plugin.stop()
        }
    }

    // MARK: - 终端跳转

    public func activateTerminal(for session: Session) {
        plugins[session.pluginId]?.activateTerminal(for: session)
    }

    // MARK: - 查询

    /// 获取插件信息
    public func getPluginInfo(for pluginId: String) -> (displayName: String, icon: String, themeColor: Color)? {
        guard let plugin = plugins[pluginId] else { return nil }
        return (plugin.displayName, plugin.icon, plugin.themeColor)
    }

    // MARK: - 内部

    private func handleSessionsUpdated(pluginId: String, sessions: [Session]) {
        DispatchQueue.main.async {
            self.allSessions.removeAll { $0.pluginId == pluginId }
            self.allSessions.append(contentsOf: sessions)
            self.allSessions.sort { $0.lastUpdated > $1.lastUpdated }
            self.isLoading = false

            // 通知 UI 更新状态栏
            NotificationCenter.default.post(name: NSNotification.Name("SessionsDidChange"), object: nil)
        }
    }

    private func handleUrgentEvent(session: Session, event: UrgentEvent) {
        // 通过 Notification 通知 SessionCoordinator
        NotificationCenter.default.post(
            name: .aiPluginUrgentEvent,
            object: nil,
            userInfo: [
                "session": session,
                "event": event
            ]
        )
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let aiPluginUrgentEvent = Notification.Name("aiPluginUrgentEvent")
}
