import XCTest
@testable import meee2Kit

final class PlannerCoreTests: XCTestCase {
    private let service = PlannerCoreService()

    func testNodeMockGeneratesNodesForOneCanvas() {
        let nodes = service.nodeMock(canvasId: "canvas-a")

        XCTAssertGreaterThanOrEqual(nodes.count, 3)
        XCTAssertTrue(nodes.allSatisfy { $0.canvasId == "canvas-a" })
        XCTAssertTrue(nodes.contains { $0.status == .running })
        XCTAssertTrue(nodes.contains { $0.status == .blocked })
        XCTAssertTrue(nodes.contains { $0.status == .done })
    }

    func testApplyNodeChangeRequiresApprovedProposal() throws {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let proposal = PlanProposal(
            id: "proposal-a",
            canvasId: "canvas-a",
            summary: "Pending change",
            changes: [.updateNode(id: nodes[0].id, title: "Changed")],
            status: .pending
        )

        XCTAssertThrowsError(try service.applyNodeChange(nodes: nodes, proposal: proposal)) { error in
            XCTAssertEqual(error as? PlannerCoreError, .proposalNotApproved)
        }
        XCTAssertEqual(nodes[0].title, "Planner LLM Spike")
    }

    func testApplyNodeChangeAddsAndUpdatesApprovedProposal() throws {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let newNode = PlanningNode(
            id: "canvas-a-node-5",
            canvasId: "canvas-a",
            title: "Real Planner Adapter",
            ioSchema: IOSchema(
                consumes: ["node state"],
                produces: ["planner proposal"],
                completionSignal: "proposal generated"
            ),
            contextSources: [],
            executionMode: .signOff,
            executorType: .mock,
            doerId: "A",
            status: .waiting
        )
        let proposal = service.approve(PlanProposal(
            id: "proposal-a",
            canvasId: "canvas-a",
            summary: "Add planner adapter",
            changes: [
                .updateNode(id: nodes[0].id, title: "Planner LLM Spike Done", status: .done),
                .addNode(newNode)
            ],
            status: .pending
        ))

        let updated = try service.applyNodeChange(nodes: nodes, proposal: proposal)

        XCTAssertEqual(updated.count, nodes.count + 1)
        XCTAssertEqual(updated.first { $0.id == nodes[0].id }?.title, "Planner LLM Spike Done")
        XCTAssertEqual(updated.first { $0.id == nodes[0].id }?.status, .done)
        XCTAssertEqual(updated.last?.id, "canvas-a-node-5")
    }

    func testReadNodeStateExposesBlockedNodeToPlanner() {
        let nodes = service.nodeMock(canvasId: "canvas-a")

        let states = service.readNodeState(nodes: nodes)

        let blocked = states.first { $0.runState == .blocked }
        XCTAssertNotNil(blocked)
        XCTAssertEqual(blocked?.blockers, ["Node is blocked and needs planner attention"])
        XCTAssertEqual(blocked?.needsOwnerReview, true)
    }

    func testMockPlannerGeneratePlanReturnsPendingProposal() async throws {
        let planner = MockPlannerAgent()
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Tonight Planner Core",
            plannerContext: "docs/decisions/planner-core-contract.md"
        )

        let proposal = try await planner.generatePlan(goal: "Build planner contract", canvas: canvas)

        XCTAssertEqual(proposal.canvasId, "canvas-a")
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.count, 1)
        XCTAssertEqual(proposal.changes.first?.kind, .addNode)
    }

    func testMockPlannerInspectDriftReturnsProposalForBlockedState() async throws {
        let planner = MockPlannerAgent()
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let states = service.readNodeState(nodes: nodes)

        let proposal = try await planner.inspectDrift(nodes: nodes, states: states)

        XCTAssertNotNil(proposal)
        XCTAssertEqual(proposal?.status, .pending)
        XCTAssertTrue(proposal?.summary.contains("detected drift") ?? false)
        XCTAssertEqual(proposal?.changes.first?.kind, .updateNode)
    }

    func testPlannerBoardBridgeBuildsCanvasStateFromBoardSnapshot() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)

        XCTAssertEqual(state.canvas.id, "canvas-a")
        XCTAssertEqual(state.canvas.ownerId, "owner-a")
        XCTAssertTrue(state.nodes.allSatisfy { $0.canvasId == "canvas-a" })
        XCTAssertEqual(state.states.count, state.nodes.count)
    }

    func testPlannerBoardBridgeGenerateProposalStaysPending() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Ship proposal shell",
            for: "canvas-a",
            snapshot: snapshot
        )

        XCTAssertEqual(proposal.canvasId, "canvas-a")
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.first?.kind, .addNode)
        XCTAssertEqual(proposal.changes.first?.node?.doerId, "owner-a")
    }

    func testPlannerBoardBridgeRejectsUnknownCanvas() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        XCTAssertThrowsError(try PlannerBoardBridge.canvasState(for: "missing", snapshot: snapshot)) { error in
            XCTAssertEqual(error as? PlannerCoreError, .canvasNotFound("missing"))
        }
    }

    func testPlannerBoardBridgeApplyPreviewApprovesAndReturnsUpdatedState() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Ship owner approval",
            for: "canvas-a",
            snapshot: snapshot
        )

        let preview = try PlannerBoardBridge.applyPreview(
            proposal: proposal,
            for: "canvas-a",
            snapshot: snapshot
        )

        XCTAssertEqual(preview.proposal.status, .approved)
        XCTAssertTrue(preview.nodes.contains { $0.id == "canvas-a-proposal-node-1" })
        XCTAssertEqual(preview.nodes.count, preview.states.count)
    }

    private func boardSnapshot(canvasId: String, ownerId: String) -> BoardLayoutStore.Snapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let canvas = BoardLayoutStore.Canvas(
            id: canvasId,
            name: "Planning Canvas",
            scope: .personal,
            ownerUserId: ownerId,
            teamId: nil,
            isDefault: true,
            workspaceFolderName: nil,
            createdBy: ownerId,
            createdAt: now,
            updatedAt: now
        )
        return BoardLayoutStore.Snapshot(
            activeCanvasId: canvasId,
            canvases: [canvas],
            memberships: []
        )
    }
}
