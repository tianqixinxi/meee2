import Foundation
import Darwin

/// 审计事件类型 - 对应 A2A 消息状态转换
public enum AuditEventType: String, Codable, Sendable {
    /// send() 持久化了一条新的 pending 消息（非人工注入）
    case created
    /// deliverPending() 成功
    case delivered
    /// 显式 hold()
    case held
    /// 显式 drop()
    case dropped
    /// edit() 修改了正文
    case edited
    /// send() 时 injectedByHuman=true（不再额外发 created 事件）
    case injected
}

/// 审计事件 - append-only JSONL 行
public struct AuditEvent: Codable, Sendable {
    public let ts: Date
    public let event: AuditEventType
    public let msgId: String
    public let channel: String
    public let fromAlias: String
    public let toAlias: String
    /// "agent:<alias>" | "human" | "system"
    public let actor: String
    /// 辅助上下文（例如 "len old=23 new=31"、"fanout=[b,c]"）
    public let details: String?

    public init(
        ts: Date = Date(),
        event: AuditEventType,
        msgId: String,
        channel: String,
        fromAlias: String,
        toAlias: String,
        actor: String,
        details: String? = nil
    ) {
        self.ts = ts
        self.event = event
        self.msgId = msgId
        self.channel = channel
        self.fromAlias = fromAlias
        self.toAlias = toAlias
        self.actor = actor
        self.details = details
    }
}

/// Bounds the append-only audit trail without requiring callers to schedule
/// maintenance. The logger compacts once on startup, periodically before
/// appends, and whenever the next record would exceed the byte ceiling.
public struct AuditRetentionPolicy: Sendable, Equatable {
    public let maxAge: TimeInterval
    public let maxBytes: Int
    public let pruneInterval: TimeInterval

    public init(
        maxAge: TimeInterval = 30 * 24 * 60 * 60,
        maxBytes: Int = 25 * 1_024 * 1_024,
        pruneInterval: TimeInterval = 60 * 60
    ) {
        self.maxAge = max(0, maxAge)
        self.maxBytes = max(1, maxBytes)
        self.pruneInterval = max(0, pruneInterval)
    }

    public static let production = AuditRetentionPolicy()
}

/// AuditLogger - 把所有 A2A 消息状态转换写入 ~/.meee2/audit.log (append-only JSONL)。
///
/// 契约：
///   - 写入失败绝不抛出 / 传播 —— 只用 MWarn 记录。router 的 API 语义不变。
///   - 一次调用 = 一行紧凑 JSON。
///   - 读取是 MVP：把整个文件读入内存再过滤。
public final class AuditLogger {
    public static let shared = AuditLogger(storage: .processDefault)

    private let fileManager: FileManager
    public let logFileURL: URL
    private let lockFileURL: URL
    private let queue = DispatchQueue(label: "com.meee2.audit", qos: .utility)
    private let retentionPolicy: AuditRetentionPolicy
    private let now: () -> Date
    private var lastCompactionAt: Date?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        storage: CommKitStoragePaths,
        fileManager: FileManager = .default,
        retentionPolicy: AuditRetentionPolicy = .production,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.retentionPolicy = retentionPolicy
        self.now = now
        let baseDir = storage.baseDirectory
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        logFileURL = baseDir.appendingPathComponent("audit.log")
        lockFileURL = baseDir.appendingPathComponent("audit.log.lock")
        compactNow()
        commLog(.info, "[AuditLogger] log path: \(logFileURL.path)")
    }

    /// 追加一条审计事件。线程安全；失败只 warn，不抛出。
    public func log(_ event: AuditEvent) {
        queue.sync {
            do {
                let currentTime = now()
                guard event.ts >= currentTime.addingTimeInterval(-retentionPolicy.maxAge) else {
                    return
                }
                let data = try encoder.encode(event)
                guard var line = String(data: data, encoding: .utf8) else {
                    commLog(.warning, "[AuditLogger] failed to stringify event for \(event.msgId)")
                    return
                }
                // 单行 JSON：移除内部换行（ISO8601/字符串内容都不应含字面换行，但保险起见）
                line = line.replacingOccurrences(of: "\n", with: " ")
                line.append("\n")
                guard let bytes = line.data(using: .utf8) else {
                    commLog(.warning, "[AuditLogger] failed to encode utf8 for \(event.msgId)")
                    return
                }
                guard bytes.count <= retentionPolicy.maxBytes else {
                    commLog(.warning, "[AuditLogger] event \(event.msgId) exceeds retention byte limit")
                    return
                }

                let appended = withFileLock(operation: LOCK_EX) {
                    let currentSize = self.fileSizeLocked()
                    let pruneDue = self.lastCompactionAt.map {
                        currentTime.timeIntervalSince($0) >= self.retentionPolicy.pruneInterval
                    } ?? true
                    if pruneDue || currentSize + bytes.count > self.retentionPolicy.maxBytes {
                        guard self.compactLocked(at: currentTime, reservingBytes: bytes.count) else {
                            return false
                        }
                    }
                    return self.appendLocked(bytes)
                } ?? false
                if appended {
                    return
                }
                commLog(.warning, "[AuditLogger] append failed for \(event.msgId)")
            } catch {
                commLog(.warning, "[AuditLogger] write failed for \(event.msgId): \(error)")
            }
        }
    }

    /// 查询事件（newest-first）。文件不存在时返回 []。
    /// 过滤在内存中完成 —— MVP 规模小，无需流式读取。
    public func query(
        channel: String? = nil,
        msgId: String? = nil,
        actor: String? = nil,
        since: Date? = nil,
        limit: Int = 200
    ) -> [AuditEvent] {
        queue.sync {
            withFileLock(operation: LOCK_SH) {
                guard self.fileManager.fileExists(atPath: self.logFileURL.path) else { return [] }
                guard let content = try? String(contentsOf: self.logFileURL, encoding: .utf8) else {
                    commLog(.warning, "[AuditLogger] failed to read \(self.logFileURL.path)")
                    return []
                }

                // 保留文件插入顺序作为稳定排序的 tiebreaker
                var indexed: [(Int, AuditEvent)] = []
                var idx = 0
                for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let d = raw.data(using: .utf8) else { continue }
                    if let ev = try? self.decoder.decode(AuditEvent.self, from: d) {
                        indexed.append((idx, ev))
                        idx += 1
                    }
                    // 静默跳过格式错误的行 —— 避免审计 I/O 阻塞业务
                }

                // 过滤
                var filtered = indexed.filter { _, ev in
                    if let channel = channel, ev.channel != channel { return false }
                    if let msgId = msgId, ev.msgId != msgId { return false }
                    if let actor = actor, ev.actor != actor { return false }
                    if let since = since, ev.ts < since { return false }
                    return true
                }

                // newest-first：先按时间降序，时间相同时保留文件倒序（后写入者更新）
                filtered.sort { a, b in
                    if a.1.ts != b.1.ts { return a.1.ts > b.1.ts }
                    return a.0 > b.0
                }

                var result = filtered.map { $0.1 }
                if result.count > limit {
                    result = Array(result.prefix(limit))
                }
                return result
            } ?? []
        }
    }

    /// Force retention immediately. Compaction uses an atomic same-directory
    /// replace while holding the same cross-process lock as all appenders.
    public func compactNow() {
        queue.sync {
            let currentTime = now()
            let compacted = withFileLock(operation: LOCK_EX) {
                self.compactLocked(at: currentTime, reservingBytes: 0)
            } ?? false
            if !compacted {
                commLog(.warning, "[AuditLogger] retention compaction failed")
            }
        }
    }

    /// Factory-reset hook. The lock file intentionally remains: unlinking a
    /// flock inode could allow a racing process to acquire a different lock.
    @discardableResult
    public func resetForFactoryReset() -> Int64 {
        queue.sync {
            let result = withFileLock(operation: LOCK_EX) { () -> (removed: Bool, bytes: Int64) in
                guard self.fileManager.fileExists(atPath: self.logFileURL.path) else {
                    return (true, 0)
                }
                let removedBytes = Int64(self.fileSizeLocked())
                do {
                    try self.fileManager.removeItem(at: self.logFileURL)
                    self.lastCompactionAt = self.now()
                    return (true, removedBytes)
                } catch {
                    return (false, 0)
                }
            } ?? (removed: false, bytes: Int64(0))
            if !result.removed {
                commLog(.warning, "[AuditLogger] factory reset failed to remove audit log")
            }
            return result.bytes
        }
    }

    /// 返回审计日志文件的字节数（用于诊断）
    public func sizeBytes() -> Int {
        queue.sync {
            withFileLock(operation: LOCK_SH) {
                self.fileSizeLocked()
            } ?? 0
        }
    }

    private func compactLocked(at currentTime: Date, reservingBytes: Int) -> Bool {
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            lastCompactionAt = currentTime
            return true
        }
        guard let source = try? Data(contentsOf: logFileURL) else { return false }

        let cutoff = currentTime.addingTimeInterval(-retentionPolicy.maxAge)
        var retainedLines: [Data] = []
        for rawLine in source.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(rawLine)
            guard let event = try? decoder.decode(AuditEvent.self, from: line),
                  event.ts >= cutoff else {
                continue
            }
            retainedLines.append(line)
        }

        let availableBytes = max(0, retentionPolicy.maxBytes - reservingBytes)
        var selectedNewestFirst: [Data] = []
        var usedBytes = 0
        for line in retainedLines.reversed() {
            let lineBytes = line.count + 1
            guard usedBytes + lineBytes <= availableBytes else { break }
            selectedNewestFirst.append(line)
            usedBytes += lineBytes
        }

        var compacted = Data(capacity: usedBytes)
        for line in selectedNewestFirst.reversed() {
            compacted.append(line)
            compacted.append(0x0A)
        }
        if compacted == source {
            lastCompactionAt = currentTime
            return true
        }
        let replaced = atomicReplaceLocked(with: compacted)
        if replaced { lastCompactionAt = currentTime }
        return replaced
    }

    private func appendLocked(_ bytes: Data) -> Bool {
        let fd = Darwin.open(logFileURL.path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        _ = Darwin.fchmod(fd, 0o600)
        let originalSize = Darwin.lseek(fd, 0, SEEK_END)
        guard originalSize >= 0 else { return false }
        guard writeAll(bytes, to: fd) else {
            _ = Darwin.ftruncate(fd, originalSize)
            return false
        }
        return true
    }

    private func atomicReplaceLocked(with data: Data) -> Bool {
        let directory = logFileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".audit.log.compact.\(getpid()).\(UUID().uuidString)"
        )
        let fd = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        var succeeded = false
        defer {
            Darwin.close(fd)
            if !succeeded { try? fileManager.removeItem(at: temporaryURL) }
        }
        guard writeAll(data, to: fd), Darwin.fsync(fd) == 0 else { return false }
        guard Darwin.rename(temporaryURL.path, logFileURL.path) == 0 else { return false }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            _ = Darwin.fsync(directoryFD)
            Darwin.close(directoryFD)
        }
        succeeded = true
        return true
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func fileSizeLocked() -> Int {
        guard let attrs = try? fileManager.attributesOfItem(atPath: logFileURL.path) else {
            return 0
        }
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    private func withFileLock<T>(operation: Int32, _ body: () -> T) -> T? {
        let fd = Darwin.open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        _ = Darwin.fchmod(fd, 0o600)
        var result: Int32
        repeat {
            result = flock(fd, operation)
        } while result != 0 && errno == EINTR
        guard result == 0 else { return nil }
        defer { _ = flock(fd, LOCK_UN) }
        return body()
    }
}
