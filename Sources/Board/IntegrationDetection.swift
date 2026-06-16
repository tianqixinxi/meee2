import Foundation

// P1 of agent-integration-detection
// (see meee2-workspace/doc/agent-integration-detection-plan.md).
//
// Detects which integrations each local agent (Claude Code / Codex) has wired
// up — via MCP-server config and/or credential presence — and exposes the
// agent × integration matrix. Pure detection: reads config files + probes
// credentials, never writes anything.

// MARK: - Model

/// Connection state of one integration for one agent.
enum IntegrationConnState: String, Codable, Equatable {
    /// Every applicable channel satisfied (MCP server + credential, or — for an
    /// MCP-only integration — just the MCP server) **and**, for OAuth-shaped
    /// remote servers, the OAuth handshake has been completed (the server
    /// exposes real tools, not only `authenticate` / `complete_authentication`).
    case connected
    /// Some but not all channels satisfied (e.g. MCP server configured but the
    /// credential is missing).
    case partial
    /// MCP server is configured but OAuth hasn't been completed yet — the
    /// server only exposes its auth-bootstrap tools. User needs to run the
    /// integration's `/mcp` OAuth flow or call its `authenticate` tool.
    case needsAuth = "needs_auth"
    /// No channel satisfied.
    case missing
}

/// How to tell a credential-based integration is set up.
struct IntegrationCredentialProbe: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case ccops      // `ccops has <value>` exits 0
        case env        // environment variable <value> is non-empty
        case cliAuth    // shell command line <value> exits 0
    }
    var kind: Kind
    var value: String
}

/// How a given integration is installed. The catalog stores this structured
/// so `IntegrationInstaller` can drive a true one-click install (Pattern A —
/// remote OAuth) instead of generating a placeholder-filled runbook.
enum IntegrationInstall: Equatable {
    /// Anthropic / community plugin marketplace install —— `claude plugin
    /// install <name>@<marketplace>`. Bundle (skill + MCP server + commands)
    /// handled by Claude Code; auth happens inside the plugin's own flow.
    /// Claude-side only — Codex doesn't have a plugin concept.
    case claudePlugin(marketplace: String, name: String)
    /// Remote MCP server — Claude Code uses `--transport http` natively;
    /// Codex bridges via the `mcp-remote` stdio shim. OAuth pops on first use.
    case remoteHttp(url: String)
    /// Local stdio MCP server (npx package). Needs env credentials.
    case localStdio(command: String, args: [String], envKeys: [String])
    /// Deliberately not supported by the installer (e.g. official package
    /// archived). `reason` is surfaced in the UI.
    case unsupported(reason: String)
}

extension IntegrationInstall: Encodable {
    private enum Keys: String, CodingKey {
        case kind, url, command, args, envKeys, reason, marketplace, name
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .claudePlugin(let marketplace, let name):
            try container.encode("claudePlugin", forKey: .kind)
            try container.encode(marketplace, forKey: .marketplace)
            try container.encode(name, forKey: .name)
        case .remoteHttp(let url):
            try container.encode("remoteHttp", forKey: .kind)
            try container.encode(url, forKey: .url)
        case .localStdio(let command, let args, let envKeys):
            try container.encode("localStdio", forKey: .kind)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(envKeys, forKey: .envKeys)
        case .unsupported(let reason):
            try container.encode("unsupported", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// One integration the catalog knows how to detect + install + guide.
struct IntegrationDescriptor: Encodable, Equatable {
    var id: String
    var name: String
    var category: String
    /// MCP server-name fragments — matched case-insensitively (substring)
    /// against the server names configured in an agent's MCP config.
    var mcpServerNames: [String]
    /// Credential probes. Empty → MCP-only integration; `connected` then needs
    /// only the MCP server.
    var credentialProbes: [IntegrationCredentialProbe]
    /// Structured install spec used by `IntegrationInstaller`.
    var install: IntegrationInstall
    /// One-line setup hint, surfaced in the runbook (Pattern B fallback).
    var setupHint: String
}

/// Response envelope for `GET /api/integrations/agent-scan`.
struct AgentScanEnvelope: Encodable {
    let agents: [String]
    let statuses: [AgentIntegrationStatus]
}

/// Detection result for one (agent, integration) cell of the matrix.
struct AgentIntegrationStatus: Encodable, Equatable {
    var agent: String              // "claude-code" | "codex"
    var integrationId: String
    var integrationName: String
    var category: String
    var state: IntegrationConnState
    var mcpConfigured: Bool
    var credentialPresent: Bool
    /// Matched signals — e.g. ["mcp:github", "ccops:GITHUB_TOKEN"].
    var via: [String]
    var evidence: String           // human-readable
    /// Install spec (mirrored from the descriptor) so the UI can pick the
    /// right primary action per row (Install vs Set up vs disabled).
    var install: IntegrationInstall
}

// MARK: - Catalog

/// Catalog of integrations. Composed (in priority order) of:
///   1. `builtin` — curated, hand-tuned descriptors (better mcpServerNames,
///      remote-OAuth URLs, etc.)
///   2. `MarketplaceCatalogLoader` — every plugin in
///      `~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json`
/// Deduped by `id` (builtin wins). Future: MCP Registry as source #3.
enum IntegrationCatalog {
    /// Snapshot of the merged catalog. Computed each call — marketplace JSON
    /// lives on local disk and scans aren't hot.
    static var all: [IntegrationDescriptor] {
        // Best-effort: refresh the registry cache in the background if it's
        // stale. The current call returns whatever is already on disk (none on
        // first run); the next scan picks up the refreshed data.
        MCPRegistryClient.refreshAsyncIfStale()

        var seen = Set<String>()
        var result: [IntegrationDescriptor] = []
        for descriptor in builtin {
            seen.insert(descriptor.id)
            result.append(descriptor)
        }
        for descriptor in MarketplaceCatalogLoader.load() where !seen.contains(descriptor.id) {
            seen.insert(descriptor.id)
            result.append(descriptor)
        }
        for descriptor in MCPRegistryClient.loadFromCache() where !seen.contains(descriptor.id) {
            seen.insert(descriptor.id)
            result.append(descriptor)
        }
        return result
    }

    /// Hand-curated descriptors for integrations with tuned install + signal
    /// data. Other plugins discovered via the marketplace get generic
    /// `.claudePlugin` install entries.
    static let builtin: [IntegrationDescriptor] = [
        IntegrationDescriptor(
            id: "github", name: "GitHub", category: "dev",
            mcpServerNames: ["github"],
            // claude plugin handles auth — drop env/cliAuth probes from
            // connectivity (gh CLI auth alone doesn't expose tools to agents).
            credentialProbes: [],
            install: .claudePlugin(marketplace: "claude-plugins-official", name: "github"),
            setupHint: "One-click install: GitHub plugin from Anthropic's official marketplace."
        ),
        IntegrationDescriptor(
            id: "linear", name: "Linear", category: "dev",
            mcpServerNames: ["linear"],
            // Remote OAuth — credential lives in the MCP server's own session,
            // not in env / ccops. MCP-configured == connected.
            credentialProbes: [],
            install: .remoteHttp(url: "https://mcp.linear.app/mcp"),
            setupHint: "One-click install: Linear's hosted MCP server with OAuth."
        ),
        IntegrationDescriptor(
            id: "slack", name: "Slack", category: "comms",
            mcpServerNames: ["slack"],
            credentialProbes: [],
            install: .claudePlugin(marketplace: "claude-plugins-official", name: "slack"),
            setupHint: "One-click install: Slack plugin from Anthropic's official marketplace."
        ),
        IntegrationDescriptor(
            id: "notion", name: "Notion", category: "docs",
            mcpServerNames: ["notion"],
            // Remote OAuth — MCP-configured == connected.
            credentialProbes: [],
            install: .remoteHttp(url: "https://mcp.notion.com/mcp"),
            setupHint: "One-click install: Notion's hosted MCP server with OAuth."
        ),
        IntegrationDescriptor(
            id: "figma", name: "Figma", category: "design",
            mcpServerNames: ["figma"],
            // Remote OAuth — MCP-configured == connected.
            credentialProbes: [],
            install: .remoteHttp(url: "https://mcp.figma.com/mcp"),
            setupHint: "One-click install: Figma's hosted MCP server with OAuth."
        ),
        IntegrationDescriptor(
            id: "supabase", name: "Supabase", category: "data",
            mcpServerNames: ["supabase"],
            credentialProbes: [],
            install: .claudePlugin(marketplace: "claude-plugins-official", name: "supabase"),
            setupHint: "One-click install: Supabase plugin from Anthropic's official marketplace."
        ),
        IntegrationDescriptor(
            id: "sentry", name: "Sentry", category: "dev",
            mcpServerNames: ["sentry"],
            // Remote OAuth — MCP-configured == connected.
            credentialProbes: [],
            install: .remoteHttp(url: "https://mcp.sentry.dev/mcp"),
            setupHint: "One-click install: Sentry's hosted MCP server with OAuth."
        ),
        IntegrationDescriptor(
            id: "postgres", name: "Postgres", category: "data",
            mcpServerNames: ["postgres", "postgresql"],
            credentialProbes: [
                .init(kind: .env, value: "DATABASE_URL"),
                .init(kind: .ccops, value: "DATABASE_URL")
            ],
            install: .unsupported(
                reason: "Official @modelcontextprotocol/server-postgres is archived (known SQL-injection bypass). Needs a vetted replacement."
            ),
            setupHint: "Postgres MCP install is disabled — see install.reason."
        ),
        IntegrationDescriptor(
            id: "lark", name: "Lark", category: "comms",
            mcpServerNames: ["lark", "feishu"],
            credentialProbes: [
                .init(kind: .cliAuth, value: "lark-cli auth status")
            ],
            install: .localStdio(
                command: "npx",
                args: ["-y", "@larksuiteoapi/lark-mcp", "mcp"],
                envKeys: ["LARK_APP_ID", "LARK_APP_SECRET"]
            ),
            setupHint: "Add the Lark MCP server and a Lark App ID + Secret."
        ),
        IntegrationDescriptor(
            id: "google-sheets", name: "Google Sheets", category: "data",
            mcpServerNames: ["google-sheets", "sheets", "google_sheets", "gdrive"],
            credentialProbes: [],
            // 社区 stdio server xing5/mcp-google-sheets(`uvx mcp-google-sheets@latest`),
            // OAuth installed-app 模式:CREDENTIALS_PATH(用户在 Connect 时上传的 OAuth
            // client)+ TOKEN_PATH(server 自缓存的授权 token)。OAuth 浏览器同意 + token
            // 刷新都由 server 自管,meee2 只注册 + 注入凭证路径 + Connect 时预触发授权。
            // 需本机有 uv/uvx(Python),缺失时 installer 给安装指引。
            install: .localStdio(
                command: "uvx",
                args: ["mcp-google-sheets@latest"],
                envKeys: ["CREDENTIALS_PATH", "TOKEN_PATH"]
            ),
            setupHint: "Connect Google Sheets: upload your GCP OAuth client credentials.json once, then authorize in the browser. Needs `uv` installed."
        )
    ]
}

// MARK: - Detector

/// The detection engine. Reads agent MCP config + probes credentials.
enum IntegrationDetector {
    static let agents = ["claude-code", "codex"]

    /// Full agent × integration matrix.
    static func scan() -> [AgentIntegrationStatus] {
        let claudeServers = claudeMCPServerNames()
        let codexServers = codexMCPServerNames()
        var credCache: [String: Bool] = [:]   // probe-key → passed

        func credentialMatches(_ descriptor: IntegrationDescriptor) -> [String] {
            descriptor.credentialProbes.compactMap { probe in
                let key = "\(probe.kind.rawValue):\(probe.value)"
                let passed: Bool
                if let cached = credCache[key] {
                    passed = cached
                } else {
                    let result = probePasses(probe)
                    credCache[key] = result
                    passed = result
                }
                return passed ? key : nil
            }
        }

        var out: [AgentIntegrationStatus] = []
        for descriptor in IntegrationCatalog.all {
            let credViaShared = credentialMatches(descriptor)
            // Probe tools/list once per integration (transport is the same
            // across agents) — only when MCP-only and at least one agent has
            // it configured. Lazy: skipped for missing/credential-gated rows.
            var probeResult: MCPProbeResult?
            for agent in agents {
                let servers = agent == "claude-code" ? claudeServers : codexServers
                let mcpVia: [String] = descriptor.mcpServerNames.compactMap { fragment in
                    let lowered = fragment.lowercased()
                    let hit = servers.first { $0.lowercased().contains(lowered) }
                    return hit.map { "mcp:\($0)" }
                }
                let mcpConfigured = !mcpVia.isEmpty
                let credentialPresent = !credViaShared.isEmpty
                if mcpConfigured && descriptor.credentialProbes.isEmpty && probeResult == nil {
                    probeResult = MCPToolListProbe.probe(
                        integrationId: descriptor.id, install: descriptor.install
                    )
                }
                let state = resolveState(
                    descriptor: descriptor,
                    mcpConfigured: mcpConfigured,
                    credentialPresent: credentialPresent,
                    probeResult: probeResult
                )
                out.append(AgentIntegrationStatus(
                    agent: agent,
                    integrationId: descriptor.id,
                    integrationName: descriptor.name,
                    category: descriptor.category,
                    state: state,
                    mcpConfigured: mcpConfigured,
                    credentialPresent: credentialPresent,
                    via: mcpVia + credViaShared,
                    evidence: evidence(
                        descriptor: descriptor, agent: agent,
                        mcpConfigured: mcpConfigured, credentialPresent: credentialPresent,
                        probeResult: probeResult
                    ),
                    install: descriptor.install
                ))
            }
        }
        return out
    }

    /// `connected` needs every applicable channel; an MCP-only integration
    /// (no credential probes) is `connected` on the MCP server alone — unless
    /// the optional tools/list probe reports an OAuth-pending state, in which
    /// case the row is `.needsAuth`.
    static func resolveState(
        descriptor: IntegrationDescriptor,
        mcpConfigured: Bool,
        credentialPresent: Bool,
        probeResult: MCPProbeResult? = nil
    ) -> IntegrationConnState {
        if descriptor.credentialProbes.isEmpty {
            guard mcpConfigured else { return .missing }
            if case .onlyAuthBootstrap = probeResult { return .needsAuth }
            return .connected
        }
        switch (mcpConfigured, credentialPresent) {
        case (true, true): return .connected
        case (false, false): return .missing
        default: return .partial
        }
    }

    private static func evidence(
        descriptor: IntegrationDescriptor, agent: String,
        mcpConfigured: Bool, credentialPresent: Bool,
        probeResult: MCPProbeResult? = nil
    ) -> String {
        let mcp = mcpConfigured ? "MCP server configured" : "no MCP server"
        if descriptor.credentialProbes.isEmpty {
            var detail = mcp + " (\(agent))"
            // Probe annotations only matter when this agent actually has the
            // MCP server — otherwise the row is just plain `missing` and the
            // "OAuth pending" note from a sibling agent's view would mislead.
            if mcpConfigured {
                if case .onlyAuthBootstrap(let tools) = probeResult {
                    detail += "; OAuth pending — server only exposes \(tools.joined(separator: ", "))"
                } else if case .hasRealTools(let tools) = probeResult {
                    detail += "; \(tools.count) tools live"
                }
            }
            return detail
        }
        let cred = credentialPresent ? "credential present" : "credential missing"
        return "\(mcp); \(cred)"
    }

    // MARK: Config readers (user-level only — P1 decision #3)

    /// Claude Code's MCP servers — across all scopes Claude Code reads, **plus**
    /// the names of installed marketplace plugins (so a `.claudePlugin`
    /// integration shows up as connected even when the plugin's MCP server is
    /// internal). Returns the union of names.
    ///
    /// Sources:
    ///   1. `~/.claude.json` top-level `mcpServers`            (user scope)
    ///   2. `~/.claude.json` `projects.<path>.mcpServers`      (project scope,
    ///      what the Connectors UI / `claude mcp add` default writes to)
    ///   3. `~/.claude/settings.json` `mcpServers`             (settings scope)
    ///   4. `~/.claude/plugins/installed_plugins.json` `plugins` keys
    ///      (marketplace plugin installs — name stripped from "<name>@<mkt>")
    static func claudeMCPServerNames() -> [String] {
        var names = Set<String>()

        // (1) + (2) from ~/.claude.json
        let claudeJSON = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeJSON),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let userScope = obj["mcpServers"] as? [String: Any] {
                userScope.keys.forEach { names.insert($0) }
            }
            if let projects = obj["projects"] as? [String: Any] {
                for (_, value) in projects {
                    guard let project = value as? [String: Any],
                          let projectServers = project["mcpServers"] as? [String: Any] else { continue }
                    projectServers.keys.forEach { names.insert($0) }
                }
            }
        }

        // (3) from ~/.claude/settings.json
        let settingsJSON = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsJSON),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = obj["mcpServers"] as? [String: Any] {
            servers.keys.forEach { names.insert($0) }
        }

        // (4) from ~/.claude/plugins/installed_plugins.json — plugin keys are
        // "<name>@<marketplace>"; we record the bare name so a matrix row like
        // "github" matches an installed "github@claude-plugins-official".
        let installedPlugins = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("plugins")
            .appendingPathComponent("installed_plugins.json")
        if let data = try? Data(contentsOf: installedPlugins),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plugins = obj["plugins"] as? [String: Any] {
            for key in plugins.keys {
                let bareName = key.split(separator: "@").first.map(String.init) ?? key
                names.insert(bareName)
            }
        }

        return Array(names)
    }

    /// Codex's MCP config: `~/.codex/config.toml` `[mcp_servers.<name>]` tables.
    static func codexMCPServerNames() -> [String] {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("config.toml")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return []
        }
        var names: [String] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[mcp_servers.") && line.hasSuffix("]") else { continue }
            var inner = String(line.dropFirst("[mcp_servers.".count).dropLast())
            inner = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !inner.isEmpty { names.append(inner) }
        }
        return names
    }

    // MARK: Credential probing

    /// Whether a credential probe passes. Never reads/returns the secret value
    /// itself — existence only.
    static func probePasses(_ probe: IntegrationCredentialProbe) -> Bool {
        switch probe.kind {
        case .ccops:
            return shell("ccops", ["has", probe.value]).code == 0
        case .env:
            let value = ProcessInfo.processInfo.environment[probe.value] ?? ""
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .cliAuth:
            let parts = probe.value.split(separator: " ").map(String.init)
            guard let first = parts.first else { return false }
            return shell(first, Array(parts.dropFirst())).code == 0
        }
    }

    /// Run a command via `/usr/bin/env` (PATH lookup). Returns exit code +
    /// stdout. Exit code -1 when the binary cannot be launched.
    @discardableResult
    private static func shell(_ name: String, _ args: [String]) -> (code: Int32, out: String) {
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
            return (-1, "")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - P2: node side-effect inference

/// Text fragments that, found in a node's context / artifacts / dispatch,
/// indicate the node's IO touches that integration. Coarse on purpose — the
/// plan deliberately avoids precise `schema` token matching (decision D).
enum IntegrationSignals {
    static let keywords: [String: [String]] = [
        "github": ["github.com", "github", "/pull/", "/pulls/", "pull request", "impl-pr", "main-merge"],
        "linear": ["linear.app", "linear"],
        "slack": ["slack.com", "slack"],
        "notion": ["notion.so", "notion"],
        "figma": ["figma.com", "figma"],
        "supabase": ["supabase.co", "supabase"],
        "sentry": ["sentry.io", "sentry"],
        "postgres": ["postgres", "postgresql", "psql"],
        "lark": ["larksuite.com", "feishu.cn", "lark", "feishu", "idea-draft", "lark-doc"],
        "google-sheets": ["docs.google.com/spreadsheets", "gsheet://", "google sheets", "google-sheets"]
    ]
}

/// A side-effect surface of one planner node: its IO touches `integrationId`
/// in `direction`. Coarse — integration-id level, not artifact-kind level.
struct NodeSideEffect: Codable, Equatable {
    var integrationId: String
    var direction: String   // "reads" (input side) | "writes" (output side)
    var source: String      // "inferred"
}

/// Per-node side effect crossed with the detection matrix.
struct NodeSideEffectCoverage: Codable, Equatable {
    var integrationId: String
    var direction: String
    /// Whether that integration is `connected` on at least one agent.
    var connected: Bool
}

struct NodeSideEffectDTO: Encodable {
    let nodeId: String
    let title: String
    let sideEffects: [NodeSideEffectCoverage]
}

struct CanvasSideEffectsEnvelope: Encodable {
    let canvasId: String
    let nodes: [NodeSideEffectDTO]
}

/// Infers which integrations a planner node's input/output touch — purely from
/// the node's existing fields (contextSources / artifactRefs / schema /
/// dispatch). No precise IO vocabulary required.
enum NodeSideEffectInferrer {
    static func infer(node: PlanningNode) -> [NodeSideEffect] {
        var directionsById: [String: Set<String>] = [:]
        func tag(_ id: String, _ direction: String) {
            directionsById[id, default: []].insert(direction)
        }
        func scan(_ haystack: String, _ direction: String) {
            let lowered = haystack.lowercased()
            guard !lowered.isEmpty else { return }
            for (id, keywords) in IntegrationSignals.keywords
            where keywords.contains(where: { lowered.contains($0) }) {
                tag(id, direction)
            }
        }

        // Input side — context sources the node reads from.
        for source in node.contextSources {
            if source.kind == .repository { tag("github", "reads") }
            scan(source.reference + " " + source.title, "reads")
        }
        scan(node.schema.inputs.joined(separator: " "), "reads")

        // Output side — artifacts / produces the node writes.
        scan(((node.artifactRefs ?? []) + node.schema.outputs).joined(separator: " "), "writes")

        // Dispatch skill/command — loosely an input touch.
        if let dispatch = node.dispatch {
            scan((dispatch.skill ?? "") + " " + (dispatch.command ?? ""), "reads")
        }

        return directionsById
            .flatMap { id, directions in
                directions.map { NodeSideEffect(integrationId: id, direction: $0, source: "inferred") }
            }
            .sorted { ($0.integrationId, $0.direction) < ($1.integrationId, $1.direction) }
    }

    /// Infer side effects for every node and cross with the detection matrix.
    static func coverage(nodes: [PlanningNode]) -> [NodeSideEffectDTO] {
        let scan = IntegrationDetector.scan()
        let connectedIds = Set(
            scan.filter { $0.state == .connected }.map { $0.integrationId }
        )
        return nodes.map { node in
            let effects = infer(node: node).map { effect in
                NodeSideEffectCoverage(
                    integrationId: effect.integrationId,
                    direction: effect.direction,
                    connected: connectedIds.contains(effect.integrationId)
                )
            }
            return NodeSideEffectDTO(nodeId: node.id, title: node.title, sideEffects: effects)
        }
    }
}
