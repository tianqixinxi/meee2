import Foundation

/// Session 与终端的映射信息
struct SessionTerminalInfo: Codable {
    let sessionId: String
    var tty: String?
    var termProgram: String?
    var termBundleId: String?
    var cwd: String
    var lastActivityAt: Date
    var status: String

    // cmux 专用
    var cmuxSocketPath: String?
    var cmuxSurfaceId: String?
}

/// 持久化 Session-Terminal 映射
/// 存储位置: ~/.meee2/session-terminals.json
class SessionTerminalStore {
    static let shared = SessionTerminalStore()

    private let fileManager = FileManager.default
    private let storeURL: URL
    private var store: [String: SessionTerminalInfo] = [:]
    private let queue = DispatchQueue(label: "com.meee2.terminalstore", qos: .utility)

    private init() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        storeURL = dir.appendingPathComponent("session-terminals.json")

        // 确保目录存在
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        load()

        // 启动时清理过期 session
        cleanupExpired()
    }

    // MARK: - Public Methods

    /// 更新 session 的终端信息
    func update(sessionId: String, tty: String?, termProgram: String?, termBundleId: String?, cmuxSocketPath: String?, cmuxSurfaceId: String?, cwd: String, status: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            var info = self.store[sessionId] ?? SessionTerminalInfo(
                sessionId: sessionId,
                tty: tty,
                termProgram: termProgram,
                termBundleId: termBundleId,
                cwd: cwd,
                lastActivityAt: Date(),
                status: status,
                cmuxSocketPath: cmuxSocketPath,
                cmuxSurfaceId: cmuxSurfaceId
            )

            info.tty = tty ?? info.tty
            info.termProgram = termProgram ?? info.termProgram
            info.termBundleId = termBundleId ?? info.termBundleId
            info.cmuxSocketPath = cmuxSocketPath ?? info.cmuxSocketPath
            info.cmuxSurfaceId = cmuxSurfaceId ?? info.cmuxSurfaceId
            info.cwd = cwd
            info.lastActivityAt = Date()
            info.status = status

            self.store[sessionId] = info
            self.save()

            NSLog("[SessionTerminalStore] Updated session \(sessionId.prefix(8)): tty=\(tty ?? "nil"), term=\(termProgram ?? "nil"), cmuxSocket=\(cmuxSocketPath ?? "nil")")
        }
    }

    /// 获取 session 的终端信息
    func get(sessionId: String) -> SessionTerminalInfo? {
        return queue.sync {
            store[sessionId]
        }
    }

    /// 获取所有存储的 session
    func getAll() -> [String: SessionTerminalInfo] {
        return queue.sync {
            store
        }
    }

    /// 删除已结束的 session
    func remove(sessionId: String) {
        queue.async { [weak self] in
            self?.store.removeValue(forKey: sessionId)
            self?.save()
        }
    }

    /// 清理过期 session (超过 24 小时无活动)
    func cleanupExpired() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let threshold = Date().addingTimeInterval(-24 * 60 * 60)
            let before = self.store.count

            self.store = self.store.filter { $0.value.lastActivityAt > threshold }

            let removed = before - self.store.count
            if removed > 0 {
                NSLog("[SessionTerminalStore] Cleaned up \(removed) expired sessions")
                self.save()
            }
        }
    }

    // MARK: - Private Methods

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: SessionTerminalInfo].self, from: data) else {
            NSLog("[SessionTerminalStore] No existing store found, starting fresh")
            return
        }

        store = decoded
        NSLog("[SessionTerminalStore] Loaded \(store.count) session-terminal mappings")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL)
    }
}
