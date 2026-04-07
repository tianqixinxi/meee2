import Foundation

/// 检查 CSM hooks 是否已配置
/// 不再自己写入 bridge script hooks — CSM 是唯一的 hook 写入者
class ClaudeConfigManager {
    private let settingsPath: URL

    init() {
        settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    func ensureHooksConfigured() {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            NSLog("[ClaudeConfigManager] settings.json not found, please run 'csm install'")
            return
        }

        guard let data = try? Data(contentsOf: settingsPath),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            NSLog("[ClaudeConfigManager] Failed to read settings.json")
            return
        }

        // 检查 CSM hooks 是否存在
        let requiredEvents = ["SessionStart", "Stop", "PreToolUse"]
        var hasCsmHooks = false

        for event in requiredEvents {
            if let eventHooks = hooks[event] as? [[String: Any]] {
                for hookConfig in eventHooks {
                    if let innerHooks = hookConfig["hooks"] as? [[String: Any]] {
                        for hook in innerHooks {
                            if let command = hook["command"] as? String, command.contains("csm _hook") {
                                hasCsmHooks = true
                                break
                            }
                        }
                    }
                    if hasCsmHooks { break }
                }
            }
            if hasCsmHooks { break }
        }

        if hasCsmHooks {
            NSLog("[ClaudeConfigManager] CSM hooks found, data sharing enabled")
        } else {
            NSLog("[ClaudeConfigManager] CSM hooks not found! Run 'csm install' to enable session tracking")
        }
    }
}
