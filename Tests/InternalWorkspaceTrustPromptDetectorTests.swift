import XCTest
@testable import meee2Kit
import Meee2CommKit

final class InternalWorkspaceTrustPromptDetectorTests: XCTestCase {
    private func managedWorkspace(_ suffix: String) -> String {
        StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("workspaces/global/\(suffix)", isDirectory: true)
            .path
    }

    func testWorkspaceTrustPromptDetectorMatchesClaudeFolderPrompt() {
        let prompt = """
        Do you trust the files in this folder?
        1. Yes, proceed
        2. No, exit
        """

        XCTAssertTrue(InternalWorkspaceTrustPromptDetector.shouldAutoAccept(
            provider: "claude",
            command: "claude --dangerously-skip-permissions",
            output: prompt
        ))
        XCTAssertEqual(InternalWorkspaceTrustPromptDetector.response(for: prompt), "1\r")
    }

    func testWorkspaceTrustPromptDetectorUsesYForYesNoPrompts() {
        let prompt = "Do you trust the files in this folder? [y/n]"

        XCTAssertTrue(InternalWorkspaceTrustPromptDetector.shouldAutoAccept(
            provider: "claude",
            command: "claude",
            output: prompt
        ))
        XCTAssertEqual(InternalWorkspaceTrustPromptDetector.response(for: prompt), "y\r")
    }

    func testWorkspaceTrustPromptDetectorMatchesClaudeQuickSafetyCheckPrompt() {
        let prompt = """
        Accessing workspace:
        /Users/kai/.meee2/workspaces/global/lark-meeting-founders-5702a82b

        Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source
        project, or work from your team). If not, take a moment to review what's in this folder first.

        Claude Code'll be able to read, edit, and execute files here.

        Security guide

        1. Yes, I trust this folder
        2. No, exit

        Enter to confirm · Esc to cancel
        """

        XCTAssertTrue(InternalWorkspaceTrustPromptDetector.shouldAutoAccept(
            provider: "claude",
            command: "claude --dangerously-skip-permissions",
            output: prompt
        ))
        XCTAssertEqual(InternalWorkspaceTrustPromptDetector.response(for: prompt), "\r")
    }

    func testWorkspaceTrustPromptDetectorIgnoresNonClaudeAndTrustErrors() {
        XCTAssertFalse(InternalWorkspaceTrustPromptDetector.shouldAutoAccept(
            provider: "codex",
            command: "codex",
            output: "Do you trust the files in this folder?"
        ))
        XCTAssertFalse(InternalWorkspaceTrustPromptDetector.shouldAutoAccept(
            provider: "claude",
            command: "claude",
            output: "/goal is only available in trusted workspaces. Restart, accept the trust dialog, and try again."
        ))
    }

    func testWorkspaceTrustPromptDetectorAllowsProactiveMeee2ClaudeWorkspaces() {
        let workspace = managedWorkspace("lark-meeting-founders")

        XCTAssertTrue(InternalWorkspaceTrustPromptDetector.shouldProactivelyAutoAccept(
            provider: "claude",
            command: "claude --dangerously-skip-permissions",
            cwd: workspace
        ))
    }

    func testWorkspaceTrustPromptDetectorDoesNotProactivelyAcceptOutsideMeee2Workspaces() {
        XCTAssertFalse(InternalWorkspaceTrustPromptDetector.shouldProactivelyAutoAccept(
            provider: "claude",
            command: "claude --dangerously-skip-permissions",
            cwd: FileManager.default.temporaryDirectory.path
        ))
        XCTAssertFalse(InternalWorkspaceTrustPromptDetector.shouldProactivelyAutoAccept(
            provider: "codex",
            command: "codex",
            cwd: managedWorkspace("demo")
        ))
    }

    func testInternalSessionIdentityMatchesManagedWorkspaceMirrors() {
        let workspace = managedWorkspace("lark-meeting-founders")
        let internalCwds = Set([InternalSessionIdentity.normalizedManagedWorkspacePath(workspace)!])

        XCTAssertTrue(InternalSessionIdentity.externalManagedWorkspaceMatchesInternal(
            cwd: workspace,
            internalManagedWorkspaceCwds: internalCwds
        ))
        XCTAssertTrue(InternalSessionIdentity.externalManagedWorkspaceMatchesInternal(
            cwd: workspace + "/../lark-meeting-founders",
            internalManagedWorkspaceCwds: internalCwds
        ))
        XCTAssertFalse(InternalSessionIdentity.externalManagedWorkspaceMatchesInternal(
            cwd: FileManager.default.temporaryDirectory.path,
            internalManagedWorkspaceCwds: internalCwds
        ))
    }
}
