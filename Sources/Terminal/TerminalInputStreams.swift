import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif

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
/// 关键实现细节：
///
/// 1. **NSAppleScript 而不是 osascript 子进程**。`Process(/usr/bin/osascript)`
///    跑的脚本身份是 `osascript` 自己，没有 Accessibility 权限就报
///    `error 1002 osascript is not allowed to send keystrokes`。
///    `NSAppleScript` 在 meee2 进程内执行，身份是 meee2.app —— 用户给
///    meee2 授过 Accessibility（已经为 Ghostty TerminalJumper 需要），
///    keystroke 就能走通。TerminalJumper.runAppleScript 已经踩过这条坑。
///
/// 2. **全局串行**。Claude.app 是单例 + 同时只能 focus 一个 session，所以
///    每次 sendText 都通过 `claude://resume` 切换 + activate + keystroke。
///    多个 sendText 并发会让 Claude.app 在 sessions 之间抽搐（2026-05-05
///    现场：4 条 inbox 消息分散在 2 个 desktop session 上，每秒翻 2-3 次）。
///    用一个 global actor 串行所有 keystroke 调用，一条做完才轮下一条。
///
/// 调用前提：
///   * Claude.app 在跑（脚本里检测，没在跑直接 fail）
///   * meee2.app 有 Accessibility 权限（meee2 启动时通常用户已授）
///   * 目标 sid 是 desktop-backed（caller 自己判定，这里不管）
///   * 目标 session 处于 idle / waitingForUser / completed
///     （AgentInboxShell 已经 gate 在 resting，避免 Claude 正在跑 turn 时
///     keystroke 被吃掉或叠到正在打的字上）
///
/// 实现：
///   1. `claude://resume?session=<sid>` deep-link 切到目标 session（已通过
///      ClaudeDesktopActivator 验证过，URL handler 走 `Resume` host 然后
///      `importCliSession` + 导航）
///   2. 1.0s delay 让 Claude.app 完成 navigation + 输入框 focus
///   3. System Events keystroke <text> + key code 36 (Return) 提交
///
/// 返回值：脚本无错算成功；脚本错（`error 1002`、`process not running`、
/// AppleScript 语法等）都返 false，message 留 inbox 等下次 Stop 兜底。
public struct ClaudeDesktopInputStream {
    /// 全局 actor 串行所有 desktop keystroke。任何并发 caller 都被排队，
    /// 一条 sendText 完整走完（resume + activate + keystroke + Return + 收
    /// 尾延迟）才轮下一条。避免多 session 同时 push 时 Claude.app 抽搐。
    private actor Serializer {
        static let shared = Serializer()
        func runExclusive<T>(_ op: () async -> T) async -> T {
            await op()
        }
    }

    public enum SendError: Error, LocalizedError {
        case accessibilityNotGranted
        case claudeNotRunning
        case appleScriptFailed(String)

        public var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "meee2 doesn't have Accessibility permission. " +
                    "System Settings → Privacy & Security → Accessibility, " +
                    "add /Applications/meee2.app and turn the toggle on."
            case .claudeNotRunning:
                return "Claude.app is not running."
            case .appleScriptFailed(let detail):
                return "Keystroke failed: \(detail)"
            }
        }
    }

    public init() {}

    /// 旧 Bool API：保持向后兼容（AgentInboxShell.deliverIfResting 等老 caller
    /// 不需要 typed error）。新 caller 优先用 `sendTextThrowing` 拿到具体
    /// 错误类型。
    public func sendText(sid: String, text: String) async -> Bool {
        do {
            try await sendTextThrowing(sid: sid, text: text)
            return true
        } catch {
            return false
        }
    }

    /// throws 版本：上层（pushDesktopNow / BoardAPI）能区分 accessibilityNotGranted
    /// 还是普通 keystroke 失败，给 webui 不同 toast / 操作（自动开 System
    /// Settings 等）。
    public func sendTextThrowing(sid: String, text: String) async throws {
        // 先做 Accessibility 预检——没权限就直接 throw，不抢焦点不动 Claude.app。
        // 用户授权后再点 push 重试，体验干净。
        if !Self.isAccessibilityTrusted() {
            throw SendError.accessibilityNotGranted
        }
        let result = await Serializer.shared.runExclusive {
            await Self.runOnce(sid: sid, text: text)
        }
        if result == "ok" { return }
        if result.contains("claude_not_running") {
            throw SendError.claudeNotRunning
        }
        throw SendError.appleScriptFailed(result)
    }

    /// 通过 ApplicationServices 的 `AXIsProcessTrusted`（C API）查 meee2.app
    /// 自身是否在 macOS Accessibility allowlist 里。**不弹 prompt** ——
    /// `AXIsProcessTrustedWithOptions(prompt: true)` 会立刻抛系统弹窗，
    /// 但如果 user 之前已经主动 deny 过，prompt 不会再出现，会很迷惑；
    /// 我们更想"探测 + 上报 webui"，让 user 在自己的节奏去 System Settings。
    private static func isAccessibilityTrusted() -> Bool {
        #if canImport(ApplicationServices)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    /// Returns "ok" on success, or the runNSAppleScript error string on failure
    /// (looks like `err:[N] <msg>` or `err:claude_not_running`).
    private static func runOnce(sid: String, text: String) async -> String {
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

        let script = """
        tell application "System Events"
            if not (exists process "Claude") then
                error "claude_not_running" number -2700
            end if
        end tell

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

        -- 收尾延迟：让 Claude.app 把 keystroke 吃进去再放下一条（如果有），
        -- 否则下一条 sendText 立刻又 resume + activate 会撞 Electron view
        -- 还在异步处理上一条的状态。
        delay 0.4
        return "ok"
        """

        let result = await runNSAppleScript(script)
        NSLog("[ClaudeDesktopInputStream] sendText sid=\(sid.prefix(8)) textLen=\(text.count) result='\(result)'")
        return result
    }
}

/// 在 meee2 进程内执行 AppleScript（继承 meee2.app 的 Accessibility 权限）。
/// 返回 stringValue；脚本报错时返回 "err:<msg>" 让 caller 直接 log。
@inline(__always)
private func runNSAppleScript(_ source: String) async -> String {
    #if canImport(AppKit)
    return await MainActor.run {
        guard let script = NSAppleScript(source: source) else {
            return "err:nsapplescript_create_failed"
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown"
            let num = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            return "err:[\(num)] \(msg)"
        }
        return result.stringValue ?? ""
    }
    #else
    return "err:appkit_unavailable"
    #endif
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
