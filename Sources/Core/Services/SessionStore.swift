import Foundation
import PeerPluginKit

/// 统一会话持久化
/// 采用 CSM 的原子写入模式：写入 .tmp 文件后 rename
class SessionStore {
    static let shared = SessionStore()

    private let sessionsDir: URL
    private let queue = DispatchQueue(label: "com.peerisland.sessionstore")
    private var cache: [String: Session] = [:]

    init(baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peer-island")
        self.sessionsDir = base.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - CRUD

    func upsert(_ session: Session) {
        queue.async { [self] in
            cache[session.id] = session
            atomicWrite(session)
        }
    }

    func get(_ sessionId: String) -> Session? {
        queue.sync { cache[sessionId] }
    }

    func getAll() -> [Session] {
        queue.sync { Array(cache.values) }
    }

    func getAllByPlugin(_ pluginId: String) -> [Session] {
        queue.sync { cache.values.filter { $0.pluginId == pluginId } }
    }

    func remove(_ sessionId: String) {
        queue.async { [self] in
            cache.removeValue(forKey: sessionId)
            let path = sessionPath(for: sessionId)
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// 清理过期会话 (默认 24 小时)
    func cleanupExpired(olderThan interval: TimeInterval = 86400) {
        queue.async { [self] in
            let cutoff = Date().addingTimeInterval(-interval)
            let expired = cache.values.filter { $0.lastUpdated < cutoff && !$0.status.isWorking }
            for session in expired {
                cache.removeValue(forKey: session.id)
                try? FileManager.default.removeItem(at: sessionPath(for: session.id))
            }
        }
    }

    // MARK: - 内部

    private func sessionPath(for id: String) -> URL {
        // 将 ID 中的特殊字符替换为安全字符
        let safeName = id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sessionsDir.appendingPathComponent("\(safeName).json")
    }

    /// 原子写入：先写到 .tmp，再 rename
    private func atomicWrite(_ session: Session) {
        let path = sessionPath(for: session.id)
        let tmpPath = path.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: tmpPath)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
        }
    }

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(Session.self, from: data) else {
                continue
            }
            cache[session.id] = session
        }
    }
}
