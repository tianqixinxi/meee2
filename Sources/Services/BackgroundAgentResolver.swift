import Foundation

/// 一个当前正在"后台跑"的 Claude Code 子 agent / task 的描述。
///
/// 三种来源：
///   - `Agent` tool 带 `run_in_background: true` → kind = "agent"
///   - `Monitor` tool（总是后台）                → kind = "monitor"
///   - `Bash` tool 带 `run_in_background: true`  → kind = "bash"
public struct BackgroundAgent: Codable, Sendable, Hashable {
    public let id: String              // Claude 返回的 agentId / taskId
    public let kind: String            // "agent" | "monitor" | "bash"
    public let description: String?    // tool input 里的 description
    public let startedAt: Date?        // tool_result 所在 transcript entry 的 timestamp

    /// Claude CLI 把 bg task 的 stdout 流到 `.../tasks/<id>.output`，agent 的
    /// 则是 `.../subagents/agent-<id>.jsonl`。tool_result 启动确认文本里带
    /// 绝对路径（`output_file: ...`），我们在 parse 时顺手抓下来；之后拿来
    /// 做 "最近有没有输出" 的 quiescence 判活。
    public let outputPath: String?
}

/// 从 transcript 里抽取当前在后台运行的 Claude Code 子 agent / task。
///
/// Claude Code 的 background tool 行为很规则：发起时 tool_result 里带一个
/// 明文的启动确认（"Async agent launched...", "Monitor started (task ...",
/// "Command running in background with ID: ..."）；结束时 Claude CLI 把一条
/// `<task-notification>...<status>completed</status>...</task-notification>`
/// 的 user 消息注回 transcript。我们在 transcript tail 里把这两种信号都
/// 抽出来，started - completed = 还在跑的集合。
///
/// 为什么不靠 SubagentStart/SubagentStop hook：那两个 hook 对应的是 `Agent`
/// 工具同步调用（`Task` sub-agent 走 sync 的情况），不覆盖 Monitor /
/// run_in_background Bash，也没 taskId 字段。transcript 扫描更统一。
public enum BackgroundAgentResolver {

    // MARK: - 缓存

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 3.0
    private struct CacheEntry {
        let at: Date
        let agents: [BackgroundAgent]
    }

    // MARK: - Public

    public static func resolve(transcriptPath: String?) -> [BackgroundAgent] {
        guard let path = transcriptPath, !path.isEmpty else { return [] }

        cacheLock.lock()
        if let c = cache[path], Date().timeIntervalSince(c.at) < cacheTTL {
            cacheLock.unlock()
            return c.agents
        }
        cacheLock.unlock()

        let agents = resolveUncached(path: path)

        cacheLock.lock()
        cache[path] = CacheEntry(at: Date(), agents: agents)
        cacheLock.unlock()
        return agents
    }

    public static func invalidate(transcriptPath: String?) {
        guard let path = transcriptPath, !path.isEmpty else { return }
        cacheLock.lock()
        cache.removeValue(forKey: path)
        cacheLock.unlock()
    }

    // MARK: - 解析

    /// 只读尾部 ~2MB。一个 bg agent 如果活得超过这个窗口被 flush 出去了，
    /// 我们会丢掉它；但这种场景下主 session 本身早已 compact 过，信息价值
    /// 很低。对常规几分钟到半小时的 bg task 完全够用。
    private static let tailBytes: UInt64 = 2 * 1024 * 1024

    private static func resolveUncached(path: String) -> [BackgroundAgent] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        guard let tail = readTail(path: path, maxBytes: tailBytes) else { return [] }

        // 第一遍：recognised tool_use（按 tool_use_id 索引）——记 kind+desc，
        // 只为后面 tool_result 出现时配对启动确认。
        var startedByToolUseId: [String: (kind: String, description: String?)] = [:]
        // 第二遍累积：已确认启动的 bg task（taskId 从 tool_result 文本里抠）
        var running: [String: BackgroundAgent] = [:]
        // 完成的 taskId（来自 <task-notification>…<status>completed</status>）
        var completed: Set<String> = []

        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBase = ISO8601DateFormatter()

        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = obj["type"] as? String
            let tsStr = (obj["timestamp"] as? String) ?? ""
            let ts: Date? = isoWithFrac.date(from: tsStr) ?? isoBase.date(from: tsStr)

            guard let msg = obj["message"] as? [String: Any] else { continue }

            // ── assistant 的 tool_use：记 kind+desc ──
            if type == "assistant", let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    guard (block["type"] as? String) == "tool_use",
                          let toolId = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    let desc = input["description"] as? String

                    switch name {
                    case "Agent", "Task":
                        if (input["run_in_background"] as? Bool) == true {
                            startedByToolUseId[toolId] = ("agent", desc)
                        }
                    case "Monitor":
                        startedByToolUseId[toolId] = ("monitor", desc)
                    case "Bash":
                        if (input["run_in_background"] as? Bool) == true {
                            startedByToolUseId[toolId] = ("bash", desc)
                        }
                    default:
                        break
                    }
                }
            }

            // ── user 的 tool_result / 嵌入式 task-notification ──
            if type == "user" {
                // user message content 可能是 string 或 array
                if let contentArr = msg["content"] as? [[String: Any]] {
                    for block in contentArr {
                        let btype = block["type"] as? String
                        if btype == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String,
                           let started = startedByToolUseId[toolUseId] {
                            let text = extractText(block["content"])
                            if let taskId = extractTaskId(from: text, kind: started.kind) {
                                // output path: 先从 tool_result 文本里抠，抠不到就按 Claude CLI 的
                                // 约定从 transcriptPath + taskId 推导（Monitor 经常不附带）。
                                let outputPath = extractOutputPath(from: text)
                                    ?? derivedOutputPath(kind: started.kind, id: taskId, transcriptPath: path)
                                running[taskId] = BackgroundAgent(
                                    id: taskId,
                                    kind: started.kind,
                                    description: started.description,
                                    startedAt: ts,
                                    outputPath: outputPath
                                )
                            }
                        }
                        // task-notification 可能作为 text block 出现
                        if btype == "text", let text = block["text"] as? String {
                            collectCompletedTasks(from: text, into: &completed)
                        }
                        // 有时 tool_result 的 content 本身就是 task-notification
                        if btype == "tool_result" {
                            collectCompletedTasks(from: extractText(block["content"]), into: &completed)
                        }
                    }
                } else if let contentStr = msg["content"] as? String {
                    // content 是纯字符串的情况（老格式 / task-notification 注回路径）
                    collectCompletedTasks(from: contentStr, into: &completed)
                }
            }
        }

        let active = running.values
            .filter { !completed.contains($0.id) }
            .filter { isStillYoung($0) }
            .filter { isOutputFresh($0) }
        return active.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    // MARK: - helpers

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

    private static func extractText(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            var out: [String] = []
            for item in arr {
                if item["type"] as? String == "text", let t = item["text"] as? String {
                    out.append(t)
                }
            }
            return out.joined(separator: "\n")
        }
        return ""
    }

    /// tool_result 启动确认里带着 output 文件的绝对路径。Agent 用
    /// `output_file:`，bash bg 用 `Output is being written to:`，Monitor 不一定
    /// 附带。两种锚点都试一下，匹到就返回。
    private static func extractOutputPath(from text: String) -> String? {
        if let p = firstCapture(in: text, pattern: #"output_file:\s*(\S+)"#) { return p }
        if let p = firstCapture(in: text, pattern: #"Output is being written to:\s*(\S+)"#) { return p }
        return nil
    }

    /// tool_result 里没明文给 output 路径时（典型：Monitor），按 Claude CLI
    /// 的固定约定推导：
    ///   - bash/monitor: `/private/tmp/claude-<uid>/<encodedCwd>/<sid>/tasks/<id>.output`
    ///   - agent:        `~/.claude/projects/<encodedCwd>/<sid>/subagents/agent-<id>.jsonl`
    /// `transcriptPath` 的 shape 是 `~/.claude/projects/<encodedCwd>/<sid>.jsonl`，
    /// 从它拆出两个组件。
    private static func derivedOutputPath(
        kind: String, id: String, transcriptPath: String
    ) -> String? {
        let url = URL(fileURLWithPath: transcriptPath)
        let sid = url.deletingPathExtension().lastPathComponent
        let encoded = url.deletingLastPathComponent().lastPathComponent
        guard !sid.isEmpty, !encoded.isEmpty else { return nil }

        switch kind {
        case "agent":
            return (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/projects/\(encoded)/\(sid)/subagents/agent-\(id).jsonl")
        case "bash", "monitor":
            let uid = getuid()
            return "/private/tmp/claude-\(uid)/\(encoded)/\(sid)/tasks/\(id).output"
        default:
            return nil
        }
    }

    private static func extractTaskId(from text: String, kind: String) -> String? {
        // 各 kind 的 tool_result 启动确认文本是固定格式，挑最明确的锚点匹配：
        switch kind {
        case "agent":
            return firstCapture(in: text, pattern: #"agentId:\s*([A-Za-z0-9_-]+)"#)
        case "monitor":
            // "Monitor started (task bixqv0khl, timeout ..."
            return firstCapture(in: text, pattern: #"Monitor started \(task\s+([A-Za-z0-9_-]+)"#)
        case "bash":
            // "Command running in background with ID: b2yt7t2ag."
            return firstCapture(in: text, pattern: #"background with ID:\s*([A-Za-z0-9_-]+)"#)
        default:
            return nil
        }
    }

    private static func collectCompletedTasks(from text: String, into set: inout Set<String>) {
        guard text.contains("<task-notification>") else { return }
        // 一个 user message 里可能连续注多条 task-notification（比如同一次 Stop
        // drain 里多个后台任务同时完成），所以要循环匹配。
        // 终态状态：`completed` 是正常结束，`failed` 是 Monitor timeout /
        // subagent 异常死。两者都应视为"不再占坑"。streaming 中间事件的
        // notification 没有 <status> 标签，不会落入这个分支。
        var cursor = text.startIndex
        while let open = text.range(of: "<task-notification>", range: cursor..<text.endIndex),
              let close = text.range(of: "</task-notification>", range: open.upperBound..<text.endIndex) {
            let block = text[open.upperBound..<close.lowerBound]
            if block.contains("<status>completed</status>") || block.contains("<status>failed</status>") {
                if let id = firstCapture(in: String(block), pattern: #"<task-id>([^<]+)</task-id>"#) {
                    set.insert(id)
                }
            }
            cursor = close.upperBound
        }
    }

    // MARK: - 老化保护
    //
    // 有些 bg task 永远不会发 completion notification：Monitor 的 parent
    // session crash、Bash bg 被用户直接 kill、Claude CLI compact 把 completion
    // 消息 flush 掉、等等。过了一个明显不合理的时长还挂着"running"非常误导。
    // 保守挡一下：比该 kind 的合理最长生命周期更久的一律当已结束忽略。
    //
    // 这些门限按 Claude Code 当前 tool 默认值取 3× 裕量：
    //   - Monitor:   默认 timeout 10min → 30min
    //   - Bash bg:   典型 <15min → 60min
    //   - Agent bg:  典型 <30min → 120min
    private static let maxAgeByKind: [String: TimeInterval] = [
        "monitor": 30 * 60,
        "bash":    60 * 60,
        "agent":   120 * 60,
    ]

    private static func isStillYoung(_ agent: BackgroundAgent) -> Bool {
        guard let started = agent.startedAt else { return true }  // 无时间戳保守认为还在跑
        let maxAge = maxAgeByKind[agent.kind] ?? 60 * 60
        return Date().timeIntervalSince(started) < maxAge
    }

    /// 最大 "输出文件静默时间"——超过这个没写东西就当已经死了。
    /// 用意是兜住那些悄悄 crash / 被 kill 但没来得及发
    /// `<task-notification>completed</task-notification>` 的 bg 任务。
    ///
    /// 门限比完成通知宽松一点、比 `maxAgeByKind` 的老化保护紧得多。bash/
    /// monitor 正常都会 1-2 帧/分钟地打点；agent 的 jsonl 每一轮 assistant
    /// think/tool 都会追加，静默 10min 基本没戏。
    private static let maxIdleByKind: [String: TimeInterval] = [
        "bash":    5 * 60,
        "monitor": 5 * 60,
        "agent":   10 * 60,
    ]

    private static func isOutputFresh(_ agent: BackgroundAgent) -> Bool {
        guard let path = agent.outputPath, !path.isEmpty else { return true }
        // 文件不存在 → 没法判活，让它通过（避免把刚启动、output_file 还没建好的误杀）
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return true
        }
        let idleCap = maxIdleByKind[agent.kind] ?? 5 * 60
        let idle = Date().timeIntervalSince(mtime)
        if idle >= idleCap {
            NSLog("[BackgroundAgentResolver] pruning \(agent.kind)/\(agent.id.prefix(10)) — output quiescent for \(Int(idle))s (path=\(path))")
            return false
        }
        return true
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
