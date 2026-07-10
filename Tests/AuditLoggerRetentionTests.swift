import XCTest
import Meee2CommKit

final class AuditLoggerRetentionTests: XCTestCase {
    private let fileManager = FileManager.default

    func testRetentionDropsExpiredEventsAndBoundsFileByBytes() {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = AuditRetentionPolicy(
            maxAge: 30 * 24 * 60 * 60,
            maxBytes: 1_200,
            pruneInterval: 0
        )
        let logger = AuditLogger(storage: paths, retentionPolicy: policy, now: { now })

        logger.log(event(id: "expired", at: now.addingTimeInterval(-31 * 24 * 60 * 60)))
        for index in 0..<12 {
            logger.log(event(
                id: "recent-\(index)",
                at: now.addingTimeInterval(TimeInterval(index)),
                details: String(repeating: "x", count: 120)
            ))
        }

        let retained = logger.query(limit: 100)
        XCTAssertFalse(retained.contains { $0.msgId == "expired" })
        XCTAssertTrue(retained.contains { $0.msgId == "recent-11" })
        XCTAssertLessThan(retained.count, 12)
        XCTAssertLessThanOrEqual(logger.sizeBytes(), policy.maxBytes)
    }

    func testConcurrentLoggerInstancesAppendAndCompactWithoutLostOrTornLines() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = AuditRetentionPolicy(
            maxAge: 30 * 24 * 60 * 60,
            maxBytes: 2 * 1_024 * 1_024,
            pruneInterval: 0
        )
        let first = AuditLogger(storage: paths, retentionPolicy: policy, now: { now })
        let second = AuditLogger(storage: paths, retentionPolicy: policy, now: { now })

        DispatchQueue.concurrentPerform(iterations: 120) { index in
            let logger = index.isMultiple(of: 2) ? first : second
            logger.log(self.event(id: "concurrent-\(index)", at: now))
        }

        let retained = first.query(limit: 500)
        XCTAssertEqual(retained.count, 120)
        XCTAssertEqual(Set(retained.map(\.msgId)).count, 120)
        let rawLines = try String(contentsOf: first.logFileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(rawLines.count, 120)
    }

    func testFactoryResetRemovesAuditLogAndLoggerCanAppendAgain() {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let logger = AuditLogger(storage: paths, now: { now })
        logger.log(event(id: "before-reset", at: now))
        XCTAssertGreaterThan(logger.sizeBytes(), 0)

        logger.resetForFactoryReset()
        XCTAssertFalse(fileManager.fileExists(atPath: logger.logFileURL.path))

        logger.log(event(id: "after-reset", at: now))
        XCTAssertEqual(logger.query(limit: 10).map(\.msgId), ["after-reset"])
    }

    private func event(
        id: String,
        at date: Date,
        details: String? = nil
    ) -> AuditEvent {
        AuditEvent(
            ts: date,
            event: .created,
            msgId: id,
            channel: "retention-test",
            fromAlias: "source",
            toAlias: "target",
            actor: "system",
            details: details
        )
    }

    private func temporaryRoot() -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("audit-retention-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
