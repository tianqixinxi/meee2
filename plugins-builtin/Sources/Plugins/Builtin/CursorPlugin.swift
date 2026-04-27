import Foundation
import SwiftUI
import Meee2PluginKit

class CursorPlugin: SessionPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.meee2.plugin.cursor" }
    override var displayName: String { "Cursor" }
    override var icon: String { "location.fill" }
    override var themeColor: Color { .blue }
    override var version: String { "0.2.0" }
    override var helpUrl: String? { "https://docs.cursor.com/meee2-plugin" }

    // MARK: - Private

    private var isRunning = false
    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private let refreshQueue = DispatchQueue(label: "com.meee2.plugin.cursor.refresh", qos: .utility)

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash
    private var lastStatuses: [String: SessionStatus] = [:]

    // 刷新间隔（秒）- 可通过 AppStorage 配置
    @AppStorage("cursorRefreshInterval") private var refreshInterval: Double = 10.0

    // Cursor projects 路径（可配置）
    @AppStorage("cursorProjectsPath") private var projectsPathString: String = ""

    // 默认路径
    private var defaultProjectsPath: URL {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".cursor")
            .appendingPathComponent("projects")
    }

    // 实际使用的路径
    private var cursorProjectsPath: URL {
        if projectsPathString.isEmpty {
            return defaultProjectsPath
        }
        return URL(fileURLWithPath: projectsPathString)
    }

    // 活跃时间阈值（秒）- 文件修改时间在此阈值内视为活跃
    private let activeThreshold: TimeInterval = 300  // 5分钟

    // MARK: - Lifecycle

    override func initialize() -> Bool {
        // 始终允许初始化
        return true
    }

    override func start() -> Bool {
        guard !isRunning else { return true }

        isRunning = true

        // 启动定时器
        startTimer()
        refresh()

        NSLog("[CursorPlugin] Started, watching: \(cursorProjectsPath.path), interval: \(refreshInterval)s")
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
        refreshInFlight = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        NSLog("[CursorPlugin] Stopped")
    }

    override func cleanup() {
        stop()
    }

    // MARK: - Session Management

    override func getSessions() -> [PluginSession] {
        scanCursorProjects()
    }

    override func refresh() {
        guard isRunning, !refreshInFlight else { return }
        refreshInFlight = true

        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            let sessions = self.getSessions()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshInFlight = false
                guard self.isRunning else { return }
                self.handleRefreshResult(sessions)
            }
        }
    }

    private func handleRefreshResult(_ sessions: [PluginSession]) {
        // 检测新消息
        for session in sessions {
            guard let newMessage = session.lastMessage ?? session.subtitle else {
                lastStatuses[session.id] = session.status
                continue
            }

            let previousMessage = lastMessages[session.id]
            let previousStatus = lastStatuses[session.id]
            if previousMessage != newMessage {
                if previousMessage != nil,
                   shouldTriggerUrgentEvent(session: session, previousStatus: previousStatus, message: newMessage) {
                    NSLog("[CursorPlugin] New message detected for \(session.title): \(newMessage.prefix(50))...")
                    onUrgentEvent?(session, newMessage, nil)
                }
                lastMessages[session.id] = newMessage
            }
            lastStatuses[session.id] = session.status
        }

        onSessionsUpdated?(sessions)
    }

    // MARK: - Terminal

    override func activateTerminal(for session: PluginSession) {
        if let cwd = session.cwd {
            openCursor(at: cwd)
        } else {
            // 回退：直接激活 Cursor 应用
            openCursorApp()
        }
    }

    // MARK: - Urgent Event

    override func clearUrgentEvent(sessionId: String) {
        // 清除消息缓存，防止下次刷新时重复触发
        lastMessages.removeValue(forKey: sessionId)
        lastStatuses.removeValue(forKey: sessionId)
        PluginLog("[CursorPlugin] Cleared urgent event for session: \(sessionId)")
    }

    // MARK: - Private

    /// 扫描 Cursor projects 目录
    private func scanCursorProjects() -> [PluginSession] {
        // 检查目录是否存在
        guard FileManager.default.fileExists(atPath: cursorProjectsPath.path) else {
            NSLog("[CursorPlugin] Projects directory not found: \(cursorProjectsPath.path)")
            return []
        }

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: cursorProjectsPath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            NSLog("[CursorPlugin] Failed to read projects directory")
            return []
        }

        var sessions: [PluginSession] = []

        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            // 检查是否有 agent-transcripts 目录
            let transcriptsDir = projectDir.appendingPathComponent("agent-transcripts")

            guard FileManager.default.fileExists(atPath: transcriptsDir.path) else {
                continue
            }

            // 解析项目路径
            let projectName = parseProjectName(from: projectDir.lastPathComponent)
            let projectPath = parseProjectPath(from: projectDir.lastPathComponent)

            // 获取最近的 transcript 活动时间、最后消息和状态
            if let (lastActivity, lastMessage, detectedStatus) = getLastTranscriptActivityAndMessage(transcriptsDir: transcriptsDir) {
                let timeSinceActivity = Date().timeIntervalSince(lastActivity)
                // 使用 TranscriptStatusParser 检测的状态，而非简单的时间判断
                let status: SessionStatus = detectedStatus

                // 只显示最近活跃的 session (1小时内)
                if timeSinceActivity < 3600 {
                    let session = PluginSession(
                        id: "\(pluginId)-\(projectDir.lastPathComponent)",
                        pluginId: pluginId,
                        title: projectName,
                        status: status,
                        startedAt: lastActivity,
                        cwd: projectPath,
                        icon: "cursorarrow",
                        accentColor: .blue,
                        lastMessage: lastMessage
                    )
                    sessions.append(session)
                }
            }
        }

        // 按活动时间排序，最近的在前
        sessions.sort { $0.startedAt > $1.startedAt }

        NSLog("[CursorPlugin] Found \(sessions.count) active projects")
        return sessions
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

    /// 解析项目名称
    /// 例如: "Users-bytedance-code-Claw3D" -> "Claw3D"
    private func parseProjectName(from dirName: String) -> String {
        // Cursor 目录名格式：路径分隔符替换为短横线
        // 取最后一部分作为项目名
        let parts = dirName.split(separator: "-")
        if let last = parts.last {
            return String(last)
        }
        return dirName
    }

    /// 解析项目路径
    /// 例如: "Users-USERNAME-code-deer-flow" 反向还原为绝对路径（/Users/USERNAME/code/deer-flow）
    /// 注意：路径中可能包含短横线，需要特殊处理
    private func parseProjectPath(from dirName: String) -> String? {
        let parts = dirName.split(separator: "-")

        // 格式：/Users/xxx/path...
        if parts.first == "Users" && parts.count >= 2 {
            // 尝试直接替换短横线为斜杠
            let directPath = "/" + dirName.replacingOccurrences(of: "-", with: "/")
            if FileManager.default.fileExists(atPath: directPath) {
                return directPath
            }

            // 尝试保留某些短横线（路径中包含短横线的情况）
            for i in 2..<parts.count {
                var testParts = parts.map(String.init)
                if i < testParts.count - 1 {
                    let combined = testParts[i] + "-" + testParts[i + 1]
                    testParts.remove(at: i + 1)
                    testParts[i] = combined

                    let testPath = "/" + testParts.joined(separator: "/")
                    if FileManager.default.fileExists(atPath: testPath) {
                        return testPath
                    }
                }
            }
        }

        return nil
    }

    /// 获取 transcripts 目录中最后活动时间、最后消息和状态
    /// 返回: (最后活动时间, 最后消息, 状态)
    private func getLastTranscriptActivityAndMessage(transcriptsDir: URL) -> (Date, String?, SessionStatus)? {
        guard let transcriptDirs = try? FileManager.default.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latestDate: Date?
        var latestFile: URL?
        var lastMessage: String?

        for transcriptDir in transcriptDirs where transcriptDir.hasDirectoryPath {
            // 查找目录下的 .jsonl 文件
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: transcriptDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where file.pathExtension == "jsonl" {
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = attrs.contentModificationDate {
                    if latestDate == nil || modDate > latestDate! {
                        latestDate = modDate
                        latestFile = file
                    }
                }
            }
        }

        // 解析最后消息和状态
        var detectedStatus: SessionStatus = .idle
        if let file = latestFile {
            lastMessage = parseLastAssistantMessage(from: file)
            // 使用 TranscriptStatusParser 检测状态
            let result = TranscriptStatusParser.detectStatus(file: file)
            detectedStatus = result.status
            // 如果检测到当前工具，用它作为 lastMessage
            if let tool = result.currentTool, lastMessage == nil {
                lastMessage = "🔧 \(tool)"
            }
            // 使用文件修改时间作为最后活动时间（如果解析器没返回）
            if result.lastActivity != nil {
                latestDate = result.lastActivity
            }
        }

        if let date = latestDate {
            return (date, lastMessage, detectedStatus)
        }
        return nil
    }

    /// 解析 transcript 文件中最后一条 assistant 消息
    private func parseLastAssistantMessage(from file: URL) -> String? {
        // 从后往前找最后一条 assistant 消息
        for line in Self.tailLines(file: file, maxBytes: 128 * 1024).reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["role"] as? String == "assistant" else {
                continue
            }

            // 提取 message.content
            if let message = json["message"] as? [String: Any],
               let contentArray = message["content"] as? [[String: Any]] {
                // 拼接所有文本内容
                let texts = contentArray.compactMap { $0["text"] as? String }
                let fullText = texts.joined(separator: " ")

                // 截取前 100 个字符作为摘要
                if fullText.count > 100 {
                    return String(fullText.prefix(100)) + "..."
                }
                return fullText.isEmpty ? nil : fullText
            }
        }

        return nil
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

    private func openCursor(at path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Cursor", path]
        try? task.run()
        NSLog("[CursorPlugin] Opening Cursor at: \(path)")
    }

    private func openCursorApp() {
        if let cursorUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.openApplication(at: cursorUrl, configuration: NSWorkspace.OpenConfiguration())
        } else {
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", "Cursor"]
            try? task.run()
        }
    }
}
