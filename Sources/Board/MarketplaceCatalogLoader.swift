import Foundation

// Loader for Claude Code's plugin marketplace catalog —— reads every
// `~/.claude/plugins/marketplaces/<mkt>/.claude-plugin/marketplace.json` and
// projects each plugin entry as an `IntegrationDescriptor` with a
// `.claudePlugin(marketplace:, name:)` install. Together with the curated
// builtin set, this lets `IntegrationCatalog.all` enumerate ~200 plugins from
// Anthropic's official marketplace (and any community ones the user added)
// without hardcoding.
//
// We deliberately do NOT cache: marketplace.json is on local disk and the
// matrix scan endpoint is not hot. If that changes we add a TTL cache here.

enum MarketplaceCatalogLoader {
    /// Scan `~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json`.
    /// Returns a descriptor per plugin entry; the marketplace directory name
    /// becomes the install's `marketplace` (e.g. `claude-plugins-official`).
    static func load() -> [IntegrationDescriptor] {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("marketplaces", isDirectory: true)

        let fileManager = FileManager.default
        guard let marketplaces = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [IntegrationDescriptor] = []
        for marketplaceURL in marketplaces {
            let marketplaceName = marketplaceURL.lastPathComponent
            let jsonURL = marketplaceURL
                .appendingPathComponent(".claude-plugin", isDirectory: true)
                .appendingPathComponent("marketplace.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plugins = obj["plugins"] as? [[String: Any]] else {
                continue
            }
            for plugin in plugins {
                guard let name = plugin["name"] as? String,
                      !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let description = (plugin["description"] as? String) ?? ""
                let rawCategory = (plugin["category"] as? String) ?? ""
                let category = rawCategory.isEmpty ? "other" : rawCategory
                result.append(IntegrationDescriptor(
                    id: name,
                    name: name,
                    category: category,
                    // For .claudePlugin integrations the connectivity signal is
                    // the plugin name appearing in installed_plugins.json (the
                    // detector already merges that into claudeMCPServerNames).
                    mcpServerNames: [name],
                    credentialProbes: [],
                    install: .claudePlugin(marketplace: marketplaceName, name: name),
                    setupHint: description
                ))
            }
        }
        return result
    }
}
