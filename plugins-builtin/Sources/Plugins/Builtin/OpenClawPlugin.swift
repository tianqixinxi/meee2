import Foundation
import SwiftUI
import Meee2PluginKit

class OpenClawPlugin: SessionPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.meee2.plugin.openclaw" }
    override var displayName: String { "OpenClaw" }
    override var icon: String { "house.fill" }
    override var themeColor: Color { .red }
    override var version: String { "0.2.0" }
    override var helpUrl: String? { nil }

    // MARK: - Private

    private var isRunning = false
    private var refreshTimer: Timer?
    private var currentTimerInterval: TimeInterval = 0
    private var refreshInFlight = false
    private let refreshQueue = DispatchQueue(label: "com.meee2.plugin.openclaw.refresh", qos: .utility)

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash
    private var lastStatuses: [String: SessionStatus] = [:]

    // 保存 session.id -> sessionKey 的映射，用于构建 URL
    private var sessionKeyMap: [String: String] = [:]
    private let sessionKeyMapLock = NSLock()

    // 刷新间隔（秒）
    @AppStorage("openclawRefreshInterval") private var refreshInterval: Double = 10.0

    // OpenClaw agents 路径（可配置）
    @AppStorage("openclawAgentsPath") private var agentsPathString: String = ""

    // 默认路径
    private var defaultAgentsPath: URL {
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("agents")
    }

    // 实际使用的路径
    private var openclawAgentsPath: URL {
        if agentsPathString.isEmpty {
            return defaultAgentsPath
        }
        return URL(fileURLWithPath: agentsPathString)
    }

    // OpenClaw 上游不暴露归档概念，本插件展示所有可见的 session；
    // 不再做时间窗口过滤——和其它 AI 客户端插件的语义保持一致。

    // MARK: - Lifecycle

    override func initialize() -> Bool {
        return true
    }

    override func start() -> Bool {
        guard !isRunning else { return true }

        isRunning = true

        // 启动定时器
        startTimer()
        refresh()

        NSLog("[OpenClawPlugin] Started, watching: \(openclawAgentsPath.path), interval: \(refreshInterval)s")
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
        refreshTimer?.invalidate()
        refreshTimer = nil
        NSLog("[OpenClawPlugin] Stopped")
    }

    override func cleanup() {
        stop()
    }

    // MARK: - Session Management

    override func getSessions() -> [PluginSession] {
        scanOpenClawAgents()
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
        NSLog("[OpenClawPlugin] Refresh: found \(sessions.count) sessions")

        // 检测新消息 - 使用 lastMessage 而不是 subtitle
        for session in sessions {
            let newMessage = session.lastMessage
            let previousMessage = lastMessages[session.id]
            let previousStatus = lastStatuses[session.id]

            if let msg = newMessage, previousMessage != msg {
                if previousMessage != nil,
                   shouldTriggerUrgentEvent(session: session, previousStatus: previousStatus, message: msg) {
                    NSLog("[OpenClawPlugin] *** TRIGGERING URGENT EVENT for \(session.title): \(msg.prefix(50))...")
                    onUrgentEvent?(session, msg, nil)
                } else {
                    NSLog("[OpenClawPlugin] First load, skipping urgent for \(session.title)")
                }
                lastMessages[session.id] = msg
            }
            lastStatuses[session.id] = session.status
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
        // 打开 OpenClaw web UI
        sessionKeyMapLock.lock()
        let mappedSessionKey = sessionKeyMap[session.id]
        sessionKeyMapLock.unlock()
        let sessionKey = mappedSessionKey ?? "agent:\(session.title):main"
        let urlString = "http://127.0.0.1:18789/chat?session=" + sessionKey

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            NSLog("[OpenClawPlugin] Opening URL: \(urlString)")
        }
    }

    // MARK: - Urgent Event

    override func clearUrgentEvent(sessionId: String) {
        lastMessages.removeValue(forKey: sessionId)
        lastStatuses.removeValue(forKey: sessionId)
        PluginLog("[OpenClawPlugin] Cleared urgent event for session: \(sessionId)")
    }

    // MARK: - Private

    /// 扫描 OpenClaw agents 目录
    private func scanOpenClawAgents() -> [PluginSession] {
        guard FileManager.default.fileExists(atPath: openclawAgentsPath.path) else {
            NSLog("[OpenClawPlugin] Agents directory not found: \(openclawAgentsPath.path)")
            return []
        }

        guard let agentDirs = try? FileManager.default.contentsOfDirectory(
            at: openclawAgentsPath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            NSLog("[OpenClawPlugin] Failed to read agents directory")
            return []
        }

        var sessions: [PluginSession] = []

        for agentDir in agentDirs where agentDir.hasDirectoryPath {
            let agentName = agentDir.lastPathComponent

            // 检查是否有 sessions 目录
            let sessionsDir = agentDir.appendingPathComponent("sessions")
            guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
                continue
            }

            // 解析 sessions.json 获取 session
            if let sessionInfo = parseSessionsJson(sessionsDir: sessionsDir, agentName: agentName) {
                // 获取 cwd 和 lastMessage
                let cwd = sessionInfo.cwd ?? getCwdFromAgent(agentName: agentName)
                let lastMessage = parseLastMessageFromTranscript(sessionFile: sessionInfo.sessionFile)

                // 使用 TranscriptStatusParser 检测状态
                var detectedStatus: SessionStatus = sessionInfo.status
                if let sessionFile = sessionInfo.sessionFile {
                    let result = TranscriptStatusParser.detectStatus(file: sessionFile)
                    detectedStatus = result.status
                }

                let fullSessionId = "\(pluginId)-\(agentName)-\(sessionInfo.sessionId)"

                // 保存 sessionKey 映射，用于构建 URL
                sessionKeyMapLock.lock()
                sessionKeyMap[fullSessionId] = sessionInfo.sessionKey
                sessionKeyMapLock.unlock()

                let session = PluginSession(
                    id: fullSessionId,
                    pluginId: pluginId,
                    title: agentName,
                    status: detectedStatus,
                    startedAt: sessionInfo.lastUpdate,
                    // 不设置 subtitle！这会导致右侧重复显示 lastMessage
                    cwd: cwd,
                    icon: "house.fill",
                    accentColor: .red,
                    lastMessage: lastMessage
                )
                sessions.append(session)
            }
        }

        // 按更新时间排序
        sessions.sort { $0.startedAt > $1.startedAt }

        NSLog("[OpenClawPlugin] Found \(sessions.count) active agents")
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

    /// 解析 sessions.json
    private func parseSessionsJson(sessionsDir: URL, agentName: String) -> OpenClawSessionInfo? {
        let sessionsJsonPath = sessionsDir.appendingPathComponent("sessions.json")

        guard let data = try? Data(contentsOf: sessionsJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // sessions.json 的 key 格式: "agent:{agentName}:{channel}"
        // 找最新的 session
        var latestSession: OpenClawSessionInfo?

        for (key, value) in json {  // 使用 key 来保存 sessionKey
            guard let sessionData = value as? [String: Any],
                  let sessionId = sessionData["sessionId"] as? String,
                  let updatedAt = sessionData["updatedAt"] as? Double else {
                continue
            }

            let lastUpdate = Date(timeIntervalSince1970: updatedAt / 1000)
            let model = sessionData["model"] as? String ?? sessionData["modelOverride"] as? String

            // sessionFile 路径
            let sessionFile: URL?
            if let sessionFilePath = sessionData["sessionFile"] as? String {
                sessionFile = URL(fileURLWithPath: sessionFilePath)
            } else {
                // fallback: 根据 sessionId 查找 .jsonl 文件
                sessionFile = findTranscriptFile(sessionsDir: sessionsDir, sessionId: sessionId)
            }

            // cwd - 从 origin 或其他字段提取
            let cwd: String? = nil

            // 状态判断
            let aborted = sessionData["abortedLastRun"] as? Bool ?? false
            let status: SessionStatus = aborted ? .idle : .active

            let info = OpenClawSessionInfo(
                sessionId: sessionId,
                sessionKey: key,  // 保存 sessions.json 的 key
                lastUpdate: lastUpdate,
                model: model,
                cwd: cwd,
                sessionFile: sessionFile,
                status: status
            )

            if latestSession == nil || lastUpdate > latestSession!.lastUpdate {
                latestSession = info
            }
        }

        return latestSession
    }

    /// 在 sessions 目录中查找 transcript 文件
    private func findTranscriptFile(sessionsDir: URL, sessionId: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for file in files {
            if file.pathExtension == "jsonl" && file.lastPathComponent.contains(sessionId) {
                return file
            }
        }
        return nil
    }

    /// 从 agent 目录获取 cwd (workspace 目录)
    private func getCwdFromAgent(agentName: String) -> String? {
        // OpenClaw workspace 目录通常是 ~/.openclaw/workspace-{agentName}
        let workspacePath = NSHomeDirectory() + "/.openclaw/workspace-" + agentName
        if FileManager.default.fileExists(atPath: workspacePath) {
            return workspacePath
        }
        return nil
    }

    /// 从 transcript 文件解析最后消息
    private func parseLastMessageFromTranscript(sessionFile: URL?) -> String? {
        guard let file = sessionFile else {
            return nil
        }

        // 从后往前找最后一条 assistant 消息
        for line in Self.tailLines(file: file, maxBytes: 128 * 1024).reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "message" else {
                continue
            }

            // 检查是否是 assistant 消息
            if let message = json["message"] as? [String: Any],
               message["role"] as? String == "assistant",
               let contentArray = message["content"] as? [[String: Any]] {

                // 提取文本内容
                for item in contentArray.reversed() {
                    if let text = item["text"] as? String, !text.isEmpty {
                        let truncated = text.count > 100 ? String(text.prefix(100)) + "..." : text
                        return truncated
                    }
                    // 工具调用
                    if let toolName = item["name"] as? String {
                        return "🔧 \(toolName)"
                    }
                }
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

    // MARK: - Models

    struct OpenClawSessionInfo {
        let sessionId: String
        let sessionKey: String  // sessions.json 的 key，用于构建 URL
        let lastUpdate: Date
        let model: String?
        let cwd: String?
        let sessionFile: URL?
        let status: SessionStatus
    }
}
