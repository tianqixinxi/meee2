import XCTest
import Swifter
@testable import meee2Kit

final class BoardSessionRenameTests: XCTestCase {
    func testRenamePersistsCustomTitleAndBoardDTOPrefersIt() throws {
        let sessionId = "rename-session-\(UUID().uuidString)"
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-rename-\(UUID().uuidString)", isDirectory: true)
            .path
        let session = SessionData(
            sessionId: sessionId,
            project: cwd,
            cwd: cwd,
            status: .active,
            generatedTitle: "自动标题"
        )
        SessionStore.shared.create(session)
        defer { SessionStore.shared.delete(sessionId) }

        let request = HttpRequest()
        request.method = "PATCH"
        request.path = "/api/sessions/\(sessionId)"
        request.params[":id"] = sessionId
        request.body = Array(#"{"title":"用户标题"}"#.utf8)

        _ = BoardAPI.renameSession(request)

        XCTAssertEqual(SessionStore.shared.get(sessionId)?.customTitle, "用户标题")
        let snapshot = TerminalSessionSnapshot(
            sessionId: sessionId,
            surfaceId: sessionId,
            backend: .ghosttySurface,
            status: "running",
            pid: nil,
            cwd: cwd,
            command: "claude",
            provider: "claude",
            canvasId: nil,
            nodeId: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertEqual(BoardDTOBuilder.internalSessionDTO(snapshot).title, "用户标题")
    }
}
