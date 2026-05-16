import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class PlannerCoreTests: XCTestCase {
    private let service = PlannerCoreService()
    private var plannerStoreURL: URL!

    private struct FakePlannerTextClient: PlannerTextClient {
        var output: String

        func complete(systemPrompt: String, userPrompt: String) async throws -> String {
            output
        }
    }

    override func setUpWithError() throws {
        plannerStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-core-tests-\(UUID().uuidString)")
            .appendingPathComponent("planner-canvases.json")
        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
        PlannerActivityStore.shared.reset()
    }

    override func tearDownWithError() throws {
        PlannerActivityStore.shared.reset()
        PlannerBoardBridge.store = PlannerStore.shared
        try? FileManager.default.removeItem(at: plannerStoreURL.deletingLastPathComponent())
        plannerStoreURL = nil
    }

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

    func testApplyNodeChangeMarksDownstreamDependenciesPlanningOnSchemaChange() throws {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let proposal = service.approve(PlanProposal(
            id: "proposal-schema",
            canvasId: "canvas-a",
            summary: "Change upstream schema",
            changes: [
                .updateNode(
                    id: "canvas-a-node-1",
                    ioSchema: IOSchema(
                        consumes: ["owner goal", "new contract"],
                        produces: ["revised proposal"],
                        completionSignal: "schema changed"
                    )
                )
            ],
            status: .pending
        ))

        let updated = try service.applyNodeChange(nodes: nodes, proposal: proposal)

        XCTAssertEqual(updated.first { $0.id == "canvas-a-node-1" }?.status, .running)
        XCTAssertEqual(updated.first { $0.id == "canvas-a-node-2" }?.status, .planning)
        XCTAssertEqual(updated.first { $0.id == "canvas-a-node-3" }?.status, .blocked)
    }

    func testApplyNodeChangeCanAttachSubCanvas() throws {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let proposal = service.approve(PlanProposal(
            id: "proposal-subcanvas",
            canvasId: "canvas-a",
            summary: "Attach sub canvas",
            changes: [
                .updateNode(id: nodes[0].id, subCanvasId: "canvas-a-child")
            ],
            status: .pending
        ))

        let updated = try service.applyNodeChange(nodes: nodes, proposal: proposal)

        XCTAssertEqual(updated.first { $0.id == nodes[0].id }?.subCanvasId, "canvas-a-child")
    }

    func testReadNodeStateExposesBlockedNodeToPlanner() {
        let nodes = service.nodeMock(canvasId: "canvas-a")

        let states = service.readNodeState(nodes: nodes)

        let blocked = states.first { $0.runState == .blocked }
        XCTAssertNotNil(blocked)
        XCTAssertEqual(blocked?.blockers, ["Node is blocked and needs planner attention"])
        XCTAssertEqual(blocked?.needsOwnerReview, true)
    }

    func testReadNodeStateTreatsPlanningAsReplanningNotOwnerReview() {
        var nodes = service.nodeMock(canvasId: "canvas-a")
        nodes[1].status = .planning

        let planning = service.readNodeState(nodes: nodes).first { $0.nodeId == nodes[1].id }

        XCTAssertEqual(planning?.runState, .planning)
        XCTAssertEqual(planning?.blockers, ["Node is replanning after dependency or schema change"])
        XCTAssertEqual(planning?.needsOwnerReview, false)
    }

    func testSubCanvasNodeExposesArtifactRefAndSummary() {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let states = service.readNodeState(nodes: nodes)
        let subCanvasNode = nodes.first { $0.subCanvasId != nil }
        let subCanvasState = states.first { $0.nodeId == subCanvasNode?.id }

        XCTAssertEqual(subCanvasState?.artifactRefs.last, "subcanvas:\(subCanvasNode?.subCanvasId ?? "")")

        let summary = service.summarizeSubCanvas(
            subCanvasId: "child-canvas",
            states: [
                NodeStateSnapshot(
                    nodeId: "child-node",
                    runState: .blocked,
                    blockers: ["child blocked"],
                    artifactRefs: [],
                    needsOwnerReview: true
                )
            ],
            proposals: [
                PlanProposal(
                    id: "child-proposal",
                    canvasId: "child-canvas",
                    summary: "Review child",
                    changes: [],
                    status: .pending
                )
            ]
        )

        XCTAssertEqual(summary.runState, .blocked)
        XCTAssertEqual(summary.pendingProposalCount, 1)
        XCTAssertEqual(summary.needsOwnerReview, true)
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

    func testLLMPlannerAgentValidatesGeneratedProposal() async throws {
        let raw = """
        ```json
        {
          "id": "proposal-a",
          "canvasId": "canvas-a",
          "summary": "Generated by provider",
          "changes": [
            {
              "kind": "addNode",
              "node": {
                "id": "node-generated",
                "canvasId": "canvas-a",
                "title": "Provider generated node",
                "ioSchema": {
                  "consumes": ["goal"],
                  "produces": ["artifact"],
                  "completionSignal": "owner review"
                },
                "contextSources": [],
                "executionMode": "sign-off",
                "executorType": "mock",
                "doerId": "owner-a",
                "status": "waiting"
              }
            }
          ],
          "status": "pending"
        }
        ```
        """
        let planner = LLMPlannerAgent(client: FakePlannerTextClient(output: raw))
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Provider Canvas",
            plannerContext: "canvas:canvas-a"
        )

        let proposal = try await planner.generatePlan(goal: "Build the plan", canvas: canvas)

        XCTAssertEqual(proposal.id, "proposal-a")
        XCTAssertEqual(proposal.changes.first?.node?.id, "node-generated")
    }

    func testLLMPlannerAgentRejectsCrossCanvasOutput() async throws {
        let raw = """
        {
          "id": "proposal-b",
          "canvasId": "other-canvas",
          "summary": "Wrong canvas",
          "changes": [],
          "status": "pending"
        }
        """
        let planner = LLMPlannerAgent(client: FakePlannerTextClient(output: raw))
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Provider Canvas",
            plannerContext: "canvas:canvas-a"
        )

        do {
            _ = try await planner.generatePlan(goal: "Build the plan", canvas: canvas)
            XCTFail("Expected cross-canvas proposal to be rejected")
        } catch let error as PlannerCoreError {
            XCTAssertEqual(error, .canvasMismatch(expected: "canvas-a", actual: "other-canvas"))
        }
    }

    func testPlannerProposalValidatorDecodesRawAndFencedJSON() throws {
        let raw = """
        {
          "id": "proposal-a",
          "canvasId": "canvas-a",
          "summary": "Repair blocked node",
          "changes": [
            {
              "kind": "updateNode",
              "nodeId": "canvas-a-node-1",
              "title": "Repair node",
              "status": "planning"
            }
          ],
          "status": "pending"
        }
        """
        let fenced = """
        Planner output:
        ```json
        \(raw)
        ```
        """

        XCTAssertEqual(try PlannerProposalValidator.decodeProposal(from: raw).id, "proposal-a")
        XCTAssertEqual(try PlannerProposalValidator.decodeProposal(from: fenced).changes.first?.status, .planning)
    }

    func testPlannerProposalValidatorRejectsInvalidJSON() {
        XCTAssertThrowsError(try PlannerProposalValidator.decodeProposal(from: "not json")) { error in
            XCTAssertEqual(error as? PlannerCoreError, .invalidPlannerProposalJSON)
        }
    }

    func testPlannerProposalValidatorRejectsInvalidChanges() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let nodes = service.nodeMock(canvasId: "canvas-a")

        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-empty",
                canvasId: "canvas-a",
                summary: "No changes",
                changes: [],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .emptyProposalChanges)
        }

        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-unknown",
                canvasId: "canvas-a",
                summary: "Unknown update",
                changes: [.updateNode(id: "missing-node", title: "Missing")],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .nodeNotFound("missing-node"))
        }

        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-empty-update",
                canvasId: "canvas-a",
                summary: "Empty update",
                changes: [PlanChange(kind: .updateNode, node: nil, nodeId: nodes[0].id, title: nil, status: nil)],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .updateNodeNoFields(nodes[0].id))
        }
    }

    func testPlannerProposalValidatorRejectsCrossCanvasProposalAndAddNode() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let nodes = service.nodeMock(canvasId: "canvas-a")
        var crossCanvasNode = nodes[0]
        crossCanvasNode.id = "canvas-b-node-1"
        crossCanvasNode.canvasId = "canvas-b"

        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-cross",
                canvasId: "canvas-b",
                summary: "Cross canvas",
                changes: [.updateNode(id: nodes[0].id, title: "Cross")],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .canvasMismatch(expected: "canvas-a", actual: "canvas-b"))
        }

        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-cross-add",
                canvasId: "canvas-a",
                summary: "Cross add",
                changes: [.addNode(crossCanvasNode)],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .canvasMismatch(expected: "canvas-a", actual: "canvas-b"))
        }
    }

    func testMockPlannerInspectDriftSuggestsSplitForRepeatedFailure() async throws {
        let planner = MockPlannerAgent()
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let state = NodeStateSnapshot(
            nodeId: nodes[0].id,
            runState: .blocked,
            blockers: ["repeated failure after two retries"],
            artifactRefs: [],
            needsOwnerReview: true
        )

        let proposal = try await planner.inspectDrift(nodes: nodes, states: [state])

        XCTAssertEqual(proposal?.summary, "Split \(nodes[0].title) because repeated failure after two retries")
        XCTAssertEqual(proposal?.changes.map(\.kind), [.updateNode, .addNode])
        XCTAssertEqual(proposal?.changes.last?.node?.status, .planning)
    }

    func testMockPlannerInspectDriftReturnsRepairProposalForPlanningState() async throws {
        let planner = MockPlannerAgent()
        var nodes = service.nodeMock(canvasId: "canvas-a")
        nodes[1].status = .planning
        let states = service.readNodeState(nodes: nodes)

        let proposal = try await planner.inspectDrift(nodes: nodes, states: states.filter { $0.runState == .planning })

        XCTAssertEqual(proposal?.summary, "Repair planning state for \(nodes[1].title)")
        XCTAssertEqual(proposal?.changes.first?.kind, .updateNode)
        XCTAssertEqual(proposal?.changes.first?.contextSources?.last?.title, "Planning repair reason")
    }

    func testPlannerBoardBridgeBuildsCanvasStateFromBoardSnapshot() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")

        XCTAssertEqual(state.canvas.id, "canvas-a")
        XCTAssertEqual(state.canvas.ownerId, "owner-a")
        XCTAssertTrue(state.nodes.allSatisfy { $0.canvasId == "canvas-a" })
        XCTAssertEqual(state.states.count, state.nodes.count)
        XCTAssertEqual(state.proposals.count, 0)
        XCTAssertEqual(state.access.role, .owner)
        XCTAssertTrue(state.access.canApplyProposal)
        XCTAssertEqual(state.activities.first?.userId, "owner-a")
        XCTAssertEqual(state.activities.first?.currentCanvasId, "canvas-a")
    }

    func testPlannerBoardBridgeDoesNotAutoAttachVisibleSessionsToPlannerNodes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = boardSnapshot(
            canvasId: "canvas-a",
            ownerId: "owner-a",
            memberships: [
                BoardLayoutStore.CanvasSession(
                    canvasId: "canvas-a",
                    sessionId: "existing-session",
                    visible: true,
                    addedBy: "owner-a",
                    addedAt: now,
                    updatedAt: now
                )
            ]
        )

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")

        XCTAssertTrue(state.nodes.allSatisfy { $0.source != .session })
        XCTAssertTrue(state.nodes.allSatisfy { $0.sessionId == nil })
        XCTAssertEqual(state.nodes.count, service.nodeMock(canvasId: "canvas-a").count)
    }

    func testPlannerBoardBridgeTreatsPersonalCanvasActorAsOwnerWhenStoredOwnerIsStale() throws {
        let defaults = UserDefaults.standard
        let oldConnected = defaults.object(forKey: "meee2Connected")
        let oldUserId = defaults.string(forKey: "meee2UserId")
        defaults.set(true, forKey: "meee2Connected")
        defaults.set("current-local-user", forKey: "meee2UserId")
        defer {
            if let oldConnected {
                defaults.set(oldConnected, forKey: "meee2Connected")
            } else {
                defaults.removeObject(forKey: "meee2Connected")
            }
            if let oldUserId {
                defaults.set(oldUserId, forKey: "meee2UserId")
            } else {
                defaults.removeObject(forKey: "meee2UserId")
            }
        }
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "stale-owner")

        let state = try PlannerBoardBridge.canvasState(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "current-local-user"
        )

        XCTAssertEqual(state.canvas.ownerId, "current-local-user")
        XCTAssertEqual(state.access.role, .owner)
        XCTAssertTrue(state.access.canCreateProposal)
    }

    func testPlannerPermissionResolvesOwnerDoerAndViewerAccess() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let nodes = service.nodeMock(canvasId: "canvas-a")

        let owner = PlannerPermission.access(for: canvas, nodes: nodes, actorId: "owner-a")
        let doer = PlannerPermission.access(for: canvas, nodes: nodes, actorId: "B")
        let viewer = PlannerPermission.access(for: canvas, nodes: nodes, actorId: "viewer-a")

        XCTAssertEqual(owner.role, .owner)
        XCTAssertTrue(owner.canCreateProposal)
        XCTAssertTrue(owner.canApplyProposal)

        XCTAssertEqual(doer.role, .doer)
        XCTAssertTrue(doer.canUpdateAssignedNode)
        XCTAssertFalse(doer.canApplyProposal)

        XCTAssertEqual(viewer.role, .viewer)
        XCTAssertFalse(viewer.canCreateProposal)
        XCTAssertFalse(viewer.canUpdateAssignedNode)
    }

    func testPlannerBoardBridgeGenerateProposalStaysPending() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Ship proposal shell",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(proposal.canvasId, "canvas-a")
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.first?.kind, .addNode)
        XCTAssertEqual(proposal.changes.first?.node?.doerId, "owner-a")

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        XCTAssertEqual(state.proposals.map(\.id), [proposal.id])
    }

    func testPlannerBoardBridgeRefineProposalStaysPending() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        let node = try XCTUnwrap(state.nodes.first)

        let proposal = try PlannerBoardBridge.refineProposal(
            nodeId: node.id,
            reason: "Split contract into DTO and API work",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(proposal.canvasId, "canvas-a")
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.map(\.kind), [.updateNode, .addNode])
        XCTAssertEqual(proposal.changes.last?.node?.title, "Split contract into DTO and API work")

        let nextState = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        XCTAssertTrue(nextState.proposals.contains { $0.id == proposal.id })
    }

    func testPlannerBoardBridgeRejectsUnknownCanvas() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        XCTAssertThrowsError(try PlannerBoardBridge.canvasState(for: "missing", snapshot: snapshot)) { error in
            XCTAssertEqual(error as? PlannerCoreError, .canvasNotFound("missing"))
        }
    }

    func testPlannerBoardBridgeRejectsNonOwnerProposalMutation() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Owner topology change",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertThrowsError(try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "viewer-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "approve proposal", role: .viewer))
        }

        XCTAssertThrowsError(try PlannerBoardBridge.generateProposal(
            goal: "Viewer cannot mutate topology",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "viewer-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "create proposal", role: .viewer))
        }
    }

    func testPlannerWorkspaceMonitorRanksBlockedAndPendingWork() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Pending monitor proposal",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "owner-a")

        XCTAssertTrue(monitor.items.contains { $0.proposalId == proposal.id && $0.proposalStatus == .pending })
        XCTAssertTrue(monitor.items.contains { $0.runState == .blocked })
        XCTAssertEqual(monitor.items.first?.riskRank, 0)
    }

    func testPlannerWorkspaceMonitorDoerViewFiltersAssignedNodes() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "B")

        XCTAssertFalse(monitor.items.isEmpty)
        XCTAssertTrue(monitor.items.allSatisfy { item in
            item.kind == .node && item.doerId == "B"
        })
    }

    func testPlannerBoardBridgeApplyPreviewApprovesAndReturnsUpdatedState() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Ship owner approval",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let preview = try PlannerBoardBridge.applyPreview(
            proposal: proposal,
            for: "canvas-a",
            snapshot: snapshot
        )

        XCTAssertEqual(preview.proposal.status, .approved)
        XCTAssertTrue(preview.nodes.contains { $0.title == "Ship owner approval" })
        XCTAssertEqual(preview.nodes.count, preview.states.count)

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        XCTAssertFalse(state.nodes.contains { $0.title == "Ship owner approval" })
        XCTAssertEqual(state.proposals.first?.status, .pending)
    }

    func testPlannerStorePersistsStateAcrossInstances() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Persist planner proposal",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)

        XCTAssertEqual(state.proposals.first?.id, proposal.id)
        XCTAssertEqual(state.proposals.first?.status, .pending)
        XCTAssertTrue(state.nodes.contains { $0.title == "Planner LLM Spike" })
    }

    func testPlannerProposalLifecycleRequiresApprovalBeforePersistentApply() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Persist applied node",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertThrowsError(try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .proposalNotApproved)
        }

        let approved = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(approved.status, .approved)

        let applied = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(applied.proposal.status, .applied)
        XCTAssertTrue(applied.nodes.contains { $0.title == "Persist applied node" })

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        XCTAssertEqual(state.proposals.first?.status, .applied)
        XCTAssertTrue(state.nodes.contains { $0.title == "Persist applied node" })
    }

    func testPlannerStoreWritesProposalAndNodeEvents() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Event sourced node",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let record = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(
                id: "canvas-a",
                ownerId: "owner-a",
                title: "Planning Canvas",
                plannerContext: "canvas:canvas-a"
            ),
            seedNodes: service.nodeMock(canvasId: "canvas-a")
        )

        XCTAssertTrue(record.events.contains { $0.type == .proposalCreated && $0.proposalId == proposal.id })
        XCTAssertTrue(record.events.contains { $0.type == .proposalApproved && $0.proposalId == proposal.id })
        XCTAssertTrue(record.events.contains { $0.type == .proposalApplied && $0.proposalId == proposal.id })
        XCTAssertTrue(record.events.contains { $0.type == .nodeCreated && $0.proposalId == proposal.id })
    }

    func testPlannerProposalCanBeRejected() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Reject this proposal",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let rejected = try PlannerBoardBridge.rejectProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertThrowsError(try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .proposalNotApproved)
        }
    }

    func testPlannerProposalCannotApplyAcrossCanvas() throws {
        let snapshotA = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let snapshotB = boardSnapshot(canvasId: "canvas-b", ownerId: "owner-b")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Canvas scoped proposal",
            for: "canvas-a",
            snapshot: snapshotA,
            actorUserId: "owner-a"
        )

        _ = try PlannerBoardBridge.canvasState(for: "canvas-b", snapshot: snapshotB)

        XCTAssertThrowsError(try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: "canvas-b",
            snapshot: snapshotB,
            actorUserId: "owner-b"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .proposalNotFound(proposal.id))
        }
    }

    func testSessionToPlanningNodeMapperMapsRealSessionShape() {
        let session = PluginSession(
            id: "com.meee2.plugin.codex-thread-123",
            pluginId: "com.meee2.plugin.codex",
            title: "Fix failing tests",
            status: .permissionRequired,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subtitle: "Waiting for owner approval",
            cwd: "/tmp/project",
            transcriptPath: "/tmp/project/thread.jsonl",
            lastMessage: "Need permission to edit files"
        )

        let node = SessionToPlanningNodeMapper.map(
            session: session,
            canvasId: "canvas-a",
            doerId: "owner-a"
        )

        XCTAssertEqual(node.canvasId, "canvas-a")
        XCTAssertEqual(node.title, "Fix failing tests")
        XCTAssertEqual(node.executorType, .codex)
        XCTAssertEqual(node.executionMode, .signOff)
        XCTAssertEqual(node.status, .blocked)
        XCTAssertEqual(node.sessionId, session.id)
        XCTAssertEqual(node.chatThreadId, session.id)
        XCTAssertEqual(node.source, .session)
        XCTAssertTrue(node.contextSources.contains { $0.kind == .repository && $0.reference == "/tmp/project" })
        XCTAssertTrue(node.contextSources.contains { $0.kind == .chatHistory && $0.reference == "/tmp/project/thread.jsonl" })
    }

    func testSessionToPlanningNodeMapperMapsRunningAndDoneStates() {
        let running = PluginSession(
            id: "claude-running",
            pluginId: "com.meee2.plugin.claude",
            title: "Claude run",
            status: .tooling,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let done = PluginSession(
            id: "cursor-done",
            pluginId: "com.meee2.plugin.cursor",
            title: "Cursor run",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(SessionToPlanningNodeMapper.map(session: running, canvasId: "c", doerId: "d").status, .running)
        XCTAssertEqual(SessionToPlanningNodeMapper.map(session: running, canvasId: "c", doerId: "d").executorType, .claude)
        XCTAssertEqual(SessionToPlanningNodeMapper.map(session: done, canvasId: "c", doerId: "d").status, .done)
        XCTAssertEqual(SessionToPlanningNodeMapper.map(session: done, canvasId: "c", doerId: "d").executorType, .cursor)
    }

    func testCrossCanvasSuggestionRequiresTargetOwnerApproval() throws {
        let targetCanvas = PlanningCanvas(
            id: "target-canvas",
            ownerId: "target-owner",
            title: "Target Canvas",
            plannerContext: "canvas:target-canvas"
        )
        let proposal = PlanProposal(
            id: "proposal-target",
            canvasId: "target-canvas",
            summary: "Suggest target repair",
            changes: [
                .updateNode(id: "target-node", title: "Suggested repair")
            ],
            status: .pending
        )

        let suggestion = try service.createCrossCanvasSuggestion(
            id: "suggestion-1",
            sourceCanvasId: "source-canvas",
            targetCanvas: targetCanvas,
            sourcePlannerId: "planner-source",
            suggestedProposal: proposal,
            reason: "Source planner needs target output"
        )

        XCTAssertEqual(suggestion.status, .pending)
        XCTAssertEqual(suggestion.targetOwnerId, "target-owner")
        XCTAssertThrowsError(try service.acceptCrossCanvasSuggestion(suggestion, byOwnerId: "source-owner")) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "accept cross-canvas suggestion", role: .viewer))
        }

        let accepted = try service.acceptCrossCanvasSuggestion(suggestion, byOwnerId: "target-owner")
        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertEqual(accepted.suggestedProposal.status, .pending)
    }

    func testCrossCanvasSuggestionRejectsProposalForWrongTargetCanvas() throws {
        let targetCanvas = PlanningCanvas(
            id: "target-canvas",
            ownerId: "target-owner",
            title: "Target Canvas",
            plannerContext: "canvas:target-canvas"
        )
        let proposal = PlanProposal(
            id: "proposal-other",
            canvasId: "other-canvas",
            summary: "Wrong target",
            changes: [],
            status: .pending
        )

        XCTAssertThrowsError(try service.createCrossCanvasSuggestion(
            sourceCanvasId: "source-canvas",
            targetCanvas: targetCanvas,
            sourcePlannerId: "planner-source",
            suggestedProposal: proposal,
            reason: "Mismatch"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .canvasMismatch(expected: "target-canvas", actual: "other-canvas"))
        }
    }

    func testPlannerActivityStoreKeepsRecentCanvasPresence() {
        let store = PlannerActivityStore(ttl: 60)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = store.heartbeat(
            userId: "user-a",
            displayName: "User A",
            currentCanvasId: "canvas-a",
            selectedNodeId: "node-a",
            selectedSessionId: "session-a",
            now: now
        )
        _ = store.heartbeat(
            userId: "user-b",
            displayName: "User B",
            currentCanvasId: "canvas-b",
            selectedNodeId: nil,
            selectedSessionId: nil,
            now: now
        )

        let fallback = PlannerActivity(
            userId: "owner-a",
            displayName: "Owner",
            currentCanvasId: "canvas-a",
            selectedNodeId: nil,
            selectedSessionId: nil,
            lastActiveAt: now
        )
        let recent = store.activities(for: "canvas-a", fallback: fallback, now: now.addingTimeInterval(10))
        XCTAssertEqual(Set(recent.map(\.userId)), Set(["owner-a", "user-a"]))
        XCTAssertEqual(recent.first { $0.userId == "user-a" }?.selectedNodeId, "node-a")

        let expired = store.activities(for: "canvas-a", fallback: fallback, now: now.addingTimeInterval(120))
        XCTAssertEqual(expired.map(\.userId), ["owner-a"])
    }

    func testPlannerBoardBridgeRecordsSelectedNodeActivity() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let state = try PlannerBoardBridge.canvasState(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let node = try XCTUnwrap(state.nodes.first)

        let activity = try PlannerBoardBridge.recordActivity(
            canvasId: "canvas-a",
            selectedNodeId: node.id,
            selectedSessionId: nil,
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(activity.selectedNodeId, node.id)

        let updated = try PlannerBoardBridge.canvasState(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(updated.activities.first?.selectedNodeId, node.id)
    }

    private func boardSnapshot(
        canvasId: String,
        ownerId: String,
        memberships: [BoardLayoutStore.CanvasSession] = []
    ) -> BoardLayoutStore.Snapshot {
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
            memberships: memberships
        )
    }
}
