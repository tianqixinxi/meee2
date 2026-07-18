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

    func testCodexSetupCommandUsesOfficialGitMarketplaceBeforePluginAdd() {
        let command = Meee2AgentRuntimeInstaller.codexSetupCommand(
            marketplaceSource: "tianqixinxi/meee2-marketplace",
            marketplaceRef: nil
        )

        XCTAssertEqual(
            command,
            "codex plugin marketplace add tianqixinxi/meee2-marketplace && codex plugin add meee2@meee2-official"
        )
    }

    func testClaudeSetupCommandUsesOfficialGitMarketplaceBeforePlugins() {
        let command = Meee2AgentRuntimeInstaller.claudeSetupCommand()

        XCTAssertEqual(
            command,
            "claude plugin marketplace add tianqixinxi/meee2-marketplace --scope user && claude plugin install meee2@meee2-official --scope user && claude plugin install meee2-workflow-bridge@meee2-official --scope user && claude plugin enable meee2@meee2-official --scope user && claude plugin enable meee2-workflow-bridge@meee2-official --scope user"
        )
    }

    func testCodexSetupCommandQuotesMarketplaceSourceWithSpaces() {
        let command = Meee2AgentRuntimeInstaller.codexSetupCommand(
            marketplaceSource: "https://github.com/acme/meee2 marketplace.git",
            marketplaceRef: "release channel",
            codexCommand: "/Applications/Codex.app/Contents/Resources/codex"
        )

        XCTAssertEqual(
            command,
            "/Applications/Codex.app/Contents/Resources/codex plugin marketplace add 'https://github.com/acme/meee2 marketplace.git' --ref 'release channel' && /Applications/Codex.app/Contents/Resources/codex plugin add meee2@meee2-official"
        )
    }
}
