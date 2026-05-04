import Foundation

/// Comm-kit 日志级别。映射到主仓的 `MLog/MDebug/MInfo/MWarn/MError`。
public enum CommLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

/// 默认 handler:写 stderr。主仓在 AppDelegate 启动时把它替换成
/// `MLog` 家族的转发,让 comm-kit 内部日志走统一日志管道。
///
/// 不加锁:与 `MLog` 家族的语义保持一致(后者也是无锁全局函数),写入端
/// 由调用方的串行队列保护;handler 替换在启动早期一次性完成。
public nonisolated(unsafe) var commLogHandler: (CommLogLevel, String) -> Void = { level, msg in
    let line = "[\(level.rawValue)] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

@inlinable
public func commLog(_ level: CommLogLevel, _ message: String) {
    commLogHandler(level, message)
}
