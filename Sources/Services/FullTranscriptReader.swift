import Foundation

/// Claude Code JSONL transcript 的完整解析器，用于 Web 端 TranscriptPanel。
/// 和 TranscriptParser 不一样——那个只抽最近 N 条预览（截断到 100/200 字），
/// 这个要把每个 block（text / thinking / tool_use / tool_result）完整原样
/// 送给前端，让 sidebar 能做富渲染。
public struct FullTranscriptEntry: Encodable {
    public let id: String           // uuid；缺失时用 index
    public let type: String         // "user" | "assistant" | "system"
    public let timestamp: String?   // ISO8601
    public let blocks: [FullTranscriptBlock]
}

public struct FullTranscriptBlock: Encodable {
    /// block 类型：text / thinking / tool_use / tool_result
    public let type: String

    // text / thinking
    public let text: String?

    // tool_use
    public let toolId: String?
    public let toolName: String?
    /// input 的 JSON 字符串（前端自己 JSON.parse），保留原始结构
    public let toolInputJSON: String?

    // tool_result
    public let toolUseId: String?
    public let toolResultText: String?  // 拍平成文本；过长会被截断
    public let toolResultTruncated: Bool?
}

/// 对外接口：读一个 sessionId 对应的 transcript 文件，返回所有 user/assistant
/// 类型条目（过滤掉 system/meta 条目，那些对用户没意义）。
public enum FullTranscriptReader {
    /// 单条 tool_result 的最大字符数。Read 工具返回整个文件内容，不截会爆。
    private static let _toolResultCap = 8_000

    public static func read(
        transcriptPath: String?,
        limit: Int? = nil
    ) -> [FullTranscriptEntry] {
        guard let path = transcriptPath,
              FileManager.default.fileExists(atPath: path) else {
            return []
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else {
            return []
        }

        var out: [FullTranscriptEntry] = []
        var index = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseLine(String(line), fallbackIndex: index) {
                out.append(entry)
            }
            index += 1
        }

        // 从尾部取 `limit` 条（更像聊天流 —— 最新在底部）
        if let limit = limit, out.count > limit {
            out = Array(out.suffix(limit))
        }
        return out
    }

    private static func parseLine(_ line: String, fallbackIndex: Int) -> FullTranscriptEntry? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String,
              ["user", "assistant", "system"].contains(type) else {
            return nil
        }

        let uuid = (json["uuid"] as? String) ?? "idx-\(fallbackIndex)"
        let ts = json["timestamp"] as? String

        // Skip isMeta user entries (Claude CLI local !bash commands)
        if type == "user", let meta = json["isMeta"] as? Bool, meta {
            return nil
        }

        var blocks: [FullTranscriptBlock] = []

        let message = json["message"]
        if let msg = message as? [String: Any] {
            let content = msg["content"]
            if let str = content as? String, !str.isEmpty {
                // Skip local-command echoes
                if str.contains("<bash-input>") ||
                   str.contains("<bash-stdout>") ||
                   str.contains("<local-command-caveat>") {
                    return nil
                }
                blocks.append(FullTranscriptBlock(
                    type: "text",
                    text: str,
                    toolId: nil, toolName: nil, toolInputJSON: nil,
                    toolUseId: nil, toolResultText: nil, toolResultTruncated: nil
                ))
            } else if let arr = content as? [[String: Any]] {
                for b in arr {
                    if let blk = parseBlock(b) {
                        blocks.append(blk)
                    }
                }
            }
        } else if let str = message as? String, !str.isEmpty {
            blocks.append(FullTranscriptBlock(
                type: "text",
                text: str,
                toolId: nil, toolName: nil, toolInputJSON: nil,
                toolUseId: nil, toolResultText: nil, toolResultTruncated: nil
            ))
        }

        // 没有任何 block 的条目（比如纯 meta）跳过
        guard !blocks.isEmpty else { return nil }

        return FullTranscriptEntry(
            id: uuid,
            type: type,
            timestamp: ts,
            blocks: blocks
        )
    }

    private static func parseBlock(_ b: [String: Any]) -> FullTranscriptBlock? {
        guard let t = b["type"] as? String else { return nil }
        switch t {
        case "text":
            let text = b["text"] as? String ?? ""
            if text.isEmpty { return nil }
            // 过滤 Claude CLI 本地命令的 echo
            if text.contains("<bash-input>") ||
               text.contains("<bash-stdout>") ||
               text.contains("<local-command-caveat>") {
                return nil
            }
            return FullTranscriptBlock(
                type: "text", text: text,
                toolId: nil, toolName: nil, toolInputJSON: nil,
                toolUseId: nil, toolResultText: nil, toolResultTruncated: nil
            )
        case "thinking":
            let text = b["thinking"] as? String ?? b["text"] as? String ?? ""
            if text.isEmpty { return nil }
            return FullTranscriptBlock(
                type: "thinking", text: text,
                toolId: nil, toolName: nil, toolInputJSON: nil,
                toolUseId: nil, toolResultText: nil, toolResultTruncated: nil
            )
        case "tool_use":
            let id = b["id"] as? String
            let name = b["name"] as? String
            let input = b["input"] ?? [:] as [String: Any]
            let inputJSON = jsonString(input) ?? "{}"
            return FullTranscriptBlock(
                type: "tool_use", text: nil,
                toolId: id, toolName: name, toolInputJSON: inputJSON,
                toolUseId: nil, toolResultText: nil, toolResultTruncated: nil
            )
        case "tool_result":
            let tuid = b["tool_use_id"] as? String
            let flat = flattenToolResultContent(b["content"])
            let (truncated, capped) = cap(flat)
            return FullTranscriptBlock(
                type: "tool_result", text: nil,
                toolId: nil, toolName: nil, toolInputJSON: nil,
                toolUseId: tuid, toolResultText: capped, toolResultTruncated: truncated
            )
        default:
            return nil
        }
    }

    /// tool_result.content 可能是 string 也可能是 [{"type":"text","text":...}, ...]
    private static func flattenToolResultContent(_ c: Any?) -> String {
        if let s = c as? String { return s }
        if let arr = c as? [[String: Any]] {
            var parts: [String] = []
            for b in arr {
                if let t = b["text"] as? String { parts.append(t) }
                else if let t = b["content"] as? String { parts.append(t) }
            }
            return parts.joined(separator: "\n")
        }
        return ""
    }

    private static func cap(_ s: String) -> (truncated: Bool, text: String) {
        if s.count > _toolResultCap {
            let cut = s.prefix(_toolResultCap)
            return (true, String(cut) + "\n…(truncated)")
        }
        return (false, s)
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// 响应 envelope
public struct FullTranscriptEnvelope: Encodable {
    public let entries: [FullTranscriptEntry]
    public let sessionId: String
}
