import XCTest
@testable import meee2Kit

final class InternalTerminalRuntimeTests: XCTestCase {
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

    @MainActor
    func testPausedClientReceivesReplayWhenProcessExits() async throws {
        let sawInitialOutput = expectation(description: "saw initial output")
        let sawPausedReplay = expectation(description: "saw paused replay")
        let sawExit = expectation(description: "saw exit")
        let client = RuntimeCaptureClient(
            initialNeedle: "before",
            replayNeedle: "after",
            exitCode: 0,
            sawInitialOutput: sawInitialOutput,
            sawPausedReplay: sawPausedReplay,
            sawExit: sawExit
        )

        let snapshot = try InternalTerminalRuntime.shared.createSurface(
            provider: "claude",
            cwd: FileManager.default.temporaryDirectory.path,
            command: "/bin/sh -c 'printf before; sleep 0.3; printf after'",
            canvasId: nil,
            nodeId: nil,
            initialPrompt: nil,
            preferredSessionId: "test-paused-replay-\(UUID().uuidString)",
            cols: 80,
            rows: 24
        )
        defer {
            _ = InternalTerminalRuntime.shared.close(surfaceOrSessionId: snapshot.surfaceId)
        }

        XCTAssertTrue(InternalTerminalRuntime.shared.addClient(
            client,
            surfaceOrSessionId: snapshot.surfaceId,
            replay: true,
            wantsOutput: true
        ))

        await fulfillment(of: [sawInitialOutput], timeout: 2)
        XCTAssertNotNil(InternalTerminalRuntime.shared.pauseClientOutput(
            client,
            surfaceOrSessionId: snapshot.surfaceId
        ))

        await fulfillment(of: [sawPausedReplay, sawExit], timeout: 3)
        XCTAssertTrue(client.replayedText.contains("after"))
    }
}

@MainActor
private final class RuntimeCaptureClient: InternalTerminalSurfaceClient {
    private let initialNeedle: String
    private let replayNeedle: String
    private let exitCode: Int
    private let sawInitialOutput: XCTestExpectation
    private let sawPausedReplay: XCTestExpectation
    private let sawExit: XCTestExpectation
    private var didFulfillInitial = false
    private var didFulfillReplay = false
    private var didFulfillExit = false
    private(set) var receivedText = ""
    private(set) var replayedText = ""

    init(
        initialNeedle: String,
        replayNeedle: String,
        exitCode: Int,
        sawInitialOutput: XCTestExpectation,
        sawPausedReplay: XCTestExpectation,
        sawExit: XCTestExpectation
    ) {
        self.initialNeedle = initialNeedle
        self.replayNeedle = replayNeedle
        self.exitCode = exitCode
        self.sawInitialOutput = sawInitialOutput
        self.sawPausedReplay = sawPausedReplay
        self.sawExit = sawExit
    }

    func internalTerminalSurface(_ surfaceId: String, didReplayOutput text: String) {
        replayedText += text
        if !didFulfillReplay, replayedText.contains(replayNeedle) {
            didFulfillReplay = true
            sawPausedReplay.fulfill()
        }
    }

    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput text: String) {
        receivedText += text
        if !didFulfillInitial, receivedText.contains(initialNeedle) {
            didFulfillInitial = true
            sawInitialOutput.fulfill()
        }
    }

    func internalTerminalSurface(_ surfaceId: String, didExitWithCode code: Int) {
        guard !didFulfillExit, code == exitCode else { return }
        didFulfillExit = true
        sawExit.fulfill()
    }
}
