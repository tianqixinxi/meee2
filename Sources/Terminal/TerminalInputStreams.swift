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

// MARK: - Claude Desktop input injection

/// 直接往 Claude.app 当前 focused 输入框 keystroke 一段文字 + 回车提交。
///
/// 跟其他 InputStream 的区别：Claude.app 不是终端，没有 tty / pane id /
/// session id 给 AppleScript 锚定，只能用 System Events `keystroke` —— 这
/// 个命令打到当前 focus 的元素，所以 *必须* 先把对的 session 切到前台。
///
/// 调用前提：
///   * Claude.app 在跑（用 `process "Claude" exists` 检测，否则 fail）
///   * meee2 已被授予 Accessibility 权限（meee2 现在为 Ghostty TerminalJumper
///     就需要这个权限，绝大多数用户已经给了）
///   * 目标 sid 是 desktop-backed（caller 自己判定，这里不管）
///   * 目标 session 处于 idle / waitingForUser / completed
///     （AgentInboxShell 已经 gate 在 resting，避免 Claude 正在跑 turn 时
///     keystroke 被吃掉或叠到正在打的字上）
///
/// 实现：
///   1. `claude://resume?session=<sid>` deep-link 切到目标 session（已通过
///      ClaudeDesktopActivator 验证过，URL handler 走 `Resume` host 然后
///      `importCliSession` + 导航）
///   2. 1.0s delay 让 Claude.app 完成 navigation + 输入框 focus（Electron
///      app 异步加载 conversation view，硬编码延迟比 polling 简单）
///   3. System Events keystroke <text> + key code 36 (Return) 提交
///
/// 失败模式：
///   * Claude.app 没启动 → `process "Claude" exists` 返 false → 返 false
///   * Accessibility 权限缺失 → keystroke 抛错 → osascript 退出非 0 →
///     runOSAScript 返 "err:..." → 返 false
///   * `claude://resume` URL 失效（Claude.app 改了 URL handler）→ 切错
///     session，但 keystroke 仍发到当前 focus 的输入框，message 进了**别**
///     的 session。这种情况短期内不会发生（CLI session 跳转都依赖这条 URL）；
///     若改了我们整套 desktop 集成都要更新
///
/// 返回值：osascript 输出 "ok" 算成功；其它都是失败，message 留 inbox。
public struct ClaudeDesktopInputStream {
    public init() {}

    public func sendText(sid: String, text: String) async -> Bool {
        // 文本结尾的换行会被 keystroke 当字面字符发，会比 key code 36 多敲
        // 一行——剥掉。
        var body = text
        while body.hasSuffix("\n") || body.hasSuffix("\r") {
            body.removeLast()
        }
        let escapedText = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedSid = sid.replacingOccurrences(of: "\"", with: "\\\"")

        // 第一步：检查 Claude.app 在跑。在跑才有 URL handler 接 deep-link。
        // 不在跑的话 NSWorkspace.open 会启动 Claude.app，但用户体验糟（突
        // 然弹个新 app）+ 启动后 navigation 时序更难拿捏。直接 fail 让
        // 消息留 inbox 等用户自己开 Claude.app。
        let script = """
        on run
            tell application "System Events"
                if not (exists process "Claude") then
                    return "err:claude_not_running"
                end if
            end tell

            -- claude://resume?session=<sid> 切到目标 session（importCliSession 是 idempotent get-or-create）
            do shell script "open 'claude://resume?session=\(escapedSid)'"
            delay 1.0

            tell application "Claude" to activate
            delay 0.3

            tell application "System Events"
                tell process "Claude"
                    set frontmost to true
                    delay 0.2
                    keystroke "\(escapedText)"
                    delay 0.1
                    key code 36 -- Return
                end tell
            end tell
            return "ok"
        end run
        """

        let result = await runOSAScript(script)
        NSLog("[ClaudeDesktopInputStream] sendText sid=\(sid.prefix(8)) textLen=\(text.count) result='\(result)'")
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
            // Explicit fd close — Pipe()'s file handles are otherwise held
            // until ARC, which under high-frequency osascript calls (每条
            // direct-push 一个) 会累积到 EBADF "Bad file descriptor"。
            defer {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
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
