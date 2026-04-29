import Foundation

/// Claude Desktop 的 session metadata 信息（从 ~/Library/Application Support/Claude
/// 下面的 JSON 文件读取）。Desktop 内嵌的 Claude Code 子进程会把会话元信息额外
/// 写到这个目录，但 cliSessionId 字段和 CLI 共享 UUID 命名空间——transcript 仍然
/// 写在 ~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl 里。
///
/// meee2 集成方式：ClaudePlugin 通过 hook 路径已经能看到 desktop session（它的
/// 内嵌 binary 也读 ~/.claude/settings.json hooks），唯一缺的是 desktop-specific
/// metadata。这个 reader 提供一个 cliSessionId → metadata 的查表，供 BoardDTO
/// builder 装饰已有 PluginSession（覆盖 title / model / 标 clientKind / 跳过
/// archived）。
/// 来源：claude-code-sessions/ 是 desktop 内置 Claude Code agent；
/// local-agent-mode-sessions/ 是 cowork（VM-sandboxed agent mode）。
/// 两者 schema 几乎一致，区别只在 cwd（cowork 是 VM 内的虚拟路径）和
/// 几个 cowork 专属字段（vmProcessName / hostLoopMode / egressAllowedDomains）。
public enum ClaudeDesktopSource: String, Sendable {
    case desktopCode = "desktop"   // claude-code-sessions
    case cowork = "cowork"          // local-agent-mode-sessions (VM)
}

public struct ClaudeDesktopMetadata: Sendable {
    public let cliSessionId: String
    public let title: String
    public let model: String?
    public let cwd: String?
    public let isArchived: Bool
    /// metadata 文件本身的 sessionId（local_<uuid>，desktop 自己的内部 id，跟
    /// cliSessionId 不一样；保留下来供将来 deep-link 跳转使用）
    public let desktopSessionId: String
    public let lastActivityAt: Date?
    public let source: ClaudeDesktopSource

    /// transcript 文件在 host 上的路径（如果存在）。
    /// - desktop-code session：transcript 跟 CLI 共用 `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`
    /// - cowork session：transcript 在 metadata 文件旁边的 `local_<desktopSid>/.claude/projects/<encoded-vm-cwd>/<sid>.jsonl`
    ///   （VM 把它内部的 .claude 目录映射到 host 上这个位置）
    /// 文件不存在时为 nil。
    public let transcriptPath: String?

    public init(
        cliSessionId: String,
        title: String,
        model: String?,
        cwd: String?,
        isArchived: Bool,
        desktopSessionId: String,
        lastActivityAt: Date?,
        source: ClaudeDesktopSource,
        transcriptPath: String?
    ) {
        self.cliSessionId = cliSessionId
        self.title = title
        self.model = model
        self.cwd = cwd
        self.isArchived = isArchived
        self.desktopSessionId = desktopSessionId
        self.lastActivityAt = lastActivityAt
        self.source = source
        self.transcriptPath = transcriptPath
    }
}

/// Claude Desktop session metadata 索引器。在 App 启动时调用 `start()` 即可，
/// 自动每 N 秒重新扫描 ~/Library/Application Support/Claude/claude-code-sessions/
/// 下的所有 local_*.json 文件，构建 cliSessionId → metadata 的索引供查询。
public final class ClaudeDesktopMetadataReader {
    public static let shared = ClaudeDesktopMetadataReader()

    /// metadata 文件根目录（macOS 标准 Application Support 路径）。
    /// 扫描两种 source：
    ///   - claude-code-sessions/   → ClaudeDesktopSource.desktopCode
    ///   - local-agent-mode-sessions/  → ClaudeDesktopSource.cowork
    private let scanRoots: [(URL, ClaudeDesktopSource)] = {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
        return [
            (base.appendingPathComponent("claude-code-sessions"), .desktopCode),
            (base.appendingPathComponent("local-agent-mode-sessions"), .cowork)
        ]
    }()

    /// 扫描间隔。新建 desktop session 也会触发 hook → ClaudePlugin 立刻知道，
    /// 我们只是慢一拍把 metadata 装饰上去——30s 完全够用，不需要文件 watcher。
    private let refreshInterval: TimeInterval = 30.0

    private let lock = NSLock()
    private var index: [String: ClaudeDesktopMetadata] = [:]
    private var timer: DispatchSourceTimer?

    private init() {}

    /// 启动周期扫描。重复调用安全（重复调用只是重置 timer）。
    public func start() {
        lock.lock()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: refreshInterval)
        t.setEventHandler { [weak self] in self?.refresh() }
        timer = t
        lock.unlock()
        t.resume()
        let roots = scanRoots.map { $0.0.lastPathComponent }.joined(separator: ", ")
        MLog("[ClaudeDesktopMetadataReader] Started, interval: \(refreshInterval)s, roots: [\(roots)]")
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// 查 cliSessionId 对应的 desktop metadata。命中即说明该 session 是 desktop
    /// 起的（CLI 起的 session 没 metadata 文件，返回 nil）。
    public func lookup(cliSessionId: String) -> ClaudeDesktopMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return index[cliSessionId]
    }

    /// 当前所有已知 desktop session 的 cliSessionId。
    /// 给"过滤 archived"等批量操作用。
    public func allCliSessionIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(index.keys)
    }

    /// 重新扫描整个目录，重建索引。
    /// 文件不多（典型 < 100），open+decode 也不慢，每 30s 一次成本可忽略。
    private func refresh() {
        var fresh: [String: ClaudeDesktopMetadata] = [:]
        for (root, source) in scanRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for url in collectMetadataFiles(under: root) {
                guard let m = parseMetadata(at: url, source: source) else { continue }
                // 同一 cliSessionId 出现在两个 root（理论上不会，cowork 和
                // desktop-code 的 cliSessionId 命名空间互不重叠）也无妨——
                // 后写覆盖前写，最近一次解析的 source 胜出。
                fresh[m.cliSessionId] = m
            }
        }
        lock.lock()
        let prev = index.count
        index = fresh
        lock.unlock()
        if fresh.count != prev {
            MDebug("[ClaudeDesktopMetadataReader] index: \(prev) → \(fresh.count) desktop+cowork sessions")
        }
    }

    /// 递归找 root 下所有 local_*.json 文件。两种 root 目录结构都是
    /// `<root>/<userId>/<workspaceId>/local_<uuid>.json`，深度固定但保险起见
    /// 用 enumerator 全扫。
    private func collectMetadataFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("local_"),
                  url.pathExtension == "json" else { continue }
            out.append(url)
        }
        return out
    }

    /// 推导 transcript path。两种 source 路径不同：
    ///   - desktop-code: ~/.claude/projects/<encoded-host-cwd>/<sid>.jsonl
    ///   - cowork:       <metadata-dir>/local_<desktopSid>/.claude/projects/<encoded-vm-cwd>/<sid>.jsonl
    /// 文件不存在返回 nil（cowork session 还没进 VM 跑过 / 路径不是预期形态）。
    private func resolveTranscriptPath(
        metadataURL: URL,
        cliSessionId: String,
        cwd: String?,
        desktopSessionId: String,
        source: ClaudeDesktopSource
    ) -> String? {
        guard let cwd = cwd, !cwd.isEmpty else { return nil }
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let candidate: String
        switch source {
        case .desktopCode:
            // host-truth：和 CLI 共用 ~/.claude/projects/
            let home = NSHomeDirectory()
            candidate = "\(home)/.claude/projects/\(encoded)/\(cliSessionId).jsonl"
        case .cowork:
            // VM 把 .claude 映射到 metadata 文件旁边
            // metadata file: .../local_<sid>.json
            // session home : .../local_<sid>/   （同名无 .json）
            let metaDir = metadataURL.deletingPathExtension().path
            candidate = "\(metaDir)/.claude/projects/\(encoded)/\(cliSessionId).jsonl"
        }
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private func parseMetadata(at url: URL, source: ClaudeDesktopSource) -> ClaudeDesktopMetadata? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let cliSid = json["cliSessionId"] as? String, !cliSid.isEmpty else {
            return nil
        }
        let desktopSid = json["sessionId"] as? String ?? "local_unknown"
        let title = (json["title"] as? String) ?? "(untitled)"
        let model = json["model"] as? String
        let cwd = json["cwd"] as? String
        let isArchived = (json["isArchived"] as? Bool) ?? false
        // Desktop 存的是 unix milliseconds (Number)
        let lastActivityAt: Date? = {
            if let ms = json["lastActivityAt"] as? Double {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            return nil
        }()
        let transcriptPath = resolveTranscriptPath(
            metadataURL: url,
            cliSessionId: cliSid,
            cwd: cwd,
            desktopSessionId: desktopSid,
            source: source
        )
        return ClaudeDesktopMetadata(
            cliSessionId: cliSid,
            title: title,
            model: model,
            cwd: cwd,
            isArchived: isArchived,
            desktopSessionId: desktopSid,
            lastActivityAt: lastActivityAt,
            source: source,
            transcriptPath: transcriptPath
        )
    }
}
