import Foundation

/// 幂等地把 meee2 的 MCP server 写进 Claude 和 Codex 的全局 MCP 配置。
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

    /// meee2 MCP server 暴露的全部 tool 名（必须跟 Bridge/mcp-meee2/server.js
    /// 里 TOOLS 数组里的 name 字段保持同步）。
    private let mcpToolNames: [String] = [
        "mcp__meee2__list_sessions"
    ]

    private var configPath: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// permissions.allow 的归属文件——与 hooks 同源（settings.json，不是
    /// 那个 200KB 的 .claude.json 大杂烩）。
    private var settingsPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    /// Codex CLI / Desktop 读取的全局配置。
    private var codexConfigPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("config.toml")
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

        // Already correctly registered → 跳过 mcpServers 写入但 permissions
        // allowlist 仍要 ensure（旧版本 meee2 注册了 server 但没配 allowlist，
        // 升级到新版后第一次启动需要补上）。
        if existingCmd == nodeBin, existingArgsFirst == expectedServerPath {
            NSLog("[MCPConfigManager] already registered with correct path, noop")
            ensurePermissionsAllowlist()
            ensureCodexMCPServer(nodeBin: nodeBin, serverPath: expectedServerPath)
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
            ensureCodexMCPServer(nodeBin: nodeBin, serverPath: expectedServerPath)
            return
        }

        if existing == nil {
            NSLog("[MCPConfigManager] registered meee2 MCP server → \(expectedServerPath)")
        } else {
            NSLog("[MCPConfigManager] updated meee2 MCP server path → \(expectedServerPath)")
        }

        // 把 meee2 的 7 个 MCP tool 加进 settings.json 的 permissions.allow，
        // agent 调用就不再被 PermissionRequest 弹框拦住。幂等：已经全部都在
        // 就静默退出。
        ensurePermissionsAllowlist()
        ensureCodexMCPServer(nodeBin: nodeBin, serverPath: expectedServerPath)
    }

    /// 确保 meee2 的 MCP tool 全部在 `~/.claude/settings.json` 的
    /// `permissions.allow` 里。读 → merge → 原子写。文件缺失时创建一个
    /// 只包含我们这 7 条的最小文档（不破坏 SettingsConfigManager 的 hooks
    /// 流，因为它走自己的 ensureHooksConfigured，会再次 read+merge 自己的
    /// 字段，不依赖整个文件状态）。
    private func ensurePermissionsAllowlist() {
        var rootObject: [String: Any] = readSettings() ?? [:]
        var permissions = (rootObject["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []

        let existing = Set(allow)
        let missing = mcpToolNames.filter { !existing.contains($0) }
        if missing.isEmpty {
            // 全部已在，不动磁盘
            return
        }
        allow.append(contentsOf: missing)
        permissions["allow"] = allow
        rootObject["permissions"] = permissions

        guard writeSettingsAtomic(rootObject) else {
            NSLog("[MCPConfigManager] failed to write settings.json permissions allowlist")
            return
        }
        let names = missing.joined(separator: ", ")
        NSLog("[MCPConfigManager] permissions.allow added \(missing.count) meee2 MCP tool(s): \(names)")
    }

    /// Codex 的 MCP 配置是 TOML：
    ///
    ///     [mcp_servers.meee2]
    ///     command = "node"
    ///     args = ["/abs/path/to/server.js"]
    ///
    /// Foundation 没有内建 TOML parser；这里做一个窄用途的 table block upsert，
    /// 只替换我们自己的 `[mcp_servers.meee2]` 段，保留其他用户配置原样。
    private func ensureCodexMCPServer(nodeBin: String, serverPath: String) {
        let block = """
        [mcp_servers.\(serverName)]
        command = \(tomlString(nodeBin))
        args = [\(tomlString(serverPath))]
        """

        let original = (try? String(contentsOf: codexConfigPath, encoding: .utf8)) ?? ""
        let next = upsertTomlTableBlock(
            in: original,
            tableHeader: "[mcp_servers.\(serverName)]",
            block: block
        )
        guard next != original else { return }

        do {
            try FileManager.default.createDirectory(
                at: codexConfigPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try next.write(to: codexConfigPath, atomically: true, encoding: .utf8)
            NSLog("[MCPConfigManager] registered Codex MCP server → \(serverPath)")
        } catch {
            NSLog("[MCPConfigManager] failed to write ~/.codex/config.toml: \(error)")
        }
    }

    private func upsertTomlTableBlock(in content: String, tableHeader: String, block: String) -> String {
        let normalizedBlock = block.hasSuffix("\n") ? block : block + "\n"
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == tableHeader }) else {
            var out = content
            if !out.isEmpty && !out.hasSuffix("\n") { out.append("\n") }
            if !out.isEmpty { out.append("\n") }
            out.append(normalizedBlock)
            return out
        }

        var end = start + 1
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                break
            }
            end += 1
        }

        let replacement = normalizedBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.replaceSubrange(start..<end, with: replacement)
        return lines.joined(separator: "\n")
    }

    private func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
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

    // settings.json 一组，跟 SettingsConfigManager 走的是同一个文件——但
    // 这里只读 / 改 permissions.allow 字段，不动 hooks，避免两边 race。
    // 真有并发场景 SettingsConfigManager.ensureHooksConfigured() 也会再
    // 走一次 read+merge+write，自己的字段会被它的写覆盖回正确值。

    private func readSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsPath) else {
            NSLog("[MCPConfigManager] settings read failed: cannot read \(settingsPath.path)")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[MCPConfigManager] settings parse failed: ~/.claude/settings.json is not a JSON object; refusing to overwrite")
            return nil
        }
        return obj
    }

    private func writeSettingsAtomic(_ dict: [String: Any]) -> Bool {
        // 确保 ~/.claude/ 目录存在（settings.json 缺失时也能新建）
        let parent = settingsPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: opts) else {
            return false
        }
        do {
            try data.write(to: settingsPath, options: .atomic)
            return true
        } catch {
            NSLog("[MCPConfigManager] settings atomic write failed: \(error)")
            return false
        }
    }
}
