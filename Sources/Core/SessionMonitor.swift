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

    /// provider 目录尚未创建时，监听最近存在的父目录。
    private var parentSource: DispatchSourceFileSystemObject?
    private var watchedParentPath: String?
    private var didLogMissingDirectory = false

    /// 文件事件丢失时的补偿轮询。DispatchSource 不依赖调用线程的 RunLoop。
    private var refreshTimer: DispatchSourceTimer?

    /// 与文件源、定时器共享同一个隔离队列，避免首次启动恢复与 stop 竞态。
    private var monitoringEnabled = false
    private let parseQueueKey = DispatchSpecificKey<UInt8>()

    /// 解析队列
    private let parseQueue = DispatchQueue(label: "com.meee2.sessionparse", qos: .userInitiated)

    /// Internal observation hook used by first-run recovery tests/readiness probes.
    var onDirectoryWatcherAttached: (() -> Void)?

    // MARK: - Initialization

    convenience init() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.init(sessionsPath: home.appendingPathComponent(".claude/sessions", isDirectory: true))
    }

    init(sessionsPath: URL) {
        self.sessionsPath = sessionsPath
        parseQueue.setSpecific(key: parseQueueKey, value: 1)
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// 开始监听 sessions 目录
    func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true
        syncOnParseQueue {
            monitoringEnabled = true
            ensureDirectoryWatcher()

            let timer = DispatchSource.makeTimerSource(queue: parseQueue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                self?.ensureDirectoryWatcher()
            }
            timer.resume()
            refreshTimer = timer
        }
        NSLog("[SessionMonitor] Started monitoring: \(sessionsPath.path)")
    }

    /// 停止监听
    func stopMonitoring() {
        syncOnParseQueue {
            monitoringEnabled = false
            fileSource?.cancel()
            fileSource = nil
            parentSource?.cancel()
            parentSource = nil
            watchedParentPath = nil
            didLogMissingDirectory = false
            refreshTimer?.cancel()
            refreshTimer = nil
        }

        isMonitoring = false
        MLog("[SessionMonitor] Stopped")
    }

    /// 手动刷新 sessions
    func refreshSessions() {
        parseQueue.async { [weak self] in
            self?.refreshSessionsOnParseQueue()
        }
    }

    /// 供 readiness/测试触发一次立即恢复；不需要重启插件。
    func retryMonitoringNow() {
        syncOnParseQueue {
            ensureDirectoryWatcher()
        }
    }

    var isWatchingDirectory: Bool {
        syncOnParseQueue { fileSource != nil }
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
            guard let self else { return }
            let flags = self.fileSource?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.fileSource?.cancel()
                self.fileSource = nil
                self.ensureDirectoryWatcher()
                return
            }
            self.refreshSessionsOnParseQueue()
        }

        fileSource?.setCancelHandler {
            close(descriptor)
        }

        fileSource?.resume()
        onDirectoryWatcherAttached?()
    }

    private func ensureDirectoryWatcher() {
        guard monitoringEnabled else { return }
        guard FileManager.default.fileExists(atPath: sessionsPath.path) else {
            if fileSource != nil {
                fileSource?.cancel()
                fileSource = nil
            }
            setupParentWatcher()
            if !didLogMissingDirectory {
                NSLog("[SessionMonitor] Sessions directory not found yet: \(sessionsPath.path)")
                didLogMissingDirectory = true
            }
            return
        }
        didLogMissingDirectory = false
        parentSource?.cancel()
        parentSource = nil
        watchedParentPath = nil
        if fileSource == nil {
            setupFileWatcher()
        }
        refreshSessionsOnParseQueue()
    }

    /// 监听最近存在的祖先；当 `.claude` 或 `sessions` 首次出现时立即重试。
    private func setupParentWatcher() {
        var candidate = sessionsPath.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        guard watchedParentPath != candidate.path else { return }

        parentSource?.cancel()
        parentSource = nil
        watchedParentPath = nil

        let descriptor = open(candidate.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("[SessionMonitor] Failed to watch parent directory: \(candidate.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: parseQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.parentSource?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self.parentSource?.cancel()
                self.parentSource = nil
                self.watchedParentPath = nil
            }
            self.ensureDirectoryWatcher()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        parentSource = source
        watchedParentPath = candidate.path
    }

    private func refreshSessionsOnParseQueue() {
        let newSessions = loadSessionsFromDirectory()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessions = self.mergeSessions(newSessions, existing: self.sessions)
        }
    }

    private func syncOnParseQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: parseQueueKey) != nil {
            return work()
        }
        return parseQueue.sync(execute: work)
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
        if let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            session.lastUpdated = modifiedAt
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
    /// internal（非 private）以便 SessionMonitorMergeTests 直接验证去重，详见该测试。
    func mergeSessions(_ newSessions: [AISession], existing: [AISession]) -> [AISession] {
        var merged: [AISession] = []
        // Dedupe by sessionId: a respawn (or two live `claude` subprocesses for
        // the same session, which Claude.app does sometimes) can leave several
        // PID.json files in `~/.claude/sessions/` keyed to the same sessionId —
        // a session restore was observed to leave 7. Collapse `newSessions` by id
        // FIRST: each duplicate not matched against `existing` would otherwise fall
        // into the "new session" branch below and surface as a duplicate card.
        // Keep the most-recently-updated file (`uniqueKeysWithValues` would also
        // fatal-error on the dup).
        let dedupedNew = Dictionary(newSessions.map { ($0.id, $0) },
                                    uniquingKeysWith: { current, next in
                                        next.lastUpdated >= current.lastUpdated ? next : current
                                    }).values
        var existingMap = Dictionary(existing.map { ($0.id, $0) },
                                     uniquingKeysWith: { _, latest in latest })

        for newSession in dedupedNew {
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
