import Foundation
import SwiftUI
import PeerPluginKit

class CursorPlugin: AIPlugin {
    // MARK: - 标识

    override var pluginId: String { "com.peerisland.plugin.cursor" }
    override var displayName: String { "Cursor" }
    override var icon: String { "cursorarrow" }
    override var themeColor: Color { .blue }
    override var version: String { "1.0.0" }
    override var helpUrl: String? { "https://docs.cursor.com/peerisland-plugin" }

    // MARK: - Private

    private var isRunning = false
    private var refreshTimer: Timer?

    // 追踪上次的消息，用于检测新消息
    private var lastMessages: [String: String] = [:]  // sessionId -> lastMessageHash

    // 刷新间隔（秒）
    @AppStorage("cursorRefreshInterval") private var refreshInterval: Double = 10.0

    // Cursor projects 路径
    private let cursorProjectsPath: URL = {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor")
            .appendingPathComponent("projects")
    }()

    // 活跃时间阈值（秒）
    private let activeThreshold: TimeInterval = 300  // 5分钟

    // MARK: - Lifecycle

    override func initialize() -> Bool { true }

    override func start() -> Bool {
        guard !isRunning else { return true }

        isRunning = true

        // 初始加载（不触发 urgent）
        let sessions = getSessions()
        for session in sessions {
            if let subtitle = session.subtitle {
                lastMessages[session.id] = subtitle
            }
        }
        onSessionsUpdated?(sessions)

        startTimer()

        NSLog("[CursorPlugin] Started, watching: \(cursorProjectsPath.path)")
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
    }

    override func cleanup() { stop() }

    // MARK: - Session Management

    override func getSessions() -> [Session] {
        scanCursorProjects()
    }

    override func refresh() {
        let sessions = getSessions()

        for session in sessions {
            guard let newMessage = session.subtitle else { continue }
            let prev = lastMessages[session.id]
            if prev != newMessage {
                if prev != nil {
                    // 新消息，触发 urgent event
                    NSLog("[CursorPlugin] New message for \(session.title): \(newMessage.prefix(50))...")
                    let event = UrgentEvent(message: newMessage, eventType: "NewMessage")
                    onUrgentEvent?(session, event)
                }
                lastMessages[session.id] = newMessage
            }
        }

        onSessionsUpdated?(sessions)
    }

    // MARK: - 状态映射

    override func mapStatus(_ nativeStatus: String) -> SessionStatus {
        switch nativeStatus {
        case "active": return .active
        case "idle": return .idle
        default: return .active
        }
    }

    // MARK: - Terminal

    override func activateTerminal(for session: Session) {
        if let cwd = session.cwd {
            openCursor(at: cwd)
        } else {
            openCursorApp()
        }
    }

    // MARK: - Private

    private func scanCursorProjects() -> [Session] {
        guard FileManager.default.fileExists(atPath: cursorProjectsPath.path) else { return [] }

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: cursorProjectsPath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [Session] = []

        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            let transcriptsDir = projectDir.appendingPathComponent("agent-transcripts")
            guard FileManager.default.fileExists(atPath: transcriptsDir.path) else { continue }

            let projectName = parseProjectName(from: projectDir.lastPathComponent)
            let projectPath = parseProjectPath(from: projectDir.lastPathComponent)

            if let (lastActivity, lastMessage) = getLastTranscriptActivity(transcriptsDir: transcriptsDir) {
                let timeSinceActivity = Date().timeIntervalSince(lastActivity)
                let isActive = timeSinceActivity < activeThreshold
                let status: SessionStatus = isActive ? .active : .idle

                if timeSinceActivity < 3600 {
                    let session = Session(
                        id: "\(pluginId):\(projectDir.lastPathComponent)",
                        pluginId: pluginId,
                        title: projectName,
                        status: status,
                        startedAt: lastActivity,
                        lastUpdated: lastActivity,
                        subtitle: lastMessage,
                        cwd: projectPath,
                        iconOverride: "cursorarrow"
                    )
                    sessions.append(session)
                }
            }
        }

        sessions.sort { $0.startedAt > $1.startedAt }
        return sessions
    }

    private func parseProjectName(from dirName: String) -> String {
        let parts = dirName.split(separator: "-")
        if let last = parts.last { return String(last) }
        return dirName
    }

    private func parseProjectPath(from dirName: String) -> String? {
        let parts = dirName.split(separator: "-")
        if parts.first == "Users" && parts.count >= 2 {
            let directPath = "/" + dirName.replacingOccurrences(of: "-", with: "/")
            if FileManager.default.fileExists(atPath: directPath) { return directPath }

            for i in 2..<parts.count {
                var testParts = parts.map(String.init)
                if i < testParts.count - 1 {
                    let combined = testParts[i] + "-" + testParts[i + 1]
                    testParts.remove(at: i + 1)
                    testParts[i] = combined
                    let testPath = "/" + testParts.joined(separator: "/")
                    if FileManager.default.fileExists(atPath: testPath) { return testPath }
                }
            }
        }
        return nil
    }

    private func getLastTranscriptActivity(transcriptsDir: URL) -> (Date, String?)? {
        guard let transcriptDirs = try? FileManager.default.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latestDate: Date?
        var latestFile: URL?

        for transcriptDir in transcriptDirs where transcriptDir.hasDirectoryPath {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: transcriptDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

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

        var lastMessage: String?
        if let file = latestFile {
            lastMessage = parseLastAssistantMessage(from: file)
        }

        if let date = latestDate { return (date, lastMessage) }
        return nil
    }

    private func parseLastAssistantMessage(from file: URL) -> String? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        for line in content.components(separatedBy: "\n").reversed() where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["role"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let contentArray = message["content"] as? [[String: Any]] else { continue }

            let fullText = contentArray.compactMap { $0["text"] as? String }.joined(separator: " ")
            if fullText.isEmpty { return nil }
            return fullText.count > 100 ? String(fullText.prefix(100)) + "..." : fullText
        }
        return nil
    }

    private func openCursor(at path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "Cursor", path]
        try? task.run()
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
