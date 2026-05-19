import Foundation

// Pattern A of agent-integration one-click install
// (see meee2-workspace/doc/agent-integration-one-click-install.md).
//
// Drives the actual install of a catalog integration into the local agents:
//  · Claude Code: shells out `claude mcp add --transport http <id> <url>`.
//  · Codex:       upserts `[mcp_servers.<id>]` in `~/.codex/config.toml` with
//                 the `mcp-remote` stdio shim bridging to the same URL.
//
// Only handles `.remoteHttp` in this pass — `.localStdio` (token-based) and
// `.unsupported` throw; the caller falls back to the runbook flow.

enum IntegrationInstallError: Error, LocalizedError {
    case unknownIntegration(String)
    case unsupported(reason: String)
    case notImplementedYet(kind: String)

    var errorDescription: String? {
        switch self {
        case .unknownIntegration(let id):
            return "unknown integration: \(id)"
        case .unsupported(let reason):
            return reason
        case .notImplementedYet(let kind):
            return "install kind `\(kind)` not implemented yet — use the runbook flow."
        }
    }
}

struct IntegrationInstallResult: Encodable {
    let integrationId: String
    let claudeOK: Bool
    let codexOK: Bool
    /// Human-readable progress lines — surfaced in the UI after install.
    let messages: [String]
}

enum IntegrationInstaller {
    /// Install the integration's MCP server into Claude Code + Codex.
    /// Pattern A only — `.remoteHttp` URLs.
    static func install(integrationId: String) throws -> IntegrationInstallResult {
        guard let descriptor = IntegrationCatalog.all.first(where: { $0.id == integrationId }) else {
            throw IntegrationInstallError.unknownIntegration(integrationId)
        }
        switch descriptor.install {
        case .remoteHttp(let url):
            return installRemoteHttp(id: descriptor.id, name: descriptor.name, url: url)
        case .localStdio:
            throw IntegrationInstallError.notImplementedYet(kind: "localStdio")
        case .unsupported(let reason):
            throw IntegrationInstallError.unsupported(reason: reason)
        }
    }

    private static func installRemoteHttp(id: String, name: String, url: String) -> IntegrationInstallResult {
        var messages: [String] = []

        // Claude Code: native --transport http registration via the CLI.
        let claude = shell("claude", ["mcp", "add", "--transport", "http", id, url])
        let claudeOK = claude.code == 0
        if claudeOK {
            messages.append("Claude Code: registered \(name) via `claude mcp add --transport http`.")
        } else {
            let detail = claude.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let why = detail.isEmpty ? "exit \(claude.code)" : detail
            messages.append(
                "Claude Code: `claude mcp add` failed (\(why)). " +
                "Run it manually: claude mcp add --transport http \(id) \(url)"
            )
        }

        // Codex: stdio bridge via the `mcp-remote` shim — Codex's MCP client
        // does not yet speak HTTP transport directly.
        var codexOK = false
        do {
            try MCPConfigManager.shared.upsertCodexMCPServer(
                name: id,
                command: "npx",
                args: ["-y", "mcp-remote", url]
            )
            codexOK = true
            messages.append("Codex: wrote ~/.codex/config.toml [mcp_servers.\(id)] via mcp-remote shim.")
        } catch {
            messages.append("Codex: failed to write config.toml — \(error.localizedDescription)")
        }

        messages.append("OAuth will be triggered automatically the first time an agent calls a \(name) tool — no token paste required.")

        return IntegrationInstallResult(
            integrationId: id, claudeOK: claudeOK, codexOK: codexOK, messages: messages
        )
    }

    /// PATH-resolved subprocess. Returns exit code + stdout + stderr.
    private static func shell(_ name: String, _ args: [String]) -> (code: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [name] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", "spawn failed: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
