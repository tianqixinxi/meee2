import XCTest
@testable import meee2Kit

/// Regression for the recap-respawn hang: the per-canvas local-run gate must
/// cap `claude -p` recap spawns to at most one in-flight + a cooldown, so a
/// failing recap can never spin in a tight loop and starve the app.
final class AssistantLocalRunGateTests: XCTestCase {

    /// A second acquire for the same canvas is refused while the first lease is
    /// still in flight (max-in-flight = 1) — the core anti-storm invariant.
    func testRejectsSecondConcurrentRunForSameCanvas() {
        let gate = AssistantLocalRunGate(cooldown: 8)
        let first = gate.acquire(key: "canvas-a")
        XCTAssertNotNil(first, "first run for a canvas should acquire")
        XCTAssertNil(gate.acquire(key: "canvas-a"),
                     "a second concurrent run for the same canvas must be refused")
    }

    /// Different canvases don't block each other.
    func testDifferentCanvasesAreIndependent() {
        let gate = AssistantLocalRunGate(cooldown: 8)
        XCTAssertNotNil(gate.acquire(key: "canvas-a"))
        XCTAssertNotNil(gate.acquire(key: "canvas-b"),
                        "a different canvas must acquire independently")
    }

    /// After a run finishes, a new run is refused until the cooldown elapses —
    /// this is what stops a fast fail → retry → fail respawn loop.
    func testCooldownBlocksImmediateRespawnAfterRelease() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let gate = AssistantLocalRunGate(cooldown: 8, now: { clock })

        var lease = gate.acquire(key: "canvas-a")
        XCTAssertNotNil(lease)
        lease?.release()

        // Immediately after release: still within cooldown → refused.
        XCTAssertNil(gate.acquire(key: "canvas-a"),
                     "a respawn within the cooldown must be refused")

        // Half the cooldown later: still refused.
        clock = clock.addingTimeInterval(4)
        XCTAssertNil(gate.acquire(key: "canvas-a"))

        // Past the cooldown: allowed again (legitimate periodic recap).
        clock = clock.addingTimeInterval(5) // total 9s > 8s cooldown
        XCTAssertNotNil(gate.acquire(key: "canvas-a"),
                        "after the cooldown elapses, a fresh run is allowed")
    }

    /// User-triggered local runs still use the same max-in-flight guard, but
    /// skip the post-completion cooldown so a finished recap does not block an
    /// intentional chat / proposal action.
    func testInteractiveRunCanStartImmediatelyAfterRelease() {
        let gate = AssistantLocalRunGate(cooldown: 8)

        var lease = gate.acquire(key: "canvas-a")
        XCTAssertNotNil(lease)
        lease?.release()

        XCTAssertNotNil(
            gate.acquire(key: "canvas-a", completionCooldown: false),
            "interactive runs should not be blocked by the recap cooldown"
        )
    }

    /// Simulate the storm: a recap that fails immediately and is re-attempted in
    /// a tight loop. With the gate, only a bounded number of spawns get through
    /// over a fixed window — NOT one per loop iteration.
    func testTightFailLoopIsRateCapped() {
        var clock = Date(timeIntervalSince1970: 5_000)
        let gate = AssistantLocalRunGate(cooldown: 8, now: { clock })

        var spawnCount = 0
        // 100 tight iterations advancing only 0.2s each (20s of wall time) —
        // mimics the frontend re-firing on every state churn.
        for _ in 0..<100 {
            if var lease = gate.acquire(key: "canvas-a") {
                spawnCount += 1
                lease.release() // the recap "fails" immediately and releases
            }
            clock = clock.addingTimeInterval(0.2)
        }

        // 20s of wall time / 8s cooldown → at most 3 spawns, NOT 100.
        XCTAssertLessThanOrEqual(spawnCount, 3,
                                 "the gate must rate-cap a tight fail loop; got \(spawnCount) spawns")
        XCTAssertGreaterThanOrEqual(spawnCount, 1, "but legitimate runs still get through")
    }

    /// Empty / whitespace canvas keys normalize to one bucket ("global") so an
    /// unkeyed recap can't bypass the gate by varying whitespace.
    func testBlankKeysNormalizeToOneBucket() {
        let gate = AssistantLocalRunGate(cooldown: 8)
        XCTAssertNotNil(gate.acquire(key: ""))
        XCTAssertNil(gate.acquire(key: "   "),
                     "blank keys must map to the same bucket as empty")
    }
}
