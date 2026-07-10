import XCTest
import Swifter
@testable import meee2Kit

final class BoardStateReadPurityTests: XCTestCase {
    func testRepeatedStateReadsDoNotConsumeSpawnIntentOrDeliverPrompt() throws {
        let sessionStore = SessionStore.shared
        let originalSessions = sessionStore.sessions
        defer { sessionStore.sessions = originalSessions }

        let layoutStore = BoardLayoutStore.shared
        let canvasName = "state-read-purity-\(UUID().uuidString)"
        let created = try layoutStore.createCanvas(name: canvasName, scope: .personal)
        let canvas = try XCTUnwrap(created.canvases.first { $0.name == canvasName })
        defer { _ = try? layoutStore.deleteCanvas(id: canvas.id) }

        let cwd = "/tmp/meee2-state-read-\(UUID().uuidString)"
        let intent = try layoutStore.recordSpawnIntent(
            canvasId: canvas.id,
            cwd: cwd,
            command: "claude",
            provider: "claude",
            purpose: "test:get-state-purity",
            initialPrompt: "this must not be delivered by GET",
            layoutHint: nil
        )
        let sessionId = "state-read-session-\(UUID().uuidString)"
        let startedAt = Date().addingTimeInterval(0.1)
        sessionStore.sessions = [
            SessionData(
                sessionId: sessionId,
                project: cwd,
                cwd: cwd,
                startedAt: startedAt,
                lastActivity: startedAt,
                status: .active
            )
        ]

        let request = HttpRequest()
        request.method = "GET"
        request.path = "/api/state"
        _ = BoardAPI.getState(request)
        _ = BoardAPI.getState(request)

        // If either GET reconciled, it would have consumed the intent and
        // deliverMatchedSpawnPrompts would have queued its initial prompt.
        let matches = layoutStore.applySpawnIntents(candidates: [
            BoardLayoutStore.SpawnCandidate(
                sessionId: sessionId,
                cwd: cwd,
                provider: "claude",
                startedAt: startedAt
            )
        ])
        XCTAssertEqual(matches.map(\.intent.id), [intent.id])
    }
}
