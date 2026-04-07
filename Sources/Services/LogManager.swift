import Foundation
import os

/// 日志管理器 - 将日志写入文件
public class LogManager {
    public static let shared = LogManager()

    /// 日志文件路径
    public let logFileURL: URL

    /// 文件句柄
    private var fileHandle: FileHandle?

    /// 日志队列
    private let logQueue = DispatchQueue(label: "com.meee2.log", qos: .utility)

    private init() {
        let logsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("meee2.log")

        // 创建或打开日志文件
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFileURL)

        // 跳到文件末尾
        _ = try? fileHandle?.seekToEnd()

        // 写入启动标记
        log("[LogManager] === Application Started ===")
    }

    /// 写入日志
    public func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        logQueue.async { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }

            if let data = logLine.data(using: .utf8) {
                handle.write(data)
            }
        }

        // 同时输出到系统日志
        NSLog("%@", message)
    }

    /// 获取日志内容
    public func getLogContent() -> String? {
        return try? String(contentsOf: logFileURL, encoding: .utf8)
    }

    /// 清理旧日志（保留最近 7 天）
    public func cleanupOldLogs() {
        // 如果日志文件超过 10MB，截断
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? Int64,
           size > 10 * 1024 * 1024 {
            try? fileHandle?.close()
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
            fileHandle = try? FileHandle(forWritingTo: logFileURL)
            log("[LogManager] Log file truncated (was \(size) bytes)")
        }
    }
}

/// 全局日志函数
public func MLog(_ message: String) {
    LogManager.shared.log(message)
}