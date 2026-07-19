import XCTest
@testable import meee2Kit

/// PlannerStore 的 workflow-bridge 直连通道：appendNodes / applyWorkflowNodeState。
final class WorkflowBridgePlannerStoreTests: XCTestCase {

    private var plannerStoreURL: URL!
    private var store: PlannerStore!

    override func setUpWithError() throws {
        plannerStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfbridge-planner-tests-\(UUID().uuidString)")
            .appendingPathComponent("planner-canvases.json")
        store = PlannerStore(fileURL: plannerStoreURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: plannerStoreURL.deletingLastPathComponent())
        store = nil
    }

    private func makeNode(
        id: String,
        canvasId: String,
        dependsOn: [String]? = nil,
        kind: PlanningNodeKind = .external
    ) -> PlanningNode {
        PlanningNode(
            id: id,
            canvasId: canvasId,
            title: "node \(id)",
            schema: NodeSchema(inputs: [], outputs: [], goal: "test"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "tester",
            status: .ready,
            dependsOnNodeIds: dependsOn,
            nodeKind: kind
        )
    }

    private func seedCanvas(id: String = "wfb-test-canvas") throws -> String {
        let canvas = PlanningCanvas(
            id: id, ownerId: "tester", title: "WF test",
            plannerContext: "workflow-bridge:test"
        )
        _ = try store.record(for: canvas, seedNodes: [])
        _ = try store.seedNodesIfEmpty(
            canvasId: id,
            seedNodes: [makeNode(id: "exec", canvasId: id, kind: .step)]
        )
        return id
    }

    func testAppendNodesAddsNodesAndEdges() throws {
        let canvasId = try seedCanvas()
        let record = try store.appendNodes(canvasId: canvasId, nodes: [
            makeNode(id: "agent-1", canvasId: canvasId, dependsOn: ["exec"]),
            makeNode(id: "agent-2", canvasId: canvasId, dependsOn: ["exec"]),
        ])
        XCTAssertEqual(record.nodes.count, 3)
        // dependsOnNodeIds 必须被 reconcile 成依赖边
        let edgeTargets = record.canvas.edges
            .filter { $0.sourceRef.nodeId == "exec" }
            .map(\.targetRef.nodeId)
            .sorted()
        XCTAssertEqual(edgeTargets, ["agent-1", "agent-2"])
        // 每个新节点都有 nodeCreated 事件
        let created = record.events.filter { $0.type == .nodeCreated }
        XCTAssertEqual(created.count, 2)
    }

    func testAppendNodesIsIdempotentById() throws {
        let canvasId = try seedCanvas()
        _ = try store.appendNodes(canvasId: canvasId, nodes: [
            makeNode(id: "agent-1", canvasId: canvasId, dependsOn: ["exec"]),
        ])
        // relay 修脚本重跑 → 引擎重放 started → 重复 append 必须无害
        let record = try store.appendNodes(canvasId: canvasId, nodes: [
            makeNode(id: "agent-1", canvasId: canvasId, dependsOn: ["exec"]),
            makeNode(id: "agent-3", canvasId: canvasId, dependsOn: ["exec"]),
        ])
        XCTAssertEqual(record.nodes.map(\.id).sorted(), ["agent-1", "agent-3", "exec"])
        XCTAssertEqual(record.events.filter { $0.type == .nodeCreated }.count, 2)
    }

    func testAppendNodesRejectsCanvasMismatch() throws {
        let canvasId = try seedCanvas()
        XCTAssertThrowsError(try store.appendNodes(canvasId: canvasId, nodes: [
            makeNode(id: "alien", canvasId: "other-canvas"),
        ]))
    }

    func testApplyWorkflowNodeStateUpdatesExternalNode() throws {
        let canvasId = try seedCanvas()
        _ = try store.appendNodes(canvasId: canvasId, nodes: [
            makeNode(id: "agent-1", canvasId: canvasId, dependsOn: ["exec"]),
        ])
        let record = try store.applyWorkflowNodeState(
            canvasId: canvasId, nodeId: "agent-1",
            runState: .done, status: .done, title: "Explore · scan repo"
        )
        let node = record.nodes.first { $0.id == "agent-1" }
        XCTAssertEqual(node?.workflowRunState, .done)
        XCTAssertEqual(node?.status, .done)
        XCTAssertEqual(node?.title, "Explore · scan repo")
        // updateNodeStatus 的 .step 守卫不适用于这条通道（agent 节点是 .external）
        XCTAssertEqual(node?.nodeKind, .external)
    }

    func testApplyWorkflowNodeStateLatchStampsOutputSubmittedAt() throws {
        let canvasId = try seedCanvas()
        let record = try store.applyWorkflowNodeState(
            canvasId: canvasId, nodeId: "exec",
            runState: .done, status: .done, latch: true
        )
        let node = record.nodes.first { $0.id == "exec" }
        XCTAssertNotNil(node?.outputSubmittedAt)

        // latch 后 reconcile（会话消失）不得把终态降级
        let demoted = try store.reconcileRunStateAgainstLiveSessions(
            canvasId: canvasId, isLive: { _ in false }
        )
        XCTAssertEqual(demoted, 0)
        let after = try store.appendNodes(canvasId: canvasId, nodes: [])
        XCTAssertEqual(after.nodes.first { $0.id == "exec" }?.workflowRunState, .done)
    }

    func testApplyWorkflowNodeStateNoChangeEmitsNoEvent() throws {
        let canvasId = try seedCanvas()
        let before = try store.applyWorkflowNodeState(
            canvasId: canvasId, nodeId: "exec", runState: .running
        )
        let eventsBefore = before.events.count
        let after = try store.applyWorkflowNodeState(
            canvasId: canvasId, nodeId: "exec", runState: .running
        )
        XCTAssertEqual(after.events.count, eventsBefore)
    }
}
