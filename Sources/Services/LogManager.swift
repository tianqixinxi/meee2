import Foundation
import os
import SwiftUI

/// 日志级别
public enum LogLevel: Int, Comparable, Codable {
    case debug = 0    // 调试信息（开发时）
    case info = 1     // 正常操作信息
    case warning = 2  // 警告（潜在问题）
    case error = 3    // 错误（严重问题）

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public var prefix: String {
        switch self {
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        }
    }

    public var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

/// 日志管理器 - 将日志写入文件，支持分级
public class LogManager {
    public static let shared = LogManager()

    /// 日志文件路径
    public let logFileURL: URL

    /// 文件句柄
    private var fileHandle: FileHandle?

    /// 日志队列
    private let logQueue = DispatchQueue(label: "com.meee2.log", qos: .utility)

    /// 最小日志级别（低于此级别不输出）
    public var minLevel: LogLevel = .info

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
        log("[LogManager] === Application Started ===", level: .info)
    }

    /// 设置最小日志级别
    public func setMinLevel(_ level: LogLevel) {
        minLevel = level
    }

    /// 写入日志（带级别）
    public func log(_ message: String, level: LogLevel = .info) {
        guard level >= minLevel else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(level.prefix) \(message)\n"

        logQueue.async { [weak self] in
            guard let self = self, let handle = self.fileHandle else { return }

            if let data = logLine.data(using: .utf8) {
                handle.write(data)
            }
        }

        // ERROR 级别同时输出到系统日志
        if level >= .error {
            NSLog("%@", message)
        }
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
            log("[LogManager] Log file truncated (was \(size) bytes)", level: .warning)
        }
    }
}

/// 全局日志函数（带级别）
public func MLog(_ message: String, level: LogLevel = .info) {
    LogManager.shared.log(message, level: level)
}

/// 便捷函数
public func MDebug(_ message: String) { MLog(message, level: .debug) }
public func MInfo(_ message: String) { MLog(message, level: .info) }
public func MWarn(_ message: String) { MLog(message, level: .warning) }
public func MError(_ message: String) { MLog(message, level: .error) }