import Foundation

// P3 of agent-integration-detection. Generates an agent-agnostic Markdown
// runbook for connecting an integration, plus the per-agent command that hands
// the runbook to an agent to execute. Decision C: a runbook, not a Claude Code
// skill — so the same artifact drives Claude Code, Codex, or a human.

struct IntegrationRunbookResult: Encodable {
    let integrationId: String
    let path: String
    let content: String
    /// agent id → shell command that drives that agent through the runbook.
    let dispatch: [String: String]
}

enum IntegrationRunbookError: Error, LocalizedError {
    case unknownIntegration(String)
    var errorDescription: String? {
        switch self {
        case .unknownIntegration(let id): return "unknown integration: \(id)"
        }
    }
}

enum IntegrationRunbookGenerator {
    /// Generate the runbook for `integrationId`, write it to
    /// `~/.meee2/runbooks/connect-<id>.md`, return path + content + dispatch.
    static func generate(integrationId: String) throws -> IntegrationRunbookResult {
        guard let descriptor = IntegrationCatalog.all.first(where: { $0.id == integrationId }) else {
            throw IntegrationRunbookError.unknownIntegration(integrationId)
        }
        let statuses = IntegrationDetector.scan().filter { $0.integrationId == integrationId }
        let claude = statuses.first { $0.agent == "claude-code" }
        let codex = statuses.first { $0.agent == "codex" }

        let content = renderMarkdown(descriptor: descriptor, claude: claude, codex: codex)
        let path = try writeRunbook(integrationId: integrationId, content: content)
        let dispatch = [
            "claude-code": "claude \"Read \(path) and follow it to connect the \(descriptor.name) integration.\"",
            "codex": "codex \"Read \(path) and follow it to connect the \(descriptor.name) integration.\""
        ]
        return IntegrationRunbookResult(
            integrationId: integrationId, path: path, content: content, dispatch: dispatch
        )
    }

    private static func writeRunbook(integrationId: String, content: String) throws -> String {
        let dir = MEEE2Env.home
            .appendingPathComponent("runbooks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("connect-\(integrationId).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private static func renderMarkdown(
        descriptor: IntegrationDescriptor,
        claude: AgentIntegrationStatus?,
        codex: AgentIntegrationStatus?
    ) -> String {
        var lines: [String] = []
        lines.append("# Runbook — 接入 \(descriptor.name) integration")
        lines.append("")
        lines.append("## 当前状态")
        for (label, status) in [("Claude Code", claude), ("Codex", codex)] {
            if let status {
                lines.append("- \(label):`\(status.state.rawValue)` —— \(status.evidence)")
            } else {
                lines.append("- \(label):未知")
            }
        }
        lines.append("")
        lines.append("## 步骤")
        lines.append("")

        var stepNumber = 1

        // OAuth-pending path takes priority — the MCP server is in config,
        // user already clicked Install, the only thing left is the in-product
        // OAuth handshake. Render this as the primary (and usually only) step.
        let oauthPending = (claude?.state == .needsAuth) || (codex?.state == .needsAuth)
        if oauthPending {
            lines.append("### \(stepNumber). 完成 OAuth 授权")
            stepNumber += 1
            lines.append("MCP server 已装好,但还没完成 OAuth —— 当前只看得到 `authenticate` / `complete_authentication` 这类引导工具,真正的查询/操作工具会在授权完成后出现。")
            lines.append("")
            lines.append("- **在 Claude Code 里** —— 启动一个 session 后输入:")
            lines.append("  ```")
            lines.append("  /mcp")
            lines.append("  ```")
            lines.append("  在弹出的列表里选 `\(descriptor.id)`,按提示在浏览器完成授权,关掉浏览器回到 Claude。")
            lines.append("- **或** 让 agent 直接调用 `\(descriptor.id)` 的 authenticate tool:")
            lines.append("  > Please call the \(descriptor.name) `authenticate` tool, complete the OAuth flow, and confirm it succeeded.")
            lines.append("- **Codex** —— Codex 走 `mcp-remote` shim,首次使用任一 \(descriptor.name) tool 时会自动弹 OAuth(终端里给出回调 URL)。先跑一个无副作用的工具触发它。")
            lines.append("")
            lines.append("完成后回 meee2 的 Integrations 页点「Re-scan」,状态应从 `needs_auth` 变成 `connected`。")
            lines.append("")
            lines.append("### \(stepNumber). 验证")
            lines.append("- 让 agent 调一个真正的 \(descriptor.name) tool 试试(不是 `authenticate`)。")
            lines.append("- 或在 Claude 里 `/mcp` 查看 `\(descriptor.id)` 的 tool 列表,确认已经不止 auth 工具。")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        let claudeMCPMissing = (claude?.mcpConfigured == false)
        let codexMCPMissing = (codex?.mcpConfigured == false)
        if claudeMCPMissing || codexMCPMissing {
            lines.append("### \(stepNumber). 配置 MCP server")
            stepNumber += 1
            if claudeMCPMissing {
                lines.append("- **Claude Code** —— 加 \(descriptor.name) 的 MCP server:")
                lines.append("  ```")
                lines.append("  claude mcp add \(descriptor.id) -- <\(descriptor.name) 官方 MCP server 的启动命令>")
                lines.append("  ```")
                lines.append("  或直接在 `~/.claude.json` 的 `mcpServers` 里加一项 `\(descriptor.id)`。")
            }
            if codexMCPMissing {
                lines.append("- **Codex** —— 在 `~/.codex/config.toml` 加:")
                lines.append("  ```toml")
                lines.append("  [mcp_servers.\(descriptor.id)]")
                lines.append("  command = \"...\"")
                lines.append("  args = [...]")
                lines.append("  ```")
            }
            lines.append("")
        }

        let credentialMissing = !descriptor.credentialProbes.isEmpty
            && (claude?.credentialPresent == false)
        if credentialMissing {
            lines.append("### \(stepNumber). 配置凭证")
            stepNumber += 1
            if let ccopsKey = descriptor.credentialProbes.first(where: { $0.kind == .ccops })?.value {
                lines.append("- 用 `ccops`(macOS Keychain 的密钥管理工具)存凭证:")
                lines.append("  ```")
                lines.append("  ccops set \(ccopsKey) --value \"<your token>\"")
                lines.append("  ```")
            }
            lines.append("- \(descriptor.setupHint)")
            lines.append("")
        }

        lines.append("### \(stepNumber). 验证")
        lines.append("- 回 meee2 的 Integrations 页面点「Re-scan」,确认 \(descriptor.name) 变 connected。")
        lines.append("- 或让 agent 调用一个 \(descriptor.name) 的 tool 试试。")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
