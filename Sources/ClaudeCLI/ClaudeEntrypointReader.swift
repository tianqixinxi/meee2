import Foundation

/// 从 Claude Code transcript jsonl 顶部抽 `entrypoint` 字段。
///
/// 子进程在 SessionStart 时根据自身启动方式把 entrypoint 写到每条 entry 的
/// 顶层（不是放在 message 里）。已知值：
///   - "cli"            真正的终端 `claude` 进程
///   - "claude-desktop" Claude.app 内嵌子进程（与本地 ~/.claude 的 metadata 文件一一对应）
///   - "sdk-py"         Python SDK
///   - "sdk-ts"         TypeScript SDK
///
/// 跟 ClaudeDesktopMetadataReader 的区别：
///   - metadata reader 30s 才扫一次 ~/Library/.../claude-code-sessions/，新建
///     desktop session 在第一个扫描周期内会被错判成 CLI；而 entrypoint 写在
///     transcript 第一条 entry 上，hook 一进来就能读到。
///   - metadata reader 提供 friendly title / model / archived 等装饰信息，但
///     不区分 SDK；entrypoint 能区分 sdk-py / sdk-ts。
///
/// 用法：当 metadata reader 没命中时，用 entrypoint 兜底判断 clientKind 和
/// activate 路径。
public enum ClaudeEntrypointReader {
    /// 已知 entrypoint 值。其它值（未来可能新增）按 nil 处理，让调用方走
    /// "未知就当 CLI" 的默认分支。
    public static let knownDesktop = "claude-desktop"
    public static let knownCLI = "cli"
    public static let knownSDKPy = "sdk-py"
    public static let knownSDKTs = "sdk-ts"

    private struct CacheEntry {
        let mtime: TimeInterval
        let size: UInt64
        let entrypoint: String?  // nil = 已读但文件里没这个字段
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    /// 读 transcript 顶部，返回 entrypoint 字符串。
    /// 文件不存在 / 解析失败 / 字段缺失都返回 nil。
    public static func read(transcriptPath: String?) -> String? {
        guard let path = transcriptPath, !path.isEmpty else { return nil }

        // mtime + size 做缓存 key。Claude 的 transcript 是 append-only，文件
        // 增长但顶部那条不会变——理论上一次读完就够；但 size 变化时让缓存
        // miss 一下也无妨。
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            return nil
        }

        lock.lock()
        if let hit = cache[path], hit.mtime == mtime, hit.size == size {
            lock.unlock()
            return hit.entrypoint
        }
        lock.unlock()

        let value = parseHead(path: path)
        lock.lock()
        cache[path] = CacheEntry(mtime: mtime, size: size, entrypoint: value)
        lock.unlock()
        return value
    }

    /// 测试用：清空缓存。
    public static func _resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// 只读前几条，碰到第一条带 entrypoint 的就返回。读 64KB 上限。
    private static func parseHead(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let chunk = try? fh.read(upToCount: 64 * 1024) else { return nil }
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }

        // 容错：最后一行可能被截断（chunk 边界落在行中间），跳过。
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines {
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let ep = json["entrypoint"] as? String, !ep.isEmpty {
                return ep
            }
        }
        return nil
    }
}
