import Foundation
import SwiftUI
import Meee2PluginKit
import Combine
import Meee2CommKit

/// 会话数据 - 完整的会话信息模型
/// 兼容 csm 的 SessionData 格式
public struct SessionData: Codable, Identifiable {
    public var id: String { sessionId }

    private static let dateFormatterLock = NSLock()
    private static let dateFormatter = ISO8601DateFormatter()

    private static func parseDate(_ string: String) -> Date? {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return dateFormatter.date(from: string)
    }

    private static func dateString(from date: Date) -> String {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return dateFormatter.string(from: date)
    }

    // MARK: - Schema 版本

    /// 当前磁盘格式版本。新增迁移时 +1，永不回退。
    /// 早于 schemaVersion 引入的旧文件解码为 0，由 SessionStore 加载时自动迁移。
    public static let currentSchemaVersion: Int = 4

    /// 本条记录对应的 schema 版本。新建记录默认为 currentSchemaVersion；
    /// 磁盘上的旧文件会带着解码出的版本号进入内存，迁移完成后覆写。
    public var schemaVersion: Int = SessionData.currentSchemaVersion

    /// Monotonic compare-and-swap revision used by the daemon and offline CLI
    /// so stale processes cannot overwrite newer session state.
    public var revision: UInt64 = 0

    // MARK: - 基本信息

    public let sessionId: String
    public var project: String              // 项目"显示名"——通常 = cwd 的 basename
    /// 完整的工作目录路径（hook 的 `cwd` 字段 / `aiSession.cwd`）。`project` 历史
    /// 上只是 basename，会丢路径信息——spawn / open-in-editor 这种需要全路径的
    /// 操作必须用这个字段。`nil` 表示老 session 还没收到带 cwd 的 hook，调用方
    /// 应该回落到 `project` 或拒绝操作。
    public var cwd: String?
    public var pid: Int?                    // Claude Code 进程 ID
    public var ghosttyTerminalId: String?   // Ghostty 终端 ID
    public var iTermSessionId: String?      // iTerm2 native per-tab UUID（$ITERM_SESSION_ID）
    public var appleTerminalSessionId: String?  // Apple Terminal per-tab UUID（$TERM_SESSION_ID）
    public var transcriptPath: String?      // Transcript JSONL 文件路径
    public var providerResumeSessionId: String? // Provider-native id usable with `codex resume` / `claude --resume`

    // MARK: - 时间信息

    public var startedAt: Date
    public var lastActivity: Date

    // MARK: - 状态信息

    /// 会话状态（hook 驱动的权威值，统一 SessionStatus 枚举）
    public var status: SessionStatus
    public var currentTool: String?         // 当前工具名称
    public var description: String?         // 用户备注
    public var generatedTitle: String?      // 首条用户消息异步生成的稳定语义标题

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
        cwd: String? = nil,
        pid: Int? = nil,
        ghosttyTerminalId: String? = nil,
        iTermSessionId: String? = nil,
        appleTerminalSessionId: String? = nil,
        transcriptPath: String? = nil,
        providerResumeSessionId: String? = nil,
        startedAt: Date = Date(),
        lastActivity: Date = Date(),
        status: SessionStatus = .idle,
        currentTool: String? = nil,
        description: String? = nil,
        generatedTitle: String? = nil,
        tasks: [SessionTask] = [],
        currentTask: String? = nil,
        terminalInfo: PluginTerminalInfo? = nil,
        usageStats: UsageStats? = nil,
        lastMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.project = project
        self.cwd = cwd
        self.pid = pid
        self.ghosttyTerminalId = ghosttyTerminalId
        self.iTermSessionId = iTermSessionId
        self.appleTerminalSessionId = appleTerminalSessionId
        self.transcriptPath = transcriptPath
        self.providerResumeSessionId = providerResumeSessionId
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.status = status
        self.currentTool = currentTool
        self.description = description
        self.generatedTitle = generatedTitle
        self.tasks = tasks
        self.currentTask = currentTask
        self.terminalInfo = terminalInfo
        self.usageStats = usageStats
        self.lastMessage = lastMessage
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case sessionId = "session_id"
        case project
        case cwd
        case pid
        case ghosttyTerminalId = "ghostty_terminal_id"
        case iTermSessionId = "iterm_session_id"
        case appleTerminalSessionId = "apple_terminal_session_id"
        case transcriptPath = "transcript_path"
        case providerResumeSessionId = "provider_resume_session_id"
        case startedAt = "started_at"
        case lastActivity = "last_activity"
        case status
        case detailedStatus = "detailed_status"  // 旧字段，读取时兼容
        case currentTool = "current_tool"
        case description
        case generatedTitle = "generated_title"
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
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0

        sessionId = try container.decode(String.self, forKey: .sessionId)
        project = try container.decode(String.self, forKey: .project)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        ghosttyTerminalId = try container.decodeIfPresent(String.self, forKey: .ghosttyTerminalId)
        iTermSessionId = try container.decodeIfPresent(String.self, forKey: .iTermSessionId)
        appleTerminalSessionId = try container.decodeIfPresent(String.self, forKey: .appleTerminalSessionId)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        providerResumeSessionId = try container.decodeIfPresent(String.self, forKey: .providerResumeSessionId)

        // 时间解析
        let startedAtStr = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        startedAt = Self.parseDate(startedAtStr) ?? Date()

        let lastActivityStr = try container.decodeIfPresent(String.self, forKey: .lastActivity) ?? ""
        lastActivity = Self.parseDate(lastActivityStr) ?? Date()

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
        generatedTitle = try container.decodeIfPresent(String.self, forKey: .generatedTitle)
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
        try container.encode(revision, forKey: .revision)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(project, forKey: .project)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(ghosttyTerminalId, forKey: .ghosttyTerminalId)
        try container.encodeIfPresent(iTermSessionId, forKey: .iTermSessionId)
        try container.encodeIfPresent(appleTerminalSessionId, forKey: .appleTerminalSessionId)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try container.encodeIfPresent(providerResumeSessionId, forKey: .providerResumeSessionId)

        try container.encode(Self.dateString(from: startedAt), forKey: .startedAt)
        try container.encode(Self.dateString(from: lastActivity), forKey: .lastActivity)

        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(currentTool, forKey: .currentTool)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(generatedTitle, forKey: .generatedTitle)
        try container.encode(tasks, forKey: .tasks)
        try container.encodeIfPresent(currentTask, forKey: .currentTask)
        try container.encodeIfPresent(terminalInfo, forKey: .terminalInfo)
        try container.encodeIfPresent(usageStats, forKey: .usageStats)
        try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try container.encodeIfPresent(pendingPermissionTool, forKey: .pendingPermissionTool)
        try container.encodeIfPresent(pendingPermissionMessage, forKey: .pendingPermissionMessage)
    }

    /// Copy this record to a recovered provider id while preserving the
    /// user-owned and accumulated metadata attached to the session.
    public func withSessionId(_ newSessionId: String) -> SessionData {
        var copy = SessionData(
            sessionId: newSessionId,
            project: project,
            cwd: cwd,
            pid: pid,
            ghosttyTerminalId: ghosttyTerminalId,
            iTermSessionId: iTermSessionId,
            appleTerminalSessionId: appleTerminalSessionId,
            transcriptPath: transcriptPath,
            providerResumeSessionId: providerResumeSessionId,
            startedAt: startedAt,
            lastActivity: lastActivity,
            status: status,
            currentTool: currentTool,
            description: description,
            generatedTitle: generatedTitle,
            tasks: tasks,
            currentTask: currentTask,
            terminalInfo: terminalInfo,
            usageStats: usageStats,
            lastMessage: lastMessage
        )
        copy.schemaVersion = schemaVersion
        copy.revision = 0
        copy.pendingPermissionTool = pendingPermissionTool
        copy.pendingPermissionMessage = pendingPermissionMessage
        return copy
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
    public static let shared = SessionStore(
        baseDirectory: StorageRoots.processDefault.baseDirectory
    )

    // MARK: - 实时数据源 (订阅者自动更新)

    /// 所有会话 (内存中，实时更新)
    @Published public var sessions: [SessionData] = []

    // MARK: - 目录

    private let fileManager: FileManager
    private let repository: SessionRepository
    public let baseDirectory: URL
    private let sessionsDir: URL
    private let queuesDir: URL
    private let unreadDir: URL
    private let perfLoggingEnabled = ProcessInfo.processInfo.environment["MEEE2_PERF_LOG"] == "1"

    // MARK: - 初始化

    public init(
        baseDirectory: URL = StorageRoots.processDefault.baseDirectory,
        fileManager: FileManager = .default
    ) {
        let base = baseDirectory.standardizedFileURL
        self.baseDirectory = base
        self.fileManager = fileManager
        repository = SessionRepository(baseDirectory: base, fileManager: fileManager)
        sessionsDir = base.appendingPathComponent("sessions", isDirectory: true)
        queuesDir = base.appendingPathComponent("queues", isDirectory: true)
        unreadDir = base.appendingPathComponent("unread", isDirectory: true)

        // 确保目录存在
        try? fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: queuesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: unreadDir, withIntermediateDirectories: true)

        // 启动时加载已有数据
        loadAllSessions()
    }

    /// 从磁盘加载所有会话到内存
    private func loadAllSessions() {
        sessions = waitForSessionRepository { [repository] in
            await repository.loadAll()
        }
    }

    // MARK: - CRUD (内存 + 持久化)

    /// 创建会话 (自动更新 @Published sessions)
    public func create(_ session: SessionData) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.create(session) }
            return
        }
        let existing = sessions.first(where: { $0.sessionId == session.sessionId })
        let existed = existing != nil
        var candidate = session
        if let existing { candidate.revision = existing.revision }
        guard let persisted = saveToDisk(candidate, rebasingFrom: existing) else { return }
        // 更新内存
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = persisted
        } else {
            sessions.append(persisted)
        }
        SessionEventBus.shared.publish(existed ? .sessionMetadataChanged(sessionId: session.sessionId) : .sessionAdded(sessionId: session.sessionId))
        MLog("[SessionStore] Created session: \(session.sessionId.prefix(8))")
    }

    /// 获取会话
    public func get(_ sessionId: String) -> SessionData? {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.get(sessionId) }
        }
        return sessions.first { $0.sessionId == sessionId }
    }

    /// 更新会话 (自动更新 @Published sessions)
    public func update(_ sessionId: String, _ changes: (inout SessionData) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.update(sessionId, changes) }
            return
        }
        update(sessionId, touchLastActivity: true, changes)
    }

    private func update(_ sessionId: String, touchLastActivity: Bool, _ changes: (inout SessionData) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        let previous = sessions[idx]
        var updated = previous
        changes(&updated)
        guard hasSessionChanged(previous, updated, allowLastActivityOnly: false) else {
            return
        }
        if touchLastActivity && updated.lastActivity == previous.lastActivity {
            updated.lastActivity = Date()
        }
        guard let persisted = saveToDisk(updated, rebasingFrom: previous) else { return }
        sessions[idx] = persisted
        SessionEventBus.shared.publish(.sessionMetadataChanged(sessionId: sessionId))
    }

    public func setProviderResumeSessionId(sessionId: String, providerResumeSessionId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync {
                self.setProviderResumeSessionId(
                    sessionId: sessionId,
                    providerResumeSessionId: providerResumeSessionId
                )
            }
            return
        }
        let trimmed = providerResumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentLaunchCommand.isLikelyProviderResumeSessionId(trimmed) else { return }
        update(sessionId, touchLastActivity: false) { session in
            session.providerResumeSessionId = trimmed
        }
    }

    /// 删除会话 (自动更新 @Published sessions)
    public func delete(_ sessionId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.delete(sessionId) }
            return
        }
        guard let existing = sessions.first(where: { $0.sessionId == sessionId }) else { return }
        guard deleteFromDisk(sessionId, expectedRevision: existing.revision) else { return }
        sessions.removeAll { $0.sessionId == sessionId }

        // 同时删除队列和未读标记
        clearQueue(sessionId)
        clearUnread(sessionId)

        SessionEventBus.shared.publish(.sessionRemoved(sessionId: sessionId))
        MLog("[SessionStore] Deleted session: \(sessionId.prefix(8))")
    }

    /// 将同一真实会话的本地记录迁移到恢复后的 provider-native id。
    ///
    /// 这条路径不同于 delete/create：它保留 notes、任务、终端绑定、队列和未读状态，
    /// 用于 Claude `--resume` 或 provider metadata 暴露出更准确 session id 的情况。
    @discardableResult
    public func rekeySession(_ oldSessionId: String, to newSessionId: String) -> Bool {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.rekeySession(oldSessionId, to: newSessionId) }
        }
        guard oldSessionId != newSessionId else {
            return exists(oldSessionId)
        }
        guard let oldSession = sessions.first(where: { $0.sessionId == oldSessionId }) else {
            return false
        }

        let existingTarget = sessions.first(where: { $0.sessionId == newSessionId })
        var recovered = existingTarget
            .map { Self.mergeContinuity(from: oldSession, into: $0) }
            ?? oldSession.withSessionId(newSessionId)
        if existingTarget == nil { recovered.revision = 0 }

        guard let persisted = saveToDisk(recovered, rebasingFrom: existingTarget) else { return false }
        sessions.removeAll { $0.sessionId == oldSessionId || $0.sessionId == newSessionId }
        sessions.append(persisted)
        guard deleteFromDisk(oldSessionId, expectedRevision: oldSession.revision) else {
            MLog("[SessionStore] Rekey retained stale source \(oldSessionId.prefix(8)); target is durable", level: .warning)
            return false
        }
        moveContinuitySidecars(from: oldSessionId, to: newSessionId)

        SessionEventBus.shared.publish(.sessionRemoved(sessionId: oldSessionId))
        SessionEventBus.shared.publish(existingTarget == nil ? .sessionAdded(sessionId: newSessionId) : .sessionMetadataChanged(sessionId: newSessionId))
        MLog("[SessionStore] Rekeyed session \(oldSessionId.prefix(8)) → \(newSessionId.prefix(8))")
        return true
    }

    /// 更新或插入会话 (自动更新 @Published sessions)
    /// **粘性字段保留**：ClaudePlugin 的 sync 路径会周期性用新建 SessionData 覆盖，
    /// 此时 ghosttyTerminalId / terminalInfo 常为 nil/空。若 store 里已有有效值，
    /// 保留旧值——这些是"累积发现"的元数据，不能被后续事件无意清零。
    public func upsert(_ session: SessionData) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.upsert(session) }
            return
        }
        var merged = session
        let existing = sessions.first(where: { $0.sessionId == session.sessionId })
        if let ex = existing {
            merged.revision = ex.revision
            // 全 cwd：hook event 不一定每次都带，merge 时也要 sticky
            if (merged.cwd ?? "").isEmpty,
               let prev = ex.cwd, !prev.isEmpty {
                merged.cwd = prev
            }
            // Ghostty 原生 terminal id：只在 hook 里主动捕获过一次就该粘着
            if (merged.ghosttyTerminalId ?? "").isEmpty,
               let prev = ex.ghosttyTerminalId, !prev.isEmpty {
                merged.ghosttyTerminalId = prev
            }
            // 同样的 sticky-empty 语义给 iTerm2 / Apple Terminal 的 native id
            if (merged.iTermSessionId ?? "").isEmpty,
               let prev = ex.iTermSessionId, !prev.isEmpty {
                merged.iTermSessionId = prev
            }
            if (merged.appleTerminalSessionId ?? "").isEmpty,
               let prev = ex.appleTerminalSessionId, !prev.isEmpty {
                merged.appleTerminalSessionId = prev
            }
            if (merged.providerResumeSessionId ?? "").isEmpty,
               let prev = ex.providerResumeSessionId, !prev.isEmpty {
                merged.providerResumeSessionId = prev
            }
            // Notes are user-authored metadata. Provider snapshots do not own
            // an absent description and must not erase an offline CLI note.
            if merged.description == nil {
                merged.description = ex.description
            }
            if merged.generatedTitle == nil {
                merged.generatedTitle = ex.generatedTitle
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
            // cmuxSurfaceId 单独 sticky:PID 扫描那条 update 会带 tty/termProgram
            // 但不带 surface id,于是上面的 incomingEmpty(只看 tty/termProgram/
            // cmuxSocket)判 false、保留 incoming,把 createSurface 设好的 surface
            // 洗掉。surface 一丢,Web UI 打开会话时原生终端 attach 不上 → 面板空白。
            // 所以这里给 surface id 也加 sticky-empty 语义,单独保住。
            if (merged.terminalInfo?.cmuxSurfaceId ?? "").isEmpty,
               let prevSurface = ex.terminalInfo?.cmuxSurfaceId, !prevSurface.isEmpty {
                if merged.terminalInfo == nil {
                    merged.terminalInfo = ex.terminalInfo
                } else {
                    merged.terminalInfo?.cmuxSurfaceId = prevSurface
                }
            }
        }

        let existed = existing != nil
        if let existing = existing,
           !hasSessionChanged(existing, merged, allowLastActivityOnly: false) {
            return
        }
        guard let persisted = saveToDisk(merged, rebasingFrom: existing) else { return }
        if let idx = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[idx] = persisted
        } else {
            sessions.append(persisted)
        }
        SessionEventBus.shared.publish(existed ? .sessionMetadataChanged(sessionId: session.sessionId) : .sessionAdded(sessionId: session.sessionId))
    }

    /// 创建或更新会话 (兼容旧接口)
    public func createOrUpdate(_ session: SessionData) {
        upsert(session)
    }

    /// 检查会话是否存在
    public func exists(_ sessionId: String) -> Bool {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.exists(sessionId) }
        }
        return sessions.contains { $0.sessionId == sessionId }
    }

    /// 列出所有会话 (从内存读取，按启动时间降序)
    public func listAll() -> [SessionData] {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.listAll() }
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// 列出活跃会话（非 dead 和 completed，按启动时间降序）
    public func listActive() -> [SessionData] {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.listActive() }
        }
        return sessions.filter { $0.status != .dead && $0.status != .completed }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// 从磁盘重新加载所有会话 (用于 CLI/TUI 同步 GUI 的更新)
    public func reloadFromDisk() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.reloadFromDisk() }
            return
        }
        let newSessions = listAllFromDisk()
        sessions = newSessions
    }

    /// 清空内存中所有 session、queue、unread 缓存。
    /// 仅在 Settings → Privacy 的"删除本地数据"流程里调用——
    /// 磁盘文件由 SystemStorageAPI 删除，这里负责让 SwiftUI/@Published
    /// 订阅者（Island / Web Board / TUI）立刻看到空状态，避免运行中
    /// 的 UI 继续显示已被删除的 session 并把脏数据回写到 `~/.meee2`。
    ///
    /// 注意：这只清内存——磁盘删除责任在调用方。每条 session 单独发
    /// `.sessionRemoved` 事件以触发现有订阅链路（BoardServer 等）。
    public func clearAllInMemory() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.clearAllInMemory() }
            return
        }
        let removedIds = sessions.map { $0.sessionId }
        sessions = []
        for sid in removedIds {
            // 文件层的 queue/unread 已经被磁盘 wipe 一并清掉，这里调用
            // clearQueue/clearUnread 是 idempotent no-op（文件已不存在）。
            SessionEventBus.shared.publish(.sessionRemoved(sessionId: sid))
        }
        MLog("[SessionStore] clearAllInMemory: removed \(removedIds.count) sessions from memory")
    }

    // MARK: - 未读通知

    /// 设置未读通知
    public func setUnread(_ sessionId: String, type: String, message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.setUnread(sessionId, type: type, message: message) }
            return
        }
        let path = unreadDir.appendingPathComponent(sessionId)
        let notification = UnreadNotification(type: type, message: message)

        guard let data = try? JSONEncoder().encode(notification) else { return }
        try? data.write(to: path, options: .atomic)
    }

    /// 获取未读通知
    public func getUnread(_ sessionId: String) -> UnreadNotification? {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.getUnread(sessionId) }
        }
        let path = unreadDir.appendingPathComponent(sessionId)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(UnreadNotification.self, from: data)
    }

    /// 清除未读通知
    public func clearUnread(_ sessionId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.clearUnread(sessionId) }
            return
        }
        let path = unreadDir.appendingPathComponent(sessionId)
        try? fileManager.removeItem(at: path)
    }

    // MARK: - 消息队列

    /// 入队消息
    public func enqueue(_ sessionId: String, message: String) -> Int {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.enqueue(sessionId, message: message) }
        }
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
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.dequeue(sessionId) }
        }
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
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.queueLength(sessionId) }
        }
        let path = queuePath(sessionId)
        guard fileManager.fileExists(atPath: path.path) else { return 0 }
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return 0 }
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// 清空队列
    public func clearQueue(_ sessionId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.clearQueue(sessionId) }
            return
        }
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

    private func unreadPath(_ sessionId: String) -> URL {
        unreadDir.appendingPathComponent(sessionId)
    }

    private static func mergeContinuity(from old: SessionData, into target: SessionData) -> SessionData {
        var merged = target

        if (merged.cwd ?? "").isEmpty { merged.cwd = old.cwd }
        if merged.pid == nil { merged.pid = old.pid }
        if (merged.ghosttyTerminalId ?? "").isEmpty { merged.ghosttyTerminalId = old.ghosttyTerminalId }
        if (merged.iTermSessionId ?? "").isEmpty { merged.iTermSessionId = old.iTermSessionId }
        if (merged.appleTerminalSessionId ?? "").isEmpty { merged.appleTerminalSessionId = old.appleTerminalSessionId }
        if (merged.transcriptPath ?? "").isEmpty { merged.transcriptPath = old.transcriptPath }
        if (merged.providerResumeSessionId ?? "").isEmpty { merged.providerResumeSessionId = old.providerResumeSessionId }
        if merged.description == nil { merged.description = old.description }
        if merged.generatedTitle == nil { merged.generatedTitle = old.generatedTitle }
        if merged.tasks.isEmpty { merged.tasks = old.tasks }
        if merged.currentTask == nil { merged.currentTask = old.currentTask }
        if merged.terminalInfo == nil { merged.terminalInfo = old.terminalInfo }
        if merged.usageStats == nil { merged.usageStats = old.usageStats }
        if merged.lastMessage == nil { merged.lastMessage = old.lastMessage }
        if merged.currentTool == nil { merged.currentTool = old.currentTool }
        if merged.pendingPermissionTool == nil { merged.pendingPermissionTool = old.pendingPermissionTool }
        if merged.pendingPermissionMessage == nil { merged.pendingPermissionMessage = old.pendingPermissionMessage }
        if merged.startedAt > old.startedAt { merged.startedAt = old.startedAt }

        return merged
    }

    private func moveContinuitySidecars(from oldSessionId: String, to newSessionId: String) {
        moveOrMergeFile(from: queuePath(oldSessionId), to: queuePath(newSessionId), append: true)
        moveOrMergeFile(from: unreadPath(oldSessionId), to: unreadPath(newSessionId), append: false)
    }

    private func moveOrMergeFile(from source: URL, to target: URL, append: Bool) {
        guard fileManager.fileExists(atPath: source.path) else { return }

        if fileManager.fileExists(atPath: target.path) {
            if append,
               let sourceData = try? Data(contentsOf: source),
               let handle = try? FileHandle(forWritingTo: target) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data("\n".utf8))
                handle.write(sourceData)
            }
            try? fileManager.removeItem(at: source)
            return
        }

        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            MLog("[SessionStore] Failed to move continuity sidecar \(source.lastPathComponent): \(error)")
        }
    }

    private func listAllFromDisk() -> [SessionData] {
        waitForSessionRepository { [repository] in
            await repository.loadAll()
        }
    }

    @discardableResult
    private func saveToDisk(_ session: SessionData, rebasingFrom baseline: SessionData?) -> SessionData? {
        let started = Date()
        let originalCandidate = session
        var candidate = session

        // Cross-process writers can advance the revision between GUI events.
        // Rebase the original field delta onto the authoritative disk record
        // and retry a bounded number of times instead of leaving memory stale
        // until restart. A future schema still loads as nil and stays read-only.
        for attempt in 0..<3 {
            if let persisted = waitForSessionRepository({ [repository] in
                await repository.save(candidate)
            }) {
                let bytes = (try? JSONEncoder().encode(persisted).count) ?? 0
                perfLog(
                    "saveToDisk",
                    started: started,
                    extra: "sid=\(session.sessionId.prefix(8)),bytes=\(bytes),attempt=\(attempt + 1)"
                )
                return persisted
            }

            guard let baseline,
                  baseline.sessionId == session.sessionId,
                  let latest = waitForSessionRepository({ [repository] in
                      await repository.load(sessionId: session.sessionId)
                  }),
                  latest.revision != candidate.revision else {
                return nil
            }

            candidate = rebaseSessionChanges(originalCandidate, from: baseline, onto: latest)
            candidate.revision = latest.revision
            if !hasSessionChanged(latest, candidate, allowLastActivityOnly: true) {
                return latest
            }
            MLog(
                "[SessionStore] Rebasing stale session \(session.sessionId.prefix(8)) "
                    + "onto r\(latest.revision) (attempt \(attempt + 2)/3)",
                level: .warning
            )
        }
        return nil
    }

    private func rebaseSessionChanges(
        _ candidate: SessionData,
        from baseline: SessionData,
        onto latest: SessionData
    ) -> SessionData {
        var rebased = latest
        if candidate.schemaVersion != baseline.schemaVersion { rebased.schemaVersion = candidate.schemaVersion }
        if candidate.project != baseline.project { rebased.project = candidate.project }
        if candidate.cwd != baseline.cwd { rebased.cwd = candidate.cwd }
        if candidate.pid != baseline.pid { rebased.pid = candidate.pid }
        if candidate.ghosttyTerminalId != baseline.ghosttyTerminalId {
            rebased.ghosttyTerminalId = candidate.ghosttyTerminalId
        }
        if candidate.iTermSessionId != baseline.iTermSessionId { rebased.iTermSessionId = candidate.iTermSessionId }
        if candidate.appleTerminalSessionId != baseline.appleTerminalSessionId {
            rebased.appleTerminalSessionId = candidate.appleTerminalSessionId
        }
        if candidate.transcriptPath != baseline.transcriptPath { rebased.transcriptPath = candidate.transcriptPath }
        if candidate.providerResumeSessionId != baseline.providerResumeSessionId {
            rebased.providerResumeSessionId = candidate.providerResumeSessionId
        }
        if candidate.startedAt != baseline.startedAt { rebased.startedAt = candidate.startedAt }
        if candidate.lastActivity != baseline.lastActivity { rebased.lastActivity = candidate.lastActivity }
        if candidate.status != baseline.status { rebased.status = candidate.status }
        if candidate.currentTool != baseline.currentTool { rebased.currentTool = candidate.currentTool }
        if candidate.description != baseline.description { rebased.description = candidate.description }
        if candidate.generatedTitle != baseline.generatedTitle { rebased.generatedTitle = candidate.generatedTitle }
        if candidate.tasks != baseline.tasks { rebased.tasks = candidate.tasks }
        if candidate.currentTask != baseline.currentTask { rebased.currentTask = candidate.currentTask }
        if candidate.terminalInfo != baseline.terminalInfo { rebased.terminalInfo = candidate.terminalInfo }
        if candidate.usageStats != baseline.usageStats { rebased.usageStats = candidate.usageStats }
        if candidate.lastMessage != baseline.lastMessage { rebased.lastMessage = candidate.lastMessage }
        if candidate.pendingPermissionTool != baseline.pendingPermissionTool {
            rebased.pendingPermissionTool = candidate.pendingPermissionTool
        }
        if candidate.pendingPermissionMessage != baseline.pendingPermissionMessage {
            rebased.pendingPermissionMessage = candidate.pendingPermissionMessage
        }
        return rebased
    }

    private func hasSessionChanged(
        _ old: SessionData,
        _ new: SessionData,
        allowLastActivityOnly: Bool
    ) -> Bool {
        if old.schemaVersion != new.schemaVersion { return true }
        if old.sessionId != new.sessionId { return true }
        if old.project != new.project { return true }
        if old.cwd != new.cwd { return true }
        if old.pid != new.pid { return true }
        if old.ghosttyTerminalId != new.ghosttyTerminalId { return true }
        if old.iTermSessionId != new.iTermSessionId { return true }
        if old.appleTerminalSessionId != new.appleTerminalSessionId { return true }
        if old.transcriptPath != new.transcriptPath { return true }
        if old.providerResumeSessionId != new.providerResumeSessionId { return true }
        if old.startedAt != new.startedAt { return true }
        if old.status != new.status { return true }
        if old.currentTool != new.currentTool { return true }
        if old.description != new.description { return true }
        if old.generatedTitle != new.generatedTitle { return true }
        if old.tasks != new.tasks { return true }
        if old.currentTask != new.currentTask { return true }
        if old.terminalInfo != new.terminalInfo { return true }
        if old.usageStats != new.usageStats { return true }
        if old.lastMessage != new.lastMessage { return true }
        if old.pendingPermissionTool != new.pendingPermissionTool { return true }
        if old.pendingPermissionMessage != new.pendingPermissionMessage { return true }
        return allowLastActivityOnly && old.lastActivity != new.lastActivity
    }

    private func perfLog(_ name: String, started: Date, extra: String = "") {
        guard perfLoggingEnabled else { return }
        let ms = Date().timeIntervalSince(started) * 1_000
        let suffix = extra.isEmpty ? "" : " \(extra)"
        MLog(String(format: "[Perf][SessionStore] %@ %.1fms%@", name, ms, suffix))
    }

    private func deleteFromDisk(_ sessionId: String, expectedRevision: UInt64) -> Bool {
        waitForSessionRepository { [repository] in
            await repository.delete(sessionId: sessionId, expectedRevision: expectedRevision)
        }
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
        case 1:
            // v1 → v2：新增 `provider_resume_session_id` 长期恢复锚点。
            // 旧记录没有这个字段；后续由 terminal store 或 Codex jsonl backfill 补齐。
            return s
        case 2:
            // v2 → v3：新增跨进程 revision CAS。旧记录从 revision 0 开始，
            // 首次迁移持久化后由 SessionRepository 提升到 revision 1。
            return s
        case 3:
            // v3 → v4：新增 generated_title。旧记录保持 nil；只为新启动且
            // 带首条用户 prompt 的 session 异步生成。
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
        // 这里以前每条 PluginSession 重建都打一行——Island/StatusManager 拿
        // 状态会把它打上千次/秒。需要 trace 时去 resolver 内部 uncached path
        // 的日志看（那里才是真有信息的转折点）。
        return PluginSession(
            id: sessionId,
            pluginId: pluginId,
            title: project,
            status: resolvedStatus,
            startedAt: startedAt,
            subtitle: currentTask,
            lastUpdated: lastActivity,
            toolName: currentTool,
            cwd: cwd ?? project,
            terminalInfo: terminalInfo,
            tasks: tasks,
            usageStats: usageStats,
            lastMessage: lastMessage
        )
    }
}
