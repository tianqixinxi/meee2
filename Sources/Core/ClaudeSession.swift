import Foundation
import Meee2PluginKit

/// AI Session 数据模型
/// 支持多种 AI 助手（Claude, Cursor, Copilot 等）
public struct AISession: Identifiable, Codable, Hashable {
    // MARK: - 持久化字段 (从 JSON 文件读取)

    /// Session ID (UUID 格式)
    public let id: String

    /// 进程 ID
    public let pid: Int

    /// 工作目录
    public let cwd: String

    /// 启动时间 (毫秒时间戳)
    public let startedAt: Date

    /// Session 类型
    public var type: SessionType = .claude

    /// Session 类型描述 (interactive, etc.)
    public let kind: String

    /// 入口点 (cli, etc.)
    public let entrypoint: String

    // MARK: - 运行时状态 (非持久化，由 hooks 更新)

    /// 当前状态
    public var status: SessionStatus = .active

    /// 当前正在执行的任务描述
    public var currentTask: String?

    /// 最后更新时间
    public var lastUpdated: Date = Date()

    /// 当前使用的工具名称
    public var toolName: String?

    /// 进度百分比 (0-100)
    public var progress: Int?

    /// 错误信息
    public var errorMessage: String?

    // MARK: - 终端信息 (运行时状态)

    /// 终端 tty 设备
    public var tty: String?

    /// 终端程序名
    public var termProgram: String?

    /// 终端 Bundle ID
    public var termBundleId: String?

    /// cmux socket 路径 (用于 cmux 精确定位)
    public var cmuxSocketPath: String?

    /// cmux surface ID (用于 cmux tab 定位)
    public var cmuxSurfaceId: String?

    /// Ghostty 原生 terminal ID（AppleScript `id of terminal`），跳转优先用此字段
    public var ghosttyTerminalId: String?

    /// 最后活动时间戳 (用于清理过期 session)
    public var lastActivityTimestamp: Double?

    // MARK: - 计算属性

    /// 项目名称 (从 cwd 提取最后一级目录)
    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Session 运行时长
    public var duration: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    /// 格式化的运行时长
    public var formattedDuration: String {
        let duration = self.duration
        if duration < 60 {
            return String(format: "%.0fs", duration)
        } else if duration < 3600 {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            let hours = Int(duration / 3600)
            let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
            return String(format: "%dh %dm", hours, minutes)
        }
    }

    /// 是否活跃 (最近 5 分钟有更新)
    public var isActive: Bool {
        Date().timeIntervalSince(lastUpdated) < 300
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id = "sessionId"
        case pid
        case cwd
        case startedAt
        case type
        case kind
        case entrypoint
    }

    // MARK: - Initializers

    /// 普通初始化方法
    public init(
        id: String,
        pid: Int,
        cwd: String,
        startedAt: Date = Date(),
        type: SessionType = .claude,
        kind: String = "interactive",
        entrypoint: String = "cli",
        status: SessionStatus = .active,
        currentTask: String? = nil,
        toolName: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.startedAt = startedAt
        self.type = type
        self.kind = kind
        self.entrypoint = entrypoint
        self.status = status
        self.currentTask = currentTask
        self.toolName = toolName
        self.lastUpdated = Date()
    }

    /// Codable 初始化方法
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pid = try container.decode(Int.self, forKey: .pid)
        cwd = try container.decode(String.self, forKey: .cwd)

        // startedAt 可能是毫秒时间戳 (Int) 或秒时间戳 (Double)
        if let milliseconds = try? container.decode(Int.self, forKey: .startedAt) {
            startedAt = Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
        } else if let seconds = try? container.decode(Double.self, forKey: .startedAt) {
            startedAt = Date(timeIntervalSince1970: seconds)
        } else {
            startedAt = Date()
        }

        type = (try? container.decode(SessionType.self, forKey: .type)) ?? .claude
        kind = try container.decode(String.self, forKey: .kind)
        entrypoint = try container.decode(String.self, forKey: .entrypoint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pid, forKey: .pid)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(Int(startedAt.timeIntervalSince1970 * 1000), forKey: .startedAt)
        try container.encode(type, forKey: .type)
        try container.encode(kind, forKey: .kind)
        try container.encode(entrypoint, forKey: .entrypoint)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: AISession, rhs: AISession) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 扩展方法

public extension AISession {
    /// 更新终端信息
    func withTerminalInfo(tty: String?, termProgram: String?, termBundleId: String?, cmuxSocketPath: String?, cmuxSurfaceId: String?) -> AISession {
        var updated = self
        updated.tty = tty
        updated.termProgram = termProgram
        updated.termBundleId = termBundleId
        updated.cmuxSocketPath = cmuxSocketPath
        updated.cmuxSurfaceId = cmuxSurfaceId
        updated.lastActivityTimestamp = Date().timeIntervalSince1970
        return updated
    }

    /// 创建一个更新后的 session 副本 (保留终端信息)
    func withStatus(_ newStatus: SessionStatus, task: String? = nil, tool: String? = nil) -> AISession {
        var updated = self
        updated.status = newStatus
        updated.currentTask = task
        updated.toolName = tool
        updated.lastUpdated = Date()
        updated.lastActivityTimestamp = Date().timeIntervalSince1970
        return updated
    }
}

// MARK: - 向后兼容

/// 向后兼容的类型别名
public typealias ClaudeSession = AISession
