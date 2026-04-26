import Foundation

// MARK: - iTerm2 input injection

/// 直接往一个 iTerm2 session 推一段文字 + 回车提交。
/// 锚定方式：iTerm2 给每 tab/pane 自动 export `$ITERM_SESSION_ID`（UUID），
/// AppleScript 端可用 `id of s` 精确匹配，无需焦点。
public struct ITerm2InputStream: TerminalInputStream {
    public init() {}

    /// terminalId 这里复用接口名，但实际语义是 `$ITERM_SESSION_ID`（不是 Ghostty id）。
    public func sendText(terminalId iTermSessionId: String, text: String) async -> Bool {
        var body = text
        while body.hasSuffix("\n") || body.hasSuffix("\r") {
            body.removeLast()
        }
        let escapedText = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedId = iTermSessionId.replacingOccurrences(of: "\"", with: "\\\"")

        // iTerm2 的 `write text` 默认带 newline → 一次调用就是「键入 + 提交」，
        // 不需要 Ghostty 的两步式 input+enter 套路。
        let script = """
        tell application "iTerm2"
            try
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (id of s as string) is "\(escapedId)" then
                                tell s to write text "\(escapedText)"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "not_found"
            on error errMsg
                return "err:" & errMsg
            end try
        end tell
        """

        let result = await runOSAScript(script)
        NSLog("[ITerm2InputStream] sendText sid=\(iTermSessionId.prefix(8)) textLen=\(text.count) result='\(result)'")
        return result == "ok"
    }
}

// MARK: - Apple Terminal input injection

/// 直接往一个 Apple Terminal tab 推一段文字 + 回车提交。
/// 锚定方式：Apple Terminal 的 `tab` 本身就有 `tty` 属性，按 tty 匹配。
/// `$TERM_SESSION_ID` 我们也存了，但 AppleScript 寻址走 tty 更直接。
///
/// 限制：Apple Terminal 用 `do script "..." in tab` 提交，对多行 prompt 会
/// 把每个 \n 当成一条命令分别执行——只适合单行内容。多行场景日后接 GUI
/// keystroke fallback 或要求用户手动粘贴。
public struct AppleTerminalInputStream {
    public init() {}

    /// tty 是裸名（"ttys003"）或全路径（"/dev/ttys003"）都可，内部统一加前缀。
    public func sendText(tty: String, text: String) async -> Bool {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let escapedTty = ttyPath.replacingOccurrences(of: "\"", with: "\\\"")
        var body = text
        while body.hasSuffix("\n") || body.hasSuffix("\r") {
            body.removeLast()
        }
        let escapedText = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            try
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (tty of t as string) is "\(escapedTty)" then
                                do script "\(escapedText)" in t
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
                return "not_found"
            on error errMsg
                return "err:" & errMsg
            end try
        end tell
        """

        let result = await runOSAScript(script)
        NSLog("[AppleTerminalInputStream] sendText tty=\(tty) textLen=\(text.count) result='\(result)'")
        return result == "ok"
    }
}

// MARK: - shared osascript runner

@inline(__always)
private func runOSAScript(_ script: String) async -> String {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: result)
            } catch {
                cont.resume(returning: "err:\(error.localizedDescription)")
            }
        }
    }
}
