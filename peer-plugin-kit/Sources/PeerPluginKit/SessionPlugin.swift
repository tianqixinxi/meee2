import Foundation
import SwiftUI

/// Plugin 配置
public struct PluginConfig {
    /// 是否启用
    public var enabled: Bool = true

    /// 自定义配置 (plugin 自行解析)
    public var customSettings: [String: Any] = [:]

    public init(enabled: Bool = true, customSettings: [String: Any] = [:]) {
        self.enabled = enabled
        self.customSettings = customSettings
    }
}

/// Plugin 基类
/// 改为类而非协议，确保动态库加载时类型检查能正常工作
open class SessionPlugin: NSObject, ObservableObject {
    // MARK: - 标识

    /// Plugin 唯一标识 (反向域名格式，如 com.meee2.plugin.cursor)
    open var pluginId: String { "" }

    /// 显示名称
    open var displayName: String { "" }

    /// 图标 (SF Symbol)
    open var icon: String { "" }

    /// 主题色
    open var themeColor: Color { .blue }

    /// 版本
    open var version: String { "1.0.0" }

    /// 帮助文档链接 (Plugin 作者配置)
    open var helpUrl: String? { nil }

    // MARK: - 错误状态

    /// 是否有错误
    @Published open var hasError: Bool = false

    /// 最后的错误信息
    @Published open var lastError: String? = nil

    // MARK: - 配置

    /// 当前配置
    open var config: PluginConfig = PluginConfig()

    // MARK: - 回调

    /// Sessions 更新回调
    open var onSessionsUpdated: (([PluginSession]) -> Void)?

    /// 紧急事件回调 (需要用户介入)
    open var onUrgentEvent: ((PluginSession, String, String?) -> Void)?

    // MARK: - 生命周期

    /// 初始化 plugin (加载配置等)
    open func initialize() -> Bool { true }

    /// 启动监控
    open func start() -> Bool { false }

    /// 停止监控
    open func stop() {}

    /// 清理资源
    open func cleanup() {}

    // MARK: - Session 管理

    /// 获取当前所有 sessions
    open func getSessions() -> [PluginSession] { [] }

    /// 刷新 sessions
    open func refresh() {}

    // MARK: - 终端跳转

    /// 激活指定 session 的终端
    open func activateTerminal(for session: PluginSession) {}

    // MARK: - 配置 UI

    /// 配置视图 (显示在设置中)
    open var settingsView: AnyView? { nil }
}