import Foundation

/// 紧急事件 (需要用户介入)
public struct UrgentEvent {
    /// 事件描述
    public let message: String

    /// 事件类型 (插件定义，如 "PermissionRequest", "NewMessage")
    public let eventType: String

    /// 操作按钮文本 (如 "Approve"，nil 表示仅展示)
    public let actionLabel: String?

    public init(message: String, eventType: String, actionLabel: String? = nil) {
        self.message = message
        self.eventType = eventType
        self.actionLabel = actionLabel
    }
}

/// 插件处理 hook 事件后返回的会话更新
public struct SessionUpdate {
    /// 要更新的会话 ID
    public let sessionId: String

    /// 新状态
    public var status: SessionStatus?

    /// 新副标题
    public var subtitle: String?

    /// 当前工具名
    public var toolName: String?

    /// 终端信息
    public var terminalInfo: TerminalInfo?

    /// 使用统计
    public var usage: UsageStats?

    /// 紧急事件 (若有)
    public var urgentEvent: UrgentEvent?

    public init(
        sessionId: String,
        status: SessionStatus? = nil,
        subtitle: String? = nil,
        toolName: String? = nil,
        terminalInfo: TerminalInfo? = nil,
        usage: UsageStats? = nil,
        urgentEvent: UrgentEvent? = nil
    ) {
        self.sessionId = sessionId
        self.status = status
        self.subtitle = subtitle
        self.toolName = toolName
        self.terminalInfo = terminalInfo
        self.usage = usage
        self.urgentEvent = urgentEvent
    }
}

/// 插件的 Hook 配置
public struct HookConfig {
    /// HTTP 监听端口 (nil 表示不需要 HTTP 监听)
    public let listenPort: UInt16?

    /// Bridge 脚本路径
    public let bridgeScript: String?

    /// 支持的事件类型列表
    public let eventTypes: [String]

    public init(listenPort: UInt16? = nil, bridgeScript: String? = nil, eventTypes: [String] = []) {
        self.listenPort = listenPort
        self.bridgeScript = bridgeScript
        self.eventTypes = eventTypes
    }
}
