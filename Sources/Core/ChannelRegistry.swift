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
        let prevMembers: [ChannelMember]
        let result: Channel
        (prevMembers, result) = try queue.sync { () -> ([ChannelMember], Channel) in
            guard var ch = cache[channel] else {
                throw ChannelRegistryError.notFound(channel)
            }
            if ch.members.contains(where: { $0.alias == alias }) {
                throw ChannelRegistryError.aliasTaken(alias)
            }
            let prev = ch.members
            ch.members.append(ChannelMember(alias: alias, sessionId: sessionId))
            try persist(ch)
            cache[channel] = ch
            MInfo("[ChannelRegistry] Join '\(channel)' alias=\(alias) session=\(sessionId.prefix(8))")
            return (prev, ch)
        }
        SessionEventBus.shared.publish(.channelMutated(name: channel))
        // Orientation: bilateral notification when a real session joins a real
        // (non-operator) channel. Best-effort — failures don't roll back join.
        notifyOrientation(
            channel: channel,
            event: .joined(alias: alias, sessionId: sessionId),
            otherMembers: prevMembers
        )
        return result
    }

    /// 让某个别名退出频道
    @discardableResult
    public func leave(channel: String, alias: String) throws -> Channel {
        let leftMember: ChannelMember?
        let result: Channel
        (leftMember, result) = try queue.sync { () -> (ChannelMember?, Channel) in
            guard var ch = cache[channel] else {
                throw ChannelRegistryError.notFound(channel)
            }
            guard let leaving = ch.members.first(where: { $0.alias == alias }) else {
                throw ChannelRegistryError.aliasNotFound(alias)
            }
            ch.members.removeAll { $0.alias == alias }
            try persist(ch)
            cache[channel] = ch
            MInfo("[ChannelRegistry] Leave '\(channel)' alias=\(alias)")
            return (leaving, ch)
        }
        SessionEventBus.shared.publish(.channelMutated(name: channel))
        if let left = leftMember {
            notifyOrientation(
                channel: channel,
                event: .left(alias: alias, sessionId: left.sessionId),
                otherMembers: result.members
            )
        }
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

    // MARK: - Orientation messages (push)
    //
    // 当 session 加入 / 离开 channel 时，往相关 session 的 inbox 推一条
    // synthetic operator → session 系统消息，让 agent 知道:
    //   - 自己在哪个 channel
    //   - 同 channel 的 teammates 是谁
    //   - 怎么用 send_message tool 协作
    //
    // 走的是已有的 `__ops-<sid>` operator channel + Stop-hook inbox drain
    // 路径，零新基础设施。

    fileprivate enum OrientationEvent {
        case joined(alias: String, sessionId: String)
        case left(alias: String, sessionId: String)
    }

    /// Best-effort: throw 不向上传播，orientation 失败不能拖累 join/leave 本身。
    fileprivate func notifyOrientation(
        channel: String,
        event: OrientationEvent,
        otherMembers: [ChannelMember]
    ) {
        // 跳过 operator channel 本身（`__ops-<sid>` 这种），否则给 operator
        // channel 加成员会触发递归（ensureOperatorChannel 又会 join）
        guard !channel.hasPrefix("__") else { return }

        let actor: (alias: String, sessionId: String) = {
            switch event {
            case .joined(let a, let s): return (a, s)
            case .left(let a, let s): return (a, s)
            }
        }()
        // 跳过合成 actor（operator / 没 sid 的）
        let actorIsReal = !actor.alias.isEmpty
            && actor.alias != "operator"
            && !actor.sessionId.isEmpty

        // 真实其他成员（过滤合成 + 自己）
        let realOthers = otherMembers.filter {
            !$0.alias.isEmpty
                && $0.alias != "operator"
                && !$0.sessionId.isEmpty
                && $0.sessionId != actor.sessionId
        }

        switch event {
        case .joined:
            // 1) 通知刚加入的 session：你进了 #X，teammates 是 ...
            if actorIsReal {
                let teammatesDesc = realOthers.isEmpty
                    ? "no other teammates yet"
                    : "teammates: " + realOthers.map { "\($0.alias)" }.joined(separator: ", ")
                let msg = """
                You just joined channel #\(channel) (\(teammatesDesc)).

                To talk to teammates use the meee2 MCP tool:
                  send_message(channel: "\(channel)", toAlias: "*", content: "...")    // broadcast
                  send_message(channel: "\(channel)", toAlias: "<alias>", content: "...")  // direct

                Incoming messages will appear at the start of your next turn under "[a2a from <alias> via \(channel)]".
                Use list_channels / read_inbox if you need to re-check membership or pending mail.
                """
                Self.pushOrientation(actor.sessionId, msg)
            }
            // 2) 通知现有成员：alias-X 加入了
            if actorIsReal {
                let notice = "Heads up: agent '\(actor.alias)' just joined channel #\(channel). You can reach them via send_message(channel: \"\(channel)\", toAlias: \"\(actor.alias)\", ...)."
                for member in realOthers {
                    Self.pushOrientation(member.sessionId, notice)
                }
            }
        case .left:
            // 通知剩余成员：alias-X 离开了。不通知 actor 自己（他刚 leave 大概率知道）。
            if actorIsReal && !realOthers.isEmpty {
                let notice = "Note: agent '\(actor.alias)' left channel #\(channel)."
                for member in realOthers {
                    Self.pushOrientation(member.sessionId, notice)
                }
            }
        }
    }

    /// 注入点：实际的 inbox push 由 MessageRouter 实现，但 ChannelRegistry
    /// 不该硬依赖它（避免循环 init 顺序）。AppDelegate / MessageRouter 启动
    /// 时设置这个 closure。未设置时 orientation 静默 no-op（不影响 join/leave）。
    public static var pushOrientation: (_ toSessionId: String, _ content: String) -> Void = { _, _ in }
}
