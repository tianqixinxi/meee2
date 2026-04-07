import Foundation
import SwiftUI

/// Plugin Session 数据模型 (已废弃，请使用 Session)
@available(*, deprecated, message: "Use Session instead")
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

    // MARK: - 初始化

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
        accentColor: Color? = nil
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
    }

    public static func == (lhs: PluginSession, rhs: PluginSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.pluginId == rhs.pluginId &&
        lhs.title == rhs.title &&
        lhs.status == rhs.status &&
        lhs.subtitle == rhs.subtitle &&
        lhs.cwd == rhs.cwd
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
public struct PluginTerminalInfo: Hashable {
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