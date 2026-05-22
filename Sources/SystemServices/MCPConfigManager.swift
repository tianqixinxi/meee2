import Foundation

public struct Meee2MCPStatus: Encodable {
    public let configured: Bool
    public let configCommand: String?
    public let configArgs: [String]
    public let expectedServerPath: String
    public let serverPath: String?
    public let serverExists: Bool
    public let nodeAvailable: Bool
    public let launches: Bool
    public let tools: [String]
    public let missingRequiredTools: [String]
    public let error: String?
    public let checkedAt: Date
}

/// 幂等地把 meee2 的 MCP server 写进 Claude 和 Codex 的全局 MCP 配置，
/// 让任何 Claude Code / Codex session 都能原生调 `read_node_contract` /
/// `submit_node_output` 等 tool。应用启动时调一次，无变化就是个 noop。
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
    /// 里 TOOLS 数组里的 name 字段保持同步——加新 tool 时两边都要改）。
    /// 这些名字按 Claude Code 的 MCP 命名约定 `mcp__<server>__<tool>`，会被
    /// 写进 `~/.claude/settings.json` 的 permissions.allow，让 agent 调用
    /// 这些 tool 时不再触发 PermissionRequest 弹框。
    private let mcpToolNames: [String] = [
        "mcp__meee2__list_sessions",
        "mcp__meee2__read_inbox",
        "mcp__meee2__read_node_contract",
        "mcp__meee2__submit_node_output",
        "mcp__meee2__attach_artifact_to_node"
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

    public func diagnoseMeee2Server() -> Meee2MCPStatus {
        let expectedServerPath = resolveServerScriptPath()
        let rootObject = readConfig() ?? [:]
        let mcpServers = (rootObject["mcpServers"] as? [String: Any]) ?? [:]
        let entry = mcpServers[serverName] as? [String: Any]
        let configCommand = entry?["command"] as? String
        let configArgs = entry?["args"] as? [String] ?? []
        let configured = configCommand != nil && !configArgs.isEmpty
        let command = configCommand ?? "node"
        let args = configArgs.isEmpty ? [expectedServerPath] : configArgs
        let serverPath = args.first ?? expectedServerPath
        let serverExists = FileManager.default.fileExists(atPath: serverPath)
        let nodeAvailable = commandAvailable(command)
        let requiredTools = ["read_node_contract", "submit_node_output", "attach_artifact_to_node"]

        guard serverExists else {
            return Meee2MCPStatus(
                configured: configured,
                configCommand: configCommand,
                configArgs: configArgs,
                expectedServerPath: expectedServerPath,
                serverPath: serverPath,
                serverExists: false,
                nodeAvailable: nodeAvailable,
                launches: false,
                tools: [],
                missingRequiredTools: requiredTools,
                error: "Meee2 MCP server.js was not found at \(serverPath).",
                checkedAt: Date()
            )
        }

        guard nodeAvailable else {
            return Meee2MCPStatus(
                configured: configured,
                configCommand: configCommand,
                configArgs: configArgs,
                expectedServerPath: expectedServerPath,
                serverPath: serverPath,
                serverExists: true,
                nodeAvailable: false,
                launches: false,
                tools: [],
                missingRequiredTools: requiredTools,
                error: "Node.js command '\(command)' is not available in PATH.",
                checkedAt: Date()
            )
        }

        let probe = probeServer(command: command, args: args)
        let missing = requiredTools.filter { !probe.tools.contains($0) }
        let launches = probe.error == nil && missing.isEmpty
        return Meee2MCPStatus(
            configured: configured,
            configCommand: configCommand,
            configArgs: configArgs,
            expectedServerPath: expectedServerPath,
            serverPath: serverPath,
            serverExists: true,
            nodeAvailable: true,
            launches: launches,
            tools: probe.tools,
            missingRequiredTools: missing,
            error: probe.error ?? (missing.isEmpty ? nil : "Meee2 MCP launched but is missing required planner tools: \(missing.joined(separator: ", "))."),
            checkedAt: Date()
        )
    }

    /// 应用启动时调；无论现在是啥状态都收敛到"已注册，命令指向当前的 server.js
    /// 绝对路径"。
    public func ensureRegistered() {
        let expectedServerPath = resolveServerScriptPath()
        NSLog("[MCPConfigManager] expected server.js path: \(expectedServerPath)")

        guard FileManager.default.fileExists(atPath: expectedServerPath) else {
            NSLog("[MCPConfigManager] skip register: server.js not found at \(expectedServerPath)")
            return
        }

        // node 路径——meee2 作为 launchd 启动的 GUI app，PATH 是精简版，不含
        // nvm / Homebrew 目录；裸 `node` 的 MCP 条目在 meee2 自己以及它派发的
        // session 里都起不来。注册时解析出一个绝对路径写进去。
        let nodeBin = resolveNodeBinary()
        if nodeBin == "node" {
            NSLog("[MCPConfigManager] WARNING: could not resolve an absolute node path; falling back to bare `node` (requires Node.js >= 18 on the spawner PATH).")
        } else {
            NSLog("[MCPConfigManager] resolved node binary → \(nodeBin)")
        }

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

        // 把 meee2 的 MCP tool 加进 settings.json 的 permissions.allow，
        // agent 调用就不再被 PermissionRequest 弹框拦住。幂等：已经全部都在
        // 就静默退出。
        ensurePermissionsAllowlist()
        ensureCodexMCPServer(nodeBin: nodeBin, serverPath: expectedServerPath)
    }

    public func currentServerScriptPath() -> String {
        resolveServerScriptPath()
    }

    public func stageServerForPluginRuntime() throws -> String {
        let source = URL(fileURLWithPath: resolveServerScriptPath())
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(
                domain: "Meee2MCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Meee2 MCP server.js was not found at \(source.path)."]
            )
        }
        let sourceDir = source.deletingLastPathComponent()
        let targetDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        for name in [serverJsName, "package.json", "package-lock.json"] {
            let from = sourceDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = targetDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: to.path) {
                try FileManager.default.removeItem(at: to)
            }
            try FileManager.default.copyItem(at: from, to: to)
        }

        return targetDir.appendingPathComponent(serverJsName).path
    }

    /// 确保 meee2 的 MCP tool 全部在 `~/.claude/settings.json` 的
    /// `permissions.allow` 里。读 → merge → 原子写。文件缺失时创建一个
    /// 只包含我们这些 tool 的最小文档（不破坏 SettingsConfigManager 的 hooks
    /// 流，因为它走自己的 ensureHooksConfigured，会再次 read+merge 自己的
    /// 字段，不依赖整个文件状态）。
    private func ensurePermissionsAllowlist() {
        var rootObject: [String: Any] = readSettings() ?? [:]
        var permissions = (rootObject["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []

        let supportedMeee2Tools = Set(mcpToolNames)
        let originalCount = allow.count
        allow = allow.filter { name in
            !name.hasPrefix("mcp__meee2__") || supportedMeee2Tools.contains(name)
        }

        let existing = Set(allow)
        let missing = mcpToolNames.filter { !existing.contains($0) }
        if missing.isEmpty && allow.count == originalCount {
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
        let removedCount = originalCount - allow.count + missing.count
        NSLog("[MCPConfigManager] permissions.allow synced meee2 MCP tools; added \(missing.count), removed \(removedCount). Added: \(names)")
    }

    /// Codex 的 MCP 配置是 TOML：
    ///
    ///     [mcp_servers.meee2]
    ///     command = "node"
    ///     args = ["/abs/path/to/server.js"]
    ///
    /// Foundation 没有内建 TOML parser；这里做一个窄用途的 table block upsert，
    /// 只替换我们自己的 `[mcp_servers.meee2]` 段，保留其他用户配置原样。
    /// Upsert an arbitrary MCP server entry in `~/.codex/config.toml`. Used by
    /// `IntegrationInstaller` to install third-party integrations (Linear /
    /// Notion / Figma / …) the same way we install meee2's own server here.
    /// Idempotent — re-running with the same args is a no-op.
    public func upsertCodexMCPServer(
        name: String,
        command: String,
        args: [String]
    ) throws {
        let header = "[mcp_servers.\(name)]"
        let argsBlock = args.map { tomlString($0) }.joined(separator: ", ")
        let block = """
        \(header)
        command = \(tomlString(command))
        args = [\(argsBlock)]
        """
        let original = (try? String(contentsOf: codexConfigPath, encoding: .utf8)) ?? ""
        let next = upsertTomlTableBlock(in: original, tableHeader: header, block: block)
        guard next != original else { return }
        try FileManager.default.createDirectory(
            at: codexConfigPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try next.write(to: codexConfigPath, atomically: true, encoding: .utf8)
    }

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

    /// Resolve an absolute path to a `node` binary.
    ///
    /// meee2 runs as a launchd-started GUI app with a minimal PATH that does
    /// not include nvm / Homebrew / asdf dirs, so a bare `node` command in the
    /// MCP config fails to launch (both for meee2's own probe and for the
    /// sessions it dispatches). We resolve a concrete path at registration
    /// time instead. Order: the user's login shell (respects nvm's default
    /// alias) → known install locations → bare `node` as a last resort.
    private func resolveNodeBinary() -> String {
        let fm = FileManager.default

        // 1) Ask the user's login+interactive shell — loads nvm/asdf/volta from
        //    the rc files and picks whatever `node` the user actually uses.
        //    Bounded: a launchd GUI app inherits a minimal env, and a slow or
        //    prompting `.zshrc`/`.bashrc` under `-lic` must not hang startup.
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           shell.hasPrefix("/"),
           fm.isExecutableFile(atPath: shell),
           let output = runWithTimeout(shell, ["-lic", "command -v node"], seconds: 3) {
            let resolved = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") }
            if let resolved, fm.isExecutableFile(atPath: resolved) {
                return resolved
            }
        }

        // 2) Scan known install locations. nvm: newest version wins.
        let nvmRoot = "\(NSHomeDirectory())/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            let newestFirst = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in newestFirst {
                let candidate = "\(nvmRoot)/\(version)/bin/node"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }

        // 3) Last resort — bare command, relies on the spawner's PATH.
        return "node"
    }

    /// Run `command` with `arguments`, returning its stdout on a clean
    /// (status 0) exit within `seconds`, or `nil` on launch failure, a
    /// non-zero exit, or a timeout. stdin is `/dev/null` so an rc script that
    /// prompts gets an immediate EOF instead of blocking the caller; on
    /// timeout the process is sent SIGTERM and `nil` is returned without
    /// waiting further, so a stalled shell can never hang `ensureRegistered()`.
    private func runWithTimeout(_ command: String, _ arguments: [String], seconds: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(bytes: data, encoding: .utf8)
    }

    private func commandAvailable(_ command: String) -> Bool {
        // An absolute path (what `resolveNodeBinary` writes) — check directly;
        // `which` is for PATH lookups of bare command names.
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func probeServer(command: String, args: [String]) -> (tools: [String], error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let input = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"meee2-health","version":"0"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}

        """

        do {
            try process.run()
            if let data = input.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            stdin.fileHandleForWriting.closeFile()
        } catch {
            return ([], "Failed to launch Meee2 MCP server: \(error.localizedDescription)")
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 2.0) == .timedOut {
            process.terminate()
            return ([], "Meee2 MCP server did not answer tools/list within 2 seconds.")
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: err, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stdoutText = String(data: out, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let detail = stderrText.isEmpty ? "exit \(process.terminationStatus)" : stderrText
            return ([], "Meee2 MCP server exited before listing tools: \(detail)")
        }

        var tools: [String] = []
        for line in stdoutText.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int,
                  id == 2,
                  let result = object["result"] as? [String: Any],
                  let rawTools = result["tools"] as? [[String: Any]] else {
                continue
            }
            tools = rawTools.compactMap { $0["name"] as? String }
        }

        guard !tools.isEmpty else {
            let detail = stderrText.isEmpty ? "No tools/list response was returned." : stderrText
            return ([], "Meee2 MCP server launched but did not return tools: \(detail)")
        }
        return (tools.sorted(), nil)
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
