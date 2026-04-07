import Foundation
import SwiftUI

/// 统一会话模型
/// 替代原有的 AISession (Claude 专用) 和 PluginSession (插件专用)
public struct Session: Identifiable, Hashable, Codable {
    // MARK: - 身份

    /// 全局唯一 ID，格式: "{pluginId}:{localId}"
    public let id: String

    /// 所属插件 ID
    public let pluginId: String

    // MARK: - 显示

    /// 显示标题 (项目名)
    public var title: String

    /// 副标题 (当前操作/最后消息)
    public var subtitle: String?

    // MARK: - 状态

    /// 统一状态
    public var status: SessionStatus

    /// 插件原始状态字符串 (调试用)
    public var nativeStatus: String?

    // MARK: - 时间

    /// 启动时间
    public let startedAt: Date

    /// 最后更新时间
    public var lastUpdated: Date

    // MARK: - 进程

    /// 进程 ID (并非所有 AI 都有)
    public var pid: Int?

    /// 工作目录
    public var cwd: String?

    // MARK: - 工具

    /// 当前使用的工具名称
    public var toolName: String?

    // MARK: - 终端

    /// 终端跳转信息
    public var terminalInfo: TerminalInfo?

    // MARK: - 统计

    /// 使用统计 (tokens/cost)
    public var usage: UsageStats?

    /// 进度 (0-100)
    public var progress: Int?

    // MARK: - 错误

    /// 错误信息
    public var errorMessage: String?

    // MARK: - UI 覆写

    /// 图标覆写 (SF Symbol)
    public var iconOverride: String?

    /// 颜色覆写 (hex)
    public var colorOverride: String?

    // MARK: - 初始化

    public init(
        id: String,
        pluginId: String,
        title: String,
        status: SessionStatus = .idle,
        nativeStatus: String? = nil,
        startedAt: Date = Date(),
        lastUpdated: Date = Date(),
        subtitle: String? = nil,
        pid: Int? = nil,
        cwd: String? = nil,
        toolName: String? = nil,
        terminalInfo: TerminalInfo? = nil,
        usage: UsageStats? = nil,
        progress: Int? = nil,
        errorMessage: String? = nil,
        iconOverride: String? = nil,
        colorOverride: String? = nil
    ) {
        self.id = id
        self.pluginId = pluginId
        self.title = title
        self.status = status
        self.nativeStatus = nativeStatus
        self.startedAt = startedAt
        self.lastUpdated = lastUpdated
        self.subtitle = subtitle
        self.pid = pid
        self.cwd = cwd
        self.toolName = toolName
        self.terminalInfo = terminalInfo
        self.usage = usage
        self.progress = progress
        self.errorMessage = errorMessage
        self.iconOverride = iconOverride
        self.colorOverride = colorOverride
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.subtitle == rhs.subtitle &&
        lhs.toolName == rhs.toolName &&
        lhs.lastUpdated == rhs.lastUpdated &&
        lhs.progress == rhs.progress
    }

    // MARK: - Computed

    /// 项目名称 (从 cwd 提取目录名)
    public var projectName: String {
        if let cwd = cwd {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return title
    }

    /// 是否正在活跃
    public var isActive: Bool {
        status.isWorking
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
            let minutes = Int((duration - TimeInterval(hours * 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}
