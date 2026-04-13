import Foundation
import SwiftUI

// MARK: - 权限决策

/// 权限请求的响应决策
public enum PermissionDecision {
    case allow
    case deny(reason: String?)
}

// MARK: - 紧急事件信息

/// 紧急事件信息 (需要用户介入)
public struct UrgentEventInfo: Identifiable {
    public let id: String
    /// 事件类型: "permission", "notification", "waitingInput"
    public let eventType: String
    /// 事件消息
    public let message: String
    /// 操作按钮标签 (如 "Approve", "Deny")
    public let actionLabel: String?
    /// 响应回调 (用于权限请求)
    public var respond: ((PermissionDecision) -> Void)?

    public init(
        id: String,
        eventType: String,
        message: String,
        actionLabel: String? = nil,
        respond: ((PermissionDecision) -> Void)? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.message = message
        self.actionLabel = actionLabel
        self.respond = respond
    }
}

// MARK: - Plugin Session

/// Plugin Session 数据模型
public struct PluginSession: Identifiable, Hashable {
    // MARK: - 必需字段

    /// 唯一标识 (建议格式: pluginId-sessionId)
    public let id: String

    /// 所属 Plugin ID
    public let pluginId: String

    /// 显示标题 (如项目名、文件名)
    public let title: String

    /// 当前状态
    public var status: SessionStatus

    /// 启动时间
    public let startedAt: Date

    // MARK: - 可选字段

    /// 副标题 (如任务描述、当前操作)
    public var subtitle: String?

    /// 最后更新时间
    public var lastUpdated: Date?

    /// 进度 (0-100)
    public var progress: Int?

    /// 错误信息
    public var errorMessage: String?

    /// 当前工具名称
    public var toolName: String?

    /// 工作目录
    public var cwd: String?

    // MARK: - 终端跳转

    public var terminalInfo: PluginTerminalInfo?

    // MARK: - UI 自定义

    /// 图标 (SF Symbol 名称，可选，默认用 plugin 图标)
    public var icon: String?

    /// 强调色 (可选，默认用 plugin 主题色)
    public var accentColor: Color?

    // MARK: - 紧急事件

    /// 紧急事件信息 (nil 表示无紧急事件)
    public var urgentEvent: UrgentEventInfo?

    // MARK: - 增强字段 (csm 兼容)

    /// 精细状态
    public var detailedStatus: DetailedStatus?

    /// 任务列表
    public var tasks: [SessionTask]?

    /// 使用统计
    public var usageStats: UsageStats?

    /// 最后消息摘要
    public var lastMessage: String?

    /// 进度描述 (如 "2/5")
    public var progressText: String? {
        guard let tasks = tasks, !tasks.isEmpty else { return nil }
        let done = tasks.filter { $0.status == .done || $0.status == .completed }.count
        return "\(done)/\(tasks.count)"
    }

    // MARK: - 初始化

    /// 完整初始化器 (包含所有字段)
    public init(
        id: String,
        pluginId: String,
        title: String,
        status: SessionStatus,
        startedAt: Date,
        subtitle: String? = nil,
        lastUpdated: Date? = nil,
        progress: Int? = nil,
        errorMessage: String? = nil,
        toolName: String? = nil,
        cwd: String? = nil,
        terminalInfo: PluginTerminalInfo? = nil,
        icon: String? = nil,
        accentColor: Color? = nil,
        urgentEvent: UrgentEventInfo? = nil,
        detailedStatus: DetailedStatus? = nil,
        tasks: [SessionTask]? = nil,
        usageStats: UsageStats? = nil,
        lastMessage: String? = nil
    ) {
        self.id = id
        self.pluginId = pluginId
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.subtitle = subtitle
        self.lastUpdated = lastUpdated
        self.progress = progress
        self.errorMessage = errorMessage
        self.toolName = toolName
        self.cwd = cwd
        self.terminalInfo = terminalInfo
        self.icon = icon
        self.accentColor = accentColor
        self.urgentEvent = urgentEvent
        self.detailedStatus = detailedStatus
        self.tasks = tasks
        self.usageStats = usageStats
        self.lastMessage = lastMessage
    }

    /// 向后兼容初始化器 (不含新增字段，用于旧插件)
    /// 注意：新字段 (detailedStatus, tasks, usageStats) 会设为 nil
    @_disfavoredOverload
    public init(
        id: String,
        pluginId: String,
        title: String,
        status: SessionStatus,
        startedAt: Date,
        subtitle: String? = nil,
        lastUpdated: Date? = nil,
        progress: Int? = nil,
        errorMessage: String? = nil,
        toolName: String? = nil,
        cwd: String? = nil,
        terminalInfo: PluginTerminalInfo? = nil,
        icon: String? = nil,
        accentColor: Color? = nil,
        urgentEvent: UrgentEventInfo? = nil
    ) {
        self.id = id
        self.pluginId = pluginId
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.subtitle = subtitle
        self.lastUpdated = lastUpdated
        self.progress = progress
        self.errorMessage = errorMessage
        self.toolName = toolName
        self.cwd = cwd
        self.terminalInfo = terminalInfo
        self.icon = icon
        self.accentColor = accentColor
        self.urgentEvent = urgentEvent
        self.detailedStatus = nil
        self.tasks = nil
        self.usageStats = nil
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pluginId)
        hasher.combine(title)
        hasher.combine(status)
        hasher.combine(startedAt)
        hasher.combine(subtitle)
        hasher.combine(cwd)
        hasher.combine(urgentEvent?.id)  // 添加 urgentEvent
    }

    public static func == (lhs: PluginSession, rhs: PluginSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.pluginId == rhs.pluginId &&
        lhs.title == rhs.title &&
        lhs.status == rhs.status &&
        lhs.subtitle == rhs.subtitle &&
        lhs.cwd == rhs.cwd &&
        lhs.urgentEvent?.id == rhs.urgentEvent?.id  // 添加 urgentEvent 比较
    }

    // MARK: - Computed

    /// 项目名称 (从 cwd 或 title 提取)
    public var projectName: String {
        if let cwd = cwd {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return title
    }

    /// 格式化运行时间
    public var formattedDuration: String {
        let duration = Date().timeIntervalSince(startedAt)
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

/// 终端跳转信息
public struct PluginTerminalInfo: Hashable, Codable {
    public var tty: String?
    public var termProgram: String?
    public var termBundleId: String?
    public var cmuxSocketPath: String?
    public var cmuxSurfaceId: String?

    /// 自定义跳转处理器 ID (由 plugin 注册)
    public var jumpHandlerId: String?

    public init(
        tty: String? = nil,
        termProgram: String? = nil,
        termBundleId: String? = nil,
        cmuxSocketPath: String? = nil,
        cmuxSurfaceId: String? = nil,
        jumpHandlerId: String? = nil
    ) {
        self.tty = tty
        self.termProgram = termProgram
        self.termBundleId = termBundleId
        self.cmuxSocketPath = cmuxSocketPath
        self.cmuxSurfaceId = cmuxSurfaceId
        self.jumpHandlerId = jumpHandlerId
    }
}