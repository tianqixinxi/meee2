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
