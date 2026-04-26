import Foundation

/// BoardLayoutStore —— 看板上 session 卡片 + channel hub 椭圆的画布坐标
///
/// 布局：`~/.meee2/board-layout.json`（单文件，原子覆写）
///
/// 搬到服务端的动机：之前只在浏览器 localStorage，换浏览器 / 清 storage 都丢；
/// 也没法在多个 tab 之间同步。现在：
///   - 所有 web 客户端 `GET /api/board/layout` 拿到同一份坐标
///   - 任一 tab `PUT` 后，server 存盘 + 通过 WS `state.changed` 广播，其他 tab
///     下一次拉 state 时顺便刷新画布（或单独重新 GET layout）
///
/// 线程安全：通过串行队列互斥。
public final class BoardLayoutStore {
    public static let shared = BoardLayoutStore()

    public struct Point: Codable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Layout: Codable, Equatable {
        public var sessions: [String: Point]
        public var channels: [String: Point]
        public var updatedAt: Date

        public init(sessions: [String: Point], channels: [String: Point], updatedAt: Date) {
            self.sessions = sessions
            self.channels = channels
            self.updatedAt = updatedAt
        }

        public static let empty = Layout(sessions: [:], channels: [:], updatedAt: Date(timeIntervalSince1970: 0))
    }

    private let fileManager = FileManager.default
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.meee2.BoardLayoutStore", qos: .utility)
    private var cached: Layout?

    private init() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            MWarn("[BoardLayoutStore] failed to create dir \(dir.path): \(error)")
        }
        self.fileURL = dir.appendingPathComponent("board-layout.json")
    }

    // MARK: - Public API

    /// 读取当前 layout；文件不存在返回 `.empty`
    public func load() -> Layout {
        queue.sync {
            if let cached = cached { return cached }
            let loaded = loadFromDiskLocked()
            cached = loaded
            return loaded
        }
    }

    /// 整体替换 layout（web 客户端 PUT 的典型路径）。成功后发布
    /// `.boardLayoutChanged` 到事件总线。
    @discardableResult
    public func save(_ layout: Layout) throws -> Layout {
        let stamped = Layout(
            sessions: layout.sessions,
            channels: layout.channels,
            updatedAt: Date()
        )
        try queue.sync {
            try writeToDiskLocked(stamped)
            cached = stamped
        }
        SessionEventBus.shared.publish(.boardLayoutChanged)
        return stamped
    }

    /// 合并更新：传入的 sessions / channels 覆盖同名 key，其他 key 保留。
    /// 目前不公开暴露到 API，仅作为未来 partial-update 扩展点保留。
    @discardableResult
    public func merge(sessions: [String: Point]?, channels: [String: Point]?) throws -> Layout {
        let merged: Layout = try queue.sync {
            let current = cached ?? loadFromDiskLocked()
            var nextSessions = current.sessions
            var nextChannels = current.channels
            if let s = sessions {
                for (k, v) in s { nextSessions[k] = v }
            }
            if let c = channels {
                for (k, v) in c { nextChannels[k] = v }
            }
            let next = Layout(sessions: nextSessions, channels: nextChannels, updatedAt: Date())
            try writeToDiskLocked(next)
            cached = next
            return next
        }
        SessionEventBus.shared.publish(.boardLayoutChanged)
        return merged
    }

    // MARK: - Disk I/O（must be called inside `queue`）

    private func loadFromDiskLocked() -> Layout {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Layout.self, from: data)
        } catch {
            MWarn("[BoardLayoutStore] failed to decode \(fileURL.path): \(error); starting empty")
            return .empty
        }
    }

    private func writeToDiskLocked(_ layout: Layout) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(layout)
        // 原子写：先写 .tmp.<pid>，再用 replaceItemAt（背后是 POSIX rename(2)，
        // 同一文件系统下原子；旧版本是 remove + move，崩在中间会只剩 .tmp.<pid>，
        // 而正式文件不存在）。
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = fileURL.appendingPathExtension("tmp.\(pid)")
        try? fileManager.removeItem(at: tmp)
        try data.write(to: tmp, options: [.atomic])
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            // 文件还不存在：replaceItemAt 在原 URL 不存在时会抛错；走 moveItem。
            try fileManager.moveItem(at: tmp, to: fileURL)
        }
    }
}
