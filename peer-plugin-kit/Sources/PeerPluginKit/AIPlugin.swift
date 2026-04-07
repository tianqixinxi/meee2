import Foundation
import SwiftUI

/// AI 插件基类
/// 每个 AI 助手（Claude、Cursor、Copilot 等）实现此类
/// 使用类而非协议，以确保 dlopen 动态加载时类型检查正常工作
open class AIPlugin: NSObject, ObservableObject {
    // MARK: - 身份

    /// 插件唯一标识 (反向域名格式，如 com.peerisland.claude)
    open var pluginId: String { "" }

    /// 显示名称
    open var displayName: String { "" }

    /// 图标 (SF Symbol)
    open var icon: String { "" }

    /// 主题色
    open var themeColor: Color { .blue }

    /// 版本
    open var version: String { "1.0.0" }

    /// 帮助文档链接
    open var helpUrl: String? { nil }

    // MARK: - 错误状态

    /// 是否有错误
    @Published open var hasError: Bool = false

    /// 最后的错误信息
    @Published open var lastError: String? = nil

    // MARK: - 配置

    /// 当前配置
    open var config: PluginConfig = PluginConfig()

    // MARK: - 回调 (由核心层设置)

    /// 会话列表更新回调
    open var onSessionsUpdated: (([Session]) -> Void)?

    /// 紧急事件回调
    open var onUrgentEvent: ((Session, UrgentEvent) -> Void)?

    // MARK: - 生命周期

    /// 初始化插件 (加载配置，验证依赖)
    open func initialize() -> Bool { true }

    /// 启动监控
    open func start() -> Bool { false }

    /// 停止监控
    open func stop() {}

    /// 清理资源
    open func cleanup() {}

    // MARK: - 会话发现

    /// 获取当前所有会话
    open func getSessions() -> [Session] { [] }

    /// 刷新会话状态 (定期调用或事件触发)
    open func refresh() {}

    // MARK: - 状态映射

    /// 将插件原生状态字符串映射到统一 SessionStatus
    /// 默认实现：非空返回 .active
    open func mapStatus(_ nativeStatus: String) -> SessionStatus {
        nativeStatus.isEmpty ? .idle : .active
    }

    // MARK: - Hook 系统 (插件拥有自己的 hook 体系)

    /// 处理原始 hook 事件
    /// 插件解释 payload 并返回 SessionUpdate
    open func handleHookEvent(_ payload: [String: Any]) -> SessionUpdate? { nil }

    /// 返回插件的 hook 配置
    /// 无 hook 需求的插件（如 Cursor 用轮询）返回 nil
    open func hookConfiguration() -> HookConfig? { nil }

    // MARK: - 终端跳转 (插件实现，可使用 TerminalManager 共享工具)

    /// 激活指定会话的终端/IDE
    open func activateTerminal(for session: Session) {}

    // MARK: - 设置 UI

    /// 设置视图 (显示在设置面板中)
    open var settingsView: AnyView? { nil }
}
