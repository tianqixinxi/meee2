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
///
/// 只扫 `claude-code-sessions/`（Claude.app 内嵌的 Claude Code 标签）。早期版本
/// 还顺带扫 `local-agent-mode-sessions/`（VM 沙箱 agent mode）合成 cowork synthetic
/// session，但 cowork 的 hook 在 VM 内、不进 host 的 `/tmp/meee2.sock`，meee2
/// 既无法跟踪它的实时状态也无法把消息推回去——展示了反而是误导。所以现在 cowork
/// 完全不收。
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

    /// transcript 文件在 host 上的路径（如果存在）。
    /// desktop session 跟 CLI 共用 `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`。
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
        transcriptPath: String?
    ) {
        self.cliSessionId = cliSessionId
        self.title = title
        self.model = model
        self.cwd = cwd
        self.isArchived = isArchived
        self.desktopSessionId = desktopSessionId
        self.lastActivityAt = lastActivityAt
        self.transcriptPath = transcriptPath
    }
}

/// Claude Desktop session metadata 索引器。在 App 启动时调用 `start()` 即可，
/// 自动每 N 秒重新扫描 ~/Library/Application Support/Claude/claude-code-sessions/
/// 下的所有 local_*.json 文件，构建 cliSessionId → metadata 的索引供查询。
public final class ClaudeDesktopMetadataReader {
    public static let shared = ClaudeDesktopMetadataReader()

    /// metadata 根目录（macOS 标准 Application Support 路径下的 claude-code-sessions/）。
    private let scanRoot: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("claude-code-sessions")
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
        MLog("[ClaudeDesktopMetadataReader] Started, interval: \(refreshInterval)s, root: \(scanRoot.lastPathComponent)")
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
    ///
    /// 同一个 cliSessionId 可能对应多个 `local_<uuid>.json` wrapper —— Claude
    /// Desktop 端在某些操作（resume / 重新打开 / 等）下会另起 wrapper 但保留
    /// CLI session 实体。用户在 Desktop UI 里 archive 的是单个 wrapper（标
    /// `isArchived=true` 的也只是该 wrapper），底层 CLI session 通常还在另
    /// 一个 wrapper 里活着 isArchived=false。
    ///
    /// 历史 bug（2026-05-04 现场）：以前这里是 `fresh[id] = m`（last-write-wins）
    /// + `enumerator` 顺序不定 → archived 的旧 wrapper 抢到 index 槽位 →
    /// BoardAPI.archivedDesktopSids 把整条 cliSessionId 误判成 archived → 当前
    /// session 在 webui 里凭空消失。
    ///
    /// 正确语义：只要还有任何一个 wrapper 没被 archive，这个 cliSessionId 就
    /// 是活的。冲突时 prefer unarchived；都 unarchived / 都 archived 时选
    /// `lastActivityAt` 最新的（最贴近用户最近操作的那条）。
    private func refresh() {
        var fresh: [String: ClaudeDesktopMetadata] = [:]
        if FileManager.default.fileExists(atPath: scanRoot.path) {
            for url in collectMetadataFiles(under: scanRoot) {
                guard let m = parseMetadata(at: url) else { continue }
                if let prev = fresh[m.cliSessionId] {
                    fresh[m.cliSessionId] = Self.preferredMetadata(prev, m)
                } else {
                    fresh[m.cliSessionId] = m
                }
            }
        }
        lock.lock()
        let prev = index.count
        index = fresh
        lock.unlock()
        if fresh.count != prev {
            MDebug("[ClaudeDesktopMetadataReader] index: \(prev) → \(fresh.count) desktop sessions")
        }
    }

    /// 同一 cliSessionId 的两条 metadata 选一条留下：
    ///   1. 任一 unarchived → 选 unarchived（active 优先）
    ///   2. 都 unarchived 或都 archived → 选 `lastActivityAt` 更新的
    ///   3. lastActivity 都缺 → 任选 a（稳定，避免无意义的 index churn）
    /// internal 访问级别 —— 让 `@testable import` 能直接测纯函数行为，
    /// 不用搭整个文件系统 + JSON parsing 的舞台。
    static func preferredMetadata(_ a: ClaudeDesktopMetadata, _ b: ClaudeDesktopMetadata) -> ClaudeDesktopMetadata {
        if a.isArchived != b.isArchived {
            return a.isArchived ? b : a
        }
        switch (a.lastActivityAt, b.lastActivityAt) {
        case let (.some(da), .some(db)):
            return da >= db ? a : b
        case (.some, .none):
            return a
        case (.none, .some):
            return b
        case (.none, .none):
            return a
        }
    }

    /// 递归找 root 下所有 local_*.json 文件。目录结构是
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

    /// 推导 transcript path：跟 CLI 共用 `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`。
    /// 文件不存在返回 nil。
    private func resolveTranscriptPath(cliSessionId: String, cwd: String?) -> String? {
        guard let cwd = cwd, !cwd.isEmpty else { return nil }
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let home = NSHomeDirectory()
        let candidate = "\(home)/.claude/projects/\(encoded)/\(cliSessionId).jsonl"
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    private func parseMetadata(at url: URL) -> ClaudeDesktopMetadata? {
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
        let transcriptPath = resolveTranscriptPath(cliSessionId: cliSid, cwd: cwd)
        return ClaudeDesktopMetadata(
            cliSessionId: cliSid,
            title: title,
            model: model,
            cwd: cwd,
            isArchived: isArchived,
            desktopSessionId: desktopSid,
            lastActivityAt: lastActivityAt,
            transcriptPath: transcriptPath
        )
    }
}
