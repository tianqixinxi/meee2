import Foundation

/// 频道注册表错误
public enum ChannelRegistryError: Error, CustomStringConvertible {
    case alreadyExists(String)
    case notFound(String)
    case aliasTaken(String)
    case aliasNotFound(String)
    /// 合法名：小写字母数字 + `-` + `_`，长度 1..64
    case invalidName(String)

    public var description: String {
        switch self {
        case .alreadyExists(let n): return "channel already exists: \(n)"
        case .notFound(let n): return "channel not found: \(n)"
        case .aliasTaken(let a): return "alias already taken in channel: \(a)"
        case .aliasNotFound(let a): return "alias not found in channel: \(a)"
        case .invalidName(let n): return "invalid channel name: \(n) (allowed: [a-z0-9_-], 1..64 chars)"
        }
    }
}

/// 频道注册表 - 管理所有频道的创建、成员关系、持久化
/// 持久化位置: ~/.meee2/channels/<name>.json
/// 线程安全：所有公开方法通过串行 DispatchQueue 同步
public final class ChannelRegistry {
    public static let shared = ChannelRegistry()

    private let fileManager = FileManager.default
    private let baseDir: URL
    private let channelsDir: URL

    /// 内存缓存（name -> Channel），所有访问必须持 queue
    private var cache: [String: Channel] = [:]

    /// 串行队列，保证注册表操作的线程安全
    private let queue = DispatchQueue(label: "com.meee2.channel-registry", qos: .userInitiated)

    private init() {
        let home = NSHomeDirectory()
        baseDir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        channelsDir = baseDir.appendingPathComponent("channels")

        try? fileManager.createDirectory(at: channelsDir, withIntermediateDirectories: true)

        loadAll()
    }

    // MARK: - Public API

    /// 列出所有频道（按创建时间降序）
    public func list() -> [Channel] {
        queue.sync {
            Array(cache.values).sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// 获取指定频道
    public func get(_ name: String) -> Channel? {
        queue.sync { cache[name] }
    }

    /// 创建新频道
    @discardableResult
    public func create(name: String, description: String? = nil, mode: ChannelMode = .auto) throws -> Channel {
        try Self.validateName(name)

        let created: Channel = try queue.sync {
            if cache[name] != nil {
                throw ChannelRegistryError.alreadyExists(name)
            }
            let channel = Channel(name: name, members: [], mode: mode, createdAt: Date(), description: description)
            try persist(channel)
            cache[name] = channel
            MInfo("[ChannelRegistry] Created channel '\(name)' mode=\(mode.rawValue)")
            return channel
        }
        SessionEventBus.shared.publish(.channelMutated(name: name))
        return created
    }

    /// 删除频道
    public func delete(_ name: String) throws {
        try queue.sync {
            guard cache[name] != nil else {
                throw ChannelRegistryError.notFound(name)
            }
            let path = channelPath(name)
            try? fileManager.removeItem(at: path)
            cache.removeValue(forKey: name)
            MInfo("[ChannelRegistry] Deleted channel '\(name)'")
        }
        SessionEventBus.shared.publish(.channelMutated(name: name))
    }

    /// 让会话以某个别名加入频道
    @discardableResult
    public func join(channel: String, alias: String, sessionId: String) throws -> Channel {
        let result: Channel = try queue.sync {
            guard var ch = cache[channel] else {
                throw ChannelRegistryError.notFound(channel)
            }
            if ch.members.contains(where: { $0.alias == alias }) {
                throw ChannelRegistryError.aliasTaken(alias)
            }
            ch.members.append(ChannelMember(alias: alias, sessionId: sessionId))
            try persist(ch)
            cache[channel] = ch
            MInfo("[ChannelRegistry] Join '\(channel)' alias=\(alias) session=\(sessionId.prefix(8))")
            return ch
        }
        SessionEventBus.shared.publish(.channelMutated(name: channel))
        return result
    }

    /// 让某个别名退出频道
    @discardableResult
    public func leave(channel: String, alias: String) throws -> Channel {
        let result: Channel = try queue.sync {
            guard var ch = cache[channel] else {
                throw ChannelRegistryError.notFound(channel)
            }
            guard ch.members.contains(where: { $0.alias == alias }) else {
                throw ChannelRegistryError.aliasNotFound(alias)
            }
            ch.members.removeAll { $0.alias == alias }
            try persist(ch)
            cache[channel] = ch
            MInfo("[ChannelRegistry] Leave '\(channel)' alias=\(alias)")
            return ch
        }
        SessionEventBus.shared.publish(.channelMutated(name: channel))
        return result
    }

    /// 切换频道模式
    @discardableResult
    public func setMode(_ name: String, mode: ChannelMode) throws -> Channel {
        let result: Channel = try queue.sync {
            guard var ch = cache[name] else {
                throw ChannelRegistryError.notFound(name)
            }
            ch.mode = mode
            try persist(ch)
            cache[name] = ch
            MInfo("[ChannelRegistry] setMode '\(name)' -> \(mode.rawValue)")
            return ch
        }
        SessionEventBus.shared.publish(.channelMutated(name: name))
        return result
    }

    /// 通用更新（在 mutate 回调内修改一份副本）
    @discardableResult
    public func update(_ name: String, mutate: (inout Channel) -> Void) throws -> Channel {
        let result: Channel = try queue.sync {
            guard var ch = cache[name] else {
                throw ChannelRegistryError.notFound(name)
            }
            mutate(&ch)
            try persist(ch)
            cache[name] = ch
            return ch
        }
        SessionEventBus.shared.publish(.channelMutated(name: name))
        return result
    }

    // MARK: - Validation

    /// 合法名：小写字母数字 + `-` + `_`，长度 1..64
    public static func validateName(_ name: String) throws {
        if name.isEmpty || name.count > 64 {
            throw ChannelRegistryError.invalidName(name)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw ChannelRegistryError.invalidName(name)
        }
    }

    // MARK: - Persistence (must be called on queue)

    private func channelPath(_ name: String) -> URL {
        channelsDir.appendingPathComponent("\(name).json")
    }

    private func persist(_ channel: Channel) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(channel)

        let path = channelPath(channel.name)
        // 原子写入
        try data.write(to: path, options: .atomic)
    }

    private func loadAll() {
        queue.sync {
            cache.removeAll()
            guard let files = try? fileManager.contentsOfDirectory(at: channelsDir, includingPropertiesForKeys: nil) else {
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file) else { continue }
                guard let ch = try? decoder.decode(Channel.self, from: data) else {
                    MWarn("[ChannelRegistry] Failed to decode \(file.lastPathComponent)")
                    continue
                }
                cache[ch.name] = ch
            }
            MDebug("[ChannelRegistry] Loaded \(cache.count) channel(s)")
        }
    }
}
