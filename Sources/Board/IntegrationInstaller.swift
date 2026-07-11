import Foundation

// Pattern A of agent-integration one-click install
// (see meee2-workspace/doc/agent-integration-one-click-install.md).
//
// Drives the actual install of a catalog integration into the local agents:
//  · Claude Code: shells out `claude mcp add --transport http <id> <url>`.
//  · Codex:       upserts `[mcp_servers.<id>]` in `~/.codex/config.toml` with
//                 the `mcp-remote` stdio shim bridging to the same URL.
//
enum IntegrationInstallError: Error, LocalizedError {
    case unknownIntegration(String)

    var errorDescription: String? {
        switch self {
        case .unknownIntegration(let id):
            return "unknown integration: \(id)"
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
        case .localStdio(let command, let args, let envKeys):
            return installLocalStdio(id: descriptor.id, name: descriptor.name, command: command, args: args, envKeys: envKeys)
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

    // MARK: - localStdio (community stdio MCP server) install

    /// Per-connector data dir under `~/.meee2/connectors/<id>/` — holds the
    /// user-supplied OAuth `credentials.json` and the server-cached `token.json`
    /// for stdio connectors that authenticate via the server's own OAuth flow.
    static func connectorDir(_ integrationId: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent("connectors", isDirectory: true)
            .appendingPathComponent(integrationId, isDirectory: true)
    }

    /// Install a community stdio MCP server (e.g. google-sheets via uvx, lark via
    /// npx) into Claude Code (`~/.claude.json`) + Codex (`config.toml`), injecting
    /// the credential env. Mirrors the remoteHttp path's two-agent registration;
    /// runtime (uv / node) availability is surfaced rather than failed silently.
    private static func installLocalStdio(
        id: String, name: String, command: String, args: [String], envKeys: [String]
    ) -> IntegrationInstallResult {
        var messages: [String] = []

        // Resolve credential env. CREDENTIALS_PATH/TOKEN_PATH map to the
        // per-connector dir (OAuth-via-server model); other keys are read from
        // ccops / environment. Missing required values are surfaced, not fatal.
        let resolved = resolveStdioEnv(integrationId: id, envKeys: envKeys)
        messages.append(contentsOf: resolved.messages)

        // Runtime preflight: uvx for Python servers, node for npx servers.
        if command == "uvx" || command == "uv" {
            if selectUvxBin() == nil {
                messages.append(
                    "Skipped — `uv`/`uvx` not on PATH (the \(name) server is Python). " +
                    "Install it (`curl -LsSf https://astral.sh/uv/install.sh | sh`) and re-run Connect."
                )
                return IntegrationInstallResult(integrationId: id, claudeOK: false, codexOK: false, messages: messages)
            }
        } else if command == "npx", selectModernNodeBin() == nil {
            messages.append(
                "Skipped — need Node ≥ 20 on PATH for the \(name) npx server. " +
                "Install Node 20+ (`brew install node`) and re-run Connect."
            )
            return IntegrationInstallResult(integrationId: id, claudeOK: false, codexOK: false, messages: messages)
        }

        // Claude Code: write the stdio entry (+ env) into ~/.claude.json
        // mcpServers (user scope — visible to every project), via the same
        // read→merge→atomic-write path as meee2's self-registration.
        let claudeOK = MCPConfigManager.shared.upsertClaudeStdioMCPServer(
            name: id, command: command, args: args, env: resolved.env
        )
        messages.append(claudeOK
            ? "Claude Code: registered \(name) stdio MCP server in ~/.claude.json (user scope)."
            : "Claude Code: failed to write ~/.claude.json — see logs.")

        // Codex: same server + env into ~/.codex/config.toml.
        var codexOK = false
        do {
            try MCPConfigManager.shared.upsertCodexMCPServer(name: id, command: command, args: args, env: resolved.env)
            codexOK = true
            messages.append("Codex: wrote ~/.codex/config.toml [mcp_servers.\(id)].")
        } catch {
            messages.append("Codex: failed to write config.toml — \(error.localizedDescription)")
        }

        if !resolved.missing.isEmpty {
            messages.append(
                "Pending credentials: \(resolved.missing.joined(separator: ", ")). " +
                "The connector is registered but won't authenticate until these are provided."
            )
        }

        return IntegrationInstallResult(integrationId: id, claudeOK: claudeOK, codexOK: codexOK, messages: messages)
    }

    /// Resolve env values for a localStdio server's declared `envKeys`.
    /// - `CREDENTIALS_PATH` / `TOKEN_PATH`: per-connector dir paths (OAuth model).
    ///   CREDENTIALS_PATH must already exist (user uploaded it) — else `missing`.
    ///   TOKEN_PATH need not exist yet (the server's OAuth flow creates it).
    /// - other keys: read from `ccops get <KEY>` or the process environment.
    private static func resolveStdioEnv(
        integrationId: String, envKeys: [String]
    ) -> (env: [String: String], missing: [String], messages: [String]) {
        var env: [String: String] = [:]
        var missing: [String] = []
        var messages: [String] = []
        let dir = connectorDir(integrationId)
        for key in envKeys {
            switch key {
            case "CREDENTIALS_PATH":
                let path = dir.appendingPathComponent("credentials.json").path
                if FileManager.default.fileExists(atPath: path) {
                    env[key] = path
                } else {
                    missing.append("credentials.json (OAuth client) — upload it in Connect first")
                }
            case "TOKEN_PATH":
                env[key] = dir.appendingPathComponent("token.json").path
            default:
                if let value = readSecret(key), !value.isEmpty {
                    env[key] = value
                } else {
                    missing.append(key)
                }
            }
        }
        if !env.isEmpty {
            messages.append("Injected credential env: \(env.keys.sorted().joined(separator: ", ")).")
        }
        return (env, missing, messages)
    }

    /// Best-effort secret read for non-path env keys: `ccops get <KEY>` then the
    /// process environment. Returns nil if neither has it.
    private static func readSecret(_ key: String) -> String? {
        let ccops = shell("ccops", ["get", key])
        let value = ccops.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if ccops.code == 0, !value.isEmpty { return value }
        return ProcessInfo.processInfo.environment[key]
    }

    /// Pick a `uvx` binary: PATH first, then `~/.local/bin`, then homebrew.
    /// nil → uv isn't installed (the Python stdio servers can't run).
    private static func selectUvxBin() -> String? {
        let which = shell("which", ["uvx"])
        let pathUvx = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if which.code == 0, !pathUvx.isEmpty { return pathUvx }
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/uvx").path,
            "/opt/homebrew/bin/uvx",
            "/usr/local/bin/uvx"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - localStdio pre-auth (provoke the server's own OAuth at Connect time)

    struct PreAuthResult: Encodable {
        /// already | provoked | needs_credentials | needs_runtime | unsupported | spawn_failed
        let status: String
        let message: String
    }

    /// Provoke a localStdio connector's server-managed OAuth browser flow NOW,
    /// at Connect time, so the cached token exists before any headless dispatched
    /// session tries to write — otherwise that first write's browser prompt would
    /// land in a session that can't surface it.
    ///
    /// The server (e.g. xing5/mcp-google-sheets) has no auth bootstrap subcommand;
    /// its OAuth `InstalledAppFlow` fires when credentials are first loaded for an
    /// API call. So we spawn it, speak a minimal MCP stdio handshake, list tools,
    /// and call the first tool — which makes the server build its Google client,
    /// find no token, and open the browser. We then poll for token.json.
    ///
    /// Best-effort: bounded, detached, and self-reaping. If the provoke doesn't
    /// land, the fallback is unchanged (first real use opens the browser). This
    /// path needs live smoke (real uv + credentials.json + a Google account) — it
    /// cannot be exercised in CI.
    @discardableResult
    static func triggerStdioPreAuth(integrationId: String) -> PreAuthResult {
        guard let descriptor = IntegrationCatalog.all.first(where: { $0.id == integrationId }),
              case let .localStdio(command, args, _) = descriptor.install else {
            return PreAuthResult(status: "unsupported", message: "integration `\(integrationId)` is not a localStdio connector.")
        }
        let dir = connectorDir(integrationId)
        let tokenPath = dir.appendingPathComponent("token.json").path
        let credsPath = dir.appendingPathComponent("credentials.json").path
        if FileManager.default.fileExists(atPath: tokenPath) {
            return PreAuthResult(status: "already", message: "Already authorized — token is cached; dispatched sessions will reuse it.")
        }
        guard FileManager.default.fileExists(atPath: credsPath) else {
            return PreAuthResult(status: "needs_credentials", message: "Upload your OAuth credentials.json first, then Connect.")
        }
        // Resolve the runtime binary so the spawned `env` finds it.
        let runtimeDir: String?
        if command == "uvx" || command == "uv" {
            guard let uvx = selectUvxBin() else {
                return PreAuthResult(status: "needs_runtime", message: "`uv`/`uvx` not installed — `curl -LsSf https://astral.sh/uv/install.sh | sh`, then retry.")
            }
            runtimeDir = (uvx as NSString).deletingLastPathComponent
        } else if command == "npx" {
            guard let node = selectModernNodeBin() else {
                return PreAuthResult(status: "needs_runtime", message: "Need Node ≥ 20 on PATH for this server.")
            }
            runtimeDir = (node as NSString).deletingLastPathComponent
        } else {
            runtimeDir = nil
        }

        let logPath = "/tmp/meee2-stdio-preauth-\(integrationId).log"
        let resolved = resolveStdioEnv(integrationId: integrationId, envKeys: ["CREDENTIALS_PATH", "TOKEN_PATH"])
        let spawned = spawnStdioPreAuthDriver(
            command: command, args: args, env: resolved.env, runtimeDir: runtimeDir, logPath: logPath
        )
        guard spawned else {
            return PreAuthResult(status: "spawn_failed", message: "Could not launch \(descriptor.name) server for pre-auth — see \(logPath). First real use will trigger the browser instead.")
        }
        return PreAuthResult(
            status: "provoked",
            message: "Authorizing \(descriptor.name) — a browser window should open for Google consent. Approve it; the token caches locally so dispatched sessions write without prompting. If no browser opens, the first sheet write will trigger it."
        )
    }

    /// Spawn the stdio MCP server detached and drive a minimal handshake +
    /// first tool call to provoke its OAuth. Output → logPath (so pipes don't
    /// block and we can debug). Self-reaps after 5 minutes.
    @discardableResult
    private static func spawnStdioPreAuthDriver(
        command: String, args: [String], env: [String: String], runtimeDir: String?, logPath: String
    ) -> Bool {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        var processEnv = ProcessInfo.processInfo.environment
        if let runtimeDir { processEnv["PATH"] = "\(runtimeDir):\(processEnv["PATH"] ?? "")" }
        for (k, v) in env { processEnv[k] = v }
        process.environment = processEnv

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            return false
        }

        // Drive the MCP handshake on a background thread: initialize →
        // initialized → tools/list → call the first tool (empty args). The
        // server builds its Google client on that call, finds no token, and
        // runs InstalledAppFlow (opens the browser). We don't parse responses
        // strictly — newline-delimited JSON-RPC, fire the sequence with small
        // gaps so the server processes each.
        let handle = stdinPipe.fileHandleForWriting
        DispatchQueue.global().async {
            func send(_ json: String) {
                if let data = (json + "\n").data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
            }
            send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"meee2-preauth","version":"1.0"}}}"#)
            Thread.sleep(forTimeInterval: 1.0)
            send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            Thread.sleep(forTimeInterval: 0.5)
            send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            Thread.sleep(forTimeInterval: 1.0)
            // Probe a Google-touching tool to force credential load → OAuth.
            // `list_spreadsheets` is xing5/mcp-google-sheets's no-required-arg
            // listing tool; harmless if absent (server returns method error,
            // no state change). Try a couple of common names.
            for tool in ["list_spreadsheets", "list_sheets", "get_spreadsheet_info"] {
                send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":{}}}")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // Self-reap: terminate once token.json appears (auth done) or after a
        // generous window for the user to complete browser consent.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            if process.isRunning { process.terminate() }
        }
        return true
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
        case .localStdio:
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
