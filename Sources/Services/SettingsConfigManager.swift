import Foundation

/// 管理 Claude CLI settings.json 配置
/// 在 app 启动时检查并确保 hooks 配置存在
public class SettingsConfigManager {
    // MARK: - Singleton

    public static let shared = SettingsConfigManager()

    // MARK: - Constants

    /// settings.json 路径
    private let settingsPath: URL

    /// bridge 脚本名称
    private let bridgeScriptName = "claude-hook-bridge.sh"

    /// 需要配置的 hook 事件类型
    private let hookEventTypes: [String] = [
        "Notification",
        "PermissionRequest",
        "PostToolUse",
        "PreToolUse",
        "PreCompact",
        "SessionStart",
        "SessionEnd",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "UserPromptSubmit"
    ]

    /// PermissionRequest 需要特殊 timeout
    private let permissionRequestTimeout: Int = 86400

    // MARK: - Init

    private init() {
        let home = NSHomeDirectory()
        settingsPath = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    // MARK: - Public

    /// 确保 hooks 配置存在，如果不存在则添加，路径不对则更新
    public func ensureHooksConfigured() {
        NSLog("[SettingsConfigManager] Checking hooks configuration at: \(settingsPath.path)")

        // 1. 确定 bridge 脚本路径
        let bridgePath = getBridgeScriptPath()
        NSLog("[SettingsConfigManager] Bridge script path: \(bridgePath)")

        // 2. 检查 settings.json 是否存在
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            NSLog("[SettingsConfigManager] settings.json not found, creating new file with hooks")
            createNewSettingsFile(bridgePath: bridgePath)
            return
        }

        // 3. 读取现有配置
        guard let data = try? Data(contentsOf: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[SettingsConfigManager] Failed to read settings.json")
            return
        }

        // 4. 检查是否需要更新或添加 hooks
        let needsUpdate = checkAndUpdateHooks(settings: &settings, bridgePath: bridgePath)

        if needsUpdate {
            // 5. 写回文件
            writeSettings(settings: settings)
        } else {
            NSLog("[SettingsConfigManager] Hooks already configured with correct path")
        }
    }

    /// 检查 hooks 配置，返回是否需要写入
    /// - 如果没有 meee2 hooks，添加
    /// - 如果有但路径不对，更新路径
    private func checkAndUpdateHooks(settings: inout [String: Any], bridgePath: String) -> Bool {
        var hooks: [String: Any] = settings["hooks"] as? [String: Any] ?? [:]
        var needsWrite = false

        for eventType in hookEventTypes {
            var eventHooks = hooks[eventType] as? [[String: Any]] ?? []
            var foundAndUpdated = false

            // 查找现有的 meee2 hook 配置
            for i in 0..<eventHooks.count {
                var hookConfig = eventHooks[i]
                guard var innerHooks = hookConfig["hooks"] as? [[String: Any]] else { continue }

                for j in 0..<innerHooks.count {
                    var hook = innerHooks[j]
                    guard let command = hook["command"] as? String,
                          command.contains(bridgeScriptName) else { continue }

                    // 找到了，检查路径是否正确
                    if command != bridgePath {
                        NSLog("[SettingsConfigManager] Updating path for \(eventType): \(command) -> \(bridgePath)")
                        hook["command"] = bridgePath
                        innerHooks[j] = hook
                        hookConfig["hooks"] = innerHooks
                        eventHooks[i] = hookConfig
                        hooks[eventType] = eventHooks
                        needsWrite = true
                    }
                    foundAndUpdated = true
                    break
                }
                if foundAndUpdated { break }
            }

            // 如果没找到，添加新的 hook
            if !foundAndUpdated {
                NSLog("[SettingsConfigManager] Adding hook for: \(eventType)")
                let peerIslandHook: [String: Any]
                if eventType == "PermissionRequest" {
                    peerIslandHook = [
                        "hooks": [
                            [
                                "command": bridgePath,
                                "timeout": permissionRequestTimeout,
                                "type": "command"
                            ]
                        ],
                        "matcher": "*"
                    ]
                } else {
                    peerIslandHook = [
                        "hooks": [
                            [
                                "command": bridgePath,
                                "type": "command"
                            ]
                        ],
                        "matcher": "*"
                    ]
                }
                eventHooks.append(peerIslandHook)
                hooks[eventType] = eventHooks
                needsWrite = true
            }
        }

        settings["hooks"] = hooks
        return needsWrite
    }

    /// 创建新的 settings.json 文件（带 hooks 配置）
    private func createNewSettingsFile(bridgePath: String) {
        var settings: [String: Any] = [
            "permissions": ["allow": []]
        ]

        var hooks: [String: Any] = [:]
        for eventType in hookEventTypes {
            let peerIslandHook: [String: Any]
            if eventType == "PermissionRequest" {
                peerIslandHook = [
                    "hooks": [
                        [
                            "command": bridgePath,
                            "timeout": permissionRequestTimeout,
                            "type": "command"
                        ]
                    ],
                    "matcher": "*"
                ]
            } else {
                peerIslandHook = [
                    "hooks": [
                        [
                            "command": bridgePath,
                            "type": "command"
                        ]
                    ],
                    "matcher": "*"
                ]
            }
            hooks[eventType] = [peerIslandHook]
        }
        settings["hooks"] = hooks

        writeSettings(settings: settings)
    }

    // MARK: - Private

    /// 获取 bridge 脚本路径
    /// 开发环境：源码目录下的 Bridge/
    /// 发布环境：app bundle 内的 Resources/bridge/
    private func getBridgeScriptPath() -> String {
        // 检查是否在 app bundle 中
        // Bundle.main.path 会搜索 Contents/Resources/
        if let bundlePath = Bundle.main.path(forResource: "claude-hook-bridge", ofType: "sh", inDirectory: "Bridge") {
            NSLog("[SettingsConfigManager] Found bridge in bundle: \(bundlePath)")
            return bundlePath
        }

        // 开发环境：尝试查找源码目录
        // Bundle.main.resourcePath 在开发时可能是 .build 或其他路径
        let resourcePath = Bundle.main.resourcePath ?? ""

        // 尝试多个可能的开发路径
        let possiblePaths = [
            // 标准 SwiftPM 构建路径
            URL(fileURLWithPath: resourcePath).appendingPathComponent("Bridge").appendingPathComponent(bridgeScriptName).path,
            // 源码目录 (相对于 workspace) - 更新为 meee2
            "/Users/bytedance/peer_island_workspace/meee2/Bridge/\(bridgeScriptName)"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                NSLog("[SettingsConfigManager] Found bridge at dev path: \(path)")
                return path
            }
        }

        // 默认使用第一个可能的路径（即使不存在，用户可能需要手动安装）
        let defaultPath = possiblePaths[0]
        NSLog("[SettingsConfigManager] Using default dev path: \(defaultPath)")
        return defaultPath
    }

    /// 写入 settings.json
    private func writeSettings(settings: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsPath, options: .atomic)
            NSLog("[SettingsConfigManager] Successfully wrote settings.json")
        } catch {
            NSLog("[SettingsConfigManager] Failed to write settings.json: \(error)")
        }
    }
}