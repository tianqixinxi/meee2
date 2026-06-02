import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class TerminalSessionBackendTests: XCTestCase {
    func testTerminalSessionRequestCarriesWorkspaceSemantics() {
        let request = TerminalSessionRequest(
            provider: "codex",
            cwd: "/tmp/project",
            command: "codex",
            canvasId: "canvas-a",
            nodeId: "node-a",
            initialPrompt: "ship it",
            preferredSessionId: "session-a",
            cols: 100,
            rows: 28
        )

        XCTAssertEqual(request.provider, "codex")
        XCTAssertEqual(request.cwd, "/tmp/project")
        XCTAssertEqual(request.canvasId, "canvas-a")
        XCTAssertEqual(request.nodeId, "node-a")
        XCTAssertEqual(request.preferredSessionId, "session-a")
        XCTAssertEqual(request.cols, 100)
        XCTAssertEqual(request.rows, 28)
    }

    func testSessionTerminalInfoDecodesLegacyRecordsWithoutBackend() throws {
        let json = """
        {
          "sessionId": "session-a",
          "tty": null,
          "termProgram": "meee2-internal",
          "termBundleId": "meee2-internal",
          "cwd": "/tmp/project",
          "lastActivityAt": 10,
          "status": "running",
          "command": "claude",
          "provider": "claude",
          "providerResumeSessionId": null,
          "canvasId": "canvas-a",
          "nodeId": "node-a",
          "cmuxSocketPath": null,
          "cmuxSurfaceId": "surface-a"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionTerminalInfo.self, from: json)

        XCTAssertEqual(decoded.sessionId, "session-a")
        XCTAssertNil(decoded.backend)
    }

    func testTerminalSessionSnapshotExposesBackendKind() {
        let now = Date(timeIntervalSince1970: 10)
        let snapshot = TerminalSessionSnapshot(
            sessionId: "session-a",
            surfaceId: "surface-a",
            backend: .ghosttySurface,
            status: "running",
            pid: 42,
            cwd: "/tmp/project",
            command: "claude",
            provider: "claude",
            canvasId: "canvas-a",
            nodeId: "node-a",
            createdAt: now,
            updatedAt: now
        )

        XCTAssertEqual(snapshot.backend, .ghosttySurface)
        XCTAssertEqual(snapshot.surfaceId, "surface-a")
        XCTAssertNil(snapshot.fallbackReason)
    }

    func testTerminalSessionSnapshotCodableKeepsFallbackReason() throws {
        let now = Date(timeIntervalSince1970: 10)
        let snapshot = TerminalSessionSnapshot(
            sessionId: "session-a",
            surfaceId: "surface-a",
            backend: .ghosttySurface,
            status: "running",
            pid: nil,
            cwd: "/tmp/project",
            command: "claude",
            provider: "claude",
            canvasId: "canvas-a",
            nodeId: "node-a",
            createdAt: now,
            updatedAt: now,
            fallbackReason: "startup failed"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TerminalSessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.backend, .ghosttySurface)
        XCTAssertEqual(decoded.fallbackReason, "startup failed")
    }

    func testGhosttyPreferredBackendRequiresRegisteredBackend() {
        TerminalSessionBackendRegistry.shared.setPreferredKind(.ghosttySurface)
        defer {
            TerminalSessionBackendRegistry.shared.setPreferredKind(nil)
        }

        XCTAssertThrowsError(try TerminalSessionBackendRegistry.shared.createSession(
            request: TerminalSessionRequest(
                provider: "claude",
                cwd: NSTemporaryDirectory(),
                command: "shell",
                canvasId: "canvas-a",
                nodeId: "node-a",
                initialPrompt: nil
            )
        )) { error in
            XCTAssertEqual(
                error as? TerminalSessionBackendError,
                .backendUnavailable("ghostty-surface backend is not registered in this process")
            )
        }
    }

    func testStaleInternalSessionDTOIsNotNativeWorkspaceOpenable() {
        let now = Date(timeIntervalSince1970: 10)
        let terminalInfo = PluginTerminalInfo(
            tty: nil,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cmuxSocketPath: nil,
            cmuxSurfaceId: "surface-a",
            jumpHandlerId: "meee2-internal"
        )
        let session = SessionData(
            sessionId: "claude-internal-session-a",
            project: "project-a",
            cwd: "/tmp/project-a",
            startedAt: now,
            lastActivity: now,
            status: .active,
            currentTool: "terminal",
            terminalInfo: terminalInfo
        )
        let stored = SessionTerminalInfo(
            sessionId: session.sessionId,
            tty: nil,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cwd: "/tmp/project-a",
            lastActivityAt: now,
            status: "running",
            command: "claude",
            provider: "claude",
            providerResumeSessionId: "provider-session-a",
            canvasId: "canvas-a",
            nodeId: "node-a",
            backend: TerminalSessionBackendKind.external.rawValue,
            fallbackReason: nil,
            cmuxSocketPath: nil,
            cmuxSurfaceId: "surface-a"
        )

        let dto = BoardDTOBuilder.staleInternalSessionDTO(session, terminalInfo: stored)

        XCTAssertTrue(BoardDTOBuilder.isInternalTerminalProgram(dto.termProgram))
        XCTAssertEqual(dto.terminalKind, "internal")
        XCTAssertNil(dto.surfaceId)
        XCTAssertEqual(dto.surfaceStatus, "exited")
        XCTAssertFalse(dto.canOpenExternal)
        XCTAssertFalse(dto.nativeWorkspaceAvailable)
        XCTAssertEqual(dto.openTarget, "web-fallback")
        XCTAssertNil(dto.providerResumeSessionId)
    }

    func testNonJumpableExternalSessionKeepsResolvedLiveStatus() {
        let session = PluginSession(
            id: "sdk-session-a",
            pluginId: "com.meee2.plugin.claude",
            title: "SDK Session",
            status: .thinking,
            startedAt: Date(timeIntervalSince1970: 10),
            cwd: "/tmp/project-a",
            terminalInfo: nil
        )

        let dto = BoardDTOBuilder.sessionDTO(session)

        XCTAssertEqual(dto.status, SessionStatus.thinking.rawValue)
        XCTAssertFalse(dto.canOpenExternal)
        XCTAssertNil(dto.surfaceStatus)
    }
}
