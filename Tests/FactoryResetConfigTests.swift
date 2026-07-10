import XCTest
@testable import meee2Kit

final class FactoryResetConfigTests: XCTestCase {
    private var temporaryHome: URL!

    override func setUpWithError() throws {
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-factory-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryHome)
        temporaryHome = nil
    }

    func testHookUnregisterPreservesThirdPartyHooksAndPermissions() throws {
        let claudeDirectory = temporaryHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [
                        ["command": "/Applications/Meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh"],
                        ["command": "/usr/local/bin/third-party-hook"]
                    ]]
                ]
            ],
            "permissions": [
                "allow": [
                    "mcp__meee2__read_node_contract",
                    "mcp__plugin_meee2_meee2__submit_node_output",
                    "mcp__other__keep"
                ]
            ],
            "theme": "dark"
        ]
        try writeJSON(settings, to: settingsURL)

        XCTAssertTrue(SettingsConfigManager(homeDirectory: temporaryHome).unregisterMeee2Hooks())

        let updated = try readJSON(settingsURL)
        let hooks = try XCTUnwrap(updated["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let inner = try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.compactMap { $0["command"] as? String }, ["/usr/local/bin/third-party-hook"])
        let permissions = try XCTUnwrap(updated["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["mcp__other__keep"])
        XCTAssertEqual(updated["theme"] as? String, "dark")
    }

    func testMCPUnregisterPreservesOtherClaudeAndCodexServers() throws {
        try writeJSON([
            "mcpServers": [
                "meee2": ["command": "node", "args": ["/tmp/meee2/server.js"]],
                "other": ["command": "other", "args": []]
            ],
            "unrelated": true
        ], to: temporaryHome.appendingPathComponent(".claude.json"))

        let claudeDirectory = temporaryHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try writeJSON([
            "permissions": [
                "allow": ["mcp__meee2__list_sessions", "mcp__other__keep"]
            ]
        ], to: claudeDirectory.appendingPathComponent("settings.json"))

        let codexDirectory = temporaryHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let codexURL = codexDirectory.appendingPathComponent("config.toml")
        try """
        model = "gpt-5"

        [mcp_servers.meee2]
        command = "node"
        args = ["/tmp/meee2/server.js"]

        [mcp_servers.other]
        command = "other"
        args = []
        """.write(to: codexURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(MCPConfigManager(homeDirectory: temporaryHome).unregisterMeee2())

        let claude = try readJSON(temporaryHome.appendingPathComponent(".claude.json"))
        let servers = try XCTUnwrap(claude["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["meee2"])
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual(claude["unrelated"] as? Bool, true)

        let settings = try readJSON(claudeDirectory.appendingPathComponent("settings.json"))
        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["mcp__other__keep"])

        let codex = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertFalse(codex.contains("[mcp_servers.meee2]"))
        XCTAssertTrue(codex.contains("[mcp_servers.other]"))
        XCTAssertTrue(codex.contains("model = \"gpt-5\""))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
