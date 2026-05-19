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
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
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
