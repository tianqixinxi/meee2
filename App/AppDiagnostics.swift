import AppKit
import Foundation
import meee2Kit

/// Per-app diagnostics — boot header for `~/Library/Logs/meee2.log` + the
/// "Copy Diagnostic Info" clipboard payload. Goal: when a user opens the
/// status-bar menu and clicks "Copy Diagnostic Info", they paste a
/// 10-line block that tells us "what version, where installed, is
/// BoardServer up, who else holds 9876". Combined with the log file it's
/// enough to triage 90% of "open board doesn't work" reports without
/// asking the user to run terminal commands.
enum AppDiagnostics {
    /// Multiline header dropped into the log on every launch. First thing
    /// support engineers should see when scrolling to the bottom of the
    /// log file.
    static func logBootBanner() {
        let info = bootInfo()
        MInfo("=== Meee2 boot ===")
        for line in info {
            MInfo(line)
        }
        MInfo("===================")
    }

    /// Compact diagnostic block for the clipboard. Sync — spawns `lsof`
    /// (≈30ms). Run on the main thread in response to the menu click;
    /// users expect the paste to be ready when the next app comes
    /// frontmost.
    static func clipboardDiagnostic() -> String {
        var lines: [String] = []
        lines.append(contentsOf: bootInfo())
        lines.append("")
        lines.append("BoardServer: \(boardServerStateLine())")
        if let runtimeLine = boardRuntimeFileLine() {
            lines.append(runtimeLine)
        }
        lines.append("")
        lines.append("Port \(BoardServer.defaultPort) listeners:")
        let lsofOutput = lsofPort(BoardServer.defaultPort)
        lines.append(lsofOutput.isEmpty ? "  (no process listening)" : lsofOutput)
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    /// The shared "what is this app, where, on what" header — same lines
    /// for both the log banner and the clipboard payload, so screenshots
    /// of one match the other.
    private static func bootInfo() -> [String] {
        let bundle = Bundle.main
        let version = BuildInfo.version
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let bundlePath = bundle.bundlePath
        let translocated = bundlePath.contains("/AppTranslocation/")
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let pid = ProcessInfo.processInfo.processIdentifier
        let user = NSUserName()
        let logPath = LogManager.shared.logFileURL.path

        var lines: [String] = []
        lines.append("Meee2 \(version) (build \(build))")
        lines.append("Bundle: \(bundlePath)\(translocated ? "  ⚠ translocated" : "")")
        lines.append("macOS: \(osVersion)")
        lines.append("PID: \(pid)  User: \(user)")
        lines.append("Log: \(logPath)")
        return lines
    }

    private static func boardServerStateLine() -> String {
        if BoardServer.shared.isRunning {
            return "running on \(BoardServer.shared.url)"
        } else {
            return "NOT running (preferred port \(BoardServer.defaultPort))"
        }
    }

    private static func boardRuntimeFileLine() -> String? {
        guard let url = try? BoardServer.runtimeInfoFileURL() else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Runtime info file: missing (\(url.path))"
        }
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "Runtime info file: present but unreadable (\(url.path))"
        }
        let port = obj["port"] as? Int ?? -1
        let pid = obj["pid"] as? Int ?? -1
        let updatedAt = obj["updatedAt"] as? String ?? "?"
        return "Runtime info file: port=\(port) pid=\(pid) updatedAt=\(updatedAt)"
    }

    /// `lsof -nP -i :<port>` — short list of who's listening. Indented two
    /// spaces so the clipboard block stays readable when pasted into chat.
    private static func lsofPort(_ port: UInt16) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "  (lsof failed: \(error.localizedDescription))"
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // Cap to first 5 lines (header + 4 listeners is plenty)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).prefix(5)
        return lines.map { "  \($0)" }.joined(separator: "\n")
    }
}
