import XCTest
@testable import meee2Kit

final class AISessionTests: XCTestCase {

    // MARK: - JSON Decoding

    func testDecodeFromMillisecondTimestamp() throws {
        let json = """
        {
            "sessionId": "test-session-1",
            "pid": 12345,
            "cwd": "/tmp/test/projects/myapp",
            "startedAt": 1713100000000,
            "kind": "interactive",
            "entrypoint": "cli"
        }
        """
        let session = try JSONDecoder().decode(AISession.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(session.id, "test-session-1")
        XCTAssertEqual(session.pid, 12345)
        XCTAssertEqual(session.cwd, "/tmp/test/projects/myapp")
        XCTAssertEqual(session.kind, "interactive")
        XCTAssertEqual(session.entrypoint, "cli")
        // Verify millisecond conversion: 1713100000000ms = 1713100000s
        XCTAssertEqual(session.startedAt.timeIntervalSince1970, 1713100000.0, accuracy: 0.001)
    }

    func testDecodeFromSecondTimestamp() throws {
        let json = """
        {
            "sessionId": "test-session-2",
            "pid": 99999,
            "cwd": "/tmp/test",
            "startedAt": 1713100000.5,
            "kind": "interactive",
            "entrypoint": "cli"
        }
        """
        let session = try JSONDecoder().decode(AISession.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(session.startedAt.timeIntervalSince1970, 1713100000.5, accuracy: 0.001)
    }

    // MARK: - Encode/Decode Round Trip

    func testCodableRoundTrip() throws {
        let original = AISession(
            id: "round-trip-test",
            pid: 42,
            cwd: "/tmp/test",
            startedAt: Date(timeIntervalSince1970: 1713100000),
            kind: "interactive",
            entrypoint: "cli"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AISession.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.pid, original.pid)
        XCTAssertEqual(decoded.cwd, original.cwd)
        // Millisecond precision in encoding
        XCTAssertEqual(decoded.startedAt.timeIntervalSince1970, original.startedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Computed Properties

    func testProjectName() {
        let session = AISession(id: "s", pid: 1, cwd: "/tmp/dev/projects/meee2")
        XCTAssertEqual(session.projectName, "meee2")
    }

    func testProjectNameRootPath() {
        let session = AISession(id: "s", pid: 1, cwd: "/")
        XCTAssertEqual(session.projectName, "/")
    }

    func testProjectNameNestedPath() {
        let session = AISession(id: "s", pid: 1, cwd: "/tmp/dev/projects/company/frontend")
        XCTAssertEqual(session.projectName, "frontend")
    }

    // MARK: - Status

    func testDefaultStatus() {
        let session = AISession(id: "s", pid: 1, cwd: "/tmp")
        XCTAssertEqual(session.status, .active)
    }

    func testDefaultType() {
        let session = AISession(id: "s", pid: 1, cwd: "/tmp")
        XCTAssertEqual(session.type, .claude)
    }

    // MARK: - Hashable

    func testHashableById() {
        let s1 = AISession(id: "same-id", pid: 1, cwd: "/a")
        let s2 = AISession(id: "same-id", pid: 2, cwd: "/b")
        XCTAssertEqual(s1, s2) // Same id = equal

        let s3 = AISession(id: "different-id", pid: 1, cwd: "/a")
        XCTAssertNotEqual(s1, s3)
    }
}
