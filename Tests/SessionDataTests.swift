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
            status: .active,
            currentTool: "Bash"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)

        XCTAssertEqual(decoded.sessionId, "test-123")
        XCTAssertEqual(decoded.project, "/tmp/dev/myproject")
        XCTAssertEqual(decoded.pid, 5678)
        XCTAssertEqual(decoded.status, .active)
        XCTAssertEqual(decoded.currentTool, "Bash")
    }

    /// 旧文件兼容：legacy status 字符串 ("running"/"waitingInput"/...) 应迁移到新枚举
    func testLegacyStatusStringMigration() throws {
        let legacy = """
        {
            "session_id": "legacy-1",
            "project": "/tmp",
            "started_at": "2026-01-01T00:00:00Z",
            "last_activity": "2026-01-01T00:01:00Z",
            "status": "running"
        }
        """
        let data = try JSONDecoder().decode(SessionData.self, from: legacy.data(using: .utf8)!)
        XCTAssertEqual(data.status, .active)
    }

    /// 旧文件：同时有 detailed_status，应优先采用
    func testLegacyDetailedStatusWins() throws {
        let legacy = """
        {
            "session_id": "legacy-2",
            "project": "/tmp",
            "started_at": "2026-01-01T00:00:00Z",
            "last_activity": "2026-01-01T00:01:00Z",
            "status": "running",
            "detailed_status": "tooling"
        }
        """
        let data = try JSONDecoder().decode(SessionData.self, from: legacy.data(using: .utf8)!)
        XCTAssertEqual(data.status, .tooling)
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
            status: .active
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
            status: .idle
        )
        XCTAssertEqual(session.progress, "0/0")
    }

    // MARK: - Terminal Info

    func testTerminalInfoRoundTrip() throws {
        var original = SessionData(
            sessionId: "term-test",
            project: "/tmp",
            status: .active
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
            status: .active
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
        let session = SessionData(sessionId: "my-id", project: "/tmp", status: .idle)
        XCTAssertEqual(session.id, "my-id")
    }

    // MARK: - Schema 版本迁移

    /// 没有 schema_version 字段的旧文件应解码为 v0，并可被迁移器升级到 currentSchemaVersion
    func testLegacyFileDecodesAsV0AndMigrates() throws {
        let legacy = """
        {
            "session_id": "legacy-vX",
            "project": "/tmp",
            "started_at": "2026-01-01T00:00:00Z",
            "last_activity": "2026-01-01T00:01:00Z",
            "status": "tooling"
        }
        """
        let decoded = try JSONDecoder().decode(SessionData.self, from: legacy.data(using: .utf8)!)
        XCTAssertEqual(decoded.schemaVersion, 0, "missing schema_version should decode as 0")

        let migrated = SessionDataMigrations.apply(to: decoded, from: decoded.schemaVersion)
        XCTAssertEqual(migrated.schemaVersion, SessionData.currentSchemaVersion)
        XCTAssertEqual(migrated.status, .tooling, "migration should not change semantic fields")
        XCTAssertEqual(migrated.sessionId, "legacy-vX")
    }

    /// 新建记录默认就是最新版本，且 round-trip 后版本保持不变
    func testNewRecordIsCurrentSchemaVersion() throws {
        let s = SessionData(sessionId: "fresh", project: "/tmp", status: .idle)
        XCTAssertEqual(s.schemaVersion, SessionData.currentSchemaVersion)

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, SessionData.currentSchemaVersion)
    }

    /// 编码出的 JSON 必须带 schema_version 键，给外部工具/迁移脚本识别
    func testEncodedJSONContainsSchemaVersion() throws {
        let s = SessionData(sessionId: "x", project: "/tmp", status: .idle)
        let data = try JSONEncoder().encode(s)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, SessionData.currentSchemaVersion)
    }
}
