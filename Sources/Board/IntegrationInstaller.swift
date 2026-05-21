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
        case .claudePlugin(let marketplace, let name):
            return installClaudePlugin(id: descriptor.id, displayName: descriptor.name, marketplace: marketplace, pluginName: name)
        case .remoteHttp(let url):
            return installRemoteHttp(id: descriptor.id, name: descriptor.name, url: url)
        case .localStdio:
            throw IntegrationInstallError.notImplementedYet(kind: "localStdio")
        case .unsupported(let reason):
            throw IntegrationInstallError.unsupported(reason: reason)
        }
    }

    /// Install via Claude Code's plugin marketplace —— `claude plugin install
    /// <name>@<marketplace>`. Claude-side only (Codex has no plugin concept);
    /// the plugin's own setup flow handles auth and any required MCP config.
    private static func installClaudePlugin(
        id: String, displayName: String, marketplace: String, pluginName: String
    ) -> IntegrationInstallResult {
        var messages: [String] = []
        let result = shell("claude", ["plugin", "install", "\(pluginName)@\(marketplace)"])
        let claudeOK = result.code == 0
        if claudeOK {
            messages.append("Claude Code: installed plugin \(pluginName)@\(marketplace) — skills, MCP server, and commands all wired.")
            let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedStdout.isEmpty { messages.append("\(trimmedStdout)") }
        } else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let why = detail.isEmpty ? "exit \(result.code)" : detail
            messages.append(
                "Claude Code: `claude plugin install` failed (\(why)). " +
                "Run manually: claude plugin install \(pluginName)@\(marketplace)"
            )
        }
        messages.append("Codex: plugins are Claude-Code-only — no Codex config was written. The plugin will auth itself on first use in Claude Code.")
        return IntegrationInstallResult(
            integrationId: id, claudeOK: claudeOK, codexOK: false, messages: messages
        )
    }

    private static func installRemoteHttp(id: String, name: String, url: String) -> IntegrationInstallResult {
        var messages: [String] = []

        // Claude Code: native --transport http registration via the CLI.
        // `--scope user` writes to the top-level mcpServers in ~/.claude.json
        // so the install is visible to every project, not the cwd one.
        let claude = shell("claude", ["mcp", "add", "--scope", "user", "--transport", "http", id, url])
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

        // Kick off OAuth NOW so the user authorizes during the install flow,
        // not later when an agent first calls a tool. mcp-remote (the same
        // stdio shim we just wired Codex through) handles the OAuth dance —
        // first start = open browser, user authorizes, token cached in
        // ~/.mcp-auth/. We spawn it detached; the meee2 process doesn't wait.
        if let nodeBin = selectModernNodeBin() {
            let logPath = "/tmp/meee2-mcp-auth-\(id).log"
            let oauthSpawned = spawnOAuthHandshake(url: url, nodeBin: nodeBin, logPath: logPath)
            if oauthSpawned {
                let authUrl = waitForAuthURL(in: logPath, timeout: 5.0)
                if let authUrl { openInBrowser(authUrl) }
                messages.append(
                    "Browser is opening for \(name) OAuth — click Allow there and you're done. " +
                    "Token caches to ~/.mcp-auth/ so both agents pick it up on next use."
                )
            } else {
                messages.append(
                    "Could not auto-launch mcp-remote for OAuth — first agent call to \(name) " +
                    "will trigger it instead."
                )
            }
        } else {
            messages.append(
                "Skipped OAuth pre-flight: need Node ≥ 20 on PATH for mcp-remote. " +
                "Install Node 20+ (`brew install node` or `nvm install 22`) and re-run."
            )
        }

        return IntegrationInstallResult(
            integrationId: id, claudeOK: claudeOK, codexOK: codexOK, messages: messages
        )
    }

    /// Resolve a catalog integration to a remote MCP URL we can run OAuth
    /// against. `.remoteHttp` gives us the URL directly; `.claudePlugin`
    /// needs the plugin's bundled `.mcp.json`. Used by the "Complete auth"
    /// one-click flow for integrations already-installed-but-OAuth-pending.
    static func resolveOAuthURL(integrationId: String) -> String? {
        guard let descriptor = IntegrationCatalog.all.first(where: { $0.id == integrationId }) else {
            return nil
        }
        switch descriptor.install {
        case .remoteHttp(let url):
            return url
        case .claudePlugin(_, let name):
            if case .remoteHttp(let url) = MCPToolListProbe.resolveClaudePluginTransport(pluginName: name) {
                return url
            }
            return nil
        case .localStdio, .unsupported:
            return nil
        }
    }

    /// One-click OAuth result — `spawned` says the shim launched, `authUrl`
    /// is the in-browser URL extracted from mcp-remote's startup output
    /// (Frontend can render it as a "Click here if browser didn't open"
    /// fallback). `nodeBin` is the Node binary we picked so the UI / logs
    /// can explain version-mismatch failures.
    struct OAuthHandshakeResult {
        let spawned: Bool
        let authUrl: String?
        let logPath: String
        let nodeBin: String?
        let detail: String?
    }

    /// Public face of `spawnOAuthHandshake` — kicks off the browser OAuth
    /// flow for an already-installed integration whose token isn't cached
    /// yet. Captures mcp-remote's stdout/stderr so we can extract the
    /// `Please authorize this client by visiting: <url>` line and open it
    /// in the user's browser ourselves (mcp-remote's auto-open isn't
    /// reliable when meee2 spawns it from a GUI subprocess context).
    static func triggerOAuthHandshake(integrationId: String) -> OAuthHandshakeResult {
        guard let url = resolveOAuthURL(integrationId: integrationId) else {
            return OAuthHandshakeResult(
                spawned: false, authUrl: nil, logPath: "", nodeBin: nil,
                detail: "no remote MCP URL for integration `\(integrationId)`"
            )
        }
        guard let nodeBin = selectModernNodeBin() else {
            return OAuthHandshakeResult(
                spawned: false, authUrl: nil, logPath: "", nodeBin: nil,
                detail: "需要 Node ≥ 20 才能跑 mcp-remote(OAuth shim)。npx 当前版本太老。装一下:`brew install node` 或 `nvm install 22 && nvm use 22`,然后重试。"
            )
        }
        let logPath = "/tmp/meee2-mcp-auth-\(integrationId).log"
        let spawned = spawnOAuthHandshake(url: url, nodeBin: nodeBin, logPath: logPath)
        if spawned {
            MCPToolListProbe.resetCache()
            let authUrl = waitForAuthURL(in: logPath, timeout: 5.0)
            if let authUrl {
                _ = openInBrowser(authUrl)
            }
            return OAuthHandshakeResult(
                spawned: true, authUrl: authUrl, logPath: logPath, nodeBin: nodeBin,
                detail: authUrl == nil
                    ? "mcp-remote 启动了但 5s 内没打印 OAuth URL,看一下 \(logPath)"
                    : nil
            )
        }
        return OAuthHandshakeResult(
            spawned: false, authUrl: nil, logPath: logPath, nodeBin: nodeBin,
            detail: "mcp-remote 启动失败,看 \(logPath)"
        )
    }

    /// Pick a Node binary whose major version is ≥ 20. mcp-remote's undici
    /// dependency hard-fails on Node 18 (`ReferenceError: File is not defined`).
    /// Order of preference: PATH `node` (so user's nvm-current wins), then a
    /// scan of `~/.nvm/versions/node/v*/bin/node` for the highest available,
    /// then `/opt/homebrew/bin/node`.
    private static func selectModernNodeBin() -> String? {
        var candidates: [String] = []
        // (a) PATH `node`
        let which = shell("which", ["node"])
        let pathNode = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if which.code == 0, !pathNode.isEmpty { candidates.append(pathNode) }
        // (b) nvm versions, highest first
        let nvmDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".nvm").appendingPathComponent("versions").appendingPathComponent("node")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDir.path) {
            let sorted = entries.filter { $0.hasPrefix("v") }.sorted(by: nodeVersionDescending)
            for entry in sorted {
                candidates.append(nvmDir.appendingPathComponent(entry).appendingPathComponent("bin").appendingPathComponent("node").path)
            }
        }
        // (c) homebrew
        candidates.append("/opt/homebrew/bin/node")
        // (d) /usr/local/bin (Intel homebrew)
        candidates.append("/usr/local/bin/node")

        for bin in candidates {
            guard FileManager.default.isExecutableFile(atPath: bin) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = ["--version"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do { try process.run() } catch { continue }
            process.waitUntilExit()
            let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // raw like "v22.5.1\n"
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let majorStr = trimmed.split(separator: ".").first.map(String.init) ?? ""
            if let major = Int(majorStr), major >= 20 { return bin }
        }
        return nil
    }

    /// Sort "v24.13.0" descending — split on '.', compare numerically.
    private static func nodeVersionDescending(_ a: String, _ b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { $0 == "v" })
                .split(separator: ".")
                .compactMap { Int($0) }
        }
        let pa = parts(a), pb = parts(b)
        for (x, y) in zip(pa, pb) where x != y { return x > y }
        return pa.count > pb.count
    }

    /// Block up to `timeout` seconds polling `logPath` for the OAuth URL that
    /// mcp-remote prints right after spawn. Returns the first matching URL.
    private static func waitForAuthURL(in logPath: String, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        // The line is `Please authorize this client by visiting:` followed by
        // a URL on the NEXT line. We just look for the first https URL that
        // contains `/authorize?`.
        let pattern = try? NSRegularExpression(
            pattern: #"(https?://[^\s'"<>]+/authorize\?[^\s'"<>]+)"#
        )
        while Date() < deadline {
            if let text = try? String(contentsOfFile: logPath, encoding: .utf8),
               let pattern,
               let match = pattern.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
               ),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// Open a URL in the user's default browser via `/usr/bin/open`. Safe
    /// from any process context — doesn't depend on LaunchServices being
    /// reachable from our subprocess inheritance chain.
    @discardableResult
    private static func openInBrowser(_ url: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    /// Spawn `npx -y mcp-remote <url>` detached, redirecting stdout/stderr
    /// into `logPath` (so `waitForAuthURL` can grep it, and so unread pipes
    /// don't block the child). `nodeBin` is the Node ≥ 20 binary we picked —
    /// PATH is set so its sibling `npx` runs (older PATH npx would crash
    /// in undici).
    @discardableResult
    private static func spawnOAuthHandshake(url: String, nodeBin: String, logPath: String) -> Bool {
        // Wipe the log so old auth URLs from earlier attempts don't confuse
        // the URL-extraction pass.
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: logPath, contents: Data(), attributes: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "-y", "mcp-remote", url]
        // Prepend the modern Node's directory so `npx` resolves to the
        // matching binary (mcp-remote needs Node ≥ 20 / undici needs `File`).
        let nodeDir = (nodeBin as NSString).deletingLastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(nodeDir):\(env["PATH"] ?? "")"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            return false
        }
        // Belt-and-suspenders: if it's still running 5 minutes later (long
        // past any reasonable OAuth flow), reap it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            if process.isRunning { process.terminate() }
        }
        return true
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
