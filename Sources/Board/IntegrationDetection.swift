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
    /// MCP-only integration — just the MCP server).
    case connected
    /// Some but not all channels satisfied (e.g. MCP server configured but the
    /// credential is missing).
    case partial
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

/// One integration the catalog knows how to detect (and, in P3, guide).
struct IntegrationDescriptor: Codable, Equatable {
    var id: String
    var name: String
    var category: String
    /// MCP server-name fragments — matched case-insensitively (substring)
    /// against the server names configured in an agent's MCP config.
    var mcpServerNames: [String]
    /// Credential probes. Empty → MCP-only integration; `connected` then needs
    /// only the MCP server.
    var credentialProbes: [IntegrationCredentialProbe]
    /// One-line setup hint, surfaced in the runbook (P3).
    var setupHint: String
}

/// Response envelope for `GET /api/integrations/agent-scan`.
struct AgentScanEnvelope: Encodable {
    let agents: [String]
    let statuses: [AgentIntegrationStatus]
}

/// Detection result for one (agent, integration) cell of the matrix.
struct AgentIntegrationStatus: Codable, Equatable {
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
}

// MARK: - Catalog

/// Built-in, static catalog of common integrations. Remote/extensible catalog
/// is deliberately out of scope for P1.
enum IntegrationCatalog {
    static let all: [IntegrationDescriptor] = [
        IntegrationDescriptor(
            id: "github", name: "GitHub", category: "dev",
            mcpServerNames: ["github"],
            credentialProbes: [
                .init(kind: .ccops, value: "GITHUB_TOKEN"),
                .init(kind: .env, value: "GITHUB_TOKEN"),
                .init(kind: .cliAuth, value: "gh auth status")
            ],
            setupHint: "Add the GitHub MCP server and a GITHUB_TOKEN (repo scope)."
        ),
        IntegrationDescriptor(
            id: "linear", name: "Linear", category: "dev",
            mcpServerNames: ["linear"],
            credentialProbes: [
                .init(kind: .ccops, value: "LINEAR_API_KEY"),
                .init(kind: .env, value: "LINEAR_API_KEY")
            ],
            setupHint: "Add the Linear MCP server and a LINEAR_API_KEY."
        ),
        IntegrationDescriptor(
            id: "slack", name: "Slack", category: "comms",
            mcpServerNames: ["slack"],
            credentialProbes: [
                .init(kind: .ccops, value: "SLACK_BOT_TOKEN"),
                .init(kind: .env, value: "SLACK_BOT_TOKEN")
            ],
            setupHint: "Add the Slack MCP server and a SLACK_BOT_TOKEN."
        ),
        IntegrationDescriptor(
            id: "notion", name: "Notion", category: "docs",
            mcpServerNames: ["notion"],
            credentialProbes: [
                .init(kind: .ccops, value: "NOTION_TOKEN"),
                .init(kind: .env, value: "NOTION_TOKEN")
            ],
            setupHint: "Add the Notion MCP server and a NOTION_TOKEN."
        ),
        IntegrationDescriptor(
            id: "figma", name: "Figma", category: "design",
            mcpServerNames: ["figma"],
            credentialProbes: [
                .init(kind: .ccops, value: "FIGMA_TOKEN"),
                .init(kind: .env, value: "FIGMA_ACCESS_TOKEN")
            ],
            setupHint: "Add the Figma MCP server and a Figma access token."
        ),
        IntegrationDescriptor(
            id: "supabase", name: "Supabase", category: "data",
            mcpServerNames: ["supabase"],
            credentialProbes: [
                .init(kind: .ccops, value: "SUPABASE_ACCESS_TOKEN"),
                .init(kind: .env, value: "SUPABASE_ACCESS_TOKEN")
            ],
            setupHint: "Add the Supabase MCP server and a SUPABASE_ACCESS_TOKEN."
        ),
        IntegrationDescriptor(
            id: "sentry", name: "Sentry", category: "dev",
            mcpServerNames: ["sentry"],
            credentialProbes: [
                .init(kind: .ccops, value: "SENTRY_AUTH_TOKEN"),
                .init(kind: .env, value: "SENTRY_AUTH_TOKEN")
            ],
            setupHint: "Add the Sentry MCP server and a SENTRY_AUTH_TOKEN."
        ),
        IntegrationDescriptor(
            id: "postgres", name: "Postgres", category: "data",
            mcpServerNames: ["postgres", "postgresql"],
            credentialProbes: [
                .init(kind: .env, value: "DATABASE_URL"),
                .init(kind: .ccops, value: "DATABASE_URL")
            ],
            setupHint: "Add the Postgres MCP server and a DATABASE_URL."
        ),
        IntegrationDescriptor(
            id: "lark", name: "Lark", category: "comms",
            mcpServerNames: ["lark", "feishu"],
            credentialProbes: [
                .init(kind: .cliAuth, value: "lark-cli auth status")
            ],
            setupHint: "Install lark-cli and run `lark-cli auth login`."
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
            for agent in agents {
                let servers = agent == "claude-code" ? claudeServers : codexServers
                let mcpVia: [String] = descriptor.mcpServerNames.compactMap { fragment in
                    let lowered = fragment.lowercased()
                    let hit = servers.first { $0.lowercased().contains(lowered) }
                    return hit.map { "mcp:\($0)" }
                }
                let mcpConfigured = !mcpVia.isEmpty
                let credentialPresent = !credViaShared.isEmpty
                let state = resolveState(
                    descriptor: descriptor,
                    mcpConfigured: mcpConfigured,
                    credentialPresent: credentialPresent
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
                        mcpConfigured: mcpConfigured, credentialPresent: credentialPresent
                    )
                ))
            }
        }
        return out
    }

    /// `connected` needs every applicable channel; an MCP-only integration
    /// (no credential probes) is `connected` on the MCP server alone.
    private static func resolveState(
        descriptor: IntegrationDescriptor,
        mcpConfigured: Bool,
        credentialPresent: Bool
    ) -> IntegrationConnState {
        if descriptor.credentialProbes.isEmpty {
            return mcpConfigured ? .connected : .missing
        }
        switch (mcpConfigured, credentialPresent) {
        case (true, true): return .connected
        case (false, false): return .missing
        default: return .partial
        }
    }

    private static func evidence(
        descriptor: IntegrationDescriptor, agent: String,
        mcpConfigured: Bool, credentialPresent: Bool
    ) -> String {
        let mcp = mcpConfigured ? "MCP server configured" : "no MCP server"
        if descriptor.credentialProbes.isEmpty {
            return mcp + " (\(agent))"
        }
        let cred = credentialPresent ? "credential present" : "credential missing"
        return "\(mcp); \(cred)"
    }

    // MARK: Config readers (user-level only — P1 decision #3)

    /// Claude Code's user-wide MCP config: `~/.claude.json` top-level
    /// `mcpServers` map. Returns the configured server names.
    static func claudeMCPServerNames() -> [String] {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else {
            return []
        }
        return Array(servers.keys)
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
/// plan deliberately avoids precise `ioSchema` token matching (decision D).
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
        "lark": ["larksuite.com", "feishu.cn", "lark", "feishu", "idea-draft", "lark-doc"]
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
/// the node's existing fields (contextSources / artifactRefs / ioSchema /
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
        scan(node.ioSchema.consumes.joined(separator: " "), "reads")

        // Output side — artifacts / produces the node writes.
        scan(((node.artifactRefs ?? []) + node.ioSchema.produces).joined(separator: " "), "writes")

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
