import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class BoardSessionSnapshotProviderTests: XCTestCase {
    func testCurrentBoardSessionsHidesSyntheticE2ESessionsOutsideE2EMode() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["MEEE2_E2E"] == "1",
            "E2E mode intentionally keeps synthetic e2e-session-* records visible."
        )

        let store = SessionStore.shared
        let backup = store.sessions
        defer { store.sessions = backup }

        let e2eId = "e2e-session-\(UUID().uuidString)"
        let realId = "real-session-\(UUID().uuidString)"
        store.sessions = [
            makeSession(
                id: e2eId,
                project: "Meee2 E2E",
                currentTool: "WebFetch",
                currentTask: "Collecting product sentiment"
            ),
            makeSession(id: realId, project: "/tmp/real-session")
        ]

        let sessions = BoardSessionSnapshotProvider.currentBoardSessions()

        XCTAssertFalse(
            sessions.contains { $0.id == e2eId },
            "Synthetic E2E sessions must not pollute the normal Session list."
        )
        XCTAssertTrue(
            sessions.contains { $0.id == realId },
            "Filtering synthetic E2E sessions must not hide normal active sessions."
        )
    }

    func testVisibleStoredSessionsKeepsSyntheticE2ESessionsWhenRequested() {
        let e2e = makeSession(id: "e2e-session-\(UUID().uuidString)", project: "Meee2 E2E")
        let real = makeSession(id: "real-session-\(UUID().uuidString)", project: "/tmp/real-session")

        let normalMode = BoardSessionSnapshotProvider.visibleStoredSessions(
            [e2e, real],
            includeSyntheticE2ESessions: false
        )
        XCTAssertEqual(normalMode.map(\.sessionId), [real.sessionId])

        let e2eMode = BoardSessionSnapshotProvider.visibleStoredSessions(
            [e2e, real],
            includeSyntheticE2ESessions: true
        )
        XCTAssertEqual(e2eMode.map(\.sessionId), [e2e.sessionId, real.sessionId])
    }

    func testCurrentBoardSessionsHidesCliSessionAlreadyAdoptedByManagedSurface() {
        let store = SessionStore.shared
        let backup = store.sessions
        defer { store.sessions = backup }

        let cwd = "/tmp/meee2-board-session-provider-\(UUID().uuidString)"
        let providerSessionId = UUID().uuidString
        let surfaceId = "claude-ghostty-\(UUID().uuidString)"
        store.sessions = [
            makeSession(
                id: surfaceId,
                project: cwd,
                providerResumeSessionId: providerSessionId,
                terminalInfo: PluginTerminalInfo(
                    termProgram: "meee2-ghostty-surface",
                    termBundleId: "meee2-ghostty-surface"
                )
            ),
            makeSession(
                id: providerSessionId,
                project: cwd,
                terminalInfo: PluginTerminalInfo(
                    termProgram: "ghostty",
                    termBundleId: "com.mitchellh.ghostty"
                )
            )
        ]

        let sessions = BoardSessionSnapshotProvider.currentBoardSessions()

        XCTAssertTrue(
            sessions.contains { $0.id == surfaceId && $0.providerResumeSessionId == providerSessionId },
            "The managed surface remains the visible session and carries the provider resume id."
        )
        XCTAssertFalse(
            sessions.contains { $0.id == providerSessionId },
            "The adopted provider CLI session must not appear as a duplicate Session launcher row."
        )
    }

    private func makeSession(
        id: String,
        project: String,
        currentTool: String? = nil,
        currentTask: String? = nil,
        providerResumeSessionId: String? = nil,
        terminalInfo: PluginTerminalInfo? = nil
    ) -> SessionData {
        SessionData(
            sessionId: id,
            project: project,
            cwd: project,
            providerResumeSessionId: providerResumeSessionId,
            startedAt: Date(),
            lastActivity: Date(),
            status: .active,
            currentTool: currentTool,
            currentTask: currentTask,
            terminalInfo: terminalInfo
        )
    }
}
