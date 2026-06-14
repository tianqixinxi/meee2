import XCTest
@testable import meee2Kit

final class AgentLaunchCommandTests: XCTestCase {
    func testNormalizeDowngradesClaudeInternalResumeToFreshCommand() {
        let launch = AgentLaunchCommand.normalize(
            command: "claude --resume 'claude-internal-123' --dangerously-skip-permissions",
            fallbackProvider: "claude"
        )

        XCTAssertEqual(launch.provider, "claude")
        XCTAssertEqual(launch.command, "claude --dangerously-skip-permissions")
    }

    func testNormalizeDowngradesCodexInternalResumeToFreshCommand() {
        let launch = AgentLaunchCommand.normalize(
            command: "codex --dangerously-bypass-approvals-and-sandbox resume codex-internal-123",
            fallbackProvider: "codex"
        )

        XCTAssertEqual(launch.provider, "codex")
        XCTAssertEqual(launch.command, "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust")
    }

    func testNormalizeDowngradesGhosttySurfaceResumeToFreshCommand() {
        let launch = AgentLaunchCommand.normalize(
            command: "claude --resume 'claude-ghostty-123' --dangerously-skip-permissions",
            fallbackProvider: "claude"
        )

        XCTAssertEqual(launch.provider, "claude")
        XCTAssertEqual(launch.command, "claude --dangerously-skip-permissions")
    }

    func testNormalizeKeepsProviderResumeIds() {
        let launch = AgentLaunchCommand.normalize(
            command: "claude --resume 8db44e39-685d-47ab-bd0e-5e97386ded80",
            fallbackProvider: "claude"
        )

        XCTAssertEqual(launch.provider, "claude")
        XCTAssertEqual(launch.command, "claude --resume 8db44e39-685d-47ab-bd0e-5e97386ded80 --dangerously-skip-permissions")
    }

    func testNormalizeAddsCodexHookTrustBypassForAutomation() {
        let launch = AgentLaunchCommand.normalize(
            command: "codex --dangerously-bypass-approvals-and-sandbox",
            fallbackProvider: "codex"
        )

        XCTAssertEqual(launch.provider, "codex")
        XCTAssertEqual(launch.command, "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust")
    }

    func testLaunchCommandUsesProviderSpecificPermissionModes() {
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "onRequest"),
            "codex --sandbox workspace-write --ask-for-approval on-request --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "readOnly"),
            "codex --sandbox read-only --ask-for-approval on-request --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "claude", permissionMode: "default"),
            "claude --permission-mode default"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "claude", permissionMode: "acceptEdits"),
            "claude --permission-mode acceptEdits"
        )
    }

    func testLaunchCommandSupportsPlanModeForBothProviders() {
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "claude", permissionMode: "fullAccess", planMode: true),
            "claude --permission-mode plan"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "claude", permissionMode: "plan"),
            "claude --permission-mode plan"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "onRequest", planMode: true),
            "codex -c 'collaboration_mode=\"plan\"' --sandbox workspace-write --ask-for-approval on-request --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "plan"),
            "codex -c 'collaboration_mode=\"plan\"' --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        )
    }

    func testResumeCommandUsesProviderResumeSyntax() {
        XCTAssertEqual(
            AgentLaunchCommand.resumeCommand(forProvider: "claude", sessionId: "8db44e39-685d-47ab-bd0e-5e97386ded80"),
            "claude --resume '8db44e39-685d-47ab-bd0e-5e97386ded80' --dangerously-skip-permissions"
        )
        XCTAssertEqual(
            AgentLaunchCommand.resumeCommand(forProvider: "codex", sessionId: "8db44e39-685d-47ab-bd0e-5e97386ded80"),
            "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume '8db44e39-685d-47ab-bd0e-5e97386ded80'"
        )
    }

    func testProviderResumeIdHeuristicRequiresRealUuidAndRejectsInternalIds() {
        XCTAssertTrue(AgentLaunchCommand.isLikelyProviderResumeSessionId("8db44e39-685d-47ab-bd0e-5e97386ded80"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("claude-internal-8db44e39-685d-47ab-bd0e-5e97386ded80"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("claude-ghostty-8db44e39-685d-47ab-bd0e-5e97386ded80"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("claude-internal-123"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("provider-session-claude-123"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("planner-node-session"))
    }
}
