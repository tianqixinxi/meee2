import XCTest
@testable import meee2Kit

final class Meee2AgentRuntimeInstallerTests: XCTestCase {
    func testClaudePluginListStatusPreservesDisabledBridgeState() throws {
        let stdout = """
        [
          {
            "id": "meee2-workflow-bridge@meee2-official",
            "version": "0.1.2",
            "scope": "user",
            "enabled": false
          }
        ]
        """

        let status = try XCTUnwrap(Meee2AgentRuntimeInstaller.claudePluginListStatus(
            stdout,
            containsPlugin: "meee2-workflow-bridge",
            marketplace: "meee2-official"
        ))

        XCTAssertTrue(status.installed)
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.active)
    }

    func testClaudePluginSettingsDefaultEnabledUnlessExplicitlyDisabled() {
        let selector = "meee2-workflow-bridge@meee2-official"

        XCTAssertEqual(
            Meee2AgentRuntimeInstaller.claudePluginEnabledInSettings(
                enabledPlugins: nil,
                selector: selector
            ),
            true
        )
        XCTAssertEqual(
            Meee2AgentRuntimeInstaller.claudePluginEnabledInSettings(
                enabledPlugins: [selector: false],
                selector: selector
            ),
            false
        )
    }

    func testCodexSetupCommandIncludesMarketplacePathBeforePluginAdd() {
        let command = Meee2AgentRuntimeInstaller.codexSetupCommand(
            marketplacePath: "/Applications/meee2.app/Contents/Resources/meee2-agent-plugin-marketplace"
        )

        XCTAssertEqual(
            command,
            "codex plugin marketplace add /Applications/meee2.app/Contents/Resources/meee2-agent-plugin-marketplace && codex plugin add meee2@meee2-official"
        )
    }

    func testCodexSetupCommandQuotesMarketplacePathWithSpaces() {
        let command = Meee2AgentRuntimeInstaller.codexSetupCommand(
            marketplacePath: "/Users/kai/Application Support/meee2-agent-plugin-marketplace",
            codexCommand: "/Applications/Codex.app/Contents/Resources/codex"
        )

        XCTAssertEqual(
            command,
            "/Applications/Codex.app/Contents/Resources/codex plugin marketplace add '/Users/kai/Application Support/meee2-agent-plugin-marketplace' && /Applications/Codex.app/Contents/Resources/codex plugin add meee2@meee2-official"
        )
    }
}
