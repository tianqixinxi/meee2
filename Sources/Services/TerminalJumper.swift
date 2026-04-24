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

        // Strategy 1 (preferred, ground truth): 写一个唯一 marker 到 session 的
        // TTY，再用 Ghostty 原生 AppleScript 遍历 `every terminal`，按 `name`
        // 找包含 marker 的 terminal → 这个 id 是**和 session.pid 真实绑定**的，
        // 不会被 stale / 抓错的 bridge 数据污染。~200ms 代价换正确性。
        if let pid = pid {
            let foundId = await findGhosttyTerminalIdByMarker(forPid: pid)
            if let gtid = foundId {
                NSLog("[TerminalJumper] Ghostty Strategy 1 (marker) match: terminal id=\(gtid.prefix(8))")

                // 发现"真 id"与 SessionStore 里存的不一致（或 store 里为空）→ 回写
                // 自愈。下次点 Open terminal，Strategy 0 就能直接走，也是对的。
                if let sid = nonEmpty(session.id) {
                    let store = SessionStore.shared
                    let storeId = store.get(sid)?.ghosttyTerminalId ?? ""
                    if storeId != gtid {
                        store.update(sid) { $0.ghosttyTerminalId = gtid }
                        NSLog("[TerminalJumper] self-heal: sessionStore.ghosttyTerminalId \(storeId.prefix(8).isEmpty ? "(empty)" : String(storeId.prefix(8))) → \(gtid.prefix(8))")
                    }
                }

                let escaped = gtid.replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                tell application "Ghostty"
                    activate
                    try
                        focus (terminal id "\(escaped)")
                        return "success"
                    on error errMsg
                        return "err:" & errMsg
                    end try
                end tell
                """
                let result = await runAppleScript(script)
                NSLog("[TerminalJumper] Ghostty Strategy 1 focus result: '\(result)'")
                if result == "success" { return .success }
            } else {
                NSLog("[TerminalJumper] Ghostty Strategy 1 failed: marker not visible on any terminal")
            }
        }

        // Strategy 0 (fallback, best-effort): 使用 sessionStore 里缓存的 id。
        // 可能是 stale（bridge 在 UserPromptSubmit 抓到了错的前台 tab id），
        // 所以只在 Strategy 1 失败时用。即使跳错也好过"Ghostty 没反应"。
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
            NSLog("[TerminalJumper] Ghostty Strategy 0 (cached id, fallback) result: '\(result)'")
            if result == "success" {
                return .success
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

    private func nonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }

    /// 通过往 TTY 写一个唯一 marker（ESC]2;…BEL 设窗口 title），然后用 Ghostty
    /// 原生 AppleScript 遍历 `every terminal`，找 `name` 含 marker 的 terminal，
    /// 返回它的 id。比走 System Events AX (tab group) 更可靠 —— 这个 Ghostty
    /// 版本的窗口层级里根本没有 AXTabGroup。
    private func findGhosttyTerminalIdByMarker(forPid pid: Int) async -> String? {
        // Get session's TTY
        let sessionTTY = await runShellCommand("ps -o tty= -p \(pid) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionTTY.isEmpty, sessionTTY != "??" else {
            NSLog("[TerminalJumper] Could not get TTY for PID \(pid)")
            return nil
        }
        NSLog("[TerminalJumper] PID \(pid) → TTY \(sessionTTY), marker retry loop")

        let marker = "__MEEE2_JUMP_\(pid)__"

        // 找脚本：遍历 Ghostty 原生的 terminal 列表，name 含 marker 就返回它的 id
        let findScript = """
        tell application "Ghostty"
            try
                set cands to every terminal
                repeat with t in cands
                    try
                        if name of t contains "\(marker)" then
                            return id of t
                        end if
                    end try
                end repeat
            end try
        end tell
        return ""
        """

        // 调试脚本：dump 所有 terminal 的 id + name（snippet）
        let dumpScript = """
        tell application "Ghostty"
            try
                set out to ""
                set i to 0
                repeat with t in every terminal
                    set i to i + 1
                    try
                        set tid to id of t
                        set tnm to name of t
                        set out to out & "[" & i & "] " & tid & " | " & tnm & linefeed
                    end try
                end repeat
                if out is "" then return "NO_TERMINALS"
                return out
            on error errMsg
                return "ERR:" & errMsg
            end try
        end tell
        """

        let initialDump = await runAppleScript(dumpScript)
        NSLog("[TerminalJumper] ghostty terms BEFORE marker:\n\(initialDump)")

        for attempt in 0..<10 {
            _ = await runShellCommand("printf '\\033]2;\(marker)\\007' > /dev/\(sessionTTY)")
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms to paint

            let result = await runAppleScript(findScript)
            if !result.isEmpty {
                NSLog("[TerminalJumper] marker HIT: terminal id=\(result.prefix(8)) attempt=\(attempt + 1)")
                _ = await runShellCommand("printf '\\033]2;\\007' > /dev/\(sessionTTY)")
                return result
            }

            if attempt == 3 || attempt == 7 {
                let mid = await runAppleScript(dumpScript)
                NSLog("[TerminalJumper] ghostty terms MID attempt=\(attempt):\n\(mid)")
            }
        }

        _ = await runShellCommand("printf '\\033]2;\\007' > /dev/\(sessionTTY)")
        let finalDump = await runAppleScript(dumpScript)
        NSLog("[TerminalJumper] marker NEVER caught after 10 retries for pid=\(pid). Final:\n\(finalDump)")
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
