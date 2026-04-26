import Foundation
import SwiftUI
import Meee2PluginKit

class CodexPlugin: SessionPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.meee2.plugin.codex" }
    override var displayName: String { "Codex" }
    override var icon: String { "cpu.fill" }
    override var themeColor: Color { .purple }
    override var version: String { "0.2.0" }
    override var helpUrl: String? { "https://github.com/openai/codex" }

    // MARK: - Private

    private var isRunning = false
    private var refreshTimer: Timer?

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash

    // 刷新间隔（秒）- 可通过 AppStorage 配置
    @AppStorage("codexRefreshInterval") private var refreshInterval: Double = 10.0

    // 活跃时间阈值（秒）- session 更新时间在此阈值内视为活跃
    private let activeThreshold: TimeInterval = 3600  // 1小时

    // MARK: - Lifecycle

    override func initialize() -> Bool {
        // 检查数据库文件是否存在
        let stateDbPath = stateDatabasePath
        guard FileManager.default.fileExists(atPath: stateDbPath.path) else {
            NSLog("[CodexPlugin] State database not found: \(stateDbPath.path)")
            hasError = true
            lastError = "Codex state database not found"
            return true  // 仍然返回 true，让 plugin 可以加载
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

        NSLog("[CodexPlugin] Started, watching: \(stateDatabasePath.path), interval: \(refreshInterval)s")
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
        scanCodexThreads()
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
        // 打开 Codex Desktop app 或 Terminal
        // 检查是否有 Codex.app
        if let codexUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: codexUrl, configuration: NSWorkspace.OpenConfiguration())
            NSLog("[CodexPlugin] Opening Codex.app")
        } else {
            // 回退到打开 Terminal
            let script = """
            tell application "Terminal"
                activate
            end tell
            """

            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[CodexPlugin] Terminal launch error: \(error)")
                }
            }

            // 打开 cwd 目录
            if let cwd = session.cwd {
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = [cwd]
                try? task.run()
            }
        }
    }

    // MARK: - Urgent Event

    override func clearUrgentEvent(sessionId: String) {
        lastMessages.removeValue(forKey: sessionId)
        PluginLog("[CodexPlugin] Cleared urgent event for session: \(sessionId)")
    }

    // MARK: - Private

    /// Codex state database 路径 (state_5.sqlite 或更高版本)
    private var stateDatabasePath: URL {
        let home = NSHomeDirectory()
        let codexDir = URL(fileURLWithPath: home).appendingPathComponent(".codex")

        // 查找最新的 state_*.sqlite 文件
        if let files = try? FileManager.default.contentsOfDirectory(at: codexDir, includingPropertiesForKeys: nil) {
            let stateFiles = files.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            if let latest = stateFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
                return latest
            }
        }

        // 默认路径
        return codexDir.appendingPathComponent("state_5.sqlite")
    }

    /// 扫描 Codex threads 表
    private func scanCodexThreads() -> [PluginSession] {
        let dbPath = stateDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            NSLog("[CodexPlugin] Database not found: \(dbPath.path)")
            return []
        }

        var sessions: [PluginSession] = []

        // 查询 threads 表 - 未归档的活跃 thread
        // 检查进程是否在运行来判断状态
        let codexRunning = isCodexProcessRunning()

        let query = """
        SELECT id, title, cwd, archived, updated_at, first_user_message, model
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT 20
        """

        if let results = executeQuery(dbPath: dbPath, query: query) {
            for row in results {
                let threadId = row["id"] as? String ?? ""
                let title = row["title"] as? String ?? "Untitled"
                let cwd = row["cwd"] as? String
                let updatedAt = row["updated_at"] as? Int ?? 0
                let firstUserMessage = row["first_user_message"] as? String
                let model = row["model"] as? String

                let lastUpdate = Date(timeIntervalSince1970: TimeInterval(updatedAt))
                let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)

                // 只显示最近活跃的 session (1小时内)
                if timeSinceUpdate < activeThreshold {
                    // 状态判断：如果 Codex 进程在运行且这个 thread 最近更新，认为是 active
                    let status: SessionStatus = codexRunning && timeSinceUpdate < 60 ? .active : .idle

                    // lastMessage: 如果最近活跃，显示 model 或 first_user_message
                    var lastMessage: String? = nil
                    if timeSinceUpdate < 300 {
                        lastMessage = model ?? firstUserMessage?.prefix(100).description
                    }

                    let session = PluginSession(
                        id: "\(pluginId)-\(threadId)",
                        pluginId: pluginId,
                        title: title,
                        status: status,
                        startedAt: lastUpdate,
                        cwd: cwd,
                        icon: "cpu.fill",
                        accentColor: .purple,
                        lastMessage: lastMessage
                    )
                    sessions.append(session)
                }
            }
        }

        // 按更新时间排序
        sessions.sort { $0.startedAt > $1.startedAt }

        NSLog("[CodexPlugin] Found \(sessions.count) active threads from \(dbPath.lastPathComponent)")
        return sessions
    }

    /// 检查 Codex 进程是否在运行
    private func isCodexProcessRunning() -> Bool {
        // 使用 pgrep 更简单更快，避免 ps aux 管道问题
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "codex"]

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            // pgrep 返回 0 表示找到进程
            return task.terminationStatus == 0
        } catch {
            NSLog("[CodexPlugin] pgrep error: \(error)")
            return false
        }
    }

    /// 执行 SQLite 查询
    private func executeQuery(dbPath: URL, query: String) -> [[String: Any]]? {
        let process = Process()
        process.launchPath = "/usr/bin/sqlite3"
        process.arguments = [dbPath.path, "-json", query]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

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
}