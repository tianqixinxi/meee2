import Foundation
import SwiftUI

/// 状态映射配置
public struct StatusMappingConfig: Codable {
    /// 各 plugin 的映射规则
    public var plugins: [String: [String: String]] = [:]

    /// 默认映射规则
    public var defaultMapping: [String: String] = [
        "active": "running",
        "inactive": "idle",
        "running": "running",
        "idle": "idle",
        "waiting": "waitingInput",
        "completed": "completed",
        "stopped": "completed"
    ]

    /// Aime 默认映射
    public static var aimeDefault: [String: String] = [
        "created": "running",
        "waiting": "waitingInput",
        "running": "running",
        "idle": "idle",
        "stopped": "completed",
        "closed": "completed"
    ]

    /// Cursor 默认映射
    public static var cursorDefault: [String: String] = [
        "active": "running",
        "idle": "idle",
        "thinking": "thinking",
        "tooling": "tooling",
        "waiting": "waitingInput"
    ]

    /// Traecli 默认映射（与 Cursor 相同）
    public static var traecliDefault: [String: String] = cursorDefault

    /// 初始化默认配置
    public init() {
        plugins["aime"] = Self.aimeDefault
        plugins["cursor"] = Self.cursorDefault
        plugins["traecli"] = Self.traecliDefault
    }
}

/// 状态映射服务 - 统一管理各 plugin 的状态映射
public class StatusMappingService {
    public static let shared = StatusMappingService()

    /// 配置文件路径
    private let configPath: URL

    /// 当前配置
    private var config: StatusMappingConfig

    /// 配置锁
    private let lock = NSLock()

    private init() {
        let home = NSHomeDirectory()
        let configDir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        configPath = configDir.appendingPathComponent("status-mapping.json")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // 使用静态方法加载配置（不依赖 self）
        config = Self.loadConfigFromPath(configPath)

        NSLog("[StatusMappingService] Initialized with config at: \(configPath.path)")
    }

    /// 静态方法：从路径加载配置
    private static func loadConfigFromPath(_ path: URL) -> StatusMappingConfig {
        // 尝试从文件加载
        if let data = try? Data(contentsOf: path),
           let loaded = try? JSONDecoder().decode(StatusMappingConfig.self, from: data) {
            NSLog("[StatusMappingService] Loaded config from file")
            return loaded
        }

        // 使用默认配置
        NSLog("[StatusMappingService] Using default config")
        return StatusMappingConfig()
    }

    // MARK: - Public Methods

    /// 映射状态
    /// - Parameters:
    ///   - pluginId: Plugin ID（如 "aime", "cursor"）
    ///   - rawStatus: 数据源返回的原始状态字符串
    /// - Returns: 对应的 SessionStatus
    public func mapStatus(pluginId: String, rawStatus: String) -> SessionStatus {
        lock.lock()
        defer { lock.unlock() }

        // 查找 plugin 特定映射
        let pluginMapping = config.plugins[pluginId] ?? config.defaultMapping

        // 获取映射后的状态字符串
        let mappedString = pluginMapping[rawStatus.lowercased()] ?? config.defaultMapping[rawStatus.lowercased()] ?? rawStatus

        // 转换为 SessionStatus
        return SessionStatus(rawValue: mappedString) ?? .idle
    }

    /// 映射到 DetailedStatus
    public func mapDetailedStatus(pluginId: String, rawStatus: String) -> DetailedStatus {
        let sessionStatus = mapStatus(pluginId: pluginId, rawStatus: rawStatus)
        return DetailedStatus.from(sessionStatus: sessionStatus)
    }

    /// 重新加载配置（用于热更新）
    public func reloadConfig() {
        lock.lock()
        config = Self.loadConfigFromPath(configPath)
        lock.unlock()
        NSLog("[StatusMappingService] Config reloaded")
    }

    /// 保存配置
    public func saveConfig() {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configPath)
        NSLog("[StatusMappingService] Config saved to: \(configPath.path)")
    }

    /// 更新 plugin 的映射规则
    public func updateMapping(pluginId: String, mappings: [String: String]) {
        lock.lock()
        config.plugins[pluginId] = mappings
        lock.unlock()
        saveConfig()
    }

    /// 获取当前配置
    public func getConfig() -> StatusMappingConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }
}