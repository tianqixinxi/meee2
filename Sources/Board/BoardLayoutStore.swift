import Foundation
import Meee2CommKit

public enum BoardJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BoardJSONValue])
    case object([String: BoardJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BoardJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BoardJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    static func fromAny(_ raw: Any) -> BoardJSONValue? {
        if raw is NSNull { return .null }
        if let value = raw as? Bool { return .bool(value) }
        if let value = raw as? NSNumber { return .number(value.doubleValue) }
        if let value = raw as? String { return .string(value) }
        if let values = raw as? [Any] {
            return .array(values.compactMap(fromAny))
        }
        if let values = raw as? [String: Any] {
            var out: [String: BoardJSONValue] = [:]
            for (key, value) in values {
                if let converted = fromAny(value) {
                    out[key] = converted
                }
            }
            return .object(out)
        }
        return nil
    }
}

/// BoardLayoutStore —— 看板上的 canvas 持久化状态
///
/// 布局：`~/.meee2/board-layout.json`（单文件，原子覆写）
///
/// 搬到服务端的动机：之前只在浏览器 localStorage，换浏览器 / 清 storage 都丢；
/// 也没法在多个 tab 之间同步。现在：
///   - 所有 web 客户端 `GET /api/board/layout` 拿到同一份坐标、viewport、
///     用户自绘元素、dismissed/unread 集合
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

    public struct Viewport: Codable, Equatable {
        public let scrollX: Double
        public let scrollY: Double
        public let zoom: Double

        public init(scrollX: Double, scrollY: Double, zoom: Double) {
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.zoom = zoom
        }
    }

    public struct Layout: Codable, Equatable {
        public var sessions: [String: Point]
        public var channels: [String: Point]
        public var viewport: Viewport?
        public var userElements: [BoardJSONValue]
        public var dismissedSids: [String]
        public var unreadSids: [String]
        public var updatedAt: Date

        public init(
            sessions: [String: Point],
            channels: [String: Point],
            viewport: Viewport? = nil,
            userElements: [BoardJSONValue] = [],
            dismissedSids: [String] = [],
            unreadSids: [String] = [],
            updatedAt: Date
        ) {
            self.sessions = sessions
            self.channels = channels
            self.viewport = viewport
            self.userElements = userElements
            self.dismissedSids = dismissedSids
            self.unreadSids = unreadSids
            self.updatedAt = updatedAt
        }

        public static let empty = Layout(sessions: [:], channels: [:], updatedAt: Date(timeIntervalSince1970: 0))

        private enum CodingKeys: String, CodingKey {
            case sessions
            case channels
            case viewport
            case userElements
            case dismissedSids
            case unreadSids
            case updatedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decodeIfPresent([String: Point].self, forKey: .sessions) ?? [:]
            channels = try container.decodeIfPresent([String: Point].self, forKey: .channels) ?? [:]
            viewport = try container.decodeIfPresent(Viewport.self, forKey: .viewport)
            userElements = try container.decodeIfPresent([BoardJSONValue].self, forKey: .userElements) ?? []
            dismissedSids = try container.decodeIfPresent([String].self, forKey: .dismissedSids) ?? []
            unreadSids = try container.decodeIfPresent([String].self, forKey: .unreadSids) ?? []
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        }
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
            viewport: layout.viewport,
            userElements: layout.userElements,
            dismissedSids: layout.dismissedSids,
            unreadSids: layout.unreadSids,
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
            let next = Layout(
                sessions: nextSessions,
                channels: nextChannels,
                viewport: current.viewport,
                userElements: current.userElements,
                dismissedSids: current.dismissedSids,
                unreadSids: current.unreadSids,
                updatedAt: Date()
            )
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
