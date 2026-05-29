import Foundation

// Third catalog source: the official MCP Registry
// (https://registry.modelcontextprotocol.io). Paginates the public
// `/v0/servers` endpoint, caches to `~/.meee2/mcp-registry-cache.json`, and
// projects each remote-HTTP server as a `.remoteHttp` IntegrationDescriptor.
//
// We only include servers that expose a streamable-http remote — those are
// the ones meee2 can install one-click via `claude mcp add --transport http`.
// stdio-package entries from the registry are skipped (their install command
// would need bespoke per-server handling).

enum MCPRegistryClient {
    private static let endpoint = URL(string: "https://registry.modelcontextprotocol.io/v0/servers")!
    private static let pageLimit = 100
    private static let maxPages = 6
    private static let cacheTTL: TimeInterval = 24 * 3600

    private static let cacheURL = MEEE2Env.home
        .appendingPathComponent("mcp-registry-cache.json")

    /// Read cached descriptors. Returns [] when cache is missing / malformed.
    static func loadFromCache() -> [IntegrationDescriptor] {
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["servers"] as? [[String: Any]] else {
            return []
        }
        return servers.compactMap(descriptor(from:))
    }

    /// If the cache is missing or older than `cacheTTL`, refresh in the
    /// background. Returns immediately — first scan after a stale cache will
    /// see the still-stale data; the next scan picks up the refreshed cache.
    static func refreshAsyncIfStale() {
        guard isStale() else { return }
        DispatchQueue.global(qos: .utility).async {
            refreshSync()
        }
    }

    private static func isStale() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            return true
        }
        return Date().timeIntervalSince(modified) > cacheTTL
    }

    /// Synchronously paginate the registry and write the cache. Best-effort —
    /// network failures leave the previous cache (if any) untouched.
    static func refreshSync() {
        var allServers: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<maxPages {
            guard let page = fetchPage(cursor: cursor) else { break }
            if let servers = page["servers"] as? [[String: Any]] {
                allServers.append(contentsOf: servers)
            }
            cursor = (page["metadata"] as? [String: Any])?["nextCursor"] as? String
            if cursor == nil { break }
        }
        guard !allServers.isEmpty else { return }
        let payload: [String: Any] = [
            "fetchedAt": Date().timeIntervalSince1970,
            "servers": allServers
        ]
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: cacheURL, options: .atomic)
            NSLog("[MCPRegistryClient] cached %d servers", allServers.count)
        } catch {
            NSLog("[MCPRegistryClient] cache write failed: %@", error.localizedDescription)
        }
    }

    private static func fetchPage(cursor: String?) -> [String: Any]? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = [URLQueryItem(name: "limit", value: "\(pageLimit)")]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = queryItems
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = json
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }

    /// Map a registry envelope ({"server": {...}}) to an IntegrationDescriptor.
    /// Filters to streamable-http remotes — those are the one-click installable
    /// subset. Registry names contain `/` (e.g. `ac.inference.sh/mcp`); we
    /// sanitise to `--` for the integration id so `claude mcp add` accepts it.
    private static func descriptor(from entry: [String: Any]) -> IntegrationDescriptor? {
        guard let server = entry["server"] as? [String: Any],
              let name = server["name"] as? String, !name.isEmpty else { return nil }
        let remotes = (server["remotes"] as? [[String: Any]]) ?? []
        guard let http = remotes.first(where: { remote in
            guard let type = remote["type"] as? String else { return false }
            return type.lowercased().contains("http")
        }), let url = http["url"] as? String else {
            return nil
        }
        let title = (server["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let description = (server["description"] as? String) ?? ""
        let id = sanitize(name)
        return IntegrationDescriptor(
            id: id,
            name: title,
            category: "registry",
            mcpServerNames: [id, name],
            credentialProbes: [],
            install: .remoteHttp(url: url),
            setupHint: description
        )
    }

    private static func sanitize(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x80,
               let char = Unicode.Scalar(scalar.value),
               CharacterSet.alphanumerics.contains(char) || "-_.".contains(Character(char)) {
                out.append(Character(char))
            } else {
                out.append("-")
            }
        }
        return out
    }
}
