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
        NSLog("[TerminalJumper] Jump request: termApp=\(terminalApp) cwd=\(cwd)")

        // AppleScript strategies for specific terminals
        let lower = terminalApp.lowercased()

        // Try specific terminal implementations
        if lower.contains("ghostty") {
            let result = await jumpViaGhostty(cwd: cwd)
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
        if await activateRunningAppAsync(bundleId: "com.cmuxterm.app") { return .success }
        if await activateRunningAppAsync(bundleId: "com.mitchellh.ghostty") { return .success }
        if await activateRunningAppAsync(bundleId: "dev.warp.Warp-Stable") { return .success }
        if await activateRunningAppAsync(bundleId: "com.googlecode.iterm2") { return .success }
        if await activateRunningAppAsync(bundleId: "com.apple.Terminal") { return .success }

        return .notFound
    }

    // MARK: - Ghostty (AppleScript)

    private func jumpViaGhostty(cwd: String) async -> TerminalJumpResult {
        let script = """
        tell application "System Events"
            if not (exists process "Ghostty") then return "not_running"
        end tell
        tell application "Ghostty"
            try
                set matches to every terminal whose working directory contains "\(cwd)"
                if (count of matches) > 0 then
                    focus (item 1 of matches)
                    return "success"
                end if
            end try
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
                NSLog("[TerminalJumper] cmux matched: \(output.prefix(60))")
                await bringCmuxToFront()
                return .success
            }
        } catch {
            NSLog("[TerminalJumper] cmux error: \(error)")
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
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        } catch {
            NSLog("[TerminalJumper] AppleScript error: \(error)")
            return "error"
        }
    }
}