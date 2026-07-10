import Combine
import XCTest
@testable import meee2Kit

final class SessionStoreConcurrencyTests: XCTestCase {
    func testTenThousandHookAndOneThousandAPIMutationsConvergeUnderTSan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-session-concurrency-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(baseDirectory: root)

        let publicationViolation = LockedFlag()
        let cancellable = store.$sessions.dropFirst().sink { _ in
            if !Thread.isMainThread { publicationViolation.set() }
        }
        defer { cancellable.cancel() }

        await withTaskGroup(of: Void.self) { group in
            // Release-gate load: hook ingress dominates writes, while Board/CLI
            // mutations race against the same repository domain.
            for index in 0..<10_000 {
                group.addTask {
                    let sessionId = "session-\(index % 100)"
                    let session = SessionData(
                        sessionId: sessionId,
                        project: "project",
                        cwd: root.path,
                        transcriptPath: root.appendingPathComponent("\(sessionId).jsonl").path,
                        startedAt: Date(),
                        lastActivity: Date(),
                        status: .active
                    )
                    store.upsert(session)
                }
            }
            for index in 0..<1_000 {
                group.addTask {
                    let sessionId = "session-\(index % 100)"
                    store.update(sessionId) { value in
                        value.currentTool = "api-tool-\(index)"
                    }
                }
            }
        }

        // A deterministic final API revision proves all writers converge on
        // one snapshot after the concurrent phase, independent of ordering.
        for index in 0..<100 {
            store.update("session-\(index)") { value in
                value.currentTool = "final-\(index)"
            }
        }
        XCTAssertFalse(publicationViolation.value)
        XCTAssertEqual(store.listAll().count, 100)
        XCTAssertTrue(store.listAll().allSatisfy { $0.currentTool?.hasPrefix("final-") == true })
    }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
