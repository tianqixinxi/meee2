import Foundation
import Meee2PluginKit

/// Transcript 条目 - 从 JSONL 文件解析的消息
public struct TranscriptEntry {
    public let type: String?          // "user", "assistant", "system"
    public let timestamp: String
    public let message: String?
    public let toolName: String?
    public let toolInput: [String: Any]?
    public let toolResult: String?

    /// 是否为工具结果
    public var isToolResult: Bool {
        toolResult != nil || message?.contains("tool_result") == true
    }

    /// 是否为中断请求
    public var isInterrupt: Bool {
        guard let msg = message else { return false }
        return msg.hasPrefix("[Request interrupted by user")
    }

    /// 是否为本地命令 (! bash)
    public var isLocalCommand: Bool {
        guard let msg = message else { return false }
        return msg.contains("<bash-input>") || msg.contains("<local-command-caveat>")
    }
}

/// 状态覆盖 - transcript 解析后的状态建议
public struct StatusOverride {
    public var status: DetailedStatus?
    public var currentTool: String?
    public var clearTool: Bool = false
}

/// Transcript 解析器
/// 移植自 csm/lib/core/transcript.py
public class TranscriptParser {

    // MARK: - 状态检测

    /// 检测状态覆盖
    /// 逻辑移植自 csm/transcript.py detect_status
    public static func detectStatus(transcriptPath: String?, hookStatus: DetailedStatus) -> StatusOverride {
        guard let path = transcriptPath,
              let entries = parseTail(path: path, maxSize: 4096),
              !entries.isEmpty else {
            return StatusOverride()
        }

        // 找到最后一条有效消息
        var lastType: String?
        var isInterrupt = false
        var isToolResult = false

        for entry in entries.reversed() {
            guard let type = entry.type, ["user", "assistant", "system"].contains(type) else {
                continue
            }

            // 跳过本地命令
            if type == "user" && entry.isLocalCommand {
                continue
            }

            lastType = type

            if type == "user" {
                isToolResult = entry.isToolResult
                if !isToolResult {
                    isInterrupt = entry.isInterrupt
                }
            }
            break
        }

        guard let type = lastType else {
            return StatusOverride()
        }

        // 状态机逻辑 (移植自 csm)
        if type == "user" {
            if isInterrupt {
                // Case 3: 用户中断 → idle
                return StatusOverride(status: .idle, clearTool: true)
            } else if isToolResult {
                // Case 2: 工具结果 → thinking
                return StatusOverride(status: .thinking, currentTool: "thinking")
            } else {
                // Case 1: 用户消息 → thinking
                return StatusOverride(status: .thinking, currentTool: "thinking")
            }
        } else if type == "assistant" {
            if hookStatus == .idle {
                // Case 5: hook 说 idle 但没有 stop entry → thinking
                return StatusOverride(status: .thinking, currentTool: "thinking")
            }
            // Case 4: hook 说 active → 信任它
            return StatusOverride()
        } else if type == "system" {
            if hookStatus == .active {
                // Case 6: stop hook 运行了 → idle
                return StatusOverride(status: .idle, clearTool: true)
            }
        }

        return StatusOverride()
    }

    // MARK: - 解析方法

    /// 解析 transcript JSONL 文件尾部
    public static func parseTail(path: String, maxSize: Int = 4096) -> [TranscriptEntry]? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        do {
            // 读取文件尾部
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }

            let fileSize = handle.seekToEndOfFile()
            let tailSize = min(fileSize, UInt64(maxSize))
            handle.seek(toFileOffset: fileSize - tailSize)

            let data = handle.readDataToEndOfFile()
            guard let tail = String(data: data, encoding: .utf8) else { return nil }

            // 解析每一行
            var entries: [TranscriptEntry] = []
            for line in tail.split(separator: "\n") {
                guard !line.isEmpty else { continue }
                if let entry = parseLine(String(line)) {
                    entries.append(entry)
                }
            }

            return entries
        } catch {
            return nil
        }
    }

    /// 解析单行 JSON
    private static func parseLine(_ line: String) -> TranscriptEntry? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String
        let timestamp = json["timestamp"] as? String ?? ""

        // 提取消息内容
        var message: String?
        var toolName: String?
        var toolInput: [String: Any]?
        var toolResult: String?

        if let msg = json["message"] {
            if let msgStr = msg as? String {
                message = msgStr
            } else if let msgDict = msg as? [String: Any] {
                // 提取 content
                if let content = msgDict["content"] {
                    if let contentStr = content as? String {
                        message = contentStr
                    } else if let contentArray = content as? [[String: Any]] {
                        // 从 content 数组提取文本
                        var texts: [String] = []
                        for block in contentArray {
                            if let blockType = block["type"] as? String {
                                if blockType == "text", let text = block["text"] as? String {
                                    texts.append(text)
                                } else if blockType == "tool_use" {
                                    toolName = block["name"] as? String
                                    toolInput = block["input"] as? [String: Any]
                                } else if blockType == "tool_result" {
                                    toolResult = block["content"] as? String
                                }
                            }
                        }
                        message = texts.joined(separator: "\n")
                    }
                }
            }
        }

        // 检查 toolUseResult
        if let toolUseResult = json["toolUseResult"] as? [String: Any] {
            toolResult = toolUseResult["content"] as? String
        }

        return TranscriptEntry(
            type: type,
            timestamp: timestamp,
            message: message,
            toolName: toolName,
            toolInput: toolInput,
            toolResult: toolResult
        )
    }

    // MARK: - 使用统计

    /// 获取使用统计
    /// 移植自 csm/transcript.py get_usage_stats
    public static func getUsageStats(transcriptPath: String?) -> UsageStats {
        guard let path = transcriptPath,
              FileManager.default.fileExists(atPath: path) else {
            return UsageStats()
        }

        var stats = UsageStats()

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return stats
        }

        // 逐行解析
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []

        for line in lines {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard json["type"] as? String == "assistant" else { continue }

            guard let msg = json["message"] as? [String: Any] else { continue }

            // 提取 usage
            if let usage = msg["usage"] as? [String: Any] {
                stats.turns += 1
                stats.inputTokens += usage["input_tokens"] as? Int ?? 0
                stats.outputTokens += usage["output_tokens"] as? Int ?? 0
                stats.cacheCreateTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                stats.cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
            }

            // 提取 model
            if let model = msg["model"] as? String, model != "<synthetic>" {
                stats.model = model
            }
        }

        return stats
    }

    // MARK: - 消息提取

    /// 加载最近消息
    /// 移植自 csm/transcript.py load_messages
    public static func loadMessages(transcriptPath: String?, count: Int = 5) -> [(role: String, text: String)] {
        guard let path = transcriptPath,
              let entries = parseTail(path: path, maxSize: 65536) else {
            return []
        }

        var messages: [(role: String, text: String)] = []

        for entry in entries {
            guard let type = entry.type, ["user", "assistant"].contains(type) else { continue }

            if let msg = entry.message, !msg.isEmpty {
                messages.append((role: type, text: msg))
            }

            if let tool = entry.toolName {
                let summary = toolSummary(name: tool, input: entry.toolInput)
                messages.append((role: "tool", text: summary))
            }
        }

        return Array(messages.suffix(count))
    }

    /// 工具调用摘要
    /// 移植自 csm/transcript.py tool_summary
    public static func toolSummary(name: String, input: [String: Any]?) -> String {
        let inp = input ?? [:]

        switch name {
        case "Read", "Glob", "Grep":
            let path = (inp["file_path"] as? String) ?? (inp["path"] as? String) ?? (inp["pattern"] as? String) ?? ""
            return "🔧 \(name)(\(path))"
        case "Edit", "Write":
            let path = (inp["file_path"] as? String) ?? ""
            return "🔧 \(name)(\(path))"
        case "Bash":
            let desc = (inp["description"] as? String) ?? (inp["command"] as? String) ?? ""
            return "🔧 Bash: \(desc)"
        case "Agent":
            let desc = (inp["description"] as? String) ?? ((inp["prompt"] as? String)?.prefix(60).description ?? "")
            return "🔧 Agent(\(desc))"
        default:
            let firstVal = inp.values.compactMap { $0 as? String }.first?.prefix(60) ?? ""
            return "🔧 \(name)(\(firstVal))"
        }
    }
}