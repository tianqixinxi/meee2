import Foundation
import os
import SwiftUI
import Meee2CommKit

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
    public static let defaultMaxBytes: UInt64 = 10 * 1024 * 1024
    public static let defaultMaxRotatedFiles = 5

    /// 日志文件路径
    public let logFileURL: URL

    /// 文件句柄
    private var fileHandle: FileHandle?

    /// 日志队列
    private let logQueue = DispatchQueue(label: "com.meee2.log", qos: .utility)

    private let fileManager: FileManager
    private let maxBytes: UInt64
    private let maxRotatedFiles: Int

    /// 最小日志级别（低于此级别不输出）
    public var minLevel: LogLevel = .info

    public convenience init() {
        self.init(logFileURL: StorageRoots.processDefault.logFileURL)
    }

    /// Injectable file and thresholds keep rotation deterministic in tests.
    public init(
        logFileURL: URL,
        maxBytes: UInt64 = LogManager.defaultMaxBytes,
        maxRotatedFiles: Int = LogManager.defaultMaxRotatedFiles,
        fileManager: FileManager = .default
    ) {
        self.logFileURL = logFileURL.standardizedFileURL
        self.maxBytes = max(1, maxBytes)
        self.maxRotatedFiles = max(1, maxRotatedFiles)
        self.fileManager = fileManager
        let logsDir = self.logFileURL.deletingLastPathComponent()

        // 确保目录存在
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // 创建或打开日志文件
        if !fileManager.fileExists(atPath: self.logFileURL.path) {
            fileManager.createFile(atPath: self.logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: self.logFileURL)

        // 跳到文件末尾
        _ = try? fileHandle?.seekToEnd()

        // Hook rotation into startup before the first marker is queued. The
        // same check also runs before every write for long-lived processes.
        rotateIfNeededLocked(incomingBytes: 0)

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
            guard let self = self, let data = logLine.data(using: .utf8) else { return }
            self.rotateIfNeededLocked(incomingBytes: UInt64(data.count))
            guard let handle = self.fileHandle else { return }
            handle.write(data)
        }

        // ERROR 级别同时输出到系统日志
        if level >= .error {
            NSLog("%@", message)
        }
    }

    /// 获取日志内容
    public func getLogContent() -> String? {
        logQueue.sync {
            try? fileHandle?.synchronize()
            return try? String(contentsOf: logFileURL, encoding: .utf8)
        }
    }

    /// Force a size check. Rotation also runs automatically on startup and
    /// before each append, so callers no longer need to remember this hook.
    public func cleanupOldLogs() {
        logQueue.sync {
            rotateIfNeededLocked(incomingBytes: 0)
        }
    }

    /// Wait until queued writes reach disk. Primarily useful for diagnostics
    /// and focused tests.
    public func flush() {
        logQueue.sync {
            try? fileHandle?.synchronize()
        }
    }

    /// Synchronously remove the current log and every numbered archive, then
    /// reopen an empty base file so the running process can continue logging.
    @discardableResult
    public func resetForFactoryReset() -> Int64 {
        logQueue.sync {
            try? fileHandle?.close()
            fileHandle = nil

            var removedBytes: Int64 = 0
            let baseBytes = fileSize(at: logFileURL)
            do {
                try fileManager.removeItem(at: logFileURL)
                removedBytes += baseBytes
            } catch {
                // Recreating below is best-effort; a failed delete contributes
                // no reclaimed bytes to the factory-reset result.
            }
            let directory = logFileURL.deletingLastPathComponent()
            let archivePrefix = logFileURL.lastPathComponent + "."
            if let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    guard name.hasPrefix(archivePrefix),
                          Int(name.dropFirst(archivePrefix.count)) != nil else {
                        continue
                    }
                    let archiveBytes = fileSize(at: entry)
                    do {
                        try fileManager.removeItem(at: entry)
                        removedBytes += archiveBytes
                    } catch {
                        continue
                    }
                }
            }

            fileManager.createFile(atPath: logFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: logFileURL)
            _ = try? fileHandle?.seekToEnd()
            return removedBytes
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func rotateIfNeededLocked(incomingBytes: UInt64) {
        let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path)
        let currentBytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        // A single oversized record should still be written once; rotating an
        // empty file repeatedly would otherwise discard the previous archive.
        guard currentBytes > 0, currentBytes + incomingBytes > maxBytes else { return }

        try? fileHandle?.close()
        fileHandle = nil

        if maxRotatedFiles > 1 {
            for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
                let source = rotatedURL(index)
                let destination = rotatedURL(index + 1)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        let firstArchive = rotatedURL(1)
        try? fileManager.removeItem(at: firstArchive)
        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: firstArchive)
        }
        fileManager.createFile(atPath: logFileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    private func rotatedURL(_ index: Int) -> URL {
        URL(fileURLWithPath: "\(logFileURL.path).\(index)")
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
