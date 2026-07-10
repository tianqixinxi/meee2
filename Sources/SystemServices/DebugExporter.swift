import Foundation
import AppKit
import Meee2CommKit

/// 调试数据导出器
class DebugExporter {
    private static let maxExportedLogBytes = 2 * 1024 * 1024
    struct ExportResult: Encodable {
        let ok: Bool
        let path: String
    }

    static func exportToDefaultLocation() throws -> ExportResult {
        let dir = StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("debug-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meee2-Debug-\(timestampString()).zip")
        try exportToZip(url)
        NSLog("[DebugExporter] Exported to: \(url.path)")
        return ExportResult(ok: true, path: url.path)
    }

    /// 导出调试数据到 zip 文件
    static func export() {
        let panel = NSSavePanel()
        panel.title = "Export Debug Data"
        panel.nameFieldStringValue = "meee2-Debug-\(timestampString()).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try exportToZip(url)
                NSLog("[DebugExporter] Exported to: \(url.path)")

                // 显示成功提示
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Complete"
                    alert.informativeText = "Debug data saved to:\n\(url.path)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                NSLog("[DebugExporter] Export failed: \(error)")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private static func exportToZip(_ destination: URL) throws {
        // 创建临时目录
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("meee2-Debug")

        // 清理旧的临时目录
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 1. 导出 Plugin 状态
        let pluginStatus = collectPluginStatus()
        let pluginStatusUrl = tempDir.appendingPathComponent("plugin_status.json")
        try pluginStatus.write(to: pluginStatusUrl, atomically: true, encoding: .utf8)

        // 2. Export a bounded session summary. Raw transcripts can contain
        // prompts, source code and credentials, so they never enter a routine
        // diagnostic bundle.
        let sessionSummaryURL = tempDir.appendingPathComponent("session_summary.json")
        try collectSessionSummary().write(to: sessionSummaryURL, atomically: true, encoding: .utf8)

        // 4. 导出系统信息
        let systemInfo = collectSystemInfo()
        let systemInfoUrl = tempDir.appendingPathComponent("system_info.json")
        try systemInfo.write(to: systemInfoUrl, atomically: true, encoding: .utf8)

        // 4. Export only the bounded, redacted log tail.
        if let logTail = boundedLogTail(path: StorageRoots.processDefault.logFileURL.path) {
            try? logTail.write(
                to: tempDir.appendingPathComponent("meee2.log"),
                atomically: true,
                encoding: .utf8
            )
        }

        // 5. 创建 zip
        try zipDirectory(tempDir, to: destination)

        // 清理临时目录
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func collectPluginStatus() -> String {
        var status: [String: Any] = [:]

        let pluginManager = PluginManager.shared

        // Loaded plugins
        var plugins: [[String: Any]] = []
        for (id, plugin) in pluginManager.loadedPlugins {
            plugins.append([
                "id": id,
                "displayName": plugin.displayName,
                "version": plugin.version,
                "enabled": plugin.config.enabled,
                "hasError": plugin.hasError,
                "lastError": plugin.lastError ?? ""
            ])
        }
        status["loadedPlugins"] = plugins

        // Session count
        status["sessionCount"] = pluginManager.sessions.count

        // Error state
        status["hasError"] = pluginManager.hasError
        status["errors"] = pluginManager.pluginErrors

        if let data = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    private static func collectSessionSummary() -> String {
        let sessions = SessionStore.shared.listAll().map { session -> [String: Any] in
            [
                "id": String(session.sessionId.prefix(8)),
                "project": redactForExport(session.project),
                "cwd": redactForExport(session.cwd ?? ""),
                "status": session.status.rawValue,
                "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
                "lastActivity": ISO8601DateFormatter().string(from: session.lastActivity),
                "hasTranscript": !(session.transcriptPath ?? "").isEmpty,
                "hasPendingPermission": !(session.pendingPermissionTool ?? "").isEmpty
            ]
        }
        let envelope: [String: Any] = ["count": sessions.count, "sessions": sessions]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    private static func boundedLogTail(path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxExportedLogBytes) ? size - UInt64(maxExportedLogBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return redactForExport(value)
    }

    static func redactForExport(_ value: String) -> String {
        var result = value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let replacements = [
            (#"(?i)(authorization:\s*bearer\s+)[^\s\"']+"#, "$1[REDACTED]"),
            (#"(?i)(\"?(?:api[_-]?key|access[_-]?token|refresh[_-]?token)\"?\s*[:=]\s*\"?)[^\"\s,}]+"#, "$1[REDACTED]"),
            (#"\bsk-(?:ant-)?[A-Za-z0-9_-]{12,}\b"#, "[REDACTED]")
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static func collectSystemInfo() -> String {
        var info: [String: Any] = [:]

        info["appVersion"] = BuildInfo.version
        info["macOSVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        info["timestamp"] = ISO8601DateFormatter().string(from: Date())
        info["locale"] = Locale.current.identifier
        info["timezone"] = TimeZone.current.identifier

        // Screens
        var screens: [[String: Any]] = []
        for screen in NSScreen.screens {
            screens.append([
                "name": screen.displayName,
                "frame": [
                    "x": screen.frame.origin.x,
                    "y": screen.frame.origin.y,
                    "width": screen.frame.size.width,
                    "height": screen.frame.size.height
                ],
                "hasNotch": screen.notchSize != .zero
            ])
        }
        info["screens"] = screens

        if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    private static func zipDirectory(_ source: URL, to destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-r", "-q", destination.path, source.lastPathComponent]
        task.currentDirectoryURL = source.deletingLastPathComponent()

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            throw DebugExportError.zipFailed
        }
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum DebugExportError: LocalizedError {
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .zipFailed:
            return "Failed to create zip archive"
        }
    }
}
