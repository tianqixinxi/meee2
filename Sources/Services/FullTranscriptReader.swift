import Foundation

/// Claude Code JSONL transcript 的完整解析器，用于 Web 端 TranscriptPanel。
/// 和 TranscriptParser 不一样——那个只抽最近 N 条预览（截断到 100/200 字），
/// 这个要把每个 block（text / thinking / tool_use / tool_result）完整原样
/// 送给前端，让 sidebar 能做富渲染。
public struct FullTranscriptEntry: Encodable {
    public let id: String           // uuid；缺失时用 index
    public let type: String         // "user" | "assistant" | "system" | "injected"
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

        // 判定 isMeta user 的来源：
        //   - <bash-input>/<bash-stdout>/<local-command-caveat> → Claude CLI
        //     的本地 ! 命令回显，对终端用户没意义，丢
        //   - 否则就是 Stop hook 的 block reason 注入（operator/A2A 消息）。
        //     原版本一刀切丢了所有 isMeta=true，导致这些注入完全不出现在
        //     transcript 里，UI 上看到 Claude 凭空回复——保留下来标为
        //     "injected" 类型，让前端渲染成区别于普通 user 的气泡。
        let isMetaUser = type == "user" && ((json["isMeta"] as? Bool) ?? false)
        var entryType = type

        var blocks: [FullTranscriptBlock] = []

        let message = json["message"]
        if let msg = message as? [String: Any] {
            let content = msg["content"]
            if let str = content as? String, !str.isEmpty {
                // Claude CLI 本地命令回显（! 命令）只会以 type=user + content=string
                // 形式出现，且整段以 <bash-*> / <local-command-caveat> 这些标签开头。
                // 以前用 contains 一刀切，会误丢 assistant 在正文里讨论这些标志名
                // 的合法消息（比如 "...含 `<bash-input>` 标志，丢"）。改成只在 user
                // 路径上 hasPrefix 检查。
                if type == "user" && Self.isLocalCommandEcho(str) {
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

        // isMeta=true 的 user 一概标 injected。原版本只在 string content 分支
        // 标，但 Claude Code 未来如果把 Stop hook block reason 包成 block-form
        // (tool_result 之类)，老逻辑会漏判 → 又退回"凭空回复"那个老 bug。
        // 真正的本地 ! 命令回显在上面 isLocalCommandEcho 处已经 return nil 丢掉了。
        if isMetaUser {
            entryType = "injected"
        }

        return FullTranscriptEntry(
            id: uuid,
            type: entryType,
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
            // 故意不在这里过滤 <bash-input> 等 marker：本地命令回显只会以
            // type=user + content=string 的形式出现（30 天历史样本 0 条 array
            // 形式），过滤集中到 parseLine 的 string 分支。assistant 文本里
            // 提到这些字面量是合法内容，不能丢。
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
                if let t = b["text"] as? String { parts.append(t) } else if let t = b["content"] as? String { parts.append(t) }
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

    /// 判断一段 string content 是否是 Claude CLI 的本地命令回显。
    /// 关键约束：必须以 marker 开头，不是 contains —— 否则正文里讨论这些
    /// 标志名的 assistant 文本会被误丢。
    static func isLocalCommandEcho(_ s: String) -> Bool {
        return s.hasPrefix("<bash-input>")
            || s.hasPrefix("<bash-stdout>")
            || s.hasPrefix("<local-command-caveat>")
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
