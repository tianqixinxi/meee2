import Foundation
import SwiftUI
import Meee2PluginKit
import Combine

/// 会话数据 - 完整的会话信息模型
/// 兼容 csm 的 SessionData 格式
public struct SessionData: Codable, Identifiable {
    public var id: String { sessionId }

    // MARK: - Schema 版本

    /// 当前磁盘格式版本。新增迁移时 +1，永不回退。
    /// 早于 schemaVersion 引入的旧文件解码为 0，由 SessionStore 加载时自动迁移。
    public static let currentSchemaVersion: Int = 1

    /// 本条记录对应的 schema 版本。新建记录默认为 currentSchemaVersion；
    /// 磁盘上的旧文件会带着解码出的版本号进入内存，迁移完成后覆写。
    public var schemaVersion: Int = SessionData.currentSchemaVersion

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

    /// 会话状态（hook 驱动的权威值，统一 SessionStatus 枚举）
    public var status: SessionStatus
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

    // MARK: - 权限请求

    public var pendingPermissionTool: String?    // 待审批的工具名称
    public var pendingPermissionMessage: String? // 待审批的权限描述

    // MARK: - 初始化

    public init(
        sessionId: String,
        project: String,
        pid: Int? = nil,
        ghosttyTerminalId: String? = nil,
        transcriptPath: String? = nil,
        startedAt: Date = Date(),
        lastActivity: Date = Date(),
        status: SessionStatus = .idle,
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
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case project
        case pid
        case ghosttyTerminalId = "ghostty_terminal_id"
        case transcriptPath = "transcript_path"
        case startedAt = "started_at"
        case lastActivity = "last_activity"
        case status
        case detailedStatus = "detailed_status"  // 旧字段，读取时兼容
        case currentTool = "current_tool"
        case description
        case tasks
        case currentTask = "current_task"
        case terminalInfo = "terminal_info"
        case usageStats = "usage_stats"
        case lastMessage = "last_message"
        case pendingPermissionTool = "pending_permission_tool"
        case pendingPermissionMessage = "pending_permission_message"
    }

    /// 从 JSON 字典创建
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Schema 版本：缺失视为 0（pre-versioned 旧文件），由 SessionStore.loadFromDisk 负责迁移到当前版本
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0

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

        // 兼容旧文件：优先读 detailed_status，缺失回退到 status（并把旧 case 名迁移到新枚举）
        if let ds = try container.decodeIfPresent(String.self, forKey: .detailedStatus) {
            status = SessionStatus.from(rawString: ds)
        } else if let s = try container.decodeIfPresent(String.self, forKey: .status) {
            status = SessionStatus.from(rawString: s)
        } else {
            status = .idle
        }

        currentTool = try container.decodeIfPresent(String.self, forKey: .currentTool)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tasks = try container.decodeIfPresent([SessionTask].self, forKey: .tasks) ?? []
        currentTask = try container.decodeIfPresent(String.self, forKey: .currentTask)
        terminalInfo = try container.decodeIfPresent(PluginTerminalInfo.self, forKey: .terminalInfo)
        usageStats = try container.decodeIfPresent(UsageStats.self, forKey: .usageStats)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        pendingPermissionTool = try container.decodeIfPresent(String.self, forKey: .pendingPermissionTool)
        pendingPermissionMessage = try container.decodeIfPresent(String.self, forKey: .pendingPermissionMessage)
    }

    /// 编码为 JSON
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(project, forKey: .project)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(ghosttyTerminalId, forKey: .ghosttyTerminalId)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)

        let formatter = ISO8601DateFormatter()
        try container.encode(formatter.string(from: startedAt), forKey: .startedAt)
        try container.encode(formatter.string(from: lastActivity), forKey: .lastActivity)

        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(currentTool, forKey: .currentTool)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(tasks, forKey: .tasks)
        try container.encodeIfPresent(currentTask, forKey: .currentTask)
        try container.encodeIfPresent(terminalInfo, forKey: .terminalInfo)
        try container.encodeIfPresent(usageStats, forKey: .usageStats)
        try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try container.encodeIfPresent(pendingPermissionTool, forKey: .pendingPermissionTool)
        try container.encodeIfPresent(pendingPermissionMessage, forKey: .pendingPermissionMessage)
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
        let existed = sessions.contains(where: { $0.sessionId == session.sessionId })
        saveToDisk(session)
        // 更新内存
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        SessionEventBus.shared.publish(existed ? .sessionMetadataChanged(sessionId: session.sessionId) : .sessionAdded(sessionId: session.sessionId))
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
        SessionEventBus.shared.publish(.sessionMetadataChanged(sessionId: sessionId))
    }

    /// 删除会话 (自动更新 @Published sessions)
    public func delete(_ sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        deleteFromDisk(sessionId)

        // 同时删除队列和未读标记
        clearQueue(sessionId)
        clearUnread(sessionId)

        SessionEventBus.shared.publish(.sessionRemoved(sessionId: sessionId))
        MLog("[SessionStore] Deleted session: \(sessionId.prefix(8))")
    }

    /// 更新或插入会话 (自动更新 @Published sessions)
    /// **粘性字段保留**：ClaudePlugin 的 sync 路径会周期性用新建 SessionData 覆盖，
    /// 此时 ghosttyTerminalId / terminalInfo 常为 nil/空。若 store 里已有有效值，
    /// 保留旧值——这些是"累积发现"的元数据，不能被后续事件无意清零。
    public func upsert(_ session: SessionData) {
        var merged = session
        let existing = sessions.first(where: { $0.sessionId == session.sessionId })
        if let ex = existing {
            // Ghostty 原生 terminal id：只在 hook 里主动捕获过一次就该粘着
            if (merged.ghosttyTerminalId ?? "").isEmpty,
               let prev = ex.ghosttyTerminalId, !prev.isEmpty {
                merged.ghosttyTerminalId = prev
            }
            // terminalInfo：若 incoming 完全没有 tty/termProgram/cmuxSocket 就沿用旧的
            let ti = merged.terminalInfo
            let incomingEmpty = ti == nil ||
                ((ti?.tty ?? "").isEmpty &&
                 (ti?.termProgram ?? "").isEmpty &&
                 (ti?.cmuxSocketPath ?? "").isEmpty)
            if incomingEmpty, let prevInfo = ex.terminalInfo {
                merged.terminalInfo = prevInfo
            }
        }

        let existed = existing != nil
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = merged
        } else {
            sessions.append(merged)
        }
        saveToDisk(merged)
        SessionEventBus.shared.publish(existed ? .sessionMetadataChanged(sessionId: session.sessionId) : .sessionAdded(sessionId: session.sessionId))
    }

    /// 创建或更新会话 (兼容旧接口)
    public func createOrUpdate(_ session: SessionData) {
        upsert(session)
    }

    /// 检查会话是否存在
    public func exists(_ sessionId: String) -> Bool {
        sessions.contains { $0.sessionId == sessionId }
    }

    /// 列出所有会话 (从内存读取，按启动时间降序)
    public func listAll() -> [SessionData] {
        sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// 列出活跃会话（非 dead 和 completed，按启动时间降序）
    public func listActive() -> [SessionData] {
        sessions.filter { $0.status != .dead && $0.status != .completed }
            .sorted { $0.startedAt > $1.startedAt }
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
        guard var session = try? JSONDecoder().decode(SessionData.self, from: data) else { return nil }

        // 旧版本自动迁移：只在真正需要时触发，迁移完成后立刻覆写磁盘
        if session.schemaVersion < SessionData.currentSchemaVersion {
            let from = session.schemaVersion
            session = SessionDataMigrations.apply(to: session, from: from)
            MLog("[SessionStore] Migrated \(session.sessionId.prefix(8)) schema v\(from) → v\(SessionData.currentSchemaVersion)")
            saveToDisk(session)
        }
        return session
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

// MARK: - SessionData 迁移

/// 磁盘上的 `SessionData` 版本迁移器。每引入一次破坏性字段变更，
/// 在这里新增一段 vN→vN+1 的 step 并把 `currentSchemaVersion` +1。
/// 所有 step 应当满足：
///   - 幂等：对已经是目标版本的记录是 no-op；
///   - 不丢字段：保留旧字段的语义，哪怕只是为了 downgrade 容错；
///   - 纯函数：不触碰 store / 不做 I/O，仅修改传入的值。
enum SessionDataMigrations {

    /// 从 `from` 升级到 `SessionData.currentSchemaVersion`，沿途逐步迁移。
    static func apply(to session: SessionData, from: Int) -> SessionData {
        var s = session
        var v = max(0, from)
        while v < SessionData.currentSchemaVersion {
            s = step(s, from: v)
            v += 1
        }
        s.schemaVersion = SessionData.currentSchemaVersion
        return s
    }

    /// 单步迁移：从 v → v+1。新增 case 时记得同步 `SessionData.currentSchemaVersion`。
    private static func step(_ s: SessionData, from v: Int) -> SessionData {
        switch v {
        case 0:
            // v0 → v1：首次引入 `schema_version` 字段本身。
            // 旧文件的 `detailed_status` → `status` 映射已经由 `init(from:)` 处理，
            // 这里不需要额外改动数据；只是把版本号打上。
            return s
        default:
            return s
        }
    }
}

// MARK: - SessionData 转换

extension SessionData {
    /// 转换为 PluginSession (供 GUI 使用)。`status` 字段已经过
    /// `TranscriptStatusResolver` 解析，与 TUI / Board 同源。
    public func toPluginSession(pluginId: String = "com.meee2.plugin.claude") -> PluginSession {
        let resolvedStatus = TranscriptStatusResolver.resolve(for: self)
        NSLog("[StateTrace][pluginSession] sid=\(sessionId.prefix(8)) hook=\(status.rawValue) → resolved=\(resolvedStatus.rawValue) (for Island/StatusManager)")
        return PluginSession(
            id: sessionId,
            pluginId: pluginId,
            title: project,
            status: resolvedStatus,
            startedAt: startedAt,
            subtitle: currentTask,
            lastUpdated: lastActivity,
            toolName: currentTool,
            cwd: project,
            terminalInfo: terminalInfo,
            tasks: tasks,
            usageStats: usageStats,
            lastMessage: lastMessage
        )
    }
}
