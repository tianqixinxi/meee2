import Foundation

/// 一次 Claude Code "away summary" —— 用户离开回来后 CLI 自动打的那段。
/// `/recap` 手动触发和离开自动触发写的是同一个 entry 格式。
public struct SessionRecap: Codable, Sendable, Hashable {
    public let content: String
    public let timestamp: Date?
}

/// 从 transcript JSONL 里找最新一条 recap。
///
/// Claude CLI 写入格式：
///   `{"type":"system","subtype":"away_summary","content":"...","timestamp":"ISO"}`
/// 我们扫 tail（足够回溯最近几次 recap），返回时间最新的那一条。
public enum RecapResolver {

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 10.0
    private struct CacheEntry {
        let at: Date
        let recap: SessionRecap?
    }

    /// 只读 tail 最多 2MB。Recap 大概每几十分钟写一次，2MB 足够覆盖活跃
    /// session 最近几次；更老的 recap 价值也低。
    private static let tailBytes: UInt64 = 2 * 1024 * 1024

    public static func resolve(transcriptPath: String?) -> SessionRecap? {
        guard let path = transcriptPath, !path.isEmpty else { return nil }

        cacheLock.lock()
        if let c = cache[path], Date().timeIntervalSince(c.at) < cacheTTL {
            cacheLock.unlock()
            return c.recap
        }
        cacheLock.unlock()

        let recap = resolveUncached(path: path)

        cacheLock.lock()
        cache[path] = CacheEntry(at: Date(), recap: recap)
        cacheLock.unlock()
        return recap
    }

    public static func invalidate(transcriptPath: String?) {
        guard let path = transcriptPath, !path.isEmpty else { return }
        cacheLock.lock()
        cache.removeValue(forKey: path)
        cacheLock.unlock()
    }

    // MARK: - 解析

    private static func resolveUncached(path: String) -> SessionRecap? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let tail = readTail(path: path, maxBytes: tailBytes) else { return nil }

        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBase = ISO8601DateFormatter()

        var latest: SessionRecap?
        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            // 轻量早剪：大多数行都不是 system/away_summary，跳过 JSON 解析
            guard rawLine.contains("away_summary") else { continue }
            guard let data = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "system",
                  (obj["subtype"] as? String) == "away_summary",
                  let content = obj["content"] as? String,
                  !content.isEmpty else { continue }
            let tsStr = (obj["timestamp"] as? String) ?? ""
            let ts: Date? = isoWithFrac.date(from: tsStr) ?? isoBase.date(from: tsStr)
            let candidate = SessionRecap(content: content, timestamp: ts)

            // 保留时间戳最新的；没时间戳的就按文件顺序取最后一条
            if let cur = latest {
                switch (candidate.timestamp, cur.timestamp) {
                case let (a?, b?):
                    if a > b { latest = candidate }
                case (_?, nil):
                    latest = candidate
                default:
                    latest = candidate  // 两者都无时间戳，文件末尾胜
                }
            } else {
                latest = candidate
            }
        }
        return latest
    }

    private static func readTail(path: String, maxBytes: UInt64) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start: UInt64 = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
