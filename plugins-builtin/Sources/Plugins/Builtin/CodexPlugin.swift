import Foundation
import SwiftUI
import Meee2PluginKit

class CodexPlugin: SessionPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.meee2.plugin.codex" }
    override var displayName: String { "Codex" }
    override var icon: String { "cpu.fill" }
    override var themeColor: Color { .purple }
    override var version: String { "0.1.0" }
    override var helpUrl: String? { "https://github.com/openai/codex" }

    // MARK: - Private

    private var isRunning = false
    private var refreshTimer: Timer?

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash

    // 刷新间隔（秒）- 可通过 AppStorage 配置
    @AppStorage("codexRefreshInterval") private var refreshInterval: Double = 10.0

    // Codex 数据库路径（可配置）
    @AppStorage("codexDatabasePath") private var databasePathString: String = ""

    // 默认路径
    private var defaultDatabasePath: URL {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".codex")
            .appendingPathComponent("sqlite")
            .appendingPathComponent("codex-dev.db")
    }

    // 实际使用的路径
    private var codexDatabasePath: URL {
        if databasePathString.isEmpty {
            return defaultDatabasePath
        }
        return URL(fileURLWithPath: databasePathString)
    }

    // 活跃时间阈值（秒）- session 更新时间在此阈值内视为活跃
    private let activeThreshold: TimeInterval = 3600  // 1小时

    // MARK: - Lifecycle

    override func initialize() -> Bool {
        // 检查数据库文件是否存在
        guard FileManager.default.fileExists(atPath: codexDatabasePath.path) else {
            NSLog("[CodexPlugin] Database not found: \(codexDatabasePath.path)")
            hasError = true
            lastError = "Codex database not found at ~/.codex/sqlite/codex-dev.db"
            return true  // 仍然返回 true，让用户可以配置路径
        }
        hasError = false
        lastError = nil
        return true
    }

    override func start() -> Bool {
        guard !isRunning else { return true }

        isRunning = true

        // 初始加载
        let sessions = getSessions()
        for session in sessions {
            if let lastMessage = session.lastMessage {
                lastMessages[session.id] = lastMessage
            }
        }
        onSessionsUpdated?(sessions)

        // 启动定时器
        startTimer()

        NSLog("[CodexPlugin] Started, watching: \(codexDatabasePath.path), interval: \(refreshInterval)s")
        return true
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func stop() {
        isRunning = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        NSLog("[CodexPlugin] Stopped")
    }

    override func cleanup() {
        stop()
    }

    // MARK: - Session Management

    override func getSessions() -> [PluginSession] {
        scanCodexDatabase()
    }

    override func refresh() {
        let sessions = getSessions()
        NSLog("[CodexPlugin] Refresh: found \(sessions.count) sessions")

        // 检测新消息
        for session in sessions {
            let newMessage = session.lastMessage
            let previousMessage = lastMessages[session.id]

            if let msg = newMessage, previousMessage != msg {
                if previousMessage != nil {
                    NSLog("[CodexPlugin] *** TRIGGERING URGENT EVENT for \(session.title): \(msg.prefix(50))...")
                    onUrgentEvent?(session, msg, nil)
                }
                lastMessages[session.id] = msg
            }
        }

        onSessionsUpdated?(sessions)
    }

    // MARK: - Terminal

    override func activateTerminal(for session: PluginSession) {
        // 打开 Codex TUI 或者终端中的 codex 会话
        // Codex 通常在终端中运行，尝试打开终端并运行 codex
        let script = """
        tell application "Terminal"
            activate
            do script "codex"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[CodexPlugin] Terminal launch error: \(error)")
                // 尝试直接打开终端
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", "Terminal"]
                try? task.run()
            } else {
                NSLog("[CodexPlugin] Launched Codex in Terminal")
            }
        }

        // 或者如果 cwd 存在，打开那个目录
        if let cwd = session.cwd {
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = [cwd]
            try? task.run()
        }
    }

    // MARK: - Urgent Event

    override func clearUrgentEvent(sessionId: String) {
        lastMessages.removeValue(forKey: sessionId)
        PluginLog("[CodexPlugin] Cleared urgent event for session: \(sessionId)")
    }

    // MARK: - Private

    /// 扫描 Codex SQLite 数据库
    private func scanCodexDatabase() -> [PluginSession] {
        guard FileManager.default.fileExists(atPath: codexDatabasePath.path) else {
            NSLog("[CodexPlugin] Database not found: \(codexDatabasePath.path)")
            return []
        }

        var sessions: [PluginSession] = []

        // 查询 automation_runs 表
        let query = """
        SELECT thread_id, automation_id, status, thread_title, source_cwd, inbox_title, inbox_summary, updated_at
        FROM automation_runs
        WHERE status != 'ARCHIVED'
        ORDER BY updated_at DESC
        """

        if let results = executeQuery(query) {
            for row in results {
                let threadId = row["thread_id"] as? String ?? ""
                let automationId = row["automation_id"] as? String ?? ""
                let statusStr = row["status"] as? String ?? "idle"
                let threadTitle = row["thread_title"] as? String
                let sourceCwd = row["source_cwd"] as? String
                let inboxTitle = row["inbox_title"] as? String
                let inboxSummary = row["inbox_summary"] as? String
                let updatedAt = row["updated_at"] as? Int ?? 0

                let lastUpdate = Date(timeIntervalSince1970: TimeInterval(updatedAt))
                let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)

                // 只显示最近活跃的 session
                if timeSinceUpdate < activeThreshold {
                    let title = threadTitle ?? inboxTitle ?? automationId
                    let lastMessage = inboxSummary

                    // 状态映射
                    let status: SessionStatus = mapCodexStatus(statusStr)

                    let session = PluginSession(
                        id: "\(pluginId)-\(threadId)",
                        pluginId: pluginId,
                        title: title,
                        status: status,
                        startedAt: lastUpdate,
                        cwd: sourceCwd,
                        icon: "cpu.fill",
                        accentColor: .purple,
                        lastMessage: lastMessage
                    )
                    sessions.append(session)
                }
            }
        }

        // 查询 automations 表获取活跃的 automation
        let automationQuery = """
        SELECT id, name, status, last_run_at, cwds
        FROM automations
        WHERE status = 'ACTIVE'
        ORDER BY last_run_at DESC
        """

        if let results = executeQuery(automationQuery) {
            for row in results {
                let automationId = row["id"] as? String ?? ""
                let name = row["name"] as? String ?? automationId
                let lastRunAt = row["last_run_at"] as? Int ?? 0
                let cwdsStr = row["cwds"] as? String ?? "[]"

                // 解析 cwds JSON array
                var cwd: String? = nil
                if let cwdsData = cwdsStr.data(using: .utf8),
                   let cwds = try? JSONSerialization.jsonObject(with: cwdsData) as? [String],
                   let firstCwd = cwds.first {
                    cwd = firstCwd
                }

                let lastUpdate = Date(timeIntervalSince1970: TimeInterval(lastRunAt))
                let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)

                // 只显示最近运行的 automation
                if timeSinceUpdate < activeThreshold && lastRunAt > 0 {
                    let session = PluginSession(
                        id: "\(pluginId)-automation-\(automationId)",
                        pluginId: pluginId,
                        title: name,
                        status: .active,
                        startedAt: lastUpdate,
                        cwd: cwd,
                        icon: "cpu.fill",
                        accentColor: .purple,
                        lastMessage: "Automation running"
                    )
                    sessions.append(session)
                }
            }
        }

        // 按更新时间排序
        sessions.sort { $0.startedAt > $1.startedAt }

        NSLog("[CodexPlugin] Found \(sessions.count) active sessions/automations")
        return sessions
    }

    /// 执行 SQLite 查询
    private func executeQuery(_ query: String) -> [[String: Any]]? {
        let process = Process()
        process.launchPath = "/usr/bin/sqlite3"
        process.arguments = [codexDatabasePath.path, "-json", query]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.isEmpty || output == "[]" {
                return []
            }

            // 解析 JSON 输出
            if let jsonData = output.data(using: .utf8),
               let results = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                return results
            }
        } catch {
            NSLog("[CodexPlugin] Query error: \(error)")
        }

        return nil
    }

    /// 映射 Codex 状态到 SessionStatus
    private func mapCodexStatus(_ status: String) -> SessionStatus {
        switch status.lowercased() {
        case "running", "active":
            return .active
        case "waiting", "pending":
            return .waitingForUser
        case "permission_required", "permission":
            return .permissionRequired
        case "completed", "done":
            return .completed
        case "failed", "error":
            return .idle
        case "archived":
            return .completed
        default:
            return .idle
        }
    }
}