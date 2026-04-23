import Foundation

/// 新开一个 terminal / tab，落地在 `cwd`，可选地执行 `command`（比如 "claude\n"）。
///
/// 不同 terminal app 的实现方式差别很大——Ghostty 1.3+ 有原生 AppleScript；
/// iTerm 用它自己的 scripting；cmux 走 socket 协议；Terminal.app 用 legacy AS。
/// 所以抽成 protocol，按终端类型挑实现。
public protocol TerminalSpawner {
    func spawn(cwd: String, command: String?) async -> SpawnResult
}

public enum SpawnResult {
    case success
    case failed(reason: String)
}

// MARK: - Ghostty

/// Ghostty 1.3+ 原生 AppleScript 实现。参考:
///   https://ghostty.org/docs/features/applescript
///   https://github.com/ghostty-org/ghostty/discussions/10201
///
/// 核心 API：
///   tell application "Ghostty"
///     set cfg to new surface configuration
///     set initial working directory of cfg to "<path>"
///     set win to new window with configuration cfg
///   end tell
///
/// 窗口开出来后，shell 已经落在 cwd；再 `input text "claude\n"` 就跑起来。
/// 注意：Ghostty 的 CLI **不支持** `-e` / 新建 tab（1.3 版本仍缺），
/// 所以全靠 AppleScript；Cmd+T 方案需要 Accessibility 权限又 fragile。
public struct GhosttySpawner: TerminalSpawner {
    public init() {}

    public func spawn(cwd: String, command: String?) async -> SpawnResult {
        // 基础 sanity：cwd 必须存在
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return .failed(reason: "cwd does not exist or is not a directory: \(cwd)")
        }

        let escapedCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Step 1: open window at cwd
        let openScript = """
        tell application "Ghostty"
            activate
            try
                set cfg to new surface configuration
                set initial working directory of cfg to "\(escapedCwd)"
                set win to new window with configuration cfg
                -- 返回窗口里那个 terminal 的 id，方便后面 input
                return id of focused terminal of selected tab of win
            on error errMsg
                return "err:" & errMsg
            end try
        end tell
        """

        let idResult = await runAppleScript(openScript)
        NSLog("[GhosttySpawner] open-window result: '\(idResult)'")

        if idResult.hasPrefix("err:") {
            return .failed(reason: String(idResult.dropFirst(4)))
        }
        let terminalId = idResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terminalId.isEmpty else {
            return .failed(reason: "Ghostty did not return a terminal id")
        }

        // Step 2: 如果要跑命令，等 shell prompt 出现（~400ms 稳妥）再 input
        if let cmd = command, !cmd.isEmpty {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let payload = cmd.hasSuffix("\n") ? cmd : (cmd + "\n")
            let escapedCmd = payload
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escapedTid = terminalId.replacingOccurrences(of: "\"", with: "\\\"")
            let inputScript = """
            tell application "Ghostty"
                try
                    set t to terminal id "\(escapedTid)"
                    input text "\(escapedCmd)" to t
                    return "ok"
                on error errMsg
                    return "err:" & errMsg
                end try
            end tell
            """
            let inputResult = await runAppleScript(inputScript)
            NSLog("[GhosttySpawner] input-text result: '\(inputResult)' (cmd=\(cmd))")
            if inputResult.hasPrefix("err:") {
                return .failed(reason: "window opened but command failed: \(inputResult.dropFirst(4))")
            }
        }

        return .success
    }

    // 独立出来的 AS runner（不依赖 TerminalJumper 的 actor 实例）
    private func runAppleScript(_ script: String) async -> String {
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
}

// MARK: - Input Injection（直接往活着的 terminal 推文字）

/// 往一个已存在的 terminal（通过 terminalId 定位）直接推一段文字。主要
/// 场景：Claude session 已经 resting、不再会触发 Stop hook，inbox 里的消息
/// 没办法自动 drain —— 我们跳过 inbox 直接模拟键盘输入。
public protocol TerminalInputStream {
    func sendText(terminalId: String, text: String) async -> Bool
}

public struct GhosttyInputStream: TerminalInputStream {
    public init() {}

    public func sendText(terminalId: String, text: String) async -> Bool {
        // Ghostty `input text` 走的是 bracketed paste（见 sdef: "as if it was pasted"）。
        // Claude CLI 的 Ink TUI 在 paste 模式里把 CR/LF 都当多行，不会提交 prompt。
        // 所以正确做法是：先 `input text` 把正文粘进去，再用 `send key "enter"`
        // 发一次真正的回车事件去触发提交。
        var body = text
        while body.hasSuffix("\n") || body.hasSuffix("\r") {
            body.removeLast()
        }
        let escapedText = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTid = terminalId.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Ghostty"
            try
                set t to terminal id "\(escapedTid)"
                input text "\(escapedText)" to t
                delay 0.2
                send key "enter" to t
                return "ok"
            on error errMsg
                return "err:" & errMsg
            end try
        end tell
        """

        let result = await runAppleScript(script)
        NSLog("[GhosttyInputStream] sendText tid=\(terminalId.prefix(8)) textLen=\(text.count) result='\(result)'")
        return result == "ok"
    }

    private func runAppleScript(_ script: String) async -> String {
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
}

// MARK: - Router

/// 按 termProgram 挑 spawner。现在只有 Ghostty；后续接 iTerm / Terminal 往这加 case。
public enum SpawnerRouter {
    public static func forTerminal(_ termProgram: String?) -> TerminalSpawner {
        switch termProgram?.lowercased() {
        case "ghostty", nil, "":
            return GhosttySpawner()
        // case "iterm", "iterm2":
        //     return ITermSpawner()
        // case "terminal":
        //     return TerminalAppSpawner()
        default:
            // 未识别的 term 默认走 Ghostty（用户大概率在 Ghostty）
            return GhosttySpawner()
        }
    }
}
