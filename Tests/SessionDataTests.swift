import XCTest
@testable import meee2Kit
import Meee2PluginKit

final class SessionDataTests: XCTestCase {

    // MARK: - Encode/Decode Round Trip

    func testCodableRoundTrip() throws {
        let original = SessionData(
            sessionId: "test-123",
            project: "/tmp/dev/myproject",
            pid: 5678,
            startedAt: Date(timeIntervalSince1970: 1713100000),
            lastActivity: Date(timeIntervalSince1970: 1713100100),
            status: "running",
            detailedStatus: .active,
            currentTool: "Bash"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)

        XCTAssertEqual(decoded.sessionId, "test-123")
        XCTAssertEqual(decoded.project, "/tmp/dev/myproject")
        XCTAssertEqual(decoded.pid, 5678)
        XCTAssertEqual(decoded.status, "running")
        XCTAssertEqual(decoded.detailedStatus, .active)
        XCTAssertEqual(decoded.currentTool, "Bash")
    }

    func testDecodeWithMissingOptionalFields() throws {
        let json = """
        {
            "session_id": "minimal",
            "project": "/tmp",
            "started_at": "2026-01-01T00:00:00Z",
            "last_activity": "2026-01-01T00:01:00Z",
            "status": "idle"
        }
        """
        let data = try JSONDecoder().decode(SessionData.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(data.sessionId, "minimal")
        XCTAssertNil(data.pid)
        XCTAssertNil(data.currentTool)
        XCTAssertNil(data.terminalInfo)
        XCTAssertNil(data.usageStats)
        XCTAssertNil(data.lastMessage)
        XCTAssertNil(data.pendingPermissionTool)
    }

    // MARK: - Progress

    func testProgressWithTasks() {
        var session = SessionData(
            sessionId: "s",
            project: "/tmp",
            status: "running"
        )
        session.tasks = [
            SessionTask(id: "1", name: "Task 1", status: .done),
            SessionTask(id: "2", name: "Task 2", status: .inProgress),
            SessionTask(id: "3", name: "Task 3", status: .completed),
        ]
        XCTAssertEqual(session.progress, "2/3")
    }

    func testProgressWithNoTasks() {
        let session = SessionData(
            sessionId: "s",
            project: "/tmp",
            status: "idle"
        )
        XCTAssertEqual(session.progress, "0/0")
    }

    // MARK: - Terminal Info

    func testTerminalInfoRoundTrip() throws {
        var original = SessionData(
            sessionId: "term-test",
            project: "/tmp",
            status: "running"
        )
        original.terminalInfo = PluginTerminalInfo(
            tty: "ttys001",
            termProgram: "ghostty",
            termBundleId: "com.mitchellh.ghostty",
            cmuxSocketPath: nil,
            cmuxSurfaceId: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)

        XCTAssertEqual(decoded.terminalInfo?.tty, "ttys001")
        XCTAssertEqual(decoded.terminalInfo?.termProgram, "ghostty")
    }

    // MARK: - Pending Permission

    func testPendingPermissionFields() throws {
        var session = SessionData(
            sessionId: "perm-test",
            project: "/tmp",
            status: "running"
        )
        session.pendingPermissionTool = "Bash"
        session.pendingPermissionMessage = "Run: rm -rf /tmp/test"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)

        XCTAssertEqual(decoded.pendingPermissionTool, "Bash")
        XCTAssertEqual(decoded.pendingPermissionMessage, "Run: rm -rf /tmp/test")
    }

    // MARK: - ID

    func testIdIsSessionId() {
        let session = SessionData(sessionId: "my-id", project: "/tmp", status: "idle")
        XCTAssertEqual(session.id, "my-id")
    }
}
