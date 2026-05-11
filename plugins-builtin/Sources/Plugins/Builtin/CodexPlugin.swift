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
    private var currentTimerInterval: TimeInterval = 0
    private var refreshInFlight = false
    private let refreshQueue = DispatchQueue(label: "com.meee2.plugin.codex.refresh", qos: .utility)
    private let sqliteQueryTimeout: TimeInterval = 3.0
    private let perfLoggingEnabled = ProcessInfo.processInfo.environment["MEEE2_PERF_LOG"] == "1"
    private static let autoReviewModel = "codex-auto-review"
    private static let autoReviewPromptPrefix = "The following is the Codex agent history whose request action you are assessing."

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash
    private var lastStatuses: [String: SessionStatus] = [:]
    private var transcriptSnapshotCache: [String: (fingerprint: FileFingerprint, snapshot: CodexTranscriptSnapshot)] = [:]
    private var codexRunningCache: (checkedAt: Date, value: Bool)?
    private var deliveredInitialSnapshot = false

    private struct FileFingerprint: Equatable {
        let fileSize: UInt64
        let modifiedAt: TimeInterval
    }

    // 刷新间隔（秒）- 可通过 AppStorage 配置
    @AppStorage("codexRefreshInterval") private var refreshInterval: Double = 10.0

    // 活跃判定：仅依赖 SQL 里的 `archived = 0`，不再做时间窗口过滤——
    // 与 Claude Desktop / Cowork 的"用户归档 flag 即唯一过滤"保持一致。

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
        deliveredInitialSnapshot = false

        // 启动定时器
        startTimer()
        refresh()

        // NSLog("[CodexPlugin] Started, watching: \(stateDatabasePath.path), interval: \(refreshInterval)s")
        return true
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        currentTimerInterval = refreshInterval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: currentTimerInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func stop() {
        isRunning = false
        refreshInFlight = false
        deliveredInitialSnapshot = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        // NSLog("[CodexPlugin] Stopped")
    }

    override func cleanup() {
        stop()
    }

    // MARK: - Session Management

    override func getSessions() -> [PluginSession] {
        scanCodexThreads(parseTranscripts: true)
    }

    override func refresh() {
        guard isRunning, !refreshInFlight else { return }
        refreshInFlight = true

        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.deliveredInitialSnapshot {
                let quickSessions = self.scanCodexThreads(parseTranscripts: false)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    guard self.isRunning, !self.deliveredInitialSnapshot else { return }
                    self.deliveredInitialSnapshot = true
                    self.handleRefreshResult(quickSessions, detectUrgentEvents: false, rememberMessages: false)
                }
            }

            let sessions = self.scanCodexThreads(parseTranscripts: true)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshInFlight = false
                guard self.isRunning else { return }
                self.deliveredInitialSnapshot = true
                self.handleRefreshResult(sessions)
            }
        }
    }

    private func handleRefreshResult(
        _ sessions: [PluginSession],
        detectUrgentEvents: Bool = true,
        rememberMessages: Bool = true
    ) {
        // NSLog("[CodexPlugin] Refresh: found \(sessions.count) sessions")

        // 检测新消息
        if rememberMessages {
            for session in sessions {
                let newMessage = session.lastMessage
                let previousMessage = lastMessages[session.id]
                let previousStatus = lastStatuses[session.id]

                if let msg = newMessage, previousMessage != msg {
                    if detectUrgentEvents,
                       previousMessage != nil,
                       shouldTriggerUrgentEvent(session: session, previousStatus: previousStatus, message: msg) {
                        // NSLog("[CodexPlugin] *** TRIGGERING URGENT EVENT for \(session.title): \(msg.prefix(50))...")
                        onUrgentEvent?(session, msg, nil)
                    }
                    lastMessages[session.id] = msg
                }
                lastStatuses[session.id] = session.status
            }
        }

        onSessionsUpdated?(sessions)
        rescheduleTimer(active: sessions.contains { $0.status.isWorking || $0.status.needsUserAction })
    }

    private func rescheduleTimer(active: Bool) {
        let targetInterval = active ? refreshInterval : max(refreshInterval, 30.0)
        guard abs(targetInterval - currentTimerInterval) > 0.1 else { return }
        refreshTimer?.invalidate()
        currentTimerInterval = targetInterval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: targetInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Terminal

    override func activateTerminal(for session: PluginSession) {
        if let threadId = codexThreadId(from: session),
           let threadUrl = URL(string: "codex://threads/\(threadId)"),
           NSWorkspace.shared.open(threadUrl) {
            NSLog("[CodexPlugin] Opening Codex thread: \(threadId)")
            return
        }

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

    private func codexThreadId(from session: PluginSession) -> String? {
        let prefixedId = "\(pluginId)-"
        let rawId = session.id.hasPrefix(prefixedId)
            ? String(session.id.dropFirst(prefixedId.count))
            : session.id

        guard UUID(uuidString: rawId) != nil else {
            NSLog("[CodexPlugin] Invalid Codex thread id for activation: \(session.id)")
            return nil
        }

        return rawId
    }

    // MARK: - Urgent Event

    override func clearUrgentEvent(sessionId: String) {
        lastMessages.removeValue(forKey: sessionId)
        lastStatuses.removeValue(forKey: sessionId)
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
    private func scanCodexThreads(parseTranscripts: Bool) -> [PluginSession] {
        let started = Date()
        defer { perfLog("scanCodexThreads", started: started, extra: parseTranscripts ? "full" : "quick") }
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
        SELECT id, substr(title, 1, 200) AS title, cwd, archived,
               updated_at, updated_at_ms, rollout_path,
               substr(first_user_message, 1, 500) AS first_user_message,
               model
        FROM threads
        WHERE archived = 0
          AND (model IS NULL OR model != '\(Self.autoReviewModel)')
          AND (title IS NULL OR title NOT LIKE '\(Self.autoReviewPromptPrefix)%')
          AND (first_user_message IS NULL OR first_user_message NOT LIKE '\(Self.autoReviewPromptPrefix)%')
        ORDER BY updated_at_ms DESC, updated_at DESC
        LIMIT 20
        """

        if let results = executeQuery(dbPath: dbPath, query: query) {
            for row in results {
                let threadId = row["id"] as? String ?? ""
                let title = row["title"] as? String ?? "Untitled"
                let cwd = row["cwd"] as? String
                let updatedAt = intValue(row["updated_at"]) ?? 0
                let updatedAtMs = intValue(row["updated_at_ms"])
                let rolloutPath = row["rollout_path"] as? String
                let firstUserMessage = row["first_user_message"] as? String
                let model = row["model"] as? String

                guard !Self.isInternalCodexThread(
                    title: title,
                    firstUserMessage: firstUserMessage,
                    model: model
                ) else {
                    continue
                }

                let lastUpdate = Self.date(seconds: updatedAt, milliseconds: updatedAtMs)
                let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)

                let transcript = parseTranscripts
                    ? parseCodexTranscript(path: rolloutPath)
                    : CodexTranscriptSnapshot()

                // 状态优先使用 rollout tail 推断；如果最近还在写且进程存在，
                // 空闲态提升为 active，避免长推理期间只显示 idle。
                var status = transcript.status ?? .idle
                if codexRunning && timeSinceUpdate < 60 && status == .idle && !transcript.isFinalResult {
                    status = .active
                }

                let lastMessage = transcript.lastMessage
                    ?? firstUserMessage.map { String($0.prefix(100)) }
                    ?? model

                let session = PluginSession(
                    id: "\(pluginId)-\(threadId)",
                    pluginId: pluginId,
                    title: title,
                    status: status,
                    startedAt: lastUpdate,
                    lastUpdated: lastUpdate,
                    toolName: transcript.currentTool,
                    cwd: cwd,
                    transcriptPath: rolloutPath,
                    icon: "cpu.fill",
                    accentColor: .purple,
                    lastMessage: lastMessage
                )
                sessions.append(session)
            }
        }

        // 按更新时间排序
        sessions.sort { $0.startedAt > $1.startedAt }

        NSLog("[CodexPlugin] Found \(sessions.count) active threads from \(dbPath.lastPathComponent)")
        return sessions
    }

    private static func isInternalCodexThread(title: String?, firstUserMessage: String?, model: String?) -> Bool {
        if model == autoReviewModel {
            return true
        }
        if title?.hasPrefix(autoReviewPromptPrefix) == true {
            return true
        }
        if firstUserMessage?.hasPrefix(autoReviewPromptPrefix) == true {
            return true
        }
        return false
    }

    private func shouldTriggerUrgentEvent(
        session: PluginSession,
        previousStatus: SessionStatus?,
        message: String
    ) -> Bool {
        if session.status.needsUserAction {
            return previousStatus != session.status
        }

        guard session.status.isResting, previousStatus?.isWorking == true else {
            return false
        }

        return !isProgressMessage(message)
    }

    private func isProgressMessage(_ message: String) -> Bool {
        message.hasPrefix("tool:") || message.hasPrefix("🔧")
    }

    /// 检查 Codex 进程是否在运行
    private func isCodexProcessRunning() -> Bool {
        if let cached = codexRunningCache,
           Date().timeIntervalSince(cached.checkedAt) < 5.0 {
            return cached.value
        }

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
            let running = task.terminationStatus == 0
            codexRunningCache = (checkedAt: Date(), value: running)
            return running
        } catch {
            NSLog("[CodexPlugin] pgrep error: \(error)")
            codexRunningCache = (checkedAt: Date(), value: false)
            return false
        }
    }

    private func fileFingerprint(path: String) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }
        return FileFingerprint(fileSize: fileSize, modifiedAt: modifiedAt)
    }

    private func perfLog(_ name: String, started: Date, extra: String = "") {
        guard perfLoggingEnabled else { return }
        let ms = Date().timeIntervalSince(started) * 1_000
        let suffix = extra.isEmpty ? "" : " \(extra)"
        NSLog(String(format: "[Perf][CodexPlugin] %@ %.1fms%@", name, ms, suffix))
    }

    private static func date(seconds: Int, milliseconds: Int?) -> Date {
        if let milliseconds = milliseconds, milliseconds > 0 {
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private struct CodexTranscriptSnapshot {
        var lastMessage: String?
        var status: SessionStatus?
        var currentTool: String?
        var isFinalResult = false
    }

    /// Codex Desktop rollout JSONL uses `response_item.payload` records rather
    /// than Claude's `type=user/assistant` schema. Read the tail and derive the
    /// user-visible message/status from the actual matching thread transcript.
    private func parseCodexTranscript(path: String?) -> CodexTranscriptSnapshot {
        guard let path = path,
              FileManager.default.fileExists(atPath: path) else {
            return CodexTranscriptSnapshot()
        }
        if let fingerprint = fileFingerprint(path: path),
           let cached = transcriptSnapshotCache[path],
           cached.fingerprint == fingerprint {
            return cached.snapshot
        }

        var snapshot = CodexTranscriptSnapshot()

        for raw in Self.tailLines(file: URL(fileURLWithPath: path), maxBytes: 256 * 1024) {
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "response_item",
                  let payload = json["payload"] as? [String: Any],
                  let itemType = payload["type"] as? String else {
                continue
            }

            switch itemType {
            case "message":
                guard let role = payload["role"] as? String,
                      role == "user" || role == "assistant",
                      let text = Self.extractCodexText(from: payload["content"]),
                      !text.isEmpty else {
                    continue
                }
                snapshot.lastMessage = String(text.replacingOccurrences(of: "\n", with: " ").prefix(200))
                snapshot.status = role == "user" ? .thinking : .idle
                snapshot.currentTool = nil
                snapshot.isFinalResult = role == "assistant"
            case "function_call":
                snapshot.currentTool = payload["name"] as? String
                snapshot.lastMessage = snapshot.currentTool.map { "tool: \($0)" } ?? snapshot.lastMessage
                snapshot.status = .tooling
                snapshot.isFinalResult = false
            case "function_call_output":
                snapshot.status = .thinking
                snapshot.isFinalResult = false
            case "reasoning":
                snapshot.status = .thinking
                snapshot.isFinalResult = false
            default:
                continue
            }
        }

        if let fingerprint = fileFingerprint(path: path) {
            transcriptSnapshotCache[path] = (fingerprint: fingerprint, snapshot: snapshot)
            if transcriptSnapshotCache.count > 128 {
                transcriptSnapshotCache.removeAll(keepingCapacity: true)
            }
        }
        return snapshot
    }

    private static func extractCodexText(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let blocks = value as? [[String: Any]] else {
            return nil
        }
        let parts = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            if let text = block["input_text"] as? String { return text }
            if let text = block["output_text"] as? String { return text }
            return nil
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func tailLines(file: URL, maxBytes: UInt64) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let tailSize = min(fileSize, maxBytes)
        let offset = fileSize - tailSize
        handle.seek(toFileOffset: offset)

        guard let content = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }

        var lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !content.hasPrefix("\n"), !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }

    /// 执行 SQLite 查询
    private func executeQuery(dbPath: URL, query: String) -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-batch",
            "-bail",
            "-cmd", ".timeout 1000",
            "-json",
            dbPath.path,
            query
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()

            var data = Data()
            var errData = Data()
            let outputGroup = DispatchGroup()

            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                data = outPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }

            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }

            if termination.wait(timeout: .now() + sqliteQueryTimeout) == .timedOut {
                process.terminate()
                _ = termination.wait(timeout: .now() + 1.0)
                NSLog("[CodexPlugin] Query timed out after \(sqliteQueryTimeout)s")
                return nil
            }

            if outputGroup.wait(timeout: .now() + 1.0) == .timedOut {
                NSLog("[CodexPlugin] Query output drain timed out")
                return nil
            }

            guard process.terminationStatus == 0 else {
                let error = String(data: errData, encoding: .utf8) ?? "unknown sqlite error"
                NSLog("[CodexPlugin] Query failed: \(error.trimmingCharacters(in: .whitespacesAndNewlines))")
                return nil
            }

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
