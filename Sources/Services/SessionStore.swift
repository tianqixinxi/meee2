import Foundation
import SwiftUI
import Meee2PluginKit
import Combine

/// 会话数据 - 完整的会话信息模型
/// 兼容 csm 的 SessionData 格式
public struct SessionData: Codable, Identifiable {
    public var id: String { sessionId }

    // MARK: - 基本信息

    public let sessionId: String
    public var project: String              // 工作目录
    public var pid: Int?                    // Claude Code 进程 ID
    public var ghosttyTerminalId: String?   // Ghostty 终端 ID
    public var transcriptPath: String?      // Transcript JSONL 文件路径

    // MARK: - 时间信息

    public var startedAt: Date
    public var lastActivity: Date

    // MARK: - 状态信息

    public var status: String               // csm 兼容: idle, active, waiting, dead, completed
    public var detailedStatus: DetailedStatus
    public var currentTool: String?         // 当前工具名称
    public var description: String?         // 用户备注

    // MARK: - 任务追踪

    public var tasks: [SessionTask] = []
    public var currentTask: String?
    public var progress: String {
        let done = tasks.filter { $0.status == .done || $0.status == .completed }.count
        return "\(done)/\(tasks.count)"
    }

    // MARK: - 终端信息

    public var terminalInfo: PluginTerminalInfo?

    // MARK: - 使用统计

    public var usageStats: UsageStats?

    // MARK: - 最后消息

    public var lastMessage: String?          // 最后一条消息摘要

    // MARK: - 初始化

    public init(
        sessionId: String,
        project: String,
        pid: Int? = nil,
        ghosttyTerminalId: String? = nil,
        transcriptPath: String? = nil,
        startedAt: Date = Date(),
        lastActivity: Date = Date(),
        status: String = "idle",
        detailedStatus: DetailedStatus = .idle,
        currentTool: String? = nil,
        description: String? = nil,
        tasks: [SessionTask] = [],
        currentTask: String? = nil,
        terminalInfo: PluginTerminalInfo? = nil,
        usageStats: UsageStats? = nil,
        lastMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.project = project
        self.pid = pid
        self.ghosttyTerminalId = ghosttyTerminalId
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.status = status
        self.detailedStatus = detailedStatus
        self.currentTool = currentTool
        self.description = description
        self.tasks = tasks
        self.currentTask = currentTask
        self.terminalInfo = terminalInfo
        self.usageStats = usageStats
        self.lastMessage = lastMessage
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case project
        case pid
        case ghosttyTerminalId = "ghostty_terminal_id"
        case transcriptPath = "transcript_path"
        case startedAt = "started_at"
        case lastActivity = "last_activity"
        case status
        case detailedStatus = "detailed_status"
        case currentTool = "current_tool"
        case description
        case tasks
        case currentTask = "current_task"
        case terminalInfo = "terminal_info"
        case usageStats = "usage_stats"
        case lastMessage = "last_message"
    }

    /// 从 JSON 字典创建
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        sessionId = try container.decode(String.self, forKey: .sessionId)
        project = try container.decode(String.self, forKey: .project)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        ghosttyTerminalId = try container.decodeIfPresent(String.self, forKey: .ghosttyTerminalId)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)

        // 时间解析
        let startedAtStr = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        startedAt = ISO8601DateFormatter().date(from: startedAtStr) ?? Date()

        let lastActivityStr = try container.decodeIfPresent(String.self, forKey: .lastActivity) ?? ""
        lastActivity = ISO8601DateFormatter().date(from: lastActivityStr) ?? Date()

        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "idle"

        let detailedStatusStr = try container.decodeIfPresent(String.self, forKey: .detailedStatus) ?? "idle"
        detailedStatus = DetailedStatus.from(csmString: detailedStatusStr)

        currentTool = try container.decodeIfPresent(String.self, forKey: .currentTool)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tasks = try container.decodeIfPresent([SessionTask].self, forKey: .tasks) ?? []
        currentTask = try container.decodeIfPresent(String.self, forKey: .currentTask)
        terminalInfo = try container.decodeIfPresent(PluginTerminalInfo.self, forKey: .terminalInfo)
        usageStats = try container.decodeIfPresent(UsageStats.self, forKey: .usageStats)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
    }

    /// 编码为 JSON
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(project, forKey: .project)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(ghosttyTerminalId, forKey: .ghosttyTerminalId)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)

        let formatter = ISO8601DateFormatter()
        try container.encode(formatter.string(from: startedAt), forKey: .startedAt)
        try container.encode(formatter.string(from: lastActivity), forKey: .lastActivity)

        try container.encode(status, forKey: .status)
        try container.encode(detailedStatus.csmString, forKey: .detailedStatus)
        try container.encodeIfPresent(currentTool, forKey: .currentTool)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(tasks, forKey: .tasks)
        try container.encodeIfPresent(currentTask, forKey: .currentTask)
        try container.encodeIfPresent(terminalInfo, forKey: .terminalInfo)
        try container.encodeIfPresent(usageStats, forKey: .usageStats)
        try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
    }
}

// MARK: - 未读通知

/// 未读通知信息
public struct UnreadNotification: Codable {
    public let type: String
    public let message: String
    public let timestamp: Date

    public init(type: String, message: String, timestamp: Date = Date()) {
        self.type = type
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - SessionStore

/// 会话存储 - 管理会话数据的持久化
/// 数据存储在 ~/.meee2/sessions/ 目录
/// 作为单一数据源，GUI 和 CLI/TUI 都从这里读取
public class SessionStore: ObservableObject {
    public static let shared = SessionStore()

    // MARK: - 实时数据源 (订阅者自动更新)

    /// 所有会话 (内存中，实时更新)
    @Published public var sessions: [SessionData] = []

    // MARK: - 目录

    private let fileManager = FileManager.default
    private let baseDir: URL
    private let sessionsDir: URL
    private let queuesDir: URL
    private let unreadDir: URL

    // MARK: - 初始化

    private init() {
        let home = NSHomeDirectory()
        baseDir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        sessionsDir = baseDir.appendingPathComponent("sessions")
        queuesDir = baseDir.appendingPathComponent("queues")
        unreadDir = baseDir.appendingPathComponent("unread")

        // 确保目录存在
        try? fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: queuesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: unreadDir, withIntermediateDirectories: true)

        // 启动时加载已有数据
        loadAllSessions()
    }

    /// 从磁盘加载所有会话到内存
    private func loadAllSessions() {
        sessions = listAllFromDisk()
    }

    // MARK: - CRUD (内存 + 持久化)

    /// 创建会话 (自动更新 @Published sessions)
    public func create(_ session: SessionData) {
        saveToDisk(session)
        // 更新内存
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        MLog("[SessionStore] Created session: \(session.sessionId.prefix(8))")
    }

    /// 获取会话
    public func get(_ sessionId: String) -> SessionData? {
        sessions.first { $0.sessionId == sessionId }
    }

    /// 更新会话 (自动更新 @Published sessions)
    public func update(_ sessionId: String, _ changes: (inout SessionData) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        changes(&sessions[idx])
        sessions[idx].lastActivity = Date()
        saveToDisk(sessions[idx])
    }

    /// 删除会话 (自动更新 @Published sessions)
    public func delete(_ sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        deleteFromDisk(sessionId)

        // 同时删除队列和未读标记
        clearQueue(sessionId)
        clearUnread(sessionId)

        MLog("[SessionStore] Deleted session: \(sessionId.prefix(8))")
    }

    /// 更新或插入会话 (自动更新 @Published sessions)
    public func upsert(_ session: SessionData) {
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        saveToDisk(session)
    }

    /// 创建或更新会话 (兼容旧接口)
    public func createOrUpdate(_ session: SessionData) {
        upsert(session)
    }

    /// 检查会话是否存在
    public func exists(_ sessionId: String) -> Bool {
        sessions.contains { $0.sessionId == sessionId }
    }

    /// 列出所有会话 (从内存读取)
    public func listAll() -> [SessionData] {
        sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// 列出活跃会话（非 dead 和 completed）
    public func listActive() -> [SessionData] {
        sessions.filter { $0.status != "dead" && $0.status != "completed" }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// 从磁盘重新加载所有会话 (用于 CLI/TUI 同步 GUI 的更新)
    public func reloadFromDisk() {
        let newSessions = listAllFromDisk()
        sessions = newSessions
    }

    // MARK: - 未读通知

    /// 设置未读通知
    public func setUnread(_ sessionId: String, type: String, message: String) {
        let path = unreadDir.appendingPathComponent(sessionId)
        let notification = UnreadNotification(type: type, message: message)

        guard let data = try? JSONEncoder().encode(notification) else { return }
        try? data.write(to: path)
    }

    /// 获取未读通知
    public func getUnread(_ sessionId: String) -> UnreadNotification? {
        let path = unreadDir.appendingPathComponent(sessionId)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(UnreadNotification.self, from: data)
    }

    /// 清除未读通知
    public func clearUnread(_ sessionId: String) {
        let path = unreadDir.appendingPathComponent(sessionId)
        try? fileManager.removeItem(at: path)
    }

    // MARK: - 消息队列

    /// 入队消息
    public func enqueue(_ sessionId: String, message: String) -> Int {
        let path = queuePath(sessionId)

        // 追加消息
        guard let data = (message + "\n").data(using: .utf8) else { return 0 }
        if fileManager.fileExists(atPath: path.path) {
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: path)
        }

        return queueLength(sessionId)
    }

    /// 出队消息
    public func dequeue(_ sessionId: String) -> String? {
        let path = queuePath(sessionId)
        guard fileManager.fileExists(atPath: path.path) else { return nil }

        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        guard !lines.isEmpty else { return nil }

        let message = String(lines.removeFirst())

        // 写回剩余消息
        let remaining = lines.joined(separator: "\n")
        if remaining.isEmpty {
            try? fileManager.removeItem(at: path)
        } else {
            try? remaining.write(to: path, atomically: true, encoding: .utf8)
        }

        return message
    }

    /// 队列长度
    public func queueLength(_ sessionId: String) -> Int {
        let path = queuePath(sessionId)
        guard fileManager.fileExists(atPath: path.path) else { return 0 }
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return 0 }
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// 清空队列
    public func clearQueue(_ sessionId: String) {
        let path = queuePath(sessionId)
        try? fileManager.removeItem(at: path)
    }

    // MARK: - 进程存活检测

    /// 检查进程是否存活
    public static func processAlive(_ pid: Int?) -> Bool {
        guard let pid = pid else { return false }
        // 使用 signal 0 检查进程是否存在
        let result = kill(pid_t(pid), 0)
        return result == 0
    }

    // MARK: - 私有方法 (磁盘操作)

    private func sessionPath(_ sessionId: String) -> URL {
        sessionsDir.appendingPathComponent("\(sessionId).json")
    }

    private func queuePath(_ sessionId: String) -> URL {
        queuesDir.appendingPathComponent("\(sessionId).queue")
    }

    private func loadFromDisk(_ path: URL) -> SessionData? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(SessionData.self, from: data)
    }

    private func listAllFromDisk() -> [SessionData] {
        guard let files = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { loadFromDisk($0) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func saveToDisk(_ session: SessionData) {
        let path = sessionPath(session.sessionId)

        // 原子写入：先写临时文件，再重命名
        let tmpPath = path.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")

        guard let data = try? JSONEncoder().encode(session) else { return }

        do {
            try data.write(to: tmpPath)
            try? fileManager.removeItem(at: path)  // 删除旧文件
            try fileManager.moveItem(at: tmpPath, to: path)
        } catch {
            MLog("[SessionStore] Failed to save session: \(error)")
        }
    }

    private func deleteFromDisk(_ sessionId: String) {
        let path = sessionPath(sessionId)
        try? fileManager.removeItem(at: path)
    }
}

// MARK: - SessionData 转换

extension SessionData {
    /// 转换为 PluginSession (供 GUI 使用)
    public func toPluginSession(pluginId: String = "com.meee2.plugin.claude") -> PluginSession {
        PluginSession(
            id: sessionId,
            pluginId: pluginId,
            title: project,
            status: SessionStatus(rawValue: status) ?? .running,
            startedAt: startedAt,
            subtitle: currentTask,
            lastUpdated: lastActivity,
            toolName: currentTool,
            cwd: project,
            terminalInfo: terminalInfo,
            detailedStatus: detailedStatus,
            tasks: tasks,
            usageStats: usageStats,
            lastMessage: lastMessage
        )
    }
}