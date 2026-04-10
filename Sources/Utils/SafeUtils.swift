import Foundation

/// Safety utilities to prevent crashes
public enum SafeUtils {

    /// Safely access array element with bounds checking
    public static func safeGet<T>(_ array: [T], index: Int) -> T? {
        guard index >= 0, index < array.count else { return nil }
        return array[index]
    }

    /// Safely unwrap optional with default value and logging
    public static func unwrap<T>(_ value: T?, default defaultValue: T, file: String = #file, line: Int = #line) -> T {
        if let value = value {
            return value
        }
        NSLog("[SafeUtils] Unexpected nil at \(file):\(line)")
        return defaultValue
    }

    /// Execute closure safely, catching any errors
    public static func safeExecute(_ block: () throws -> Void, file: String = #file, line: Int = #line) {
        do {
            try block()
        } catch {
            NSLog("[SafeUtils] Error at \(file):\(line): \(error)")
        }
    }

    /// Execute closure safely with return value
    public static func safeExecute<T>(_ block: () throws -> T, default defaultValue: T, file: String = #file, line: Int = #line) -> T {
        do {
            return try block()
        } catch {
            NSLog("[SafeUtils] Error at \(file):\(line): \(error)")
            return defaultValue
        }
    }

    /// Safely dispatch to main thread
    public static func dispatchMainSafely(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async {
                block()
            }
        }
    }

    /// Log crash-related info
    public static func logCrashInfo(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        NSLog("[CrashGuard] \(message) at \(file):\(line) in \(function)")
    }
}