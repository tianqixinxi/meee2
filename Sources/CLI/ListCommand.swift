import Foundation
import Meee2PluginKit

/// List 命令 - 列出所有活跃的会话
public struct ListCommand {
    public static func run(format: OutputFormat = .table) {
        let store = SessionStore.shared
        let sessions = store.listAll()

        if sessions.isEmpty {
            print("No active sessions")
            return
        }

        switch format {
        case .table:
            printTable(sessions)
        case .json:
            printJSON(sessions)
        case .simple:
            printSimple(sessions)
        }
    }

    private static func printTable(_ sessions: [SessionData]) {
        // 表头
        print(pad("ID", to: 8) + " " + pad("PROJECT", to: 20) + " " +
              pad("STATUS", to: 12) + " " + pad("TOOL", to: 12) + " " +
              pad("PROGRESS", to: 8) + " " + pad("COST", to: 8))
        print(String(repeating: "─", count: 70))

        for session in sessions {
            let shortId = String(session.sessionId.prefix(8))
            let shortProject = truncate(session.project, maxLen: 20)

            // 三端共用的 resolver 解析结果
            let effectiveStatus = TranscriptStatusResolver.resolve(for: session)

            let statusIcon = effectiveStatus.terminalIcon
            let status = effectiveStatus.displayName
            let statusText = "\(statusIcon) \(status)"
            let tool = session.currentTool ?? "-"
            let progress = formatProgress(session.tasks)
            let cost = session.usageStats?.formattedCost ?? "-"

            print(pad(shortId, to: 8) + " " +
                  pad(shortProject, to: 20) + " " +
                  pad(statusText, to: 12) + " " +
                  pad(tool, to: 12) + " " +
                  pad(progress, to: 8) + " " +
                  pad(cost, to: 8))

            // 显示最近消息
            if let transcriptPath = session.transcriptPath {
                let msgs = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 3)
                for msg in msgs {
                    let prefix: String
                    let text = truncate(oneline(msg.text), maxLen: 60)
                    switch msg.role {
                    case "user":
                        prefix = TUIColor.cyan + ">" + TUIColor.reset
                    case "assistant":
                        prefix = TUIColor.yellow + "<" + TUIColor.reset  // ASCII instead of ◀
                    case "tool":
                        prefix = TUIColor.dim + "*" + TUIColor.reset  // ASCII instead of ⚡
                    default:
                        prefix = "."  // ASCII instead of ·
                    }
                    print("  \(prefix) \(text)")
                }
            }
        }
    }

    private static func printJSON(_ sessions: [SessionData]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        do {
            let data = try encoder.encode(sessions)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } catch {
            print("Error encoding JSON: \(error)")
        }
    }

    private static func printSimple(_ sessions: [SessionData]) {
        for session in sessions {
            let shortId = String(session.sessionId.prefix(8))

            let effectiveStatus = TranscriptStatusResolver.resolve(for: session)
            print("\(shortId) \(session.project) \(effectiveStatus.terminalIcon) \(effectiveStatus.displayName)")
        }
    }

    private static func formatProgress(_ tasks: [SessionTask]?) -> String {
        guard let tasks = tasks, !tasks.isEmpty else { return "-" }
        let done = tasks.filter { $0.status == .done || $0.status == .completed }.count
        return "\(done)/\(tasks.count)"
    }

    // MARK: - Formatting Helpers

    private static func pad(_ text: String, to width: Int) -> String {
        let displayWidth = calcDisplayWidth(text)
        if displayWidth > width { return truncateForDisplay(text, maxWidth: width) }
        return text + String(repeating: " ", count: width - displayWidth)
    }

    private static func calcDisplayWidth(_ text: String) -> Int {
        var w = 0
        for char in text {
            if char.isEmoji || char.isCJK { w += 2 } else { w += 1 }
        }
        return w
    }

    private static func truncateForDisplay(_ text: String, maxWidth: Int) -> String {
        var w = 0
        var result = ""
        for char in text {
            let charWidth = char.isEmoji || char.isCJK ? 2 : 1
            if w + charWidth > maxWidth - 2 { return result + ".." }
            result.append(char)
            w += charWidth
        }
        return result
    }

    private static func truncate(_ text: String, maxLen: Int) -> String {
        if text.count <= maxLen { return text }
        return String(text.prefix(maxLen - 2)) + ".."
    }

    private static func oneline(_ text: String) -> String {
        text.split(separator: "\n").joined(separator: " ")
    }
}

// MARK: - Character Extensions for Display Width

private extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        // ASCII chars (0x00-0x7F) are never displayed as emoji, even if they have emoji variants
        if scalar.value < 0x80 { return false }
        // Check for actual emoji presentation
        return scalar.properties.isEmoji && scalar.properties.generalCategory != .decimalNumber
    }

    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || // CJK Unified Ideographs
               (0x3000...0x303F).contains(scalar.value) || // CJK Symbols and Punctuation
               (0xFF00...0xFFEF).contains(scalar.value)    // Halfwidth and Fullwidth Forms
    }
}

/// 输出格式
public enum OutputFormat: String {
    case table   // 表格格式
    case json    // JSON 格式
    case simple  // 简洁格式
}
