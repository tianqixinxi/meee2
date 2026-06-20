import XCTest
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

    private func makeSession(
        id: String,
        project: String,
        currentTool: String? = nil,
        currentTask: String? = nil
    ) -> SessionData {
        SessionData(
            sessionId: id,
            project: project,
            cwd: project,
            startedAt: Date(),
            lastActivity: Date(),
            status: .active,
            currentTool: currentTool,
            currentTask: currentTask
        )
    }
}
