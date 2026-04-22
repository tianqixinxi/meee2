import Foundation

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

/// AuditLogger - 把所有 A2A 消息状态转换写入 ~/.meee2/audit.log (append-only JSONL)。
///
/// 契约：
///   - 写入失败绝不抛出 / 传播 —— 只用 MWarn 记录。router 的 API 语义不变。
///   - 一次调用 = 一行紧凑 JSON。
///   - 读取是 MVP：把整个文件读入内存再过滤。
public final class AuditLogger {
    public static let shared = AuditLogger()

    private let fileManager = FileManager.default
    private let logPath: URL
    private let queue = DispatchQueue(label: "com.meee2.audit", qos: .utility)

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

    private init() {
        let home = NSHomeDirectory()
        let baseDir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        logPath = baseDir.appendingPathComponent("audit.log")
        MInfo("[AuditLogger] log path: \(logPath.path)")
    }

    /// 追加一条审计事件。线程安全；失败只 warn，不抛出。
    public func log(_ event: AuditEvent) {
        queue.sync {
            do {
                let data = try encoder.encode(event)
                guard var line = String(data: data, encoding: .utf8) else {
                    MWarn("[AuditLogger] failed to stringify event for \(event.msgId)")
                    return
                }
                // 单行 JSON：移除内部换行（ISO8601/字符串内容都不应含字面换行，但保险起见）
                line = line.replacingOccurrences(of: "\n", with: " ")
                line.append("\n")
                guard let bytes = line.data(using: .utf8) else {
                    MWarn("[AuditLogger] failed to encode utf8 for \(event.msgId)")
                    return
                }

                if fileManager.fileExists(atPath: logPath.path) {
                    let handle = try FileHandle(forWritingTo: logPath)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                } else {
                    try bytes.write(to: logPath, options: .atomic)
                }
            } catch {
                MWarn("[AuditLogger] write failed for \(event.msgId): \(error)")
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
            guard fileManager.fileExists(atPath: logPath.path) else { return [] }
            guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
                MWarn("[AuditLogger] failed to read \(logPath.path)")
                return []
            }

            // 保留文件插入顺序作为稳定排序的 tiebreaker
            var indexed: [(Int, AuditEvent)] = []
            var idx = 0
            for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let d = raw.data(using: .utf8) else { continue }
                if let ev = try? decoder.decode(AuditEvent.self, from: d) {
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
        }
    }

    /// 返回审计日志文件的字节数（用于诊断）
    public func sizeBytes() -> Int {
        queue.sync {
            guard fileManager.fileExists(atPath: logPath.path) else { return 0 }
            guard let attrs = try? fileManager.attributesOfItem(atPath: logPath.path) else {
                return 0
            }
            return (attrs[.size] as? Int) ?? 0
        }
    }
}
