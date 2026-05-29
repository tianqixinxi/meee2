import XCTest
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
            backend: .legacyInternal,
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

        XCTAssertEqual(snapshot.backend, .legacyInternal)
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
            fallbackReason: "legacy fallback"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TerminalSessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.backend, .ghosttySurface)
        XCTAssertEqual(decoded.fallbackReason, "legacy fallback")
    }
}
