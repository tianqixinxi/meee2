import Foundation
import PeerPluginKit

/// Transcript 状态覆写结果
struct TranscriptStatusOverride {
    var status: SessionStatus?
    var currentTool: String?
    var clearTool: Bool = false
}

/// Claude JSONL Transcript 解析器
/// 移植自 CSM 的 transcript.py
/// 读取 transcript 尾部推断真实状态，聚合 token 用量
class ClaudeTranscriptReader {
    /// 已知的 transcript 路径缓存 (sessionId → path)
    private var transcriptPaths: [String: String] = [:]

    /// UsageStats 缓存 (sessionId → stats)，定期重新计算
    private var usageCache: [String: (stats: UsageStats, timestamp: Date)] = [:]
    private let usageCacheTTL: TimeInterval = 30 // 30 秒刷新一次

    // MARK: - 配置

    /// 注册某个 session 的 transcript 路径
    func setTranscriptPath(for sessionId: String, path: String) {
        transcriptPaths[sessionId] = path
    }

    /// 自动发现 transcript 路径
    /// 实际格式: ~/.claude/projects/{project-dir}/{sessionId}.jsonl
    func discoverTranscriptPath(for sessionId: String) -> String? {
        if let cached = transcriptPaths[sessionId] { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return nil }

        for project in projectDirs {
            // 格式1: {project}/{sessionId}.jsonl
            let directPath = "\(projectsDir)/\(project)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: directPath) {
                transcriptPaths[sessionId] = directPath
                return directPath
            }

            // 格式2: {project}/sessions/{sessionId}/transcript.jsonl (旧格式兼容)
            let legacyPath = "\(projectsDir)/\(project)/sessions/\(sessionId)/transcript.jsonl"
            if FileManager.default.fileExists(atPath: legacyPath) {
                transcriptPaths[sessionId] = legacyPath
                return legacyPath
            }
        }
        return nil
    }

    // MARK: - 状态推断 (CSM 6-case 决策树)

    /// 从 transcript 尾部推断真实会话状态
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - hookStatus: 当前 hook 报告的状态
    /// - Returns: 状态覆写，nil 表示不覆写
    func inferStatus(for sessionId: String, hookStatus: SessionStatus) -> TranscriptStatusOverride {
        guard let path = transcriptPaths[sessionId] ?? discoverTranscriptPath(for: sessionId) else {
            return TranscriptStatusOverride()
        }

        // 读取最后 4KB
        guard let tail = readTail(path: path, bytes: 4096) else {
            return TranscriptStatusOverride()
        }

        let lines = tail.split(separator: "\n").reversed()

        var lastType: String?
        var isInterrupt = false
        var isToolResult = false

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            guard let entryType = entry["type"] as? String,
                  ["user", "assistant", "system"].contains(entryType) else { continue }

            // 跳过 ! bash 命令 (本地命令)
            if entryType == "user" && isLocalCommand(entry) { continue }

            lastType = entryType

            if entryType == "user" {
                isToolResult = isToolResultEntry(entry)
                if !isToolResult {
                    isInterrupt = isInterruptEntry(entry)
                }
            }
            break
        }

        guard let lastType else { return TranscriptStatusOverride() }

        // CSM 6-case 决策树
        switch lastType {
        case "user":
            if isInterrupt {
                // Case 3: 用户中断 → idle
                return TranscriptStatusOverride(status: .idle, clearTool: true)
            } else {
                // Case 1 & 2: 用户消息或 tool_result → Claude 正在处理
                return TranscriptStatusOverride(status: .thinking, currentTool: "thinking")
            }

        case "assistant":
            if hookStatus == .idle {
                // Case 5: Hook 说 idle 但 transcript 最后是 assistant → 中间态
                return TranscriptStatusOverride(status: .thinking, currentTool: "thinking")
            }
            // Case 4: Hook 说 active → 信任 hook
            return TranscriptStatusOverride()

        case "system":
            if hookStatus.isWorking {
                // Case 6: system entry (stop hook) 但 hook 还是 active → 强制 idle
                return TranscriptStatusOverride(status: .idle, clearTool: true)
            }

        default:
            break
        }

        return TranscriptStatusOverride()
    }

    // MARK: - Usage Stats

    /// 获取会话的 token 用量统计
    func getUsageStats(for sessionId: String) -> UsageStats? {
        // 检查缓存
        if let cached = usageCache[sessionId],
           Date().timeIntervalSince(cached.timestamp) < usageCacheTTL {
            return cached.stats
        }

        guard let path = transcriptPaths[sessionId] ?? discoverTranscriptPath(for: sessionId) else { return nil }

        let stats = aggregateUsage(path: path)
        usageCache[sessionId] = (stats, Date())
        return stats
    }

    /// 从 transcript 聚合 token 用量
    private func aggregateUsage(path: String) -> UsageStats {
        var stats = UsageStats()
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return stats }
        defer { fileHandle.closeFile() }

        guard let content = String(data: fileHandle.readDataToEndOfFile(), encoding: .utf8) else { return stats }

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            stats.turns = (stats.turns ?? 0) + 1
            stats.inputTokens = (stats.inputTokens ?? 0) + (usage["input_tokens"] as? Int ?? 0)
            stats.outputTokens = (stats.outputTokens ?? 0) + (usage["output_tokens"] as? Int ?? 0)
            stats.cacheCreateTokens = (stats.cacheCreateTokens ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            stats.cacheReadTokens = (stats.cacheReadTokens ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)

            if let model = message["model"] as? String, model != "<synthetic>" {
                stats.model = model
            }
        }

        // 计算估算费用 (Opus 定价)
        if let input = stats.inputTokens, let output = stats.outputTokens {
            let cacheCreate = stats.cacheCreateTokens ?? 0
            let cacheRead = stats.cacheReadTokens ?? 0
            stats.estimatedCost = Double(input) * 15 / 1_000_000
                + Double(output) * 75 / 1_000_000
                + Double(cacheCreate) * 18.75 / 1_000_000
                + Double(cacheRead) * 1.5 / 1_000_000
        }

        return stats
    }

    // MARK: - 内部辅助

    private func readTail(path: String, bytes: Int) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        let offset = fileSize > UInt64(bytes) ? fileSize - UInt64(bytes) : 0
        fileHandle.seek(toFileOffset: offset)
        let data = fileHandle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// 检查是否为 tool_result 条目
    private func isToolResultEntry(_ entry: [String: Any]) -> Bool {
        if entry["toolUseResult"] != nil { return true }
        guard let msg = entry["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == "tool_result" }
    }

    /// 检查是否为本地命令 (! bash)
    private func isLocalCommand(_ entry: [String: Any]) -> Bool {
        if entry["isMeta"] as? Bool == true { return true }
        guard let msg = entry["message"] as? [String: Any] else { return false }
        let text: String
        if let content = msg["content"] as? String {
            text = content
        } else if let content = msg["content"] as? [[String: Any]] {
            text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else {
            return false
        }
        return text.contains("<bash-input>") || text.contains("<bash-stdout>") || text.contains("<local-command-caveat>")
    }

    /// 检查是否为用户中断
    private func isInterruptEntry(_ entry: [String: Any]) -> Bool {
        guard let msg = entry["message"] as? [String: Any] else { return false }
        let text: String
        if let content = msg["content"] as? String {
            text = content
        } else if let content = msg["content"] as? [[String: Any]] {
            text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else {
            return false
        }
        return text.hasPrefix("[Request interrupted by user")
    }
}
