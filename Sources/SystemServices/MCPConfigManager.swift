import Foundation

/// 幂等地把 meee2 的 MCP server 写进 `~/.claude.json` 的 `mcpServers.meee2`
/// 条目里，让任何 Claude Code session 都能原生调 `send_message` /
/// `list_channels` 等 tool。应用启动时调一次，无变化就是个 noop。
///
/// 为什么不另外写一个 `~/.claude/mcp.json`：Claude Code 目前的 user-wide
/// MCP 配置就是 `~/.claude.json` 里那个 `mcpServers` 顶级字段；单独的
/// `mcp.json` 不被读取。
///
/// 文件里还有 200+ KB 的其他状态（startup 计数、cache 等），所以绝不能
/// 整个 rewrite——走 "读 → merge → atomic write" 流程。
public final class MCPConfigManager {
    public static let shared = MCPConfigManager()

    private let serverName = "meee2"
    private let serverJsName = "server.js"
    private let subdir = "mcp-meee2"

    private var configPath: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    private init() {}

    /// 应用启动时调；无论现在是啥状态都收敛到"已注册，命令指向当前的 server.js
    /// 绝对路径"。
    public func ensureRegistered() {
        // 检查 Node.js 是否可用
        let whichNode = Process()
        whichNode.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichNode.arguments = ["which", "node"]
        whichNode.standardOutput = Pipe()
        whichNode.standardError = Pipe()
        do {
            try whichNode.run()
            whichNode.waitUntilExit()
            if whichNode.terminationStatus != 0 {
                NSLog("[MCPConfigManager] WARNING: Node.js not found in PATH. MCP server will be registered but cannot run until Node.js >= 18 is installed.")
            }
        } catch {
            NSLog("[MCPConfigManager] WARNING: Cannot check for Node.js availability.")
        }

        let expectedServerPath = resolveServerScriptPath()
        NSLog("[MCPConfigManager] expected server.js path: \(expectedServerPath)")

        guard FileManager.default.fileExists(atPath: expectedServerPath) else {
            NSLog("[MCPConfigManager] skip register: server.js not found at \(expectedServerPath)")
            return
        }

        // node 路径——Claude 的其他 MCP 条目都是裸 "node" / "npx"，靠 PATH
        // 解析。这里也用 `node`，不写死绝对路径（brew / nvm / asdf 下各家位置
        // 都不一样；子进程能从 PATH 里找到）。
        let nodeBin = "node"

        var rootObject: [String: Any] = readConfig() ?? [:]
        var mcpServers = (rootObject["mcpServers"] as? [String: Any]) ?? [:]

        let existing = mcpServers[serverName] as? [String: Any]
        let existingCmd = existing?["command"] as? String
        let existingArgs = existing?["args"] as? [String]
        let existingArgsFirst = existingArgs?.first

        // Already correctly registered → no-op.
        if existingCmd == nodeBin, existingArgsFirst == expectedServerPath {
            NSLog("[MCPConfigManager] already registered with correct path, noop")
            return
        }

        let entry: [String: Any] = [
            "type": "stdio",
            "command": nodeBin,
            "args": [expectedServerPath],
            "env": [:] as [String: String]
        ]
        mcpServers[serverName] = entry
        rootObject["mcpServers"] = mcpServers

        guard writeConfigAtomic(rootObject) else {
            NSLog("[MCPConfigManager] failed to write ~/.claude.json; leaving it alone")
            return
        }

        if existing == nil {
            NSLog("[MCPConfigManager] registered meee2 MCP server → \(expectedServerPath)")
        } else {
            NSLog("[MCPConfigManager] updated meee2 MCP server path → \(expectedServerPath)")
        }
    }

    // MARK: - Path resolution (mirror SettingsConfigManager.getBridgeScriptPath)

    /// Release bundle → dev `#file` → CWD. 和 bridge 脚本走同一套定位逻辑。
    private func resolveServerScriptPath() -> String {
        // 1. Release bundle
        if let bundlePath = Bundle.main.path(
            forResource: "server",
            ofType: "js",
            inDirectory: "Bridge/\(subdir)"
        ) {
            return bundlePath
        }

        // 2. dev: 用 #file 反推到 repo root → Bridge/mcp-meee2/server.js
        let thisFileURL = URL(fileURLWithPath: #file)
        let repoRoot = thisFileURL
            .deletingLastPathComponent()   // Services/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // meee2/
        let devPath = repoRoot
            .appendingPathComponent("Bridge")
            .appendingPathComponent(subdir)
            .appendingPathComponent(serverJsName)
            .path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        // 3. CWD 兜底
        let cwdPath = FileManager.default.currentDirectoryPath
            + "/Bridge/\(subdir)/\(serverJsName)"
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }

        return devPath
    }

    // MARK: - Config IO

    private func readConfig() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: configPath.path) else { return [:] }
        guard let data = try? Data(contentsOf: configPath) else {
            NSLog("[MCPConfigManager] read failed: cannot read \(configPath.path)")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[MCPConfigManager] parse failed: ~/.claude.json is not a JSON object; refusing to overwrite")
            return nil
        }
        return obj
    }

    private func writeConfigAtomic(_ dict: [String: Any]) -> Bool {
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: opts) else {
            return false
        }
        do {
            try data.write(to: configPath, options: .atomic)
            return true
        } catch {
            NSLog("[MCPConfigManager] atomic write failed: \(error)")
            return false
        }
    }
}
