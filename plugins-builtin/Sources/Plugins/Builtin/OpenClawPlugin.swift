import Foundation
import SwiftUI
import Meee2PluginKit

class OpenClawPlugin: SessionPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.meee2.plugin.openclaw" }
    override var displayName: String { "OpenClaw" }
    override var icon: String { "house.fill" }
    override var themeColor: Color { .red }
    override var version: String { "0.1.2" }
    override var helpUrl: String? { nil }

    // MARK: - Private

    private var isRunning = false
    private var refreshTimer: Timer?

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash

    // 保存 session.id -> sessionKey 的映射，用于构建 URL
    private var sessionKeyMap: [String: String] = [:]

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

    // 活跃时间阈值（秒）- session 更新时间在此阈值内视为活跃
    private let activeThreshold: TimeInterval = 3600  // 1小时

    // MARK: - Lifecycle

    override func initialize() -> Bool {
        return true
    }

    override func start() -> Bool {
        guard !isRunning else { return true }

        isRunning = true

        // 初始加载 - 使用 lastMessage 初始化
        let sessions = getSessions()
        for session in sessions {
            if let lastMessage = session.lastMessage {
                lastMessages[session.id] = lastMessage
            }
        }
        onSessionsUpdated?(sessions)

        // 启动定时器
        startTimer()

        NSLog("[OpenClawPlugin] Started, watching: \(openclawAgentsPath.path), interval: \(refreshInterval)s")
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
        let sessions = getSessions()
        NSLog("[OpenClawPlugin] Refresh: found \(sessions.count) sessions")

        // 检测新消息 - 使用 lastMessage 而不是 subtitle
        for session in sessions {
            let newMessage = session.lastMessage
            let previousMessage = lastMessages[session.id]

            NSLog("[OpenClawPlugin] Session \(session.title): newMessage=\(newMessage?.prefix(30) ?? "nil"), previousMessage=\(previousMessage?.prefix(30) ?? "nil")")

            if let msg = newMessage, previousMessage != msg {
                if previousMessage != nil {
                    NSLog("[OpenClawPlugin] *** TRIGGERING URGENT EVENT for \(session.title): \(msg.prefix(50))...")
                    onUrgentEvent?(session, msg, nil)
                } else {
                    NSLog("[OpenClawPlugin] First load, skipping urgent for \(session.title)")
                }
                lastMessages[session.id] = msg
            }
        }

        onSessionsUpdated?(sessions)
    }

    // MARK: - Terminal

    override func activateTerminal(for session: PluginSession) {
        // 打开 OpenClaw web UI
        let sessionKey = sessionKeyMap[session.id] ?? "agent:\(session.title):main"
        let urlString = "http://127.0.0.1:18789/chat?session=" + sessionKey

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            NSLog("[OpenClawPlugin] Opening URL: \(urlString)")
        }
    }

    // MARK: - Urgent Event

    override func clearUrgentEvent(sessionId: String) {
        lastMessages.removeValue(forKey: sessionId)
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

            // 解析 sessions.json 获取活跃 session
            if let sessionInfo = parseSessionsJson(sessionsDir: sessionsDir, agentName: agentName) {
                // 检查是否在活跃时间阈值内
                let timeSinceUpdate = Date().timeIntervalSince(sessionInfo.lastUpdate)
                if timeSinceUpdate < activeThreshold {
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
                    sessionKeyMap[fullSessionId] = sessionInfo.sessionKey

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
        }

        // 按更新时间排序
        sessions.sort { $0.startedAt > $1.startedAt }

        NSLog("[OpenClawPlugin] Found \(sessions.count) active agents")
        return sessions
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
        guard let file = sessionFile,
              let content = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        // 从后往前找最后一条 assistant 消息
        for line in lines.reversed() {
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