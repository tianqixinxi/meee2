import Foundation

struct AgentRuntimeComponentStatus: Encodable {
    var available: Bool
    var cliAvailable: Bool
    var appAvailable: Bool
    var cliPath: String?
    var appPath: String?
    var installed: Bool
    var configured: Bool
    var detail: String?
    var command: String?
}

struct Meee2AgentRuntimeStatus: Encodable {
    var marketplacePath: String
    var pluginPath: String
    var mcpServerPath: String
    var stagedMCPServerPath: String?
    var claude: AgentRuntimeComponentStatus
    var codex: AgentRuntimeComponentStatus
    var needsAttention: Bool
    var checkedAt: Date
}

struct Meee2AgentRuntimeInstallResult: Encodable {
    var ok: Bool
    var target: String
    var messages: [String]
    var logs: [String]
    var status: Meee2AgentRuntimeStatus
}

enum Meee2AgentRuntimeInstaller {
    struct ClaudePluginInstallStatus: Equatable {
        var installed: Bool
        var enabled: Bool

        static let missing = ClaudePluginInstallStatus(installed: false, enabled: false)

        var active: Bool { installed && enabled }
    }

    private static let marketplaceName = "meee2-official"
    private static let pluginName = "meee2"
    private static let workflowBridgePluginName = "meee2-workflow-bridge"
    private static let diagnoseCacheTTL: TimeInterval = 30
    private static let diagnoseLock = NSLock()
    private static var diagnoseCache: Meee2AgentRuntimeStatus?
    private static var diagnoseInFlight: DispatchGroup?
    private static var pluginSelector: String { "\(pluginName)@\(marketplaceName)" }
    private static var workflowBridgePluginSelector: String { "\(workflowBridgePluginName)@\(marketplaceName)" }

    static func diagnose(forceRefresh: Bool = false) -> Meee2AgentRuntimeStatus {
        if !forceRefresh,
           let cached = cachedDiagnoseStatus() {
            return cached
        }

        if let group = beginSharedDiagnose(forceRefresh: forceRefresh) {
            group.wait()
            if !forceRefresh,
               let cached = cachedDiagnoseStatus() {
                return cached
            }
            if !forceRefresh,
               let cached = currentDiagnoseCache() {
                return cached
            }
        }
        if !forceRefresh,
           let cached = cachedDiagnoseStatus() {
            return cached
        }

        let status = diagnoseUncached()
        finishSharedDiagnose(status)
        return status
    }

    private static func cachedDiagnoseStatus() -> Meee2AgentRuntimeStatus? {
        diagnoseLock.lock()
        defer { diagnoseLock.unlock() }
        guard let cached = diagnoseCache,
              Date().timeIntervalSince(cached.checkedAt) < diagnoseCacheTTL else {
            return nil
        }
        return cached
    }

    private static func currentDiagnoseCache() -> Meee2AgentRuntimeStatus? {
        diagnoseLock.lock()
        defer { diagnoseLock.unlock() }
        return diagnoseCache
    }

    /// Returns an existing in-flight group to wait on, or nil when this caller
    /// owns the uncached diagnose run.
    private static func beginSharedDiagnose(forceRefresh: Bool) -> DispatchGroup? {
        diagnoseLock.lock()
        defer { diagnoseLock.unlock() }
        if !forceRefresh,
           let cached = diagnoseCache,
           Date().timeIntervalSince(cached.checkedAt) < diagnoseCacheTTL {
            return nil
        }
        if let group = diagnoseInFlight {
            return group
        }
        let group = DispatchGroup()
        group.enter()
        diagnoseInFlight = group
        return nil
    }

    private static func finishSharedDiagnose(_ status: Meee2AgentRuntimeStatus) {
        diagnoseLock.lock()
        let group = diagnoseInFlight
        diagnoseCache = status
        diagnoseInFlight = nil
        group?.leave()
        diagnoseLock.unlock()
    }

    private static func invalidateDiagnoseCache() {
        diagnoseLock.lock()
        diagnoseCache = nil
        diagnoseLock.unlock()
    }

    private static func diagnoseUncached() -> Meee2AgentRuntimeStatus {
        let marketplacePath = resolveMarketplacePath()
        let pluginPath = marketplacePath.appendingPathComponent(pluginName, isDirectory: true)
        let mcpServerPath = MCPConfigManager.shared.currentServerScriptPath()
        let stagedPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent("mcp-meee2", isDirectory: true)
            .appendingPathComponent("server.js")
            .path
        let stagedExists = FileManager.default.fileExists(atPath: stagedPath)

        let claudeCliPath = commandPath("claude")
        let claudeAppPath = appPath(bundleIdentifier: "com.anthropic.claudefordesktop", fallback: "/Applications/Claude.app")
        let claudeCLIAvailable = claudeCliPath != nil
        let claudeAppAvailable = claudeAppPath != nil
        let claudeAvailable = claudeCLIAvailable || claudeAppAvailable
        let claudeMainPluginStatus = claudeCLIAvailable ? claudePluginStatusFor(marketplaceName, plugin: pluginName) : .missing
        let claudeWorkflowBridgeStatus = claudeCLIAvailable ? claudePluginStatusFor(marketplaceName, plugin: workflowBridgePluginName) : .missing
        let claudeMainPluginInstalled = claudeMainPluginStatus.installed
        let claudeWorkflowBridgeInstalled = claudeWorkflowBridgeStatus.installed
        let claudePreferredInstalled = claudeMainPluginInstalled && claudeWorkflowBridgeInstalled
        let claudePreferredEnabled = claudeMainPluginStatus.active && claudeWorkflowBridgeStatus.active
        let claudeInstalled = claudePreferredInstalled
        let claudeMarketplace = claudeAvailable && claudeMarketplaceConfigured()
        let claudeConfigured = claudeCLIAvailable && claudePreferredEnabled && stagedExists
        let claudeSetupCommand = [
            "claude plugin install \(pluginSelector) --scope user",
            "claude plugin install \(workflowBridgePluginSelector) --scope user",
            "claude plugin enable \(pluginSelector) --scope user",
            "claude plugin enable \(workflowBridgePluginSelector) --scope user"
        ].joined(separator: " && ")

        let codexPathOnPATH = commandPath("codex")
        let codexAppBinaryPath = fallbackCodexPath()
        let codexAppPath = appPath(bundleIdentifier: "com.openai.codex", fallback: "/Applications/Codex.app")
        let codexPath = codexPathOnPATH ?? codexAppBinaryPath
        let codexCLIAvailable = codexPath != nil
        let codexAppAvailable = codexAppPath != nil
        let codexAvailable = codexCLIAvailable || codexAppAvailable
        let codexSkillInstalled = FileManager.default.fileExists(atPath: codexSkillPath().path)
        let codexPluginInstalled = codexCLIAvailable && codexPluginInstalled()
        let codexMarketplace = codexCLIAvailable && codexMarketplaceConfigured()
        let codexMCPConfigured = codexMCPConfigured()
        let codexHooksBundled = codexHooksBundled()
        let codexConfigured = codexCLIAvailable && codexMCPConfigured && (codexPluginInstalled || codexSkillInstalled)

        let needsAttention =
            (claudeAvailable && !claudeConfigured)
            || (codexAvailable && !codexConfigured)

        return Meee2AgentRuntimeStatus(
            marketplacePath: marketplacePath.path,
            pluginPath: pluginPath.path,
            mcpServerPath: mcpServerPath,
            stagedMCPServerPath: stagedExists ? stagedPath : nil,
            claude: AgentRuntimeComponentStatus(
                available: claudeAvailable,
                cliAvailable: claudeCLIAvailable,
                appAvailable: claudeAppAvailable,
                cliPath: claudeCliPath,
                appPath: claudeAppPath,
                installed: claudeInstalled,
                configured: claudeConfigured,
                detail: claudeCLIAvailable
                    ? (claudePreferredEnabled
                        ? (stagedExists ? "Claude Code plugins are installed, including Workflow bridge. Claude.app \(claudeAppAvailable ? "is installed too" : "was not found")." : "Plugins installed; staged MCP server is missing.")
                        : (claudePreferredInstalled
                            ? "Claude Code plugins are installed, but one or more are disabled."
                            : (claudeMarketplace ? "Meee2 marketplace is added; Claude Code plugin or Workflow bridge is not installed." : "Claude Code CLI is available; Meee2 plugins are not installed.")))
                    : (claudeAppAvailable ? "Claude.app is installed, but Claude Code CLI was not found on PATH." : "Claude Code CLI and Claude.app were not found."),
                command: claudeSetupCommand
            ),
            codex: AgentRuntimeComponentStatus(
                available: codexAvailable,
                cliAvailable: codexCLIAvailable,
                appAvailable: codexAppAvailable,
                cliPath: codexPath,
                appPath: codexAppPath,
                installed: codexPluginInstalled || codexSkillInstalled,
                configured: codexConfigured,
                detail: codexCLIAvailable
                    ? (codexConfigured
                        ? (codexPathOnPATH == nil
                            ? "Meee2 Codex runtime is configured; Codex.app CLI binary was found outside PATH. Artifact hooks are \(codexHooksBundled ? "bundled" : "missing from this plugin package"); review/trust them in Codex /hooks if prompted."
                            : "Meee2 Codex MCP and local skill are configured. Artifact hooks are \(codexHooksBundled ? "bundled" : "missing from this plugin package"); review/trust them in Codex /hooks if prompted.")
                        : (codexPathOnPATH == nil
                            ? "Codex.app binary was found outside PATH; Meee2 MCP or local skill is missing."
                            : (codexMarketplace ? "Meee2 Codex marketplace is added; plugin, MCP, or local skill is missing." : "Codex was found; Meee2 marketplace, MCP, or local skill is missing.")))
                    : (codexAppAvailable ? "Codex.app is installed, but no Codex CLI binary was found." : "Codex CLI and Codex.app were not found."),
                command: "codex plugin add \(pluginSelector)"
            ),
            needsAttention: needsAttention,
            checkedAt: Date()
        )
    }

    static func install(target: String) -> Meee2AgentRuntimeInstallResult {
        invalidateDiagnoseCache()
        var messages: [String] = []
        var logs: [String] = []
        let normalized = target.lowercased()
        log(&logs, "Starting Meee2 Agent Runtime install target=\(normalized)")

        do {
            let staged = try MCPConfigManager.shared.stageServerForPluginRuntime()
            messages.append("Staged Meee2 MCP server at \(staged).")
            log(&logs, "Staged MCP server at \(staged)")
        } catch {
            let message = "Failed to stage Meee2 MCP server: \(error.localizedDescription)"
            messages.append(message)
            log(&logs, message)
        }

        log(&logs, "Ensuring global MCP registration for Claude Code and Codex")
        MCPConfigManager.shared.ensureRegistered()

        if normalized == "claude" || normalized == "all" {
            if commandPath("claude") == nil {
                let message = "Skipped Claude Code plugin install: Claude Code CLI was not found on PATH. Claude.app alone cannot install Claude Code plugins."
                messages.append(message)
                log(&logs, message)
            } else {
                let result = installClaudePlugin()
                messages.append(contentsOf: result.messages)
                logs.append(contentsOf: result.logs)
            }
        }

        if normalized == "codex" || normalized == "all" {
            if commandPath("codex") == nil && fallbackCodexPath() == nil {
                let message = "Skipped Codex: CLI was not found on PATH."
                messages.append(message)
                log(&logs, message)
            } else {
                let result = installCodexRuntime()
                messages.append(contentsOf: result.messages)
                logs.append(contentsOf: result.logs)
            }
        }

        // 插件可能刚装上 → 再收敛一次 MCP 注册:此时 meee2PluginActive() 已能
        // 看到插件,会清掉自注册的 mcp__meee2__,不必等下次 app 启动。幂等。
        MCPConfigManager.shared.ensureRegistered()

        let status = diagnose(forceRefresh: true)
        let ok: Bool
        switch normalized {
        case "claude":
            ok = status.claude.configured
        case "codex":
            ok = status.codex.configured
        default:
            ok = (!status.claude.cliAvailable || status.claude.configured)
                && (!status.codex.cliAvailable || status.codex.configured)
        }
        log(&logs, "Install finished ok=\(ok)")
        return Meee2AgentRuntimeInstallResult(ok: ok, target: normalized, messages: messages, logs: logs, status: status)
    }

    private static func installClaudePlugin() -> (messages: [String], logs: [String]) {
        var logs: [String] = []
        guard commandPath("claude") != nil else {
            return (["Claude Code CLI was not found on PATH."], ["Claude Code CLI was not found on PATH."])
        }
        let marketplacePath = resolveMarketplacePath().path
        guard FileManager.default.fileExists(atPath: marketplacePath) else {
            return (["Meee2 plugin marketplace was not found at \(marketplacePath)."], ["Meee2 plugin marketplace was not found at \(marketplacePath)."])
        }

        var messages: [String] = []
        let marketplaceConfigured = claudeMarketplaceConfigured()
        if marketplaceConfigured {
            messages.append("Meee2 Claude Code marketplace is already configured.")
            log(&logs, "Skipping marketplace add; \(marketplaceName) is already configured")
        } else {
            let add = runCommand("claude", ["plugin", "marketplace", "add", "--scope", "user", marketplacePath], timeoutSeconds: 60, logs: &logs)
            if add.exitCode == 0 || claudeMarketplaceConfigured() {
                messages.append("Added Meee2 Claude Code marketplace.")
            } else {
                messages.append("Failed to add Claude Code marketplace: \(add.combinedOutput)")
            }
        }

        installClaudeMarketplacePlugin(
            name: pluginName,
            displayName: "Meee2 Claude Code plugin",
            messages: &messages,
            logs: &logs
        )
        installClaudeMarketplacePlugin(
            name: workflowBridgePluginName,
            displayName: "Meee2 Workflow Bridge plugin",
            messages: &messages,
            logs: &logs
        )
        return (messages, logs)
    }

    private static func installClaudeMarketplacePlugin(
        name: String,
        displayName: String,
        messages: inout [String],
        logs: inout [String]
    ) {
        let selector = "\(name)@\(marketplaceName)"
        let status = claudePluginStatusFor(marketplaceName, plugin: name)
        if status.active {
            messages.append("Installed \(displayName).")
            log(&logs, "Skipping plugin install; \(selector) is already installed and enabled")
            return
        }
        if status.installed {
            let enable = runCommand("claude", ["plugin", "enable", "--scope", "user", selector], timeoutSeconds: 60, logs: &logs)
            if enable.exitCode == 0 || claudePluginStatusFor(marketplaceName, plugin: name).active {
                messages.append("Enabled \(displayName).")
            } else {
                messages.append("Failed to enable \(displayName): \(enable.combinedOutput)")
            }
            return
        }

        let install = runCommand("claude", ["plugin", "install", "--scope", "user", selector], timeoutSeconds: 60, logs: &logs)
        if install.exitCode == 0 || claudePluginStatusFor(marketplaceName, plugin: name).active {
            messages.append("Installed \(displayName).")
        } else {
            messages.append("Failed to install \(displayName): \(install.combinedOutput)")
        }
    }

    private static func installCodexRuntime() -> (messages: [String], logs: [String]) {
        var logs: [String] = []
        var messages = ["Synced Meee2 MCP config for Codex."]
        log(&logs, "Synced Meee2 MCP config for Codex")
        installCodexPlugin(messages: &messages, logs: &logs)
        do {
            let source = resolvePluginPath()
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("meee2", isDirectory: true)
                .appendingPathComponent("SKILL.md")
            let target = codexSkillPath()
            log(&logs, "Copying Codex skill from \(source.path) to \(target.path)")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            messages.append("Installed Meee2 Skill for Codex at \(target.path).")
            log(&logs, "Installed Meee2 Skill for Codex at \(target.path)")
        } catch {
            let message = "Failed to install Meee2 Skill for Codex: \(error.localizedDescription)"
            messages.append(message)
            log(&logs, message)
        }
        return (messages, logs)
    }

    private static func installCodexPlugin(messages: inout [String], logs: inout [String]) {
        guard let codexCommand = codexExecutablePath() else {
            let message = "Skipped Codex plugin install: Codex CLI was not found."
            messages.append(message)
            log(&logs, message)
            return
        }
        let marketplacePath = resolveMarketplacePath().path
        guard FileManager.default.fileExists(atPath: marketplacePath) else {
            let message = "Meee2 plugin marketplace was not found at \(marketplacePath)."
            messages.append(message)
            log(&logs, message)
            return
        }

        if codexMarketplaceConfigured() {
            messages.append("Meee2 Codex marketplace is already configured.")
            log(&logs, "Skipping Codex marketplace add; \(marketplaceName) is already configured")
        } else {
            let add = runCommand(codexCommand, ["plugin", "marketplace", "add", marketplacePath], timeoutSeconds: 60, logs: &logs)
            if add.exitCode == 0 || codexMarketplaceConfigured() {
                messages.append("Added Meee2 Codex marketplace.")
            } else {
                messages.append("Failed to add Codex marketplace: \(add.combinedOutput)")
            }
        }

        if codexPluginInstalled() {
            messages.append("Installed Meee2 Codex plugin.")
            log(&logs, "Skipping Codex plugin add; \(pluginSelector) is already installed")
        } else {
            let install = runCommand(codexCommand, ["plugin", "add", pluginSelector], timeoutSeconds: 60, logs: &logs)
            if install.exitCode == 0 || codexPluginInstalled() {
                messages.append("Installed Meee2 Codex plugin.")
            } else {
                messages.append("Failed to install Meee2 Codex plugin: \(install.combinedOutput)")
            }
        }
    }

    private static func resolveMarketplacePath() -> URL {
        if let raw = ProcessInfo.processInfo.environment["MEEE2_PLUGIN_MARKETPLACE"], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        if let bundled = Bundle.main.url(forResource: "meee2-agent-plugin-marketplace", withExtension: nil) {
            return bundled
        }
        // Dev fallback (non-bundled .build binary): the marketplace is vendored
        // at the repo root (meee2/meee2-agent-plugin-marketplace), so go up three
        // components from this source file (Board/ → Sources/ → repo root).
        let thisFileURL = URL(fileURLWithPath: #file)
        return thisFileURL
            .deletingLastPathComponent() // Board/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // meee2/ (repo root)
            .appendingPathComponent("meee2-agent-plugin-marketplace", isDirectory: true)
    }

    private static func resolvePluginPath() -> URL {
        resolveMarketplacePath().appendingPathComponent(pluginName, isDirectory: true)
    }

    private static func codexHome() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CODEX_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    private static func codexSkillPath() -> URL {
        codexHome()
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("meee2", isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    private static func codexMCPConfigured() -> Bool {
        let config = codexHome().appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains("[mcp_servers.meee2]")
    }

    private static func codexHooksBundled() -> Bool {
        let hooks = resolvePluginPath()
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        return FileManager.default.fileExists(atPath: hooks.path)
    }

    private static func codexMarketplaceConfigured() -> Bool {
        let config = codexHome().appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains("[marketplaces.\(marketplaceName)]")
            || text.contains("[marketplaces.\"\(marketplaceName)\"]")
    }

    /// 权威、无副作用的"meee2 官方 Claude 插件是否已装且启用"检测。
    /// MCPConfigManager 用它决定 Claude 侧是否让位给插件(mcp__plugin_meee2_meee2__*),
    /// 停止自注册一个会冲突、且 app 重建后路径/env 易陈旧的 mcp__meee2__ server。
    /// 纯文件读,不跑 `claude` 子进程,可安全用在启动路径上:
    /// installed_plugins.json 有安装记录,且 settings.json 的 enabledPlugins
    /// 没把它显式置 false(缺省视为启用)。
    /// (Codex 侧不在此合并范围 —— readiness 的 codexMCPConfigured() 依赖自注册的
    ///  [mcp_servers.meee2] 块,故 Codex 继续自注册,保持现状。)
    static func meee2ClaudePluginActive() -> Bool {
        claudePluginActiveFromState(marketplace: marketplaceName, plugin: pluginName)
    }

    private static func claudePluginActiveFromState(marketplace: String, plugin name: String) -> Bool {
        let selector = "\(name)@\(marketplace)"
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let installed = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("installed_plugins.json")
        guard
            let data = try? Data(contentsOf: installed),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = root["plugins"] as? [String: Any],
            let records = plugins[selector] as? [[String: Any]],
            !records.isEmpty
        else {
            return false
        }
        return claudePluginEnabledInSettings(selector: selector)
    }

    private static func claudePluginEnabledInSettings(selector: String) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let settings = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        if let sdata = try? Data(contentsOf: settings),
           let sroot = try? JSONSerialization.jsonObject(with: sdata) as? [String: Any],
           let enabled = sroot["enabledPlugins"] as? [String: Any],
           let flag = claudePluginEnabledInSettings(enabledPlugins: enabled, selector: selector) {
            return flag
        }
        return claudePluginEnabledInSettings(enabledPlugins: nil, selector: selector) ?? true
    }

    static func claudePluginEnabledInSettings(enabledPlugins: [String: Any]?, selector: String) -> Bool? {
        guard let flag = enabledPlugins?[selector] as? Bool else { return true }
        return flag
    }

    private static func codexPluginInstalled() -> Bool {
        let config = codexHome().appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains("[plugins.\"\(pluginSelector)\"]")
            || text.contains("[plugins.\(pluginSelector)]")
    }

    private static func claudePluginInstalled() -> Bool {
        claudePluginInstalledFor(marketplaceName, plugin: pluginName)
    }

    private static func claudePluginInstalledFor(_ marketplace: String, plugin name: String = pluginName) -> Bool {
        claudePluginStatusFor(marketplace, plugin: name).installed
    }

    private static func claudePluginStatusFor(_ marketplace: String, plugin name: String = pluginName) -> ClaudePluginInstallStatus {
        let selector = "\(name)@\(marketplace)"
        let result = runCommand("claude", ["plugin", "list", "--json"], timeoutSeconds: 3)
        if result.exitCode == 0,
           let listed = claudePluginListStatus(result.stdout, containsPlugin: name, marketplace: marketplace) {
            return ClaudePluginInstallStatus(
                installed: listed.installed,
                enabled: listed.enabled && claudePluginEnabledInSettings(selector: selector)
            )
        }
        let cacheInstalled = claudePluginCacheExists(marketplace: marketplace, plugin: name)
        return ClaudePluginInstallStatus(
            installed: cacheInstalled,
            enabled: cacheInstalled && claudePluginEnabledInSettings(selector: selector)
        )
    }

    private static func claudePluginCacheExists(marketplace: String, plugin name: String = pluginName) -> Bool {
        let cacheRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(marketplace, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) else {
            return false
        }
        return versions.contains { version in
            let pluginDir = cacheRoot.appendingPathComponent(version, isDirectory: true)
            return FileManager.default.fileExists(atPath: pluginDir.path)
        }
    }

    private static func claudeMarketplaceConfigured() -> Bool {
        claudeMarketplaceConfigured(marketplaceName)
    }

    private static func claudeMarketplaceConfigured(_ marketplace: String) -> Bool {
        let result = runCommand("claude", ["plugin", "marketplace", "list", "--json"], timeoutSeconds: 3)
        guard result.exitCode == 0 else { return false }
        return result.stdout.contains("\"name\":\"\(marketplace)\"")
            || result.stdout.contains("\"name\": \"\(marketplace)\"")
    }

    static func claudePluginListStatus(
        _ stdout: String,
        containsPlugin name: String,
        marketplace: String
    ) -> ClaudePluginInstallStatus? {
        if let data = stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return jsonClaudePluginStatus(json, name: name, marketplace: marketplace)
        }
        guard pluginListText(stdout, containsQualifiedPlugin: "\(name)@\(marketplace)") else {
            return nil
        }
        return ClaudePluginInstallStatus(installed: true, enabled: true)
    }

    private static func pluginListText(_ stdout: String, containsQualifiedPlugin qualified: String) -> Bool {
        let delimiters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'`[],{}():"))
        return stdout
            .components(separatedBy: delimiters)
            .contains(qualified)
    }

    private static func jsonClaudePluginStatus(_ value: Any, name: String, marketplace: String) -> ClaudePluginInstallStatus? {
        if let array = value as? [Any] {
            for item in array {
                if let status = jsonClaudePluginStatus(item, name: name, marketplace: marketplace) {
                    return status
                }
            }
            return nil
        }
        guard let dict = value as? [String: Any] else { return nil }

        let strings = dict.compactMapValues { $0 as? String }
        let qualified = "\(name)@\(marketplace)"
        let qualifiedKeys = ["id", "identifier", "ref", "plugin", "pluginRef", "qualifiedName"]
        if qualifiedKeys.contains(where: { strings[$0] == qualified }) {
            return ClaudePluginInstallStatus(installed: true, enabled: dict["enabled"] as? Bool ?? true)
        }

        let nameMatches = strings["name"] == name || strings["pluginName"] == name
        let marketplaceMatches =
            strings["marketplace"] == marketplace
            || strings["marketplaceName"] == marketplace
            || strings["sourceMarketplace"] == marketplace
        if nameMatches && marketplaceMatches {
            return ClaudePluginInstallStatus(installed: true, enabled: dict["enabled"] as? Bool ?? true)
        }

        for nested in dict.values {
            if let status = jsonClaudePluginStatus(nested, name: name, marketplace: marketplace) {
                return status
            }
        }
        return nil
    }

    private static func commandPath(_ command: String) -> String? {
        let result = runCommand("/usr/bin/env", ["which", command], timeoutSeconds: 3)
        if result.exitCode == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }
        return fallbackCommandPath(command)
    }

    private static func fallbackCommandPath(_ command: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/bin")
                .appendingPathComponent(command)
                .path,
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func fallbackCodexPath() -> String? {
        let path = "/Applications/Codex.app/Contents/Resources/codex"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func codexExecutablePath() -> String? {
        commandPath("codex") ?? fallbackCodexPath()
    }

    private static func appPath(bundleIdentifier: String, fallback: String) -> String? {
        let result = runCommand("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"], timeoutSeconds: 3)
        let found = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasSuffix(".app") && FileManager.default.fileExists(atPath: $0) }
        if let found { return found }
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    private static func runCommand(
        _ command: String,
        _ args: [String],
        timeoutSeconds: TimeInterval = 20,
        logs: inout [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String, combinedOutput: String) {
        log(&logs, "$ \(shellCommand(command, args))")
        let process = Process()
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            stdin.fileHandleForWriting.closeFile()
        } catch {
            log(&logs, "spawn failed: \(error.localizedDescription)")
            return (-1, "", error.localizedDescription, error.localizedDescription)
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            let message = "command timed out after \(Int(timeoutSeconds))s"
            log(&logs, message)
            return (-1, "", message, message)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [out, err]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        log(&logs, "exit \(process.terminationStatus)")
        if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log(&logs, "stdout:\n\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log(&logs, "stderr:\n\(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (process.terminationStatus, out, err, combined)
    }

    private static func runCommand(
        _ command: String,
        _ args: [String],
        timeoutSeconds: TimeInterval = 20
    ) -> (exitCode: Int32, stdout: String, stderr: String, combinedOutput: String) {
        var logs: [String] = []
        return runCommand(command, args, timeoutSeconds: timeoutSeconds, logs: &logs)
    }

    private static func log(_ logs: inout [String], _ message: String) {
        let line = "[Meee2AgentRuntime] \(message)"
        logs.append(line)
        NSLog(line)
    }

    private static func shellCommand(_ command: String, _ args: [String]) -> String {
        ([command] + args).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ raw: String) -> String {
        if raw.range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return raw
        }
        return "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
