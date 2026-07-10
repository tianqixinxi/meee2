import Foundation

/// MessageRouter 错误
public enum MessageRouterError: Error, CustomStringConvertible {
    case channelNotFound(String)
    case unknownSender(alias: String, channel: String)
    case unknownRecipient(alias: String, channel: String)
    case messageNotFound(String)
    /// 不能修改 delivered / dropped 的消息
    case alreadyTerminal(String)
    /// deliverPending 被自动调用时遇到 paused 频道（除非显式 deliver(id)）
    case channelPaused(String)
    /// 广播 `*` 但把发送方排除后没有任何接收方（channel 只有一个成员且
    /// 正好是发送方 / channel 没有成员）。不再悄悄把消息标成 delivered=[]。
    case emptyRecipients(channel: String)
    /// 一段对话 hop count 超过 MessageRouter.maxHopsHard——传输层级联放大兜底。
    /// 类比 IP TTL：到这里就强制断路，不让 agent 互相递归把磁盘和 Ghostty 打爆。
    case hopLimitExceeded(channel: String, hopCount: Int)

    public var description: String {
        switch self {
        case .channelNotFound(let n): return "channel not found: \(n)"
        case .unknownSender(let a, let c): return "unknown sender alias '\(a)' in channel '\(c)'"
        case .unknownRecipient(let a, let c): return "unknown recipient alias '\(a)' in channel '\(c)'"
        case .messageNotFound(let id): return "message not found: \(id)"
        case .alreadyTerminal(let id): return "message already terminal (delivered/dropped): \(id)"
        case .channelPaused(let c): return "channel is paused: \(c)"
        case .emptyRecipients(let c):
            return "broadcast in channel '\(c)' has no recipients (add another member or pick a specific toAlias)"
        case .hopLimitExceeded(let c, let h):
            return "hop limit exceeded in channel '\(c)' (hopCount=\(h), max=\(MessageRouter.maxHopsHard))"
        }
    }
}

/// Persisted retention contract for terminal (delivered/dropped) A2A records.
/// The activation boundary is safety-critical: records created before it are
/// preview-only until an explicit cleanup request opts in to legacy history.
public struct MessageRetentionPolicy: Codable, Sendable, Equatable {
    public let activatedAt: Date
    public let terminalMaxAge: TimeInterval
    public let telemetryMaxAge: TimeInterval
    public let maxRecordCount: Int
    public let maxTotalBytes: Int64

    public init(
        activatedAt: Date,
        terminalMaxAge: TimeInterval = 30 * 24 * 60 * 60,
        telemetryMaxAge: TimeInterval = 7 * 24 * 60 * 60,
        maxRecordCount: Int = 100_000,
        maxTotalBytes: Int64 = 250 * 1_024 * 1_024
    ) {
        self.activatedAt = activatedAt
        self.terminalMaxAge = Swift.max(0, terminalMaxAge)
        self.telemetryMaxAge = Swift.max(0, telemetryMaxAge)
        self.maxRecordCount = Swift.max(0, maxRecordCount)
        self.maxTotalBytes = Swift.max(0, maxTotalBytes)
    }

    public static func production(activatedAt: Date) -> MessageRetentionPolicy {
        MessageRetentionPolicy(activatedAt: activatedAt)
    }
}

public struct MessageRetentionPreview: Sendable, Equatable {
    public let policy: MessageRetentionPolicy
    public let automaticCount: Int
    public let automaticBytes: Int64
    public let protectedHistoryCount: Int
    public let protectedHistoryBytes: Int64
}

public struct MessageRetentionResult: Sendable, Equatable {
    public let removedCount: Int
    public let reclaimedBytes: Int64
    public let failedCount: Int
}

/// Result of the explicit legacy-history cleanup flow. The backup is a
/// timestamped directory whose contents mirror the original
/// `messages/<channel>/<message>.json` paths byte-for-byte.
public struct LegacyMessageCleanupResult: Sendable, Equatable {
    public let backupPath: String
    public let removedCount: Int
    public let reclaimedBytes: Int64
    public let failedCount: Int
}

public enum LegacyMessageCleanupError: Error, LocalizedError, Equatable {
    case noCandidates
    case previewChanged(expectedCount: Int, expectedBytes: Int64, actualCount: Int, actualBytes: Int64)
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCandidates:
            return "there are no legacy message files to clean up"
        case .previewChanged(let expectedCount, let expectedBytes, let actualCount, let actualBytes):
            return "legacy message cleanup preview changed "
                + "(expected \(expectedCount)/\(expectedBytes)B, actual \(actualCount)/\(actualBytes)B); review it again"
        case .archiveFailed(let detail):
            return "legacy message backup failed; original files were preserved: \(detail)"
        }
    }
}

/// MessageRouter - 管理 A2A 消息的投递与人机协同
///
/// 持久化：
///   - 消息信封: ~/.meee2/messages/<channel>/<msg-id>.json
///   - 接收方收件箱: ~/.claude/teams/meee2/inboxes/<sessionId>.json
///     （JSON **数组**，对齐 oh-my-claudecode / Claude Code 原生 Agent Teams
///      约定；人被视为"operator" agent，走同一个 inbox 协议）
/// 线程安全：所有公开方法通过串行 DispatchQueue 同步。
public final class MessageRouter {
    public static let shared: MessageRouter = {
        let router = MessageRouter(
            storage: .processDefault,
            channelRegistry: .shared
        )
        router.scheduleProductionRetention()
        return router
    }()

    /// 一段对话允许的最大 hop count。超过 → send() throw hopLimitExceeded。
    /// 类比 IP TTL：50 大到不会误伤任何合理工作流（plan-verify-fix 一般 < 20 跳），
    /// 但小到不会让两个 agent 互相递归打爆磁盘 / Ghostty。
    public static let maxHopsHard: Int = 50

    private let fileManager: FileManager
    private let messagesDir: URL
    private let inboxDir: URL
    private let legacyInboxDir: URL
    private let channelRegistry: ChannelRegistry
    private let auditLogger: AuditLogger
    private let diskIndex: MessageDiskIndex?
    private let terminalCacheLimit: Int
    public let storagePaths: CommKitStoragePaths

    /// 内存缓存：msgId -> A2AMessage。所有访问须持 queue
    private var cache: [String: A2AMessage] = [:]
    private var cacheOrder: [String] = []

    /// Lightweight on-disk index. Startup decodes only envelope metadata and
    /// pins mutable pending/held messages; terminal payloads are loaded lazily.
    private struct MessageIndexEntry {
        let id: String
        let channel: String
        let createdAt: Date
        let fileModifiedAt: Date
        let fileSizeBytes: Int64
        let status: MessageStatus
        /// Present for filesystem scans and fresh writes. Warm SQLite rows
        /// derive the URL only when their payload is actually requested.
        let fileURL: URL?

        var isTelemetry: Bool {
            // Current envelopes have no retention-class field. Restrict the
            // shorter window to the reserved telemetry namespace so ordinary
            // operator/A2A channels can never be guessed into 7-day cleanup.
            channel == "__telemetry" || channel.hasPrefix("__telemetry-")
        }
    }

    private struct PersistedMessageIndexRecord: Decodable {
        let id: String
        let channel: String
        let createdAt: Date
        let status: MessageStatus
    }

    private struct RetentionPlan {
        let automatic: [MessageIndexEntry]
        let protectedHistory: [MessageIndexEntry]
    }

    private var messageIndex: [String: MessageIndexEntry] = [:]

    private let queue = DispatchQueue(label: "com.meee2.message-router", qos: .userInitiated)

    /// Push delegate 注册表(weak refs,避免外部 delegate 反向 retain)。
    /// AppDelegate 启动时把 `AgentInboxShell.shared` 注册进来,外部 AI 也
    /// 可以注册自己的实现。
    private var pushDelegates: [WeakInboxPushDelegate] = []

    public init(
        storage: CommKitStoragePaths,
        channelRegistry: ChannelRegistry,
        auditLogger: AuditLogger? = nil,
        fileManager: FileManager = .default,
        terminalCacheLimit: Int = 512
    ) {
        storagePaths = storage
        self.channelRegistry = channelRegistry
        self.fileManager = fileManager
        self.auditLogger = auditLogger ?? AuditLogger(storage: storage, fileManager: fileManager)
        self.terminalCacheLimit = max(0, terminalCacheLimit)
        messagesDir = storage.messagesDirectory
        inboxDir = storage.inboxDirectory
        legacyInboxDir = storage.legacyInboxDirectory

        try? fileManager.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        do {
            diskIndex = try MessageDiskIndex(
                fileURL: messagesDir.appendingPathComponent(MessageDiskIndex.fileName)
            )
        } catch {
            diskIndex = nil
            commLog(.warning, "[MessageRouter] durable message index unavailable: \(error)")
        }

        migrateLegacyInboxes()
        loadAll()
        // Push / flush / SessionEventBus 订阅由 InboxPushDelegate(s) 负责。
        // 主仓的 AgentInboxShell 在 AppDelegate.applicationDidFinishLaunching
        // 里 register 进来(放这里会让 comm-kit 反向依赖主仓)。
    }

    // MARK: - Push delegates

    /// 注册一个 push delegate。inbox 写入完成后,所有注册的 delegate 都会被
    /// 同步通知一次(顺序与注册顺序一致)。Delegate 用 weak 引用,无需手动
    /// unregister 即可随宿主 dealloc 自动清理。
    public func registerPushDelegate(_ delegate: InboxPushDelegate) {
        queue.sync {
            pushDelegates.removeAll { $0.value == nil || $0.value === delegate }
            pushDelegates.append(WeakInboxPushDelegate(delegate))
        }
    }

    /// 显式注销。一般不需要 —— delegate 被释放后下次 push 时会被 weak 自清。
    public func unregisterPushDelegate(_ delegate: InboxPushDelegate) {
        queue.sync {
            pushDelegates.removeAll { $0.value == nil || $0.value === delegate }
        }
    }

    /// 当前活着的 delegate 数 —— 单测/排错用。
    public var pushDelegateCount: Int {
        queue.sync { pushDelegates.compactMap { $0.value }.count }
    }

    /// 显式绑定 ChannelRegistry orientation 推送（join/leave 后通知相关
    /// session）。**只在 production 启动路径调用**，由 AppDelegate 在
    /// applicationDidFinishLaunching 触发。
    /// 不放 init() 里：MessageRouter 是 singleton，单测一旦访问 .shared 就
    /// 隐式启用 orientation，会让所有 join 测试的 inbox 多出一条 "you joined"
    /// 消息，破坏既有计数断言。Test 走默认 no-op（ChannelRegistry.pushOrientation
    /// 默认是 `{ _, _ in }`）。
    public func bindChannelOrientationHook() {
        ChannelRegistry.pushOrientation = { [weak self] sessionId, content in
            guard let self = self else { return }
            do {
                let opChannel = try self.ensureOperatorChannel(sessionId: sessionId)
                _ = try self.send(
                    channel: opChannel,
                    fromAlias: "operator",
                    toAlias: "session",
                    content: content,
                    injectedByHuman: true
                )
            } catch {
                commLog(.warning, "[MessageRouter] orientation push to \(sessionId.prefix(8)) failed: \(error)")
            }
        }
    }

    /// 列出所有有 inbox 文件的 sessionId（给 AgentInboxShell.flushAllInboxes 用）
    public func allInboxSessionIds() -> [String] {
        queue.sync {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: inboxDir,
                includingPropertiesForKeys: nil
            ) else { return [] }
            return entries
                .filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
    }

    /// 一次性把 ~/.meee2/inbox/<sid>.jsonl 转成 ~/.claude/teams/meee2/inboxes/<sid>.json
    /// 转完删除旧文件。重复运行安全（老文件没了就不做事）。
    private func migrateLegacyInboxes() {
        queue.sync {
            guard fileManager.fileExists(atPath: legacyInboxDir.path) else { return }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: legacyInboxDir,
                includingPropertiesForKeys: nil
            ) else { return }
            var migrated = 0
            for oldFile in entries where oldFile.pathExtension == "jsonl" {
                let sid = oldFile.deletingPathExtension().lastPathComponent
                let newFile = inboxDir.appendingPathComponent("\(sid).json")
                guard let content = try? String(contentsOf: oldFile, encoding: .utf8) else { continue }
                let messages = parseJsonl(content)
                if messages.isEmpty {
                    try? fileManager.removeItem(at: oldFile)
                    continue
                }
                // 合并进新文件（如果已有）
                var existing: [A2AMessage] = []
                if fileManager.fileExists(atPath: newFile.path),
                   let data = try? Data(contentsOf: newFile) {
                    existing = (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
                }
                let combined = existing + messages
                if let data = try? jsonArrayEncoder.encode(combined) {
                    try? data.write(to: newFile, options: .atomic)
                    try? fileManager.removeItem(at: oldFile)
                    migrated += messages.count
                }
            }
            if migrated > 0 {
                commLog(.info, "[MessageRouter] migrated \(migrated) legacy inbox message(s) → \(inboxDir.path)")
            }
        }
    }

    private var jsonArrayEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private var jsonArrayDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Send

    /// 发送一条消息。
    /// - auto 模式：先以 .pending 持久化，随后同步调用 deliverPending()（MVP 不做延迟）
    /// - intercept / paused 模式：保持 .pending，不自动投递
    @discardableResult
    public func send(
        channel: String,
        fromAlias: String,
        toAlias: String,
        content: String,
        replyTo: String? = nil,
        injectedByHuman: Bool = false
    ) throws -> A2AMessage {
        // 不允许使用通配符作为发送方
        if fromAlias == "*" {
            throw MessageRouterError.unknownSender(alias: "*", channel: channel)
        }

        guard let ch = channelRegistry.get(channel) else {
            throw MessageRouterError.channelNotFound(channel)
        }

        // "operator" 作为合成发送方：人从 Web UI 往任意 channel 发消息，
        // operator 不必是 channel 的真 member 也能发。校验条件：必须
        // injectedByHuman=true（agent 不能伪装成 operator）。这样 channel
        // 里只有一个 agent 成员时，operator → agent 也不会踩到 "broadcast
        // 排除自己 → 收件人为空" 的死局。
        let senderSessionId: String
        if fromAlias == "operator" && injectedByHuman {
            senderSessionId = ""  // operator 在 channel member 表外
        } else {
            guard let sender = ch.memberByAlias(fromAlias) else {
                throw MessageRouterError.unknownSender(alias: fromAlias, channel: channel)
            }
            senderSessionId = sender.sessionId
        }

        // 若指定具体接收者，需验证其存在；"*" 表示广播，延迟到投递时再 fan-out
        if toAlias != "*" {
            guard ch.memberByAlias(toAlias) != nil else {
                throw MessageRouterError.unknownRecipient(alias: toAlias, channel: channel)
            }
        } else {
            // 广播预检：把发送方排除掉之后必须还有人，否则 deliverPending
            // 会写一条 status=delivered / deliveredTo=[] 的"死"消息，看起来
            // 送达了其实谁都没收到。宁可在 send 就拒掉。
            let recipients = ch.members.filter { $0.alias != fromAlias }
            if recipients.isEmpty {
                throw MessageRouterError.emptyRecipients(channel: channel)
            }
        }

        // ── traceId / hopCount 计算（envelope 协议字段）──
        // 有 replyTo → 继承 parent 的 traceId，hopCount = parent.hopCount + 1
        // 没 replyTo → 新对话根，traceId = 自己的 id（init 默认会处理），hopCount = 0
        let parentMsg: A2AMessage? = replyTo.flatMap { id in
            queue.sync { loadMessageLocked(id) }
        }
        let derivedTraceId: String? = parentMsg?.traceId
        let derivedHopCount: Int = (parentMsg?.hopCount ?? -1) + 1
        if derivedHopCount > Self.maxHopsHard {
            // 不持久化、不进 cache、不写 inbox。直接 throw + 写一条 dropped
            // audit 让 forensics 能看到曾经有人撞这堵墙。
            auditLogger.log(AuditEvent(
                event: .dropped,
                msgId: "rejected-hop-overflow",
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                actor: injectedByHuman ? "human" : "agent:\(fromAlias)",
                details: "hop \(derivedHopCount) > max \(Self.maxHopsHard) (replyTo=\(replyTo ?? "?"))"
            ))
            throw MessageRouterError.hopLimitExceeded(channel: channel, hopCount: derivedHopCount)
        }

        let msg = A2AMessage(
            traceId: derivedTraceId,
            channel: channel,
            fromAlias: fromAlias,
            fromSessionId: senderSessionId,
            toAlias: toAlias,
            content: content,
            replyTo: replyTo,
            hopCount: derivedHopCount,
            status: .pending,
            injectedByHuman: injectedByHuman
        )

        try queue.sync {
            try persist(msg)
            cacheMessageLocked(msg)
        }

        commLog(.info, "[MessageRouter] send \(msg.id) channel=\(channel) \(fromAlias) -> \(toAlias) mode=\(ch.mode.rawValue)")

        // 审计：人工注入发一条 .injected，agent 自发送发一条 .created
        if injectedByHuman {
            auditLogger.log(AuditEvent(
                event: .injected,
                msgId: msg.id,
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                actor: "human"
            ))
        } else {
            auditLogger.log(AuditEvent(
                event: .created,
                msgId: msg.id,
                channel: channel,
                fromAlias: fromAlias,
                toAlias: toAlias,
                actor: "agent:\(fromAlias)"
            ))
        }

        // 发消息本身是一次变动：订阅者可借此看到新的 pending 消息
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: channel))

        // 根据频道模式决定是否立即投递
        switch ch.mode {
        case .auto:
            // MVP：无延迟，直接自动投递
            do {
                return try deliverPending(msg.id)
            } catch {
                // 若投递过程中出错（例如频道瞬变为 paused），保留为 pending 状态
                commLog(.warning, "[MessageRouter] auto-deliver failed for \(msg.id): \(error)")
                return msg
            }
        case .intercept, .paused:
            return msg
        }
    }

    // MARK: - Query

    /// 列出消息，可按频道 / 状态过滤（按 createdAt 升序）
    public func listMessages(channel: String? = nil, statuses: Set<MessageStatus>? = nil) -> [A2AMessage] {
        queue.sync {
            let indexedEntries: [MessageIndexEntry]
            if channel != nil || statuses != nil,
               let ids = try? diskIndex?.queryIDs(channel: channel, statuses: statuses) {
                indexedEntries = ids.compactMap { messageIndex[$0] }
            } else {
                indexedEntries = messageIndex.values
                    .filter { entry in
                        if let channel = channel, entry.channel != channel { return false }
                        if let statuses = statuses, !statuses.contains(entry.status) { return false }
                        return true
                    }
                    .sorted { lhs, rhs in
                        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                        if lhs.fileModifiedAt != rhs.fileModifiedAt { return lhs.fileModifiedAt < rhs.fileModifiedAt }
                        return lhs.id < rhs.id
                    }
            }
            return indexedEntries
                .filter { entry in
                    // Defend against a stale/corrupt auxiliary index. The
                    // in-memory envelope remains authoritative for this launch.
                    if let channel = channel, entry.channel != channel { return false }
                    if let statuses = statuses, !statuses.contains(entry.status) { return false }
                    return true
                }
                .compactMap { loadMessageLocked($0.id) }
        }
    }

    /// 按 ID 获取消息
    public func get(_ id: String) -> A2AMessage? {
        queue.sync { loadMessageLocked(id) }
    }

    /// Diagnostics for validating that startup indexes history without keeping
    /// every terminal payload resident in memory.
    public var indexedMessageCount: Int {
        queue.sync { messageIndex.count }
    }

    public var cachedMessageCount: Int {
        queue.sync { cache.count }
    }

    /// Clear process-local message state after the host deletes messages and
    /// inboxes on disk. Push delegates are runtime wiring, not user data, so
    /// they remain registered.
    public func clearAllInMemory() {
        queue.sync {
            cache.removeAll()
            cacheOrder.removeAll()
            messageIndex.removeAll()
        }
        commLog(.info, "[MessageRouter] Cleared in-memory message index and cache")
    }

    // MARK: - Retention

    /// Persist the first activation boundary. Existing policy always wins so
    /// later launches cannot move the boundary backwards and auto-delete legacy
    /// history. Corrupt policy files fail safe by activating at the supplied
    /// (normally current) time.
    @discardableResult
    public func installRetentionPolicyIfNeeded(
        _ candidate: MessageRetentionPolicy
    ) -> MessageRetentionPolicy {
        queue.sync {
            if let existing = loadRetentionPolicyLocked() {
                return existing
            }
            persistRetentionPolicyLocked(candidate)
            return candidate
        }
    }

    /// Preview automatic candidates and pre-activation history that requires
    /// an explicit user-confirmed cleanup. No payload decoding is required.
    public func retentionPreview(now: Date = Date()) -> MessageRetentionPreview {
        queue.sync {
            let policy = loadRetentionPolicyLocked()
                ?? installRetentionPolicyWithoutQueueLocked(at: now)
            let plan = retentionPlanLocked(policy: policy, now: now)
            return MessageRetentionPreview(
                policy: policy,
                automaticCount: plan.automatic.count,
                automaticBytes: plan.automatic.reduce(0) { $0 + $1.fileSizeBytes },
                protectedHistoryCount: plan.protectedHistory.count,
                protectedHistoryBytes: plan.protectedHistory.reduce(0) { $0 + $1.fileSizeBytes }
            )
        }
    }

    /// Apply automatic post-activation retention synchronously. Production
    /// calls this on a utility queue. Legacy history is deliberately
    /// unreachable from this API; it can only be removed through the verified
    /// backup flow in `backupAndCleanLegacyHistory`.
    @discardableResult
    public func applyRetention(now: Date = Date()) -> MessageRetentionResult {
        queue.sync {
            let policy = loadRetentionPolicyLocked()
                ?? installRetentionPolicyWithoutQueueLocked(at: now)
            let plan = retentionPlanLocked(policy: policy, now: now)
            return removeRetentionEntriesLocked(plan.automatic)
        }
    }

    /// Export and then remove only the pre-activation terminal history shown
    /// by `retentionPreview`. This is intentionally separate from automatic
    /// retention: callers must bind the operation to the exact count and byte
    /// scope the user confirmed. The router queue covers preview, archive and
    /// deletion so in-process mutations cannot change that scope mid-flight.
    ///
    /// The archive is staged under the target backup directory and becomes
    /// visible with one same-directory rename only after every source file has
    /// been copied and verified byte-for-byte. Any archive error happens before
    /// deletion, so all original files remain in place. Pending and held
    /// records never enter the retention plan.
    @discardableResult
    public func backupAndCleanLegacyHistory(
        now: Date = Date(),
        backupsDirectory: URL? = nil,
        expectedCount: Int,
        expectedBytes: Int64
    ) throws -> LegacyMessageCleanupResult {
        try queue.sync {
            let policy = loadRetentionPolicyLocked()
                ?? installRetentionPolicyWithoutQueueLocked(at: now)
            let plan = retentionPlanLocked(policy: policy, now: now)
            let candidates = deduplicated(plan.protectedHistory)
            let actualBytes = candidates.reduce(Int64(0)) { $0 + $1.fileSizeBytes }

            guard !candidates.isEmpty else {
                throw LegacyMessageCleanupError.noCandidates
            }
            let existingCandidates = candidates.filter {
                fileManager.fileExists(atPath: messageFileURL(for: $0).path)
            }
            let currentBytes = existingCandidates.reduce(Int64(0)) {
                $0 + fileMetadata(at: messageFileURL(for: $1), fallbackDate: $1.createdAt).sizeBytes
            }
            guard candidates.count == expectedCount,
                  actualBytes == expectedBytes,
                  existingCandidates.count == expectedCount,
                  currentBytes == expectedBytes else {
                throw LegacyMessageCleanupError.previewChanged(
                    expectedCount: expectedCount,
                    expectedBytes: expectedBytes,
                    actualCount: existingCandidates.count,
                    actualBytes: currentBytes
                )
            }

            let backupRoot = (backupsDirectory
                ?? storagePaths.baseDirectory.appendingPathComponent("backups", isDirectory: true))
                .standardizedFileURL
            return try archiveAndRemoveLegacyEntriesLocked(
                candidates,
                backupRoot: backupRoot,
                now: now,
                expectedBytes: expectedBytes
            )
        }
    }

    /// Startup hook used by `shared`. It captures the activation boundary on
    /// the caller thread, then moves all indexing/deletion work off the main
    /// thread. Legacy history is previewed and logged, never auto-deleted.
    public func scheduleProductionRetention(activationTime: Date = Date()) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let policy = self.installRetentionPolicyIfNeeded(
                .production(activatedAt: activationTime)
            )
            let preview = self.retentionPreview(now: Date())
            let result = self.applyRetention(now: Date())
            commLog(
                .info,
                "[MessageRouter] retention activated=\(policy.activatedAt) "
                    + "auto=\(preview.automaticCount)/\(preview.automaticBytes)B "
                    + "legacyPreview=\(preview.protectedHistoryCount)/\(preview.protectedHistoryBytes)B "
                    + "removed=\(result.removedCount) reclaimed=\(result.reclaimedBytes)B "
                    + "failed=\(result.failedCount)"
            )
        }
    }

    /// Explicit post-activation disk-retention hook. Pending, held, and legacy
    /// pre-activation messages are never removed through this shortcut.
    /// Legacy history must use `backupAndCleanLegacyHistory`.
    @discardableResult
    public func pruneTerminalMessages(olderThan cutoff: Date) -> Int {
        queue.sync {
            let policy = loadRetentionPolicyLocked()
                ?? installRetentionPolicyWithoutQueueLocked(at: Date())
            let candidates = messageIndex.values.filter {
                ($0.status == .delivered || $0.status == .dropped)
                    && $0.createdAt > policy.activatedAt
                    && $0.createdAt < cutoff
            }
            return removeRetentionEntriesLocked(candidates).removedCount
        }
    }

    // MARK: - Human Actions

    /// 人工挂起
    @discardableResult
    public func hold(_ id: String) throws -> A2AMessage {
        let msg = try mutateNonTerminal(id) { msg in
            msg.status = .held
        }
        auditLogger.log(AuditEvent(
            event: .held,
            msgId: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            actor: "human"
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: msg.channel))
        return msg
    }

    /// 人工丢弃
    @discardableResult
    public func drop(_ id: String) throws -> A2AMessage {
        let msg = try mutateNonTerminal(id) { msg in
            msg.status = .dropped
        }
        auditLogger.log(AuditEvent(
            event: .dropped,
            msgId: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            actor: "human"
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: msg.channel))
        return msg
    }

    /// 人工编辑消息正文
    @discardableResult
    public func edit(_ id: String, newContent: String) throws -> A2AMessage {
        // 捕获编辑前长度用于审计（不记录内容 —— 可能含敏感信息）
        let oldLen = queue.sync { loadMessageLocked(id)?.content.count }
        let msg = try mutateNonTerminal(id) { msg in
            msg.content = newContent
        }
        let details = "len old=\(oldLen ?? -1) new=\(newContent.count)"
        auditLogger.log(AuditEvent(
            event: .edited,
            msgId: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            actor: "human",
            details: details
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msg.id, channel: msg.channel))
        return msg
    }

    /// 人工强制投递（绕过 paused 模式）
    @discardableResult
    public func deliver(_ id: String) throws -> A2AMessage {
        try deliverPending(id, force: true)
    }

    // MARK: - Delivery

    /// 自动投递循环 / 人工 deliver() 的核心。解析接收者，追加到收件箱，
    /// 设置 status=.delivered, deliveredAt=now。
    /// - force=true: 允许穿透 .paused 频道
    @discardableResult
    public func deliverPending(_ id: String) throws -> A2AMessage {
        try deliverPending(id, force: false)
    }

    @discardableResult
    private func deliverPending(_ id: String, force: Bool) throws -> A2AMessage {
        // 1) 先在队列内检查与解析，然后释放队列再写 inbox（inbox 写入是独立文件）
        let (msgToDeliver, recipientMembers) = try queue.sync { () -> (A2AMessage, [ChannelMember]) in
            guard var msg = loadMessageLocked(id) else {
                throw MessageRouterError.messageNotFound(id)
            }
            if msg.status == .delivered || msg.status == .dropped {
                throw MessageRouterError.alreadyTerminal(id)
            }
            guard let ch = channelRegistry.get(msg.channel) else {
                throw MessageRouterError.channelNotFound(msg.channel)
            }
            // paused 频道：除非 force，否则拒绝
            if ch.mode == .paused && !force {
                throw MessageRouterError.channelPaused(msg.channel)
            }

            // 解析接收者（广播时排除发送方）
            let recipients: [ChannelMember]
            if msg.toAlias == "*" {
                recipients = ch.members.filter { $0.alias != msg.fromAlias }
            } else {
                guard let target = ch.memberByAlias(msg.toAlias) else {
                    throw MessageRouterError.unknownRecipient(alias: msg.toAlias, channel: msg.channel)
                }
                recipients = [target]
            }

            // 更新状态（但收件箱写入放在 queue 外）
            msg.status = .delivered
            msg.deliveredAt = Date()
            msg.deliveredTo = recipients.map { $0.alias }
            try persist(msg)
            cacheMessageLocked(msg)
            return (msg, recipients)
        }

        // 2) 写入每个接收方的 inbox（JSON 数组追加）
        for member in recipientMembers {
            do {
                try appendToInbox(sessionId: member.sessionId, message: msgToDeliver)
            } catch {
                commLog(.warning, "[MessageRouter] appendToInbox failed for \(member.sessionId.prefix(8)): \(error)")
            }
        }

        // 3) 交给所有注册的 InboxPushDelegate 决定推送时机 / 方式 / 策略。
        //    主仓注册的 AgentInboxShell 看 resolver 状态 + ghosttyTerminalId
        //    + InboxShellPolicy,busy 的就跳过等 SessionEventBus 兜底;
        //    外部 AI 注册的 delegate 自行决定怎么把消息送到自己的进程里。
        let delegates = queue.sync { pushDelegates.compactMap { $0.value } }
        for member in recipientMembers where !member.sessionId.isEmpty {
            for delegate in delegates {
                delegate.handleInboxPush(sessionId: member.sessionId, message: msgToDeliver)
            }
        }

        commLog(.info, "[MessageRouter] delivered \(id) -> [\(msgToDeliver.deliveredTo.joined(separator: ","))]")

        // 审计：一个 delivered 事件，fan-out 不拆分成多条
        var auditDetails: String?
        if msgToDeliver.toAlias == "*" {
            auditDetails = "fanout=[\(msgToDeliver.deliveredTo.joined(separator: ","))]"
        }
        auditLogger.log(AuditEvent(
            event: .delivered,
            msgId: msgToDeliver.id,
            channel: msgToDeliver.channel,
            fromAlias: msgToDeliver.fromAlias,
            toAlias: msgToDeliver.toAlias,
            actor: "human",
            details: auditDetails
        ))
        SessionEventBus.shared.publish(.messageMutated(id: msgToDeliver.id, channel: msgToDeliver.channel))
        return msgToDeliver
    }

    // MARK: - Inbox

    /// 读取并清空指定会话的 inbox，返回已解析消息（oldest -> newest）。
    /// 文件缺失时返回空数组。
    public func drainInbox(sessionId: String) -> [A2AMessage] {
        queue.sync {
            let path = inboxPath(sessionId)
            guard fileManager.fileExists(atPath: path.path) else { return [] }

            // 原子化：rename -> read -> delete
            let tmp = path.appendingPathExtension("drain.\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970))")
            do {
                try fileManager.moveItem(at: path, to: tmp)
            } catch {
                commLog(.warning, "[MessageRouter] drainInbox rename failed for \(sessionId.prefix(8)): \(error)")
                return []
            }

            defer { try? fileManager.removeItem(at: tmp) }

            guard let data = try? Data(contentsOf: tmp) else { return [] }
            return (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
        }
    }

    /// 只读查看 inbox（不清空），用于人类观察
    public func peekInbox(sessionId: String) -> [A2AMessage] {
        queue.sync {
            let path = inboxPath(sessionId)
            guard fileManager.fileExists(atPath: path.path) else { return [] }
            guard let data = try? Data(contentsOf: path) else { return [] }
            return (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
        }
    }

    /// 直接把一条合成消息写进某会话的 inbox（用于 `msg halt` 等场景）。
    /// 不需要该会话在某个频道中。返回已写入的 A2AMessage。
    ///
    /// 注：这是 legacy 入口。Web UI 发消息已经改走 `send()` + 每 session 的
    /// operator channel（人 = 普通 agent 同路径）；这里保留给 CLI `msg halt`
    /// 和 A2AConnectSheet 等 side-path 使用。
    @discardableResult
    public func injectDirectToInbox(sessionId: String, message: A2AMessage) throws -> A2AMessage {
        try queue.sync {
            try appendToInbox(sessionId: sessionId, message: message)
        }
        SessionEventBus.shared.publish(.messageMutated(id: message.id, channel: message.channel))
        return message
    }

    /// 从 inbox JSON 数组中移除指定 id 的消息，原子写回。
    /// 给 AgentInboxShell push 成功后调用。线程安全（内部走 queue.sync）。
    public func removeFromInbox(sessionId: String, messageId: String) {
        queue.sync { removeFromInboxLocked(sessionId: sessionId, messageId: messageId) }
    }

    /// 实际执行 remove。调用方须持 queue。
    private func removeFromInboxLocked(sessionId: String, messageId: String) {
        let path = inboxPath(sessionId)
        guard fileManager.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              var list = try? jsonArrayDecoder.decode([A2AMessage].self, from: data) else {
            return
        }
        let before = list.count
        list.removeAll { $0.id == messageId }
        if list.count == before { return }
        do {
            if list.isEmpty {
                try fileManager.removeItem(at: path)
            } else {
                let out = try jsonArrayEncoder.encode(list)
                try out.write(to: path, options: .atomic)
            }
        } catch {
            commLog(.warning, "[MessageRouter] removeFromInbox failed for \(sessionId.prefix(8))/\(messageId): \(error)")
        }
    }

    /// 返回某 session 对应的 per-session operator channel 名字，确保它存在
    /// 且包含两个约定成员：`operator`（人）和 `session`（这个 session）。
    ///
    /// 这是"人 = agent"统一化的核心：operator 把消息发给 session 用的不是
    /// 一个特殊接口，就是 A2A channel.send 的普通调用——send() → audit →
    /// deliverPending → inbox 路径完整复用。
    ///
    /// Channel 名：默认 `__ops-<sessionId>`。Plugin session id 可能带 `.`
    /// 或超过 64 字符，不能直接当 channel name；这种情况会压成稳定的
    /// `__ops-<slug>-<hash>`，member 里的 sessionId 仍保留完整原值。
    @discardableResult
    public func ensureOperatorChannel(sessionId: String) throws -> String {
        let name = Self.operatorChannelName(for: sessionId)
        let reg = channelRegistry
        if let existing = reg.get(name) {
            if let member = existing.memberByAlias("session"), member.sessionId != sessionId {
                throw ChannelRegistryError.aliasTaken("session")
            }
            if existing.memberByAlias("operator") == nil {
                _ = try reg.join(channel: name, alias: "operator", sessionId: "")
            }
            if existing.memberByAlias("session") == nil {
                _ = try reg.join(channel: name, alias: "session", sessionId: sessionId)
            }
            return name
        }
        _ = try reg.create(name: name, description: "operator↔session (auto)", mode: .auto)
        _ = try reg.join(channel: name, alias: "operator", sessionId: "")
        _ = try reg.join(channel: name, alias: "session", sessionId: sessionId)
        return name
    }

    private static func operatorChannelName(for sessionId: String) -> String {
        let prefix = "__ops-"
        let direct = "\(prefix)\(sessionId)"
        if isValidChannelName(direct) {
            return direct
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        var slug = ""
        for scalar in sessionId.lowercased().unicodeScalars {
            slug += allowed.contains(scalar) ? String(scalar) : "-"
        }
        let trimmed = String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let base = trimmed.isEmpty ? "session" : trimmed
        return "\(prefix)\(base)-\(stableHashHex(sessionId))"
    }

    private static func isValidChannelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return !name.unicodeScalars.contains { !allowed.contains($0) }
    }

    private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", CUnsignedLongLong(hash))
    }

    // MARK: - Private helpers (most run on queue)

    private func mutateNonTerminal(_ id: String, _ change: (inout A2AMessage) -> Void) throws -> A2AMessage {
        try queue.sync {
            guard var msg = loadMessageLocked(id) else {
                throw MessageRouterError.messageNotFound(id)
            }
            if msg.status == .delivered || msg.status == .dropped {
                throw MessageRouterError.alreadyTerminal(id)
            }
            change(&msg)
            try persist(msg)
            cacheMessageLocked(msg)
            return msg
        }
    }

    private func channelDir(_ name: String) -> URL {
        messagesDir.appendingPathComponent(name)
    }

    private func messagePath(_ msg: A2AMessage) -> URL {
        channelDir(msg.channel).appendingPathComponent("\(msg.id).json")
    }

    private func inboxPath(_ sessionId: String) -> URL {
        inboxDir.appendingPathComponent("\(sessionId).json")
    }

    // MARK: Retention helpers (must be called on queue)

    private func installRetentionPolicyWithoutQueueLocked(at activationTime: Date) -> MessageRetentionPolicy {
        let policy = MessageRetentionPolicy.production(activatedAt: activationTime)
        persistRetentionPolicyLocked(policy)
        return policy
    }

    private func loadRetentionPolicyLocked() -> MessageRetentionPolicy? {
        guard let data = try? Data(contentsOf: storagePaths.messageRetentionPolicyFile) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let policy = try? decoder.decode(MessageRetentionPolicy.self, from: data) else {
            commLog(.warning, "[MessageRouter] invalid retention policy; resetting activation safely")
            return nil
        }
        return policy
    }

    private func persistRetentionPolicyLocked(_ policy: MessageRetentionPolicy) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(policy) else {
            commLog(.warning, "[MessageRouter] failed to encode retention policy")
            return
        }
        do {
            try fileManager.createDirectory(
                at: storagePaths.baseDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: storagePaths.messageRetentionPolicyFile, options: .atomic)
        } catch {
            commLog(.warning, "[MessageRouter] failed to persist retention activation: \(error)")
        }
    }

    private func retentionPlanLocked(
        policy: MessageRetentionPolicy,
        now: Date
    ) -> RetentionPlan {
        let terminal = messageIndex.values.filter {
            $0.status == .delivered || $0.status == .dropped
        }
        // Strictly newer than activation. Equality fails safe into preview-only.
        let postActivation = terminal.filter { $0.createdAt > policy.activatedAt }
        let automatic = selectRetentionEntriesLocked(
            from: postActivation,
            policy: policy,
            now: now
        )
        let fullCleanup = selectRetentionEntriesLocked(
            from: terminal,
            policy: policy,
            now: now
        )
        let protectedHistory = fullCleanup.filter { $0.createdAt <= policy.activatedAt }
        return RetentionPlan(
            automatic: automatic,
            protectedHistory: protectedHistory
        )
    }

    private func selectRetentionEntriesLocked(
        from entries: [MessageIndexEntry],
        policy: MessageRetentionPolicy,
        now: Date
    ) -> [MessageIndexEntry] {
        let normalCutoff = now.addingTimeInterval(-policy.terminalMaxAge)
        let telemetryCutoff = now.addingTimeInterval(-policy.telemetryMaxAge)
        var selectedIds = Set<String>()

        for entry in entries {
            let cutoff = entry.isTelemetry ? telemetryCutoff : normalCutoff
            if entry.createdAt < cutoff {
                selectedIds.insert(entry.id)
            }
        }

        let remaining = entries
            .filter { !selectedIds.contains($0.id) }
            .sorted(by: retentionOrder)
        var remainingCount = remaining.count
        var remainingBytes = remaining.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        for entry in remaining {
            guard remainingCount > policy.maxRecordCount
                    || remainingBytes > policy.maxTotalBytes else {
                break
            }
            selectedIds.insert(entry.id)
            remainingCount -= 1
            remainingBytes = Swift.max(0, remainingBytes - entry.fileSizeBytes)
        }

        return entries
            .filter { selectedIds.contains($0.id) }
            .sorted(by: retentionOrder)
    }

    private func retentionOrder(_ lhs: MessageIndexEntry, _ rhs: MessageIndexEntry) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.fileModifiedAt != rhs.fileModifiedAt { return lhs.fileModifiedAt < rhs.fileModifiedAt }
        return lhs.id < rhs.id
    }

    private func deduplicated(_ entries: [MessageIndexEntry]) -> [MessageIndexEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private struct LegacyBackupRecord {
        let entry: MessageIndexEntry
        let relativePath: String
        let contents: Data
    }

    private func archiveAndRemoveLegacyEntriesLocked(
        _ entries: [MessageIndexEntry],
        backupRoot: URL,
        now: Date,
        expectedBytes: Int64
    ) throws -> LegacyMessageCleanupResult {
        let fileManager = self.fileManager
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"

        let archiveStem = "legacy-messages-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8))"
        let staging = backupRoot.appendingPathComponent(".\(archiveStem).partial", isDirectory: true)
        let archive = backupRoot.appendingPathComponent(archiveStem, isDirectory: true)
        var visibleArchive = false

        do {
            try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

            let messagesRoot = messagesDir.resolvingSymlinksInPath().standardizedFileURL
            let messagesPrefix = messagesRoot.path.hasSuffix("/")
                ? messagesRoot.path
                : messagesRoot.path + "/"
            var records: [LegacyBackupRecord] = []
            records.reserveCapacity(entries.count)
            var sourceAllocatedBytes: Int64 = 0

            for entry in entries {
                let source = messageFileURL(for: entry).resolvingSymlinksInPath().standardizedFileURL
                guard source.path.hasPrefix(messagesPrefix) else {
                    throw LegacyMessageCleanupError.archiveFailed(
                        "candidate is outside the message storage root"
                    )
                }
                let relativePath = String(source.path.dropFirst(messagesPrefix.count))
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard !relativePath.isEmpty,
                      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw LegacyMessageCleanupError.archiveFailed("candidate path is unsafe")
                }
                let contents = try Data(contentsOf: source)
                guard !contents.isEmpty else {
                    throw LegacyMessageCleanupError.archiveFailed(
                        "candidate \(entry.id) is empty"
                    )
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let currentMessage = try? decoder.decode(A2AMessage.self, from: contents),
                      currentMessage.id == entry.id,
                      currentMessage.channel == entry.channel,
                      currentMessage.status == .delivered || currentMessage.status == .dropped else {
                    throw LegacyMessageCleanupError.archiveFailed(
                        "candidate \(entry.id) is no longer an eligible terminal message"
                    )
                }
                sourceAllocatedBytes += fileMetadata(
                    at: source,
                    fallbackDate: entry.createdAt
                ).sizeBytes

                let destination = staging.appendingPathComponent(relativePath, isDirectory: false)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                guard try Data(contentsOf: destination) == contents else {
                    throw LegacyMessageCleanupError.archiveFailed(
                        "backup verification failed for \(entry.id)"
                    )
                }
                records.append(LegacyBackupRecord(
                    entry: entry,
                    relativePath: relativePath,
                    contents: contents
                ))
            }

            let archivedBytes = records.reduce(Int64(0)) { $0 + Int64($1.contents.count) }
            guard records.count == entries.count, archivedBytes > 0 else {
                throw LegacyMessageCleanupError.archiveFailed("backup archive is empty")
            }
            guard sourceAllocatedBytes == expectedBytes else {
                throw LegacyMessageCleanupError.previewChanged(
                    expectedCount: entries.count,
                    expectedBytes: expectedBytes,
                    actualCount: records.count,
                    actualBytes: sourceAllocatedBytes
                )
            }

            // Same-parent rename is the visibility boundary: users never see a
            // half-populated archive directory.
            try fileManager.moveItem(at: staging, to: archive)
            visibleArchive = true

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: archive.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw LegacyMessageCleanupError.archiveFailed("backup archive was not created")
            }
            for record in records {
                let archivedFile = archive.appendingPathComponent(record.relativePath)
                guard try Data(contentsOf: archivedFile) == record.contents else {
                    throw LegacyMessageCleanupError.archiveFailed(
                        "final backup verification failed for \(record.entry.id)"
                    )
                }
            }

            var removed = 0
            var reclaimedBytes: Int64 = 0
            var failed = 0
            for record in records {
                let entry = record.entry
                do {
                    let fileURL = messageFileURL(for: entry)
                    if fileManager.fileExists(atPath: fileURL.path) {
                        // Never remove a file that another process replaced
                        // after the archive snapshot was taken.
                        guard try Data(contentsOf: fileURL) == record.contents else {
                            failed += 1
                            commLog(.warning, "[MessageRouter] legacy cleanup skipped changed file \(entry.id)")
                            continue
                        }
                        try fileManager.removeItem(at: fileURL)
                        reclaimedBytes += entry.fileSizeBytes
                    }
                    messageIndex.removeValue(forKey: entry.id)
                    cache.removeValue(forKey: entry.id)
                    cacheOrder.removeAll { $0 == entry.id }
                    removed += 1
                } catch {
                    failed += 1
                    commLog(.warning, "[MessageRouter] legacy cleanup failed for \(entry.id): \(error)")
                }
            }
            let removedIds = records.map(\.entry.id).filter { messageIndex[$0] == nil }
            do { try diskIndex?.remove(ids: removedIds) } catch {
                commLog(.warning, "[MessageRouter] failed to update legacy cleanup index: \(error)")
            }

            return LegacyMessageCleanupResult(
                backupPath: archive.path,
                removedCount: removed,
                reclaimedBytes: reclaimedBytes,
                failedCount: failed
            )
        } catch let error as LegacyMessageCleanupError {
            if visibleArchive {
                try? fileManager.removeItem(at: archive)
            } else {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        } catch {
            if visibleArchive {
                try? fileManager.removeItem(at: archive)
            } else {
                try? fileManager.removeItem(at: staging)
            }
            throw LegacyMessageCleanupError.archiveFailed(error.localizedDescription)
        }
    }

    private func removeRetentionEntriesLocked(
        _ entries: [MessageIndexEntry]
    ) -> MessageRetentionResult {
        var removed = 0
        var reclaimedBytes: Int64 = 0
        var failed = 0
        var removedIds: [String] = []
        for entry in deduplicated(entries) {
            do {
                let fileURL = messageFileURL(for: entry)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                    reclaimedBytes += entry.fileSizeBytes
                }
                messageIndex.removeValue(forKey: entry.id)
                cache.removeValue(forKey: entry.id)
                cacheOrder.removeAll { $0 == entry.id }
                removedIds.append(entry.id)
                removed += 1
            } catch {
                failed += 1
                commLog(.warning, "[MessageRouter] retention failed for \(entry.id): \(error)")
            }
        }
        do { try diskIndex?.remove(ids: removedIds) } catch {
            commLog(.warning, "[MessageRouter] failed to update retention index: \(error)")
        }
        return MessageRetentionResult(
            removedCount: removed,
            reclaimedBytes: reclaimedBytes,
            failedCount: failed
        )
    }

    /// 原子写入单条消息到磁盘
    private func persist(_ msg: A2AMessage) throws {
        let dir = channelDir(msg.channel)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)

        let path = messagePath(msg)
        try data.write(to: path, options: .atomic)
        let metadata = fileMetadata(at: path, fallbackDate: msg.createdAt)
        let entry = MessageIndexEntry(
            id: msg.id,
            channel: msg.channel,
            createdAt: msg.createdAt,
            fileModifiedAt: metadata.modifiedAt,
            fileSizeBytes: metadata.sizeBytes,
            status: msg.status,
            fileURL: path
        )
        messageIndex[msg.id] = entry
        do { try diskIndex?.upsert(diskRecord(for: entry)) } catch {
            // The payload is already durable. A background reconciliation will
            // repair the index; never report a false message-write failure.
            commLog(.warning, "[MessageRouter] failed to update message index for \(msg.id): \(error)")
        }
    }

    /// 把一条消息追加到 inbox 的 JSON 数组里。读-改-写；调用方须持 queue。
    ///
    /// 为什么不用 NDJSON append：oh-my-claudecode / Claude Code 原生 Agent
    /// Teams 的约定是 **JSON 数组文件**，agent 按数组读；我们对齐这个约定。
    /// 读-改-写的代价对这种低频操作（人发消息 / A2A 小量消息）完全可以接受。
    private func appendToInbox(sessionId: String, message: A2AMessage) throws {
        let path = inboxPath(sessionId)

        var existing: [A2AMessage] = []
        if fileManager.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path) {
            existing = (try? jsonArrayDecoder.decode([A2AMessage].self, from: data)) ?? []
        }
        existing.append(message)

        let data = try jsonArrayEncoder.encode(existing)
        try data.write(to: path, options: .atomic)
    }

    private func parseJsonl(_ content: String) -> [A2AMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [A2AMessage] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = raw.data(using: .utf8) else { continue }
            if let msg = try? decoder.decode(A2AMessage.self, from: d) {
                out.append(msg)
            } else {
                commLog(.warning, "[MessageRouter] failed to decode inbox line (\(raw.count) bytes)")
            }
        }
        return out
    }

    /// 启动时只建立 metadata index。Pending/held 是可变状态，保持在热缓存；
    /// delivered/dropped payload 在 query/get 时按需读取，并受 LRU 上限约束。
    private func loadAll() {
        queue.sync {
            cache.removeAll()
            cacheOrder.removeAll()
            messageIndex.removeAll()
            if let persisted = try? diskIndex?.loadAll(), !persisted.isEmpty {
                messageIndex.reserveCapacity(persisted.count)
                for record in persisted {
                    let entry = messageEntry(for: record)
                    messageIndex[entry.id] = entry
                    loadMutableMessageIfNeeded(entry)
                }
                commLog(.debug, "[MessageRouter] Loaded durable index \(messageIndex.count) message(s), hot=\(cache.count)")
                scheduleFilesystemIndexReconciliation()
                return
            }

            let scan = scanMessageFiles()
            messageIndex = scan.entries
            for message in scan.mutableMessages { cacheMessageLocked(message) }
            do { try diskIndex?.replaceAll(with: scan.entries.values.map(diskRecord)) } catch {
                commLog(.warning, "[MessageRouter] failed to build durable message index: \(error)")
            }
            commLog(.debug, "[MessageRouter] Indexed \(messageIndex.count) message(s), hot=\(cache.count)")
        }
    }

    private func scanMessageFiles() -> (
        entries: [String: MessageIndexEntry],
        mutableMessages: [A2AMessage]
    ) {
        guard let channelDirs = try? fileManager.contentsOfDirectory(
            at: messagesDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return ([:], []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [String: MessageIndexEntry] = [:]
        var mutableMessages: [A2AMessage] = []
        for channelDirectory in channelDirs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: channelDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let files = try? fileManager.contentsOfDirectory(
                    at: channelDirectory,
                    includingPropertiesForKeys: nil
                  ) else { continue }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let record = try? decoder.decode(PersistedMessageIndexRecord.self, from: data) else {
                    continue
                }
                let metadata = fileMetadata(at: file, fallbackDate: record.createdAt)
                entries[record.id] = MessageIndexEntry(
                    id: record.id,
                    channel: record.channel,
                    createdAt: record.createdAt,
                    fileModifiedAt: metadata.modifiedAt,
                    fileSizeBytes: metadata.sizeBytes,
                    status: record.status,
                    fileURL: file
                )
                if record.status == .pending || record.status == .held,
                   let message = try? decoder.decode(A2AMessage.self, from: data) {
                    mutableMessages.append(message)
                }
            }
        }
        return (entries, mutableMessages)
    }

    private func scheduleFilesystemIndexReconciliation() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let scan = self.scanMessageFiles()
            self.queue.async {
                let scannedIds = Set(scan.entries.keys)
                for (id, scanned) in scan.entries {
                    if let current = self.messageIndex[id],
                       current.fileModifiedAt > scanned.fileModifiedAt {
                        continue
                    }
                    self.messageIndex[id] = scanned
                    do { try self.diskIndex?.upsert(self.diskRecord(for: scanned)) } catch {
                        commLog(.warning, "[MessageRouter] reconcile upsert failed for \(id): \(error)")
                    }
                }
                let staleIds = self.messageIndex.compactMap { id, entry -> String? in
                    guard !scannedIds.contains(id),
                          !self.fileManager.fileExists(atPath: self.messageFileURL(for: entry).path) else { return nil }
                    return id
                }
                for id in staleIds {
                    self.messageIndex.removeValue(forKey: id)
                    self.cache.removeValue(forKey: id)
                    self.cacheOrder.removeAll { $0 == id }
                }
                do { try self.diskIndex?.remove(ids: staleIds) } catch {
                    commLog(.warning, "[MessageRouter] reconcile delete failed: \(error)")
                }
                for message in scan.mutableMessages { self.cacheMessageLocked(message) }
            }
        }
    }

    private func loadMutableMessageIfNeeded(_ entry: MessageIndexEntry) {
        guard entry.status == .pending || entry.status == .held,
              let data = try? Data(contentsOf: messageFileURL(for: entry)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let message = try? decoder.decode(A2AMessage.self, from: data) {
            cacheMessageLocked(message)
        }
    }

    private func diskRecord(for entry: MessageIndexEntry) -> MessageDiskIndexRecord {
        MessageDiskIndexRecord(
            id: entry.id,
            channel: entry.channel,
            createdAt: entry.createdAt,
            fileModifiedAt: entry.fileModifiedAt,
            fileSizeBytes: entry.fileSizeBytes,
            status: entry.status
        )
    }

    private func messageEntry(for record: MessageDiskIndexRecord) -> MessageIndexEntry {
        MessageIndexEntry(
            id: record.id,
            channel: record.channel,
            createdAt: record.createdAt,
            fileModifiedAt: record.fileModifiedAt,
            fileSizeBytes: record.fileSizeBytes,
            status: record.status,
            fileURL: nil
        )
    }

    private func messageFileURL(for entry: MessageIndexEntry) -> URL {
        entry.fileURL ?? messagesDir
            .appendingPathComponent(entry.channel, isDirectory: true)
            .appendingPathComponent("\(entry.id).json")
    }

    private func fileMetadata(at url: URL, fallbackDate: Date) -> (
        modifiedAt: Date,
        sizeBytes: Int64
    ) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let size = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
        return (
            modifiedAt: values?.contentModificationDate ?? fallbackDate,
            sizeBytes: Int64(size)
        )
    }

    /// Must be called while holding `queue`.
    private func loadMessageLocked(_ id: String) -> A2AMessage? {
        if let cached = cache[id] {
            touchCacheLocked(id)
            return cached
        }
        guard let entry = messageIndex[id] else { return nil }
        guard let data = try? Data(contentsOf: messageFileURL(for: entry)) else {
            messageIndex.removeValue(forKey: id)
            try? diskIndex?.remove(ids: [id])
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let message = try? decoder.decode(A2AMessage.self, from: data) else { return nil }
        cacheMessageLocked(message)
        return message
    }

    /// Must be called while holding `queue`.
    private func cacheMessageLocked(_ message: A2AMessage) {
        cache[message.id] = message
        touchCacheLocked(message.id)
        evictTerminalCacheLocked()
    }

    private func touchCacheLocked(_ id: String) {
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
    }

    private func evictTerminalCacheLocked() {
        var terminalCount = cache.values.reduce(into: 0) { count, message in
            if message.status == .delivered || message.status == .dropped { count += 1 }
        }
        while terminalCount > terminalCacheLimit,
              let victimIndex = cacheOrder.firstIndex(where: { id in
                  guard let message = cache[id] else { return false }
                  return message.status == .delivered || message.status == .dropped
              }) {
            let id = cacheOrder.remove(at: victimIndex)
            cache.removeValue(forKey: id)
            terminalCount -= 1
        }
    }
}
