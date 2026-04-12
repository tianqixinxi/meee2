import Foundation

/// Transcript 状态检测结果
public struct TranscriptStatusResult {
    public let status: SessionStatus
    public let currentTool: String?
    public let lastActivity: Date?
}

/// Transcript 状态解析器 - 用于无 hook 状态的 plugin（Cursor/Traecli）
public class TranscriptStatusParser {

    /// 检测 transcript 文件的状态
    /// - Parameters:
    ///   - file: Transcript 文件路径
    ///   - maxSize: 读取尾部最大字节数
    /// - Returns: 检测结果（状态、当前工具、最后活动时间）
    public static func detectStatus(file: URL, maxSize: Int = 4096) -> TranscriptStatusResult {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return TranscriptStatusResult(status: .idle, currentTool: nil, lastActivity: nil)
        }

        // 获取文件修改时间作为最后活动时间
        let lastActivity: Date? = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        guard let entries = parseTail(url: file, maxSize: maxSize),
              !entries.isEmpty else {
            return TranscriptStatusResult(status: .idle, currentTool: nil, lastActivity: lastActivity)
        }

        // 找到最后一条有效消息
        var lastType: String?
        var lastToolName: String?
        var isToolResult = false
        var isInterrupt = false

        for entry in entries.reversed() {
            guard let type = entry.type, ["user", "assistant"].contains(type) else {
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

            if type == "assistant" && entry.toolName != nil {
                lastToolName = entry.toolName
            }

            break
        }

        guard let type = lastType else {
            return TranscriptStatusResult(status: .idle, currentTool: nil, lastActivity: lastActivity)
        }

        // 状态判断逻辑
        if type == "user" {
            if isInterrupt {
                // 用户中断 → idle
                return TranscriptStatusResult(status: .idle, currentTool: nil, lastActivity: lastActivity)
            } else if isToolResult {
                // 工具结果返回 → thinking（等待处理）
                return TranscriptStatusResult(status: .thinking, currentTool: "thinking", lastActivity: lastActivity)
            } else {
                // 用户发送消息 → thinking（等待 AI 响应）
                return TranscriptStatusResult(status: .thinking, currentTool: "thinking", lastActivity: lastActivity)
            }
        } else if type == "assistant" {
            if let tool = lastToolName {
                // 正在使用工具 → tooling
                return TranscriptStatusResult(status: .tooling, currentTool: tool, lastActivity: lastActivity)
            } else {
                // AI 已响应但无工具 → idle（已完成）
                return TranscriptStatusResult(status: .idle, currentTool: nil, lastActivity: lastActivity)
            }
        }

        return TranscriptStatusResult(status: .idle, currentTool: nil, lastActivity: lastActivity)
    }

    // MARK: - 解析方法

    /// 解析 transcript JSONL 文件尾部
    private static func parseTail(url: URL, maxSize: Int = 4096) -> [TranscriptEntry]? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }

            let fileSize = handle.seekToEndOfFile()
            let tailSize = min(fileSize, UInt64(maxSize))
            handle.seek(toFileOffset: fileSize - tailSize)

            let data = handle.readDataToEndOfFile()
            guard let tail = String(data: data, encoding: .utf8) else { return nil }

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

        var message: String?
        var toolName: String?
        var toolInput: [String: Any]?
        var toolResult: String?

        if let msg = json["message"] {
            if let msgStr = msg as? String {
                message = msgStr
            } else if let msgDict = msg as? [String: Any] {
                if let content = msgDict["content"] {
                    if let contentStr = content as? String {
                        message = contentStr
                    } else if let contentArray = content as? [[String: Any]] {
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
}

/// Transcript 条目 - 从 JSONL 文件解析的消息
private struct TranscriptEntry {
    let type: String?
    let timestamp: String
    let message: String?
    let toolName: String?
    let toolInput: [String: Any]?
    let toolResult: String?

    /// 是否为工具结果
    var isToolResult: Bool {
        toolResult != nil || message?.contains("tool_result") == true
    }

    /// 是否为中断请求
    var isInterrupt: Bool {
        guard let msg = message else { return false }
        return msg.hasPrefix("[Request interrupted by user")
    }

    /// 是否为本地命令
    var isLocalCommand: Bool {
        guard let msg = message else { return false }
        return msg.contains("<bash-input>") || msg.contains("<local-command-caveat>")
    }
}