import XCTest
@testable import meee2Kit

final class AgentLaunchCommandTests: XCTestCase {
    func testNormalizeDowngradesClaudeInternalResumeToFreshCommand() {
        let launch = AgentLaunchCommand.normalize(
            command: "claude --resume 'claude-internal-123' --dangerously-skip-permissions",
            fallbackProvider: "claude"
        )

        XCTAssertEqual(launch.provider, "claude")
        XCTAssertEqual(launch.command, "claude --permission-mode default")
    }

    func testNormalizeDowngradesCodexInternalResumeToFreshCommand() {
        let launch = AgentLaunchCommand.normalize(
            command: "codex --dangerously-bypass-approvals-and-sandbox resume codex-internal-123",
            fallbackProvider: "codex"
        )

        XCTAssertEqual(launch.provider, "codex")
        XCTAssertEqual(launch.command, "codex --sandbox workspace-write --ask-for-approval on-request")
    }

    func testNormalizeDowngradesGhosttySurfaceResumeToFreshCommand() {
        let launch = AgentLaunchCommand.normalize(
            command: "claude --resume 'claude-ghostty-123' --dangerously-skip-permissions",
            fallbackProvider: "claude"
        )

        XCTAssertEqual(launch.provider, "claude")
        XCTAssertEqual(launch.command, "claude --permission-mode default")
    }

    func testNormalizeKeepsProviderResumeIds() {
        let launch = AgentLaunchCommand.normalize(
            command: "claude --resume 8db44e39-685d-47ab-bd0e-5e97386ded80",
            fallbackProvider: "claude"
        )

        XCTAssertEqual(launch.provider, "claude")
        XCTAssertEqual(launch.command, "claude --resume 8db44e39-685d-47ab-bd0e-5e97386ded80 --permission-mode default")
    }

    func testNormalizePreservesExplicitFullAccessWithoutSilentlyBypassingHookTrust() {
        let launch = AgentLaunchCommand.normalize(
            command: "codex --dangerously-bypass-approvals-and-sandbox",
            fallbackProvider: "codex"
        )

        XCTAssertEqual(launch.provider, "codex")
        XCTAssertEqual(launch.command, "codex --dangerously-bypass-approvals-and-sandbox")
    }

    func testLaunchCommandUsesProviderSpecificPermissionModes() {
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "onRequest"),
            "codex --sandbox workspace-write --ask-for-approval on-request"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "readOnly"),
            "codex --sandbox read-only --ask-for-approval on-request"
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
            "codex --sandbox workspace-write --ask-for-approval on-request"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "plan"),
            "codex --sandbox workspace-write --ask-for-approval on-request"
        )
    }

    func testLauncherInitialPromptUsesCodexPlanSlashCommand() {
        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(forProvider: "codex", planMode: true, initialPrompt: "ship the launcher fix"),
            "/plan ship the launcher fix"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(forProvider: "codex", planMode: true, initialPrompt: "   "),
            "/plan"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(forProvider: "codex", planMode: false, initialPrompt: "  ship it  "),
            "ship it"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(forProvider: "claude", planMode: true, initialPrompt: "  plan this  "),
            "plan this"
        )
    }

    func testLauncherInitialPromptPrefixesAttachmentPaths() {
        let attachments = [
            AgentLaunchAttachment(path: "/tmp/screenshot.png", filename: "screenshot.png", contentType: "image/png"),
            AgentLaunchAttachment(path: "/tmp/spec.md", filename: "spec.md", contentType: "text/markdown")
        ]

        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(
                forProvider: "codex",
                planMode: false,
                initialPrompt: "review these",
                attachments: attachments
            ),
            "@/tmp/screenshot.png\n@/tmp/spec.md\nreview these"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(
                forProvider: "codex",
                planMode: true,
                initialPrompt: "review these",
                attachments: attachments
            ),
            "/plan @/tmp/screenshot.png\n@/tmp/spec.md\nreview these"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherInitialPrompt(
                forProvider: "claude",
                planMode: false,
                initialPrompt: "   ",
                attachments: [attachments[0]]
            ),
            "@/tmp/screenshot.png"
        )
    }

    func testLauncherDisplayPromptStripsCodexPlanSlashCommand() {
        XCTAssertEqual(
            AgentLaunchCommand.launcherDisplayPrompt(forDeliveredInitialPrompt: "/plan ship the launcher fix"),
            "ship the launcher fix"
        )
        XCTAssertNil(
            AgentLaunchCommand.launcherDisplayPrompt(forDeliveredInitialPrompt: "/plan")
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherDisplayPrompt(forDeliveredInitialPrompt: "ship it"),
            "ship it"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherDisplayPrompt(
                forDeliveredInitialPrompt: "@/tmp/screenshot.png\n@/tmp/spec.md\nreview these"
            ),
            "review these"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherDisplayPrompt(
                forDeliveredInitialPrompt: "@/tmp/My Project/screenshot.png\nreview these"
            ),
            "review these"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launcherDisplayPrompt(
                forDeliveredInitialPrompt: "/plan @/tmp/screenshot.png\n@/tmp/spec.md\nreview these"
            ),
            "review these"
        )
        XCTAssertNil(
            AgentLaunchCommand.launcherDisplayPrompt(forDeliveredInitialPrompt: "@/tmp/screenshot.png")
        )
    }

    func testResumeCommandUsesProviderResumeSyntax() {
        XCTAssertEqual(
            AgentLaunchCommand.resumeCommand(forProvider: "claude", sessionId: "8db44e39-685d-47ab-bd0e-5e97386ded80"),
            "claude --permission-mode default --resume '8db44e39-685d-47ab-bd0e-5e97386ded80'"
        )
        XCTAssertEqual(
            AgentLaunchCommand.resumeCommand(forProvider: "codex", sessionId: "8db44e39-685d-47ab-bd0e-5e97386ded80"),
            "codex --sandbox workspace-write --ask-for-approval on-request resume '8db44e39-685d-47ab-bd0e-5e97386ded80'"
        )
        XCTAssertEqual(
            AgentLaunchCommand.resumeCommand(
                forProvider: "codex",
                sessionId: "8db44e39-685d-47ab-bd0e-5e97386ded80",
                permissionMode: "fullAccess"
            ),
            "codex --dangerously-bypass-approvals-and-sandbox resume '8db44e39-685d-47ab-bd0e-5e97386ded80'"
        )
    }

    func testMissingOrUnknownPermissionModeDefaultsToOnRequest() {
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "claude", permissionMode: nil),
            "claude --permission-mode default"
        )
        XCTAssertEqual(
            AgentLaunchCommand.launchCommand(forProvider: "codex", permissionMode: "legacy-unknown"),
            "codex --sandbox workspace-write --ask-for-approval on-request"
        )
        XCTAssertEqual(
            AgentLaunchCommand.fullAccessCommand(forProvider: "codex"),
            "codex --dangerously-bypass-approvals-and-sandbox"
        )
    }

    func testProviderResumeIdHeuristicRequiresRealUuidAndRejectsInternalIds() {
        XCTAssertTrue(AgentLaunchCommand.isLikelyProviderResumeSessionId("8db44e39-685d-47ab-bd0e-5e97386ded80"))
        XCTAssertTrue(AgentLaunchCommand.isLikelyProviderResumeSessionId("019ecba0-beb9-7dc3-b779-33f7f06453c0"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("claude-internal-8db44e39-685d-47ab-bd0e-5e97386ded80"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("claude-ghostty-8db44e39-685d-47ab-bd0e-5e97386ded80"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("claude-internal-123"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("provider-session-claude-123"))
        XCTAssertFalse(AgentLaunchCommand.isLikelyProviderResumeSessionId("planner-node-session"))
    }
}
