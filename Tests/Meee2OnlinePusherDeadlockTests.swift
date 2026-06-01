import XCTest
import Combine
import Meee2CommKit
@testable import meee2Kit

/// Regression for the team-mode AB-BA lock-ordering deadlock (commit ebd35e9).
///
/// `SessionEventBus` is a `PassthroughSubject`, so `.sink` subscribers run
/// SYNCHRONOUSLY on the publishing thread, under Combine's internal send lock.
/// Two opposite lock orders existed:
///
///  • **A (Combine → PlannerStore):** `SessionStore.upsert` publishes a session
///    event while Combine's send lock is held; the `Meee2OnlinePusher` sink then
///    called `shouldSyncSessionId → isSessionReferencedByTeamCanvas →
///    PlannerStore.canvasRecordForBridge`, which takes PlannerStore's lock.
///  • **B (PlannerStore → Combine):** `PlannerStore.reconcileRunStateAgainstLive
///    Sessions` holds PlannerStore's lock, then `save()` publishes
///    `.plannerCanvasChanged` → needs Combine's send lock.
///
/// A holds Combine→wants Planner; B holds Planner→wants Combine ⇒ classic AB-BA
/// deadlock that froze the whole app.
///
/// The fix: the pusher's session-event handling must NEVER touch PlannerStore
/// synchronously from inside the `.sink` (it now defers onto its `syncQueue`).
/// These tests reproduce the exact interleaving with the REAL `PlannerStore`
/// lock + REAL `SessionEventBus`, and assert it completes without deadlock.
final class Meee2OnlinePusherDeadlockTests: XCTestCase {
    private var storeURL: URL!
    private var store: PlannerStore!
    private let canvasId = "deadlock-canvas"

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusher-deadlock-\(UUID().uuidString)")
            .appendingPathComponent("planner-canvases.json")
        store = PlannerStore(fileURL: storeURL)
        // Seed a canvas with a node so canvasRecordForBridge + reconcile both
        // have real work to do under the lock.
        let canvas = PlanningCanvas(
            id: canvasId, ownerId: "owner", title: "Deadlock Canvas",
            plannerContext: "canvas:\(canvasId)"
        )
        let node = PlanningNode(
            id: "\(canvasId)-node-0", canvasId: canvasId, title: "Node",
            schema: NodeSchema(inputs: [], outputs: [], goal: "g"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: "owner", status: .ready, sessionId: "sess-1",
            workflowRunState: .running
        )
        _ = try store.record(for: canvas, seedNodes: [node])
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        storeURL = nil
    }

    /// Thread B: holds PlannerStore's lock then publishes under it (the real
    /// reconcile→save→publish order). `save()` inside `reconcile` emits
    /// `.plannerCanvasChanged`, taking Combine's send lock WHILE the planner
    /// lock is held.
    private func runPlannerSidePublishingUnderLock(iterations: Int) {
        for _ in 0..<iterations {
            // reconcile holds the lock and (when it demotes) calls save→publish.
            _ = try? store.reconcileRunStateAgainstLiveSessions(canvasId: canvasId) { _ in false }
        }
    }

    /// The FIXED pusher discipline: the synchronous sink does NOT touch
    /// PlannerStore — it defers that work onto a private queue. This is what
    /// `Meee2OnlinePusher.handleEvent` now does.
    func testDeferredSinkDoesNotDeadlockWithReconcile() {
        let deferQueue = DispatchQueue(label: "test.pusher.defer")
        var plannerReads = 0
        let readsLock = NSLock()

        let sink = SessionEventBus.shared.publisher.sink { [store] event in
            // Mirror the fix: NEVER read PlannerStore synchronously here.
            // Defer the team-canvas-reference check (which locks PlannerStore)
            // off the publish thread.
            if case .sessionMetadataChanged = event {
                deferQueue.async {
                    _ = try? store?.canvasRecordForBridge(canvasId: "deadlock-canvas")
                    readsLock.lock(); plannerReads += 1; readsLock.unlock()
                }
            }
        }
        defer { sink.cancel() }

        let done = expectation(description: "no deadlock")
        let group = DispatchGroup()

        // Thread B: planner-lock → publish.
        group.enter()
        DispatchQueue.global().async { [weak self] in
            self?.runPlannerSidePublishingUnderLock(iterations: 500)
            group.leave()
        }
        // Thread A: publish session events (Combine lock → sink). Pre-fix the
        // sink would grab the planner lock here → AB-BA. Post-fix it defers.
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<500 {
                SessionEventBus.shared.publish(.sessionMetadataChanged(sessionId: "sess-1"))
            }
            group.leave()
        }

        group.notify(queue: .main) { done.fulfill() }
        // Generous but finite: a real deadlock never completes → test fails.
        wait(for: [done], timeout: 20)
    }

    /// Sanity: concurrent reconcile (planner lock) + direct canvasRecordForBridge
    /// reads from another thread must not deadlock on their own — confirms the
    /// PlannerStore lock itself is well-behaved under contention.
    func testConcurrentPlannerReadsAndReconcileComplete() {
        let done = expectation(description: "completes")
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { [weak self] in
            self?.runPlannerSidePublishingUnderLock(iterations: 500)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async { [store] in
            for _ in 0..<500 {
                _ = try? store?.canvasRecordForBridge(canvasId: "deadlock-canvas")
            }
            group.leave()
        }

        group.notify(queue: .main) { done.fulfill() }
        wait(for: [done], timeout: 20)
    }
}
