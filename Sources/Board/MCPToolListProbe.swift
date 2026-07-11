import Foundation

// Probes a configured MCP server for its `tools/list` output so the integration
// detector can tell apart "MCP server installed, OAuth done, real tools live"
// (→ `.connected`) from "MCP server installed but OAuth incomplete, only
// `authenticate` / `complete_authentication` exposed" (→ `.needsAuth`).
//
// Why this exists: remote-OAuth MCPs (clickhouse, linear, notion, figma, …)
// negotiate their token inside Claude Code's MCP runtime, not on disk. There
// is no token file we can stat, so the only authoritative signal is the
// server's own tool list — pre-OAuth it advertises auth-bootstrap tools,
// post-OAuth it advertises the real ones.

// MARK: - Result

enum MCPProbeResult: Equatable {
    /// Server responded but only exposes auth-bootstrap tools — OAuth pending.
    case onlyAuthBootstrap(tools: [String])
    /// Server responded with at least one non-bootstrap tool — wired up.
    case hasRealTools(tools: [String])
    /// Probe couldn't reach the server (network, timeout, parse, …). Caller
    /// must NOT downgrade existing `.connected` state on this — we never
    /// regress the matrix because of a transient failure.
    case unreachable(reason: String)
    /// Probing this install kind isn't supported (.localStdio without env,
    /// .unsupported, …). Treat as `unreachable` but explicit.
    case unsupported
}

// MARK: - Probe

enum MCPToolListProbe {
    /// Heuristic — tool names that mean "you still need to authenticate".
    /// Match is case-insensitive, exact-name only (we don't want to count
    /// `authorize_query` or `authentic_data_*` as bootstrap).
    static let bootstrapToolNames: Set<String> = [
        "authenticate",
        "complete_authentication",
        "completeauthentication",
        "auth",
        "login",
        "oauth_authorize",
        "begin_authentication"
    ]

    /// Cache entries — 60s freshness so re-scans don't hammer remote servers.
    private struct CacheEntry {
        let result: MCPProbeResult
        let cachedAt: Date
    }
    private static let cacheTTL: TimeInterval = 60
    private static var cache: [String: CacheEntry] = [:]
    private static let cacheQueue = DispatchQueue(label: "MCPToolListProbe.cache")

    /// Probe the MCP server backing `integrationId` with this `install` spec.
    /// Results cached per `integrationId`.
    static func probe(integrationId: String, install: IntegrationInstall) -> MCPProbeResult {
        if let cached = cacheQueue.sync(execute: { cache[integrationId] }),
           Date().timeIntervalSince(cached.cachedAt) < cacheTTL {
            return cached.result
        }
        let result = runProbe(integrationId: integrationId, install: install)
        cacheQueue.sync { cache[integrationId] = CacheEntry(result: result, cachedAt: Date()) }
        return result
    }

    /// Clear the cache (used by tests + the explicit Re-scan button path).
    static func resetCache() {
        cacheQueue.sync { cache.removeAll() }
    }

    private static func runProbe(integrationId: String, install: IntegrationInstall) -> MCPProbeResult {
        switch install {
        case .remoteHttp(let url):
            return probeHTTP(url: url)
        case .claudePlugin(_, let name):
            // Plugin install — find its bundled `.mcp.json` to discover the
            // real transport (usually a remote HTTP URL).
            if let transport = resolveClaudePluginTransport(pluginName: name) {
                switch transport {
                case .remoteHttp(let url): return probeHTTP(url: url)
                case .localStdio, .claudePlugin: return .unsupported
                }
            }
            return .unsupported
        case .localStdio:
            // OAuth-shaped state doesn't apply to env-credential stdio MCPs —
            // those are gated by `IntegrationCredentialProbe` instead.
            return .unsupported
        }
    }

    // MARK: HTTP transport

    private static func probeHTTP(url urlString: String) -> MCPProbeResult {
        guard let url = URL(string: urlString) else {
            return .unreachable(reason: "invalid url: \(urlString)")
        }

        // MCP Streamable HTTP — POST a single JSON-RPC `tools/list` request.
        // Many servers reply with `application/json`; some stream
        // `text/event-stream`. We accept both and parse the first JSON-RPC
        // payload we can find.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.timeoutInterval = 2.0

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:] as [String: Any]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .unreachable(reason: "encode failed")
        }
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseHTTP: HTTPURLResponse?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseHTTP = response as? HTTPURLResponse
            responseError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 2.5) == .timedOut {
            task.cancel()
            return .unreachable(reason: "timeout after 2.5s")
        }

        if let error = responseError {
            return .unreachable(reason: error.localizedDescription)
        }
        guard let http = responseHTTP, let data = responseData else {
            return .unreachable(reason: "no response")
        }

        // 401 / 403 → server demands auth before listing tools. That itself is
        // a strong "needs OAuth" signal, but we can't extract bootstrap tool
        // names from it. Mark as needsAuth via a synthetic placeholder.
        if http.statusCode == 401 || http.statusCode == 403 {
            return .onlyAuthBootstrap(tools: ["<unauthorized>"])
        }
        guard (200..<300).contains(http.statusCode) else {
            return .unreachable(reason: "http \(http.statusCode)")
        }

        return classify(parseToolNames(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type")))
    }

    // MARK: Response parsing

    /// Pull `tools[*].name` out of a JSON-RPC `tools/list` response. Supports:
    ///   - plain `application/json` body
    ///   - `text/event-stream` body with one or more `data: {...}` lines
    static func parseToolNames(data: Data, contentType: String?) -> [String]? {
        let lowered = (contentType ?? "").lowercased()
        if lowered.contains("event-stream") {
            // Streamable HTTP — find `data: <json>` lines and try each.
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let json = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if let bytes = json.data(using: .utf8),
                   let names = extractToolNames(bytes) {
                    return names
                }
            }
            return nil
        }
        return extractToolNames(data)
    }

    private static func extractToolNames(_ data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Some servers wrap the result; some don't (e.g. error responses).
        guard let result = object["result"] as? [String: Any],
              let rawTools = result["tools"] as? [[String: Any]] else {
            return nil
        }
        return rawTools.compactMap { $0["name"] as? String }
    }

    /// Decide `needsAuth` vs `connected` from a parsed tool list. Treats
    /// "every tool is in the bootstrap allowlist" as needsAuth; presence of
    /// any other tool means OAuth has completed.
    static func classify(_ names: [String]?) -> MCPProbeResult {
        guard let names else {
            return .unreachable(reason: "no tools/list response")
        }
        if names.isEmpty {
            return .unreachable(reason: "empty tools list")
        }
        let bootstrap = bootstrapToolNames
        let allBootstrap = names.allSatisfy { bootstrap.contains($0.lowercased()) }
        return allBootstrap ? .onlyAuthBootstrap(tools: names) : .hasRealTools(tools: names)
    }

    // MARK: Plugin .mcp.json discovery

    /// Read `~/.claude/plugins/cache/<marketplace>/<pluginName>/<version>/.mcp.json`
    /// for the install path Claude Code actually loaded, and pull the first
    /// server's transport. We walk `installed_plugins.json` to find the
    /// canonical `installPath`.
    static func resolveClaudePluginTransport(pluginName: String) -> IntegrationInstall? {
        let registry = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("plugins")
            .appendingPathComponent("installed_plugins.json")
        guard let data = try? Data(contentsOf: registry),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = obj["plugins"] as? [String: Any] else {
            return nil
        }

        // Keys look like "<name>@<marketplace>" — pick any whose bare name
        // matches, take the first install entry's installPath.
        var installPath: String?
        for (key, value) in plugins {
            let bare = key.split(separator: "@").first.map(String.init) ?? key
            guard bare == pluginName,
                  let entries = value as? [[String: Any]],
                  let first = entries.first,
                  let path = first["installPath"] as? String else { continue }
            installPath = path
            break
        }
        guard let installPath else { return nil }

        let mcpJSON = URL(fileURLWithPath: installPath).appendingPathComponent(".mcp.json")
        guard let mcpData = try? Data(contentsOf: mcpJSON),
              let mcpObj = try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
              let servers = mcpObj["mcpServers"] as? [String: Any] else {
            return nil
        }

        for (_, spec) in servers {
            guard let entry = spec as? [String: Any] else { continue }
            let type = (entry["type"] as? String)?.lowercased()
            if let url = entry["url"] as? String, type == "http" || type == "sse" || type == nil {
                return .remoteHttp(url: url)
            }
            if let command = entry["command"] as? String {
                let args = (entry["args"] as? [String]) ?? []
                let envKeys = ((entry["env"] as? [String: Any])?.keys).map(Array.init) ?? []
                return .localStdio(command: command, args: args, envKeys: envKeys)
            }
        }
        return nil
    }
}
