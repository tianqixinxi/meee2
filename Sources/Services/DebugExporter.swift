import Foundation
import AppKit

/// 调试数据导出器
class DebugExporter {
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

        // 2. 复制 Session 文件
        let sessionsDir = NSHomeDirectory().appending("/.claude/sessions")
        let sessionsDest = tempDir.appendingPathComponent("sessions")
        if FileManager.default.fileExists(atPath: sessionsDir) {
            try? FileManager.default.copyItem(atPath: sessionsDir, toPath: sessionsDest.path)
        }

        // 3. 复制 Plugin 配置
        let pluginsDir = NSHomeDirectory().appending("/.meee2/plugins")
        let pluginsDest = tempDir.appendingPathComponent("plugins")
        if FileManager.default.fileExists(atPath: pluginsDir) {
            try? FileManager.default.copyItem(atPath: pluginsDir, toPath: pluginsDest.path)
        }

        // 4. 导出系统信息
        let systemInfo = collectSystemInfo()
        let systemInfoUrl = tempDir.appendingPathComponent("system_info.json")
        try systemInfo.write(to: systemInfoUrl, atomically: true, encoding: .utf8)

        // 5. 复制日志文件
        let logFile = NSHomeDirectory().appending("/Library/Logs/meee2.log")
        if FileManager.default.fileExists(atPath: logFile) {
            try? FileManager.default.copyItem(atPath: logFile, toPath: tempDir.appendingPathComponent("meee2.log").path)
        }

        // 6. 创建 zip
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

    private static func collectSystemInfo() -> String {
        var info: [String: Any] = [:]

        info["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown"
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
