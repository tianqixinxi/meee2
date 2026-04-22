import AppKit
import Foundation

/// Terminal jump result
public enum TerminalJumpResult {
    case success
    case notFound
    case error(String)
}

/// Unified terminal jumping service.
/// Detects which terminal app hosts a session and activates the correct window/tab.
public actor TerminalJumper {
    public static let shared = TerminalJumper()

    private init() {}

    /// Jump to the terminal hosting the given session.
    /// Tries strategies in order: AppleScript → generic activate.
    public func jump(to session: AISession) async -> TerminalJumpResult {
        let cwd = session.cwd
        let terminalApp = session.termProgram ?? ""
        NSLog("[TerminalJumper] jump: termApp=\(terminalApp) cwd=\(cwd) pid=\(session.pid) tty=\(session.tty ?? "nil")")

        // AppleScript strategies for specific terminals
        let lower = terminalApp.lowercased()

        // Try specific terminal implementations
        if lower.contains("ghostty") {
            let result = await jumpViaGhostty(session: session)
            NSLog("[JUMP FLOW] Ghostty jump result: \(result)")
            if case .success = result { return result }
        }

        if lower.contains("cmux") {
            let result = await jumpViaCmux(cwd: cwd)
            if case .success = result { return result }
        }

        if lower.contains("iterm") {
            let result = await jumpViaiTerm2(cwd: cwd, pid: session.pid)
            if case .success = result { return result }
        }

        if lower.contains("warp") {
            let result = await activateByBundleId("dev.warp.Warp-Stable")
            if case .success = result { return result }
        }

        // Try common terminals as fallback
        NSLog("[JUMP FLOW] falling back to 'just activate app' — precise tab switch failed")
        if await activateRunningAppAsync(bundleId: "com.cmuxterm.app") { return .success }
        if await activateRunningAppAsync(bundleId: "com.mitchellh.ghostty") { return .success }
        if await activateRunningAppAsync(bundleId: "dev.warp.Warp-Stable") { return .success }
        if await activateRunningAppAsync(bundleId: "com.googlecode.iterm2") { return .success }
        if await activateRunningAppAsync(bundleId: "com.apple.Terminal") { return .success }

        NSLog("[JUMP FLOW] ===== complete: no terminal could be activated =====")
        return .notFound
    }

    // MARK: - Ghostty (TTY + Accessibility API)

    private func jumpViaGhostty(session: AISession) async -> TerminalJumpResult {
        let cwd = session.cwd
        let pid: Int? = session.pid > 0 ? session.pid : nil
        NSLog("[TerminalJumper] jumpViaGhostty: cwd=\(cwd) pid=\(pid ?? 0) ghosttyId=\(session.ghosttyTerminalId ?? "nil")")

        // Strategy 0 (preferred): Ghostty native AppleScript —— 如果我们在 SessionStart
        // hook 里抓到过 terminal id，直接 `focus terminal id "X"`，精确、无 title race。
        if let gtid = session.ghosttyTerminalId, !gtid.isEmpty {
            let escaped = gtid.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Ghostty"
                activate
                try
                    set t to terminal id "\(escaped)"
                    focus t
                    return "success"
                on error errMsg
                    return "err:" & errMsg
                end try
            end tell
            """
            let result = await runAppleScript(script)
            NSLog("[TerminalJumper] Ghostty Strategy 0 (terminal id) result: '\(result)'")
            if result == "success" {
                return .success
            }
            // 失败（terminal id 失效，如 tab 被关过）→ 继续下面的 fallback
        }

        // Strategy 1: TTY-based tab matching via process tree
        if let pid = pid {
            let tabIndex = await findGhosttyTabIndex(forPid: pid)
            if let tabIndex = tabIndex {
                NSLog("[TerminalJumper] Ghostty Strategy 1 (marker) match: tab index \(tabIndex)")
                let script = """
                tell application "System Events"
                    if not (exists process "Ghostty") then return "not_running"
                    tell process "Ghostty"
                        set frontmost to true
                        repeat with w in windows
                            try
                                set tabGroup to first tab group of w
                                set tabCount to count of radio buttons of tabGroup
                                if \(tabIndex) is less than or equal to tabCount then
                                    click radio button \(tabIndex) of tabGroup
                                    return "success"
                                end if
                            end try
                        end repeat
                    end tell
                end tell
                tell application "Ghostty" to activate
                return "activated"
                """
                let result = await runAppleScript(script)
                NSLog("[TerminalJumper] Ghostty Strategy 1 click result: '\(result)'")
                if result == "success" { return .success }
            } else {
                NSLog("[TerminalJumper] Ghostty Strategy 1 failed: marker not visible on any tab")
            }
        }

        // Strategy 2 已删除：按目录名 substring 匹配会跳到同项目下的错误 tab
        // （多个 tab 的 cwd 都含 "meee2" 字样时无法区分）。marker 失败时只激活
        // Ghostty 应用、不切 tab——好过跳错。
        NSLog("[TerminalJumper] Ghostty: marker retry exhausted, activating app without tab switch")
        let activateScript = """
        tell application "Ghostty" to activate
        return "activated"
        """
        let result = await runAppleScript(activateScript)
        if result == "activated" {
            return .success
        }
        return .notFound
    }

    /// Find which Ghostty tab index corresponds to a given PID by writing a unique
    /// title marker to the session's TTY, then matching it against tab titles via AX API.
    /// This is reliable regardless of tab reordering.
    /// Returns 1-based tab index, or nil if not found.
    private func findGhosttyTabIndex(forPid pid: Int) async -> Int? {
        // Get session's TTY
        let sessionTTY = await runShellCommand("ps -o tty= -p \(pid) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionTTY.isEmpty, sessionTTY != "??" else {
            NSLog("[TerminalJumper] Could not get TTY for PID \(pid)")
            return nil
        }
        NSLog("[TerminalJumper] PID \(pid) → TTY \(sessionTTY), marker retry loop")

        let marker = "__MEEE2_JUMP_\(pid)__"

        // 查找脚本：返回含 marker 的 tab 索引，没找到返回 "0"
        let findScript = """
        tell application "System Events"
            tell process "Ghostty"
                repeat with w in windows
                    try
                        set tabGroup to first tab group of w
                        set tabList to radio buttons of tabGroup
                        repeat with i from 1 to count of tabList
                            set tabTitle to value of attribute "AXTitle" of item i of tabList
                            if tabTitle contains "\(marker)" then
                                return i as text
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        end tell
        return "0"
        """

        // 调试脚本：dump 所有 Ghostty tab 的 AXTitle（第一次和 retry 中段各打一次）
        let dumpScript = """
        tell application "System Events"
            if not (exists process "Ghostty") then return "NO_GHOSTTY_PROCESS"
            tell process "Ghostty"
                set out to ""
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    try
                        set tabGroup to first tab group of w
                        set tabList to radio buttons of tabGroup
                        set tCount to count of tabList
                        set out to out & "win" & wIdx & "(tabs=" & tCount & "):"
                        repeat with i from 1 to tCount
                            try
                                set tTitle to value of attribute "AXTitle" of item i of tabList
                                set out to out & " [" & i & "]" & tTitle
                            on error
                                set out to out & " [" & i & "]<NO_TITLE>"
                            end try
                        end repeat
                    on error errMsg
                        set out to out & "win" & wIdx & ":ERR(" & errMsg & ")"
                    end try
                    set out to out & " | "
                end repeat
                if out is "" then return "NO_WINDOWS"
                return out
            end tell
        end tell
        """

        // Attempt 1 前先 dump 一次看 Ghostty 初始有哪些 tab
        let initialDump = await runAppleScript(dumpScript)
        NSLog("[TerminalJumper] ghostty tabs BEFORE marker: \(initialDump)")

        // 与 Claude CLI 的 title 刷新赛跑：重试 10 次、每轮 80ms
        for attempt in 0..<10 {
            await runShellCommand("printf '\\033]2;\(marker)\\007' > /dev/\(sessionTTY)")
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms to paint

            let result = await runAppleScript(findScript)
            if let index = Int(result), index > 0 {
                NSLog("[TerminalJumper] marker HIT at tab \(index) on attempt \(attempt + 1)")
                await runShellCommand("printf '\\033]2;\\007' > /dev/\(sessionTTY)")
                return index
            }

            // attempt 3 和 7 再 dump 一次，看 title 现在被刷成什么
            if attempt == 3 || attempt == 7 {
                let mid = await runAppleScript(dumpScript)
                NSLog("[TerminalJumper] ghostty tabs MID attempt=\(attempt): \(mid)")
            }
        }

        await runShellCommand("printf '\\033]2;\\007' > /dev/\(sessionTTY)")
        let finalDump = await runAppleScript(dumpScript)
        NSLog("[TerminalJumper] marker NEVER caught after 10 retries for pid=\(pid). Final tabs: \(finalDump)")
        return nil
    }

    private func runShellCommand(_ command: String) async -> String {
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            MLog("[TerminalJumper] Shell command error: \(error)")
            return ""
        }
    }

    // MARK: - cmux (CLI)

    private func jumpViaCmux(cwd: String) async -> TerminalJumpResult {
        let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        guard FileManager.default.isExecutableFile(atPath: cmuxPath) else {
            return .notFound
        }

        let dirName = URL(fileURLWithPath: cwd).lastPathComponent

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmuxPath)
        process.arguments = ["find-window", "--content", "--select", dirName]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0,
               let output = String(data: data, encoding: .utf8),
               output.contains("workspace:") {
                MLog("[TerminalJumper] cmux matched: \(output.prefix(60))")
                await bringCmuxToFront()
                return .success
            }
        } catch {
            MLog("[TerminalJumper] cmux error: \(error)")
        }

        // Still activate cmux even if no match
        await bringCmuxToFront()
        return .success
    }

    // MARK: - iTerm2 (AppleScript)

    private func jumpViaiTerm2(cwd: String, pid: Int?) async -> TerminalJumpResult {
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent

        // Strategy 1: Match by tty (most reliable)
        if let pid = pid {
            let ttyScript = """
            tell application "System Events"
                if not (exists process "iTerm2") then return "not_running"
            end tell
            set targetTTY to do shell script "ps -o tty= -p \(pid) 2>/dev/null || echo none"
            if targetTTY is "none" then return "no_tty"
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if tty of s contains targetTTY then
                                    select t
                                    select s
                                    set index of w to 1
                                    activate
                                    return "success"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            return "not_found"
            """
            let result = await runAppleScript(ttyScript)
            if result == "success" { return .success }
        }

        // Strategy 2: Match by session name containing directory name
        let nameScript = """
        tell application "System Events"
            if not (exists process "iTerm2") then return "not_running"
        end tell
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set sName to name of s
                            set sPath to path of s
                            if sName contains "\(dirName)" or sPath contains "\(dirName)" then
                                select t
                                select s
                                set index of w to 1
                                activate
                                return "success"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            activate
            return "activated"
        end tell
        """
        let result = await runAppleScript(nameScript)
        if result == "success" || result == "activated" {
            return .success
        }
        return .notFound
    }

    // MARK: - Terminal.app (AppleScript)

    private func jumpViaTerminalApp(cwd: String, pid: Int?) async -> TerminalJumpResult {
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent
        let script = """
        tell application "System Events"
            if not (exists process "Terminal") then return "not_running"
        end tell
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if custom title of t contains "\(dirName)" or history of t contains "\(dirName)" then
                            set selected tab of w to t
                            set frontmost of w to true
                            activate
                            return "success"
                        end if
                    end try
                end repeat
            end repeat
            activate
            return "activated"
        end tell
        """
        let result = await runAppleScript(script)
        if result == "success" || result == "activated" {
            return .success
        }
        return .notFound
    }

    // MARK: - Generic Bundle ID Activation

    private func activateByBundleId(_ bundleId: String) async -> TerminalJumpResult {
        if await activateRunningAppAsync(bundleId: bundleId) {
            return .success
        }
        return .notFound
    }

    private func activateRunningAppAsync(bundleId: String) async -> Bool {
        await MainActor.run {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                return app.activate()
            }
            return false
        }
    }

    // MARK: - cmux Activation

    private func bringCmuxToFront() async {
        _ = await runAppleScript("tell application \"cmux\" to activate")
    }

    // MARK: - AppleScript Runner

    private func runAppleScript(_ source: String) async -> String {
        // 使用 NSAppleScript 在进程内执行，继承 meee2.app 的辅助功能权限
        // （通过 Process 调用 osascript 会因为 osascript 没有辅助功能权限而失败）
        return await MainActor.run {
            guard let script = NSAppleScript(source: source) else {
                MLog("[TerminalJumper] Failed to create NSAppleScript")
                return "error"
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo = errorInfo {
                let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown"
                MLog("[TerminalJumper] AppleScript error: \(msg)")
                return "error"
            }
            return result.stringValue ?? ""
        }
    }
}