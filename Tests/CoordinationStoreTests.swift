import XCTest
@testable import meee2Kit

final class CoordinationStoreTests: XCTestCase {
    private func tempStore(_ name: String = UUID().uuidString) -> CoordinationStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-coordination-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return CoordinationStore(fileURL: dir.appendingPathComponent("\(name).json"))
    }

    func testCreateGroupPersistsHybridCoordinatorState() throws {
        let store = tempStore()
        let group = try store.createGroup(
            canvasId: "canvas-a",
            coordinatorSessionId: nil,
            pendingSpawnIntentId: "intent-a",
            memberSessionIds: ["s1", "s2", "s1"],
            goal: "Coordinate work"
        )

        XCTAssertEqual(group.mode, "hybrid")
        XCTAssertEqual(group.canvasId, "canvas-a")
        XCTAssertEqual(group.pendingSpawnIntentId, "intent-a")
        XCTAssertEqual(group.memberSessionIds, ["s1", "s2"])
        XCTAssertFalse(group.paused)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testBindCoordinatorBySpawnIntent() throws {
        let store = tempStore()
        let group = try store.createGroup(
            canvasId: "canvas-a",
            coordinatorSessionId: nil,
            pendingSpawnIntentId: "intent-a",
            memberSessionIds: ["s1"],
            goal: "Coordinate work"
        )

        store.bindCoordinator(spawnIntentId: "intent-a", sessionId: "coord-1")

        let updated = try store.group(id: group.id)
        XCTAssertEqual(updated.coordinatorSessionId, "coord-1")
        XCTAssertNil(updated.pendingSpawnIntentId)
    }

    func testCompactContextIsBudgeted() throws {
        let store = tempStore()
        let group = try store.createGroup(
            canvasId: "canvas-a",
            coordinatorSessionId: "coord-1",
            pendingSpawnIntentId: nil,
            memberSessionIds: ["s1"],
            goal: String(repeating: "g", count: 10_000)
        )
        _ = try store.updateDigest(
            groupId: group.id,
            sessionId: "s1",
            summary: String(repeating: "a", count: 20_000),
            blockers: [String(repeating: "b", count: 2_000)],
            lastDecision: nil,
            currentTask: nil
        )

        let context = try store.compactContext(groupId: group.id, reason: "manual", changedSessionIds: ["s1"])
        XCTAssertLessThanOrEqual(context.count, CoordinationStore.compactContextLimit + 1)
        XCTAssertTrue(context.contains("Goal:"))
    }

    func testPauseResumeAndRemoveMember() throws {
        let store = tempStore()
        let group = try store.createGroup(
            canvasId: "canvas-a",
            coordinatorSessionId: "coord-1",
            pendingSpawnIntentId: nil,
            memberSessionIds: ["s1", "s2"],
            goal: "Coordinate work"
        )

        XCTAssertTrue(try store.setPaused(groupId: group.id, paused: true).paused)
        XCTAssertFalse(try store.setPaused(groupId: group.id, paused: false).paused)
        let updated = try store.removeMember(groupId: group.id, sessionId: "s1")
        XCTAssertEqual(updated.memberSessionIds, ["s2"])
        XCTAssertNil(updated.memberDigests["s1"])
    }
}
