import Foundation
import Combine
import Meee2PluginKit

/// 监听 Claude CLI sessions 目录变化的服务
/// 通过文件系统事件检测新 session、session 结束等
class SessionMonitor: ObservableObject {
    // MARK: - Published Properties

    /// 当前活跃的 sessions
    @Published var sessions: [AISession] = []

    /// 监控状态
    @Published var isMonitoring: Bool = false

    // MARK: - Private Properties

    /// Sessions 目录路径
    private let sessionsPath: URL

    /// 文件系统事件源
    private var fileSource: DispatchSourceFileSystemObject?

    /// 定时刷新 Timer
    private var refreshTimer: Timer?

    /// 解析队列
    private let parseQueue = DispatchQueue(label: "com.meee2.sessionparse", qos: .userInitiated)

    // MARK: - Initialization

    init() {
        let home = NSHomeDirectory()
        sessionsPath = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude")
            .appendingPathComponent("sessions")
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// 开始监听 sessions 目录
    func startMonitoring() {
        guard !isMonitoring else { return }

        // 确保目录存在
        guard FileManager.default.fileExists(atPath: sessionsPath.path) else {
            NSLog("[SessionMonitor] Sessions directory not found: \(sessionsPath.path)")
            return
        }

        // 初始加载
        refreshSessions()

        // 设置文件系统监听
        setupFileWatcher()

        // 设置定时刷新 (每 2 秒检查一次，作为文件监听的补充)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }

        isMonitoring = true
        NSLog("[SessionMonitor] Started monitoring: \(sessionsPath.path)")
    }

    /// 停止监听
    func stopMonitoring() {
        fileSource?.cancel()
        fileSource = nil

        refreshTimer?.invalidate()
        refreshTimer = nil

        isMonitoring = false
        MLog("[SessionMonitor] Stopped")
    }

    /// 手动刷新 sessions
    func refreshSessions() {
        parseQueue.async { [weak self] in
            guard let self = self else { return }
            let newSessions = self.loadSessionsFromDirectory()

            DispatchQueue.main.async {
                // 合并现有状态
                self.sessions = self.mergeSessions(newSessions, existing: self.sessions)
            }
        }
    }

    // MARK: - Private Methods

    /// 设置文件系统事件监听
    private func setupFileWatcher() {
        let descriptor = open(sessionsPath.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("[SessionMonitor] Failed to open directory for monitoring")
            return
        }

        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: parseQueue
        )

        fileSource?.setEventHandler { [weak self] in
            self?.refreshSessions()
        }

        fileSource?.setCancelHandler {
            close(descriptor)
        }

        fileSource?.resume()
    }

    /// 从目录加载所有 session 文件
    private func loadSessionsFromDirectory() -> [AISession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsPath,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            NSLog("[SessionMonitor] No sessions found at path: \(sessionsPath.path)")
            return []
        }

        var sessions: [AISession] = []

        for fileURL in files {
            // Session 文件名是 PID.json 格式
            guard fileURL.pathExtension == "json" else { continue }

            if let session = parseSessionFile(fileURL) {
                sessions.append(session)
            }
        }

        return sessions
    }

    /// 解析单个 session 文件
    /// Session 文件是 JSON 格式，包含 sessionId, pid, cwd 等
    private func parseSessionFile(_ url: URL) -> AISession? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let jsonData = content.data(using: .utf8) ?? Data()
        guard var session = try? JSONDecoder().decode(AISession.self, from: jsonData) else {
            return nil
        }

        // 检查进程是否仍然存活
        let isAlive = checkProcessAlive(pid: session.pid)
        if !isAlive {
            // 进程已结束，标记为完成状态
            session.status = .completed
        }

        return session
    }

    /// 检查进程是否存活
    private func checkProcessAlive(pid: Int) -> Bool {
        // 使用 kill(pid, 0) 检查进程是否存在
        // 返回 0 表示进程存在，返回 -1 表示不存在或无权限
        let result = kill(pid_t(pid), 0)
        return result == 0
    }

    /// 合新旧 sessions，保留运行时状态
    private func mergeSessions(_ newSessions: [AISession], existing: [AISession]) -> [AISession] {
        var merged: [AISession] = []
        var existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for newSession in newSessions {
            if let existingSession = existingMap[newSession.id] {
                // 保留运行时状态，只更新基本信息
                var mergedSession = newSession
                mergedSession.status = existingSession.status
                mergedSession.currentTask = existingSession.currentTask
                mergedSession.toolName = existingSession.toolName
                mergedSession.lastUpdated = existingSession.lastUpdated
                mergedSession.progress = existingSession.progress
                mergedSession.errorMessage = existingSession.errorMessage
                merged.append(mergedSession)
                existingMap.removeValue(forKey: newSession.id)
            } else {
                // 新 session
                merged.append(newSession)
            }
        }

        // 已结束的 sessions (文件已删除但进程可能刚结束)
        // 如果用户想保留历史，可以添加逻辑保留一段时间

        return merged.sorted { $0.startedAt > $1.startedAt }
    }

    /// 根据 sessionId 更新 session 状态
    func updateSessionStatus(sessionId: String, status: SessionStatus, task: String? = nil, tool: String? = nil) {
        DispatchQueue.main.async {
            if let index = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                self.sessions[index] = self.sessions[index].withStatus(status, task: task, tool: tool)
            }
        }
    }
}