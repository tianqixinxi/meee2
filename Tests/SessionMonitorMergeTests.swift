import XCTest
@testable import meee2Kit

/// Regression guard for the "session restore spawns N identical cards" bug:
/// `~/.claude/sessions/` can hold several PID.json files keyed to the SAME
/// sessionId (a restore was observed to leave 7). `mergeSessions` must collapse
/// them by id instead of letting each duplicate fall through as a "new" session.
final class SessionMonitorMergeTests: XCTestCase {

    private func makeSession(id: String, pid: Int, updated: Date) -> AISession {
        var s = AISession(id: id, pid: pid, cwd: "/tmp/project")
        s.lastUpdated = updated
        return s
    }

    func testSevenDuplicatePidFilesCollapseToOne() {
        let monitor = SessionMonitor()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 7 files, same sessionId, different pids/mtimes — what a restore leaves.
        let dupes = (0..<7).map { i in
            makeSession(id: "session-A", pid: 1000 + i, updated: base.addingTimeInterval(Double(i)))
        }

        let merged = monitor.mergeSessions(dupes, existing: [])

        XCTAssertEqual(merged.count, 1, "duplicate PID.json files for one sessionId must collapse to a single card")
        // Keep the most-recently-updated file (highest pid here, last mtime).
        XCTAssertEqual(merged.first?.pid, 1006)
    }

    func testDistinctSessionsArePreserved() {
        let monitor = SessionMonitor()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let input = [
            makeSession(id: "session-A", pid: 1, updated: now),
            makeSession(id: "session-A", pid: 2, updated: now.addingTimeInterval(1)),
            makeSession(id: "session-B", pid: 3, updated: now),
        ]

        let merged = monitor.mergeSessions(input, existing: [])

        XCTAssertEqual(Set(merged.map(\.id)), ["session-A", "session-B"])
        XCTAssertEqual(merged.count, 2)
    }

    func testRuntimeStateFromExistingIsPreservedOnMerge() {
        let monitor = SessionMonitor()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var existing = makeSession(id: "session-A", pid: 1, updated: now)
        existing.status = .tooling
        existing.currentTask = "running build"

        let merged = monitor.mergeSessions(
            [makeSession(id: "session-A", pid: 2, updated: now.addingTimeInterval(5))],
            existing: [existing]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.status, .tooling)
        XCTAssertEqual(merged.first?.currentTask, "running build")
    }
}
