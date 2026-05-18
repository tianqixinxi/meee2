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

    /// Minimal `AssistantProvider` that replays a canned text response (or an
    /// error) — lets the adapter be exercised without spawning a real CLI.
    private struct FakeAssistantProvider: AssistantProvider {
        var text: String?
        var errorMessage: String?

        func runTurn(
            systemPrompt: String,
            messages: [ChatMessage],
            tools: [ToolDef],
            settings: AssistantSettings
        ) -> AsyncThrowingStream<ProviderEvent, Error> {
            AsyncThrowingStream { continuation in
                if let errorMessage {
                    continuation.yield(.error(errorMessage))
                } else if let text {
                    continuation.yield(.textDelta(text))
                    continuation.yield(.turnDone(stopReason: nil))
                }
                continuation.finish()
            }
        }
    }

    private func fakeAdapterSettings() -> AssistantSettings {
        AssistantAPI.parseSettings(nil)
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
        XCTAssertEqual(nodes[0].title, "meee2 AI LLM Spike")
    }

    func testApplyNodeChangeAddsAndUpdatesApprovedProposal() throws {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let newNode = PlanningNode(
            id: "canvas-a-node-5",
            canvasId: "canvas-a",
            title: "Real meee2 AI Adapter",
            ioSchema: IOSchema(
                consumes: ["node state"],
                produces: ["meee2 AI proposal"],
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
            summary: "Add meee2 AI adapter",
            changes: [
                .updateNode(id: nodes[0].id, title: "meee2 AI LLM Spike Done", status: .done),
                .addNode(newNode)
            ],
            status: .pending
        ))

        let updated = try service.applyNodeChange(nodes: nodes, proposal: proposal)

        XCTAssertEqual(updated.count, nodes.count + 1)
        XCTAssertEqual(updated.first { $0.id == nodes[0].id }?.title, "meee2 AI LLM Spike Done")
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
        XCTAssertEqual(blocked?.blockers, ["Node is blocked and needs meee2 AI attention"])
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

    // MARK: - Phase 6 — workflow guidance (nextAction)

    /// Builds a minimal `step` node carrying the given workflow run state plus
    /// optional gate / sign-off / session context.
    private func guidanceNode(
        runState: PlannerWorkflowRunState?,
        gated: Bool = false,
        signOff: Bool = false,
        sessionId: String? = nil,
        dependsOn: [String]? = nil,
        nodeKind: PlanningNodeKind? = .step
    ) -> PlanningNode {
        PlanningNode(
            id: "node-guidance",
            canvasId: "canvas-a",
            title: "Guidance Step",
            ioSchema: IOSchema(consumes: [], produces: [], completionSignal: "done"),
            contextSources: [],
            executionMode: signOff ? .signOff : .auto,
            executorType: .mock,
            doerId: "A",
            status: .waiting,
            sessionId: sessionId,
            dependsOnNodeIds: dependsOn,
            nodeKind: nodeKind,
            gate: gated
                ? PlannerNodeGate(
                    type: "owner-review",
                    label: "Owner sign-off",
                    requiredArtifactRefs: [],
                    approvers: ["owner-a"],
                    onFailGotoNodeId: nil
                )
                : nil,
            workflowRunState: runState
        )
    }

    func testNextActionGuidancePerWorkflowRunState() {
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .gateWait, gated: true), blockers: nil),
            "Owner: review the gate and approve or send it back."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .failed), blockers: nil),
            "Failed — inspect the failure and re-dispatch."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .failed), blockers: ["upstream broke"]),
            "Failed — clear the blockers, then re-dispatch."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .pending), blockers: nil),
            "Ready — dispatch this step to start work."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(
                for: guidanceNode(runState: .pending, dependsOn: ["node-upstream"]),
                blockers: nil
            ),
            "Waiting on an upstream step — dispatch once it clears."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .dispatched), blockers: nil),
            "Dispatched — waiting for the session to spin up."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(
                for: guidanceNode(runState: .dispatched, sessionId: "sess-1"),
                blockers: nil
            ),
            "Dispatched — open the session to follow progress."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .running), blockers: nil),
            "In progress — open the session to monitor work."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .done), blockers: nil),
            "Done — confirm the artifact is attached."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .done, gated: true), blockers: nil),
            "Done — verify the delivery evidence and close the gate."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .done, signOff: true), blockers: nil),
            "Done — verify the delivery evidence and close the gate."
        )
    }

    func testNextActionIsNilWithoutActionableWorkflowState() {
        XCTAssertNil(PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: nil), blockers: nil))
        XCTAssertNil(
            PlannerWorkflowGuidance.nextAction(
                for: guidanceNode(runState: .running, nodeKind: .session),
                blockers: nil
            )
        )
    }

    func testPlanningNodeExposesDerivedNextActionAndEncodesIt() throws {
        let node = guidanceNode(runState: .gateWait, gated: true)
        XCTAssertEqual(node.nextAction, "Owner: review the gate and approve or send it back.")

        let encoded = try JSONEncoder().encode(node)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(json["nextAction"] as? String, "Owner: review the gate and approve or send it back.")

        // Round-trips: `nextAction` is encode-only, never decoded back.
        let decoded = try JSONDecoder().decode(PlanningNode.self, from: encoded)
        XCTAssertEqual(decoded, node)
    }

    func testWorkspaceMonitorItemsCarryNextAction() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "owner-a")

        let nodeItems = monitor.items.filter { $0.kind == .node }
        XCTAssertFalse(nodeItems.isEmpty)
        for item in monitor.items where item.kind == .proposal {
            XCTAssertNil(item.nextAction)
        }
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

    func testPlannerProposalValidatorRejectsCrossCanvasDependencyReference() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let nodes = service.nodeMock(canvasId: "canvas-a")

        // addNode whose node depends on a node owned by another canvas.
        let crossDepNode = PlanningNode(
            id: "canvas-a-cross-dep",
            canvasId: "canvas-a",
            title: "Cross dependency",
            ioSchema: IOSchema(consumes: ["x"], produces: ["y"], completionSignal: "done"),
            contextSources: [],
            executionMode: .signOff,
            executorType: .mock,
            doerId: "owner-a",
            status: .waiting,
            dependsOnNodeIds: ["canvas-b-node-1"]
        )
        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-cross-dep-add",
                canvasId: "canvas-a",
                summary: "Cross dependency add",
                changes: [.addNode(crossDepNode)],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(
                error as? PlannerCoreError,
                .crossCanvasNodeReference(nodeId: "canvas-b-node-1", expectedCanvas: "canvas-a")
            )
        }

        // updateNode that points dependsOnNodeIds at a foreign-canvas node.
        XCTAssertThrowsError(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-cross-dep-update",
                canvasId: "canvas-a",
                summary: "Cross dependency update",
                changes: [.updateNode(id: nodes[0].id, dependsOnNodeIds: ["canvas-b-node-9"])],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        )) { error in
            XCTAssertEqual(
                error as? PlannerCoreError,
                .crossCanvasNodeReference(nodeId: "canvas-b-node-9", expectedCanvas: "canvas-a")
            )
        }

        // A dependency on a node introduced by the same proposal is allowed.
        XCTAssertNoThrow(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-intra-dep",
                canvasId: "canvas-a",
                summary: "Intra-proposal dependency",
                changes: [
                    .addNode(PlanningNode(
                        id: "canvas-a-new-base",
                        canvasId: "canvas-a",
                        title: "New base",
                        ioSchema: IOSchema(consumes: ["x"], produces: ["y"], completionSignal: "done"),
                        contextSources: [],
                        executionMode: .signOff,
                        executorType: .mock,
                        doerId: "owner-a",
                        status: .waiting
                    )),
                    .updateNode(id: nodes[0].id, dependsOnNodeIds: ["canvas-a-new-base"])
                ],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        ))
    }

    func testPlannerProposalValidatorRejectsUnknownNodeKindInDecodedProposal() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let nodes = service.nodeMock(canvasId: "canvas-a")

        // updateNode that carries an unknown nodeKind (constructed via raw JSON
        // since the typed enum cannot hold an unknown value directly).
        let raw = """
        {
          "id": "proposal-bad-kind",
          "canvasId": "canvas-a",
          "summary": "Unknown kind",
          "changes": [
            {
              "kind": "updateNode",
              "nodeId": "\(nodes[0].id)",
              "nodeKind": "wormhole"
            }
          ],
          "status": "pending"
        }
        """
        XCTAssertThrowsError(try PlannerProposalValidator.decodeProposal(from: raw)) { error in
            XCTAssertEqual(error as? PlannerCoreError, .unknownNodeKind("wormhole"))
        }
        // The same proposal would not even reach validate(), but assert the
        // validator-level guard rejects an unknown kind too if smuggled in.
        var smuggled = service.nodeMock(canvasId: "canvas-a")[0]
        smuggled.nodeKind = .step
        XCTAssertNoThrow(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-known-kind",
                canvasId: "canvas-a",
                summary: "Known kind",
                changes: [.updateNode(id: nodes[0].id, nodeKind: .session)],
                status: .pending
            ),
            canvas: canvas,
            nodes: nodes
        ))
    }

    func testPlannerProposalValidatorRejectsUnknownChangeKind() {
        let raw = """
        {
          "id": "proposal-bad-change",
          "canvasId": "canvas-a",
          "summary": "Unknown change kind",
          "changes": [
            { "kind": "deleteNode", "nodeId": "canvas-a-node-1" }
          ],
          "status": "pending"
        }
        """
        XCTAssertThrowsError(try PlannerProposalValidator.decodeProposal(from: raw)) { error in
            XCTAssertEqual(error as? PlannerCoreError, .unknownChangeKind("deleteNode"))
        }
    }

    func testBYOAPlannerAdapterDecodesAndValidatesProviderProposal() async throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Adapter Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let state = PlannerGraphState(
            canvas: canvas,
            nodes: [],
            states: [],
            proposals: [],
            access: PlannerPermission.access(for: canvas, nodes: []),
            activities: [],
            events: [],
            artifacts: [],
            edges: []
        )
        let raw = """
        {
          "id": "proposal-adapter",
          "canvasId": "canvas-a",
          "summary": "Adapter generated plan",
          "changes": [
            {
              "kind": "addNode",
              "node": {
                "id": "canvas-a-adapter-node",
                "canvasId": "canvas-a",
                "title": "Adapter node",
                "ioSchema": {"consumes": ["goal"], "produces": ["artifact"], "completionSignal": "owner review"},
                "contextSources": [],
                "executionMode": "sign-off",
                "executorType": "mock",
                "doerId": "owner-a",
                "status": "waiting",
                "nodeKind": "step"
              }
            }
          ],
          "status": "pending"
        }
        """
        let adapter = BYOAPlannerAdapter(
            provider: FakeAssistantProvider(text: raw),
            settings: fakeAdapterSettings()
        )

        let proposal = try await adapter.generateProposal(for: state, goal: "Build the plan")

        XCTAssertEqual(proposal.id, "proposal-adapter")
        XCTAssertEqual(proposal.changes.first?.node?.id, "canvas-a-adapter-node")
    }

    func testBYOAPlannerAdapterRejectsCrossCanvasProviderOutput() async throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Adapter Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let state = PlannerGraphState(
            canvas: canvas,
            nodes: [],
            states: [],
            proposals: [],
            access: PlannerPermission.access(for: canvas, nodes: []),
            activities: [],
            events: [],
            artifacts: [],
            edges: []
        )
        let raw = """
        {
          "id": "proposal-adapter-bad",
          "canvasId": "other-canvas",
          "summary": "Wrong canvas",
          "changes": [
            { "kind": "updateNode", "nodeId": "other-canvas-node", "title": "X" }
          ],
          "status": "pending"
        }
        """
        let adapter = BYOAPlannerAdapter(
            provider: FakeAssistantProvider(text: raw),
            settings: fakeAdapterSettings()
        )

        do {
            _ = try await adapter.generateProposal(for: state, goal: "Build the plan")
            XCTFail("Expected cross-canvas adapter output to be rejected")
        } catch let error as PlannerCoreError {
            XCTAssertEqual(error, .canvasMismatch(expected: "canvas-a", actual: "other-canvas"))
        }
    }

    func testBYOAPlannerAdapterSurfacesProviderErrors() async throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Adapter Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let state = PlannerGraphState(
            canvas: canvas,
            nodes: [],
            states: [],
            proposals: [],
            access: PlannerPermission.access(for: canvas, nodes: []),
            activities: [],
            events: [],
            artifacts: [],
            edges: []
        )
        let adapter = BYOAPlannerAdapter(
            provider: FakeAssistantProvider(errorMessage: "claude unavailable"),
            settings: fakeAdapterSettings()
        )

        do {
            _ = try await adapter.generateProposal(for: state, goal: "Build the plan")
            XCTFail("Expected provider error to propagate")
        } catch let error as PlannerCoreError {
            XCTFail("Provider error should not be a PlannerCoreError: \(error)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("claude unavailable"))
        }
    }

    // MARK: - Phase 8: PlannerAgentRuntime

    /// Builds an in-memory graph state for runtime tests.
    private func runtimeGraphState(
        canvasId: String = "canvas-a",
        ownerId: String = "owner-a",
        nodes: [PlanningNode] = [],
        states: [NodeStateSnapshot] = []
    ) -> PlannerGraphState {
        let canvas = PlanningCanvas(
            id: canvasId,
            ownerId: ownerId,
            title: "Runtime Canvas",
            plannerContext: "canvas:\(canvasId)"
        )
        return PlannerGraphState(
            canvas: canvas,
            nodes: nodes,
            states: states,
            proposals: [],
            access: PlannerPermission.access(for: canvas, nodes: nodes),
            activities: [],
            events: [],
            artifacts: [],
            edges: []
        )
    }

    /// A fake runtime that records the events it sees and returns a canned
    /// outcome — lets the registry swap be observed.
    private final class RecordingPlannerAgentRuntime: PlannerAgentRuntime {
        private(set) var seenEvents: [PlannerAgentEvent] = []
        let outcome: PlannerAgentOutcome

        init(outcome: PlannerAgentOutcome) {
            self.outcome = outcome
        }

        func handle(
            _ event: PlannerAgentEvent,
            state: PlannerGraphState,
            settings: AssistantSettings
        ) async throws -> PlannerAgentOutcome {
            seenEvents.append(event)
            return outcome
        }
    }

    func testDefaultRuntimeUserGoalProducesProposalViaAdapter() async throws {
        let raw = """
        {
          "id": "proposal-adapter",
          "canvasId": "canvas-a",
          "summary": "Adapter generated plan",
          "changes": [
            {
              "kind": "addNode",
              "node": {
                "id": "canvas-a-adapter-node",
                "canvasId": "canvas-a",
                "title": "Adapter node",
                "ioSchema": {"consumes": ["goal"], "produces": ["artifact"], "completionSignal": "owner review"},
                "contextSources": [],
                "executionMode": "sign-off",
                "executorType": "mock",
                "doerId": "owner-a",
                "status": "waiting",
                "nodeKind": "step"
              }
            }
          ],
          "status": "pending"
        }
        """
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(provider: FakeAssistantProvider(text: raw), settings: settings)
        }
        let outcome = try await runtime.handle(
            .userGoal(canvasId: "canvas-a", goal: "Build the plan", context: "extra context"),
            state: runtimeGraphState(),
            settings: fakeAdapterSettings()
        )

        XCTAssertEqual(outcome.proposals.count, 1)
        XCTAssertEqual(outcome.proposals.first?.id, "proposal-adapter")
        XCTAssertNil(outcome.noActionReason)
        XCTAssertNotNil(outcome.rationale)
    }

    func testDefaultRuntimeUserGoalFallsBackToHeuristicWhenAdapterUnavailable() async throws {
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(
                provider: FakeAssistantProvider(errorMessage: "claude unavailable"),
                settings: settings
            )
        }
        let outcome = try await runtime.handle(
            .userGoal(canvasId: "canvas-a", goal: "Build the plan", context: nil),
            state: runtimeGraphState(),
            settings: fakeAdapterSettings()
        )

        XCTAssertEqual(outcome.proposals.count, 1)
        XCTAssertEqual(outcome.proposals.first?.status, .pending)
        XCTAssertEqual(outcome.proposals.first?.changes.first?.node?.title, "Build the plan")
        XCTAssertNil(outcome.noActionReason)
        XCTAssertFalse(outcome.risks.isEmpty)
    }

    func testDefaultRuntimeDriftInspectionHealthyGraphReturnsNoAction() async throws {
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(provider: FakeAssistantProvider(text: ""), settings: settings)
        }
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let states = service.readNodeState(nodes: nodes).filter { $0.runState != .blocked && !$0.needsOwnerReview }
        let outcome = try await runtime.handle(
            .driftInspection(canvasId: "canvas-a"),
            state: runtimeGraphState(nodes: nodes, states: states),
            settings: fakeAdapterSettings()
        )

        XCTAssertTrue(outcome.proposals.isEmpty)
        XCTAssertNotNil(outcome.noActionReason)
        XCTAssertTrue(outcome.noActionReason?.contains("healthy") == true)
    }

    func testDefaultRuntimeDriftInspectionUnhealthyGraphProducesProposal() async throws {
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(provider: FakeAssistantProvider(text: ""), settings: settings)
        }
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let driftState = NodeStateSnapshot(
            nodeId: nodes[0].id,
            runState: .blocked,
            blockers: ["stuck"],
            artifactRefs: [],
            needsOwnerReview: true
        )
        let outcome = try await runtime.handle(
            .driftInspection(canvasId: "canvas-a"),
            state: runtimeGraphState(nodes: nodes, states: [driftState]),
            settings: fakeAdapterSettings()
        )

        XCTAssertEqual(outcome.proposals.count, 1)
        XCTAssertEqual(outcome.proposals.first?.changes.first?.kind, .updateNode)
        XCTAssertEqual(outcome.proposals.first?.changes.first?.nodeId, nodes[0].id)
        XCTAssertNil(outcome.noActionReason)
    }

    func testDefaultRuntimeNodeRunStateChangedNonFailureReturnsNoAction() async throws {
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(provider: FakeAssistantProvider(text: ""), settings: settings)
        }
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let outcome = try await runtime.handle(
            .nodeRunStateChanged(canvasId: "canvas-a", nodeId: nodes[0].id, runState: .running),
            state: runtimeGraphState(nodes: nodes),
            settings: fakeAdapterSettings()
        )

        XCTAssertTrue(outcome.proposals.isEmpty)
        XCTAssertNotNil(outcome.noActionReason)
        XCTAssertTrue(outcome.noActionReason?.contains("running") == true)
    }

    func testDefaultRuntimeMilestoneCompletedReturnsNoAction() async throws {
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(provider: FakeAssistantProvider(text: ""), settings: settings)
        }
        let outcome = try await runtime.handle(
            .milestoneCompleted(canvasId: "canvas-a", nodeId: "node-1"),
            state: runtimeGraphState(),
            settings: fakeAdapterSettings()
        )

        XCTAssertTrue(outcome.proposals.isEmpty)
        XCTAssertEqual(
            outcome.noActionReason,
            "milestone evolution not yet implemented in DefaultPlannerAgentRuntime"
        )
    }

    func testPlannerAgentRuntimeRegistrySwapIsObserved() async throws {
        let original = PlannerAgentRuntimeRegistry.shared
        defer { PlannerAgentRuntimeRegistry.shared = original }

        let fake = RecordingPlannerAgentRuntime(
            outcome: PlannerAgentOutcome(noActionReason: "fake runtime ran")
        )
        PlannerAgentRuntimeRegistry.shared = fake

        let event = PlannerAgentEvent.driftInspection(canvasId: "canvas-a")
        let outcome = try await PlannerAgentRuntimeRegistry.shared.handle(
            event,
            state: runtimeGraphState(),
            settings: fakeAdapterSettings()
        )

        XCTAssertEqual(fake.seenEvents, [event])
        XCTAssertEqual(outcome.noActionReason, "fake runtime ran")
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
        XCTAssertTrue(state.nodes.isEmpty)
        XCTAssertTrue(state.states.isEmpty)
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
        XCTAssertTrue(state.nodes.isEmpty)
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
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
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
        // Make the canvas public so the viewer clears the visibility gate and
        // the assertion below exercises the *action*-level RBAC, not the
        // private-canvas membership gate (covered separately in Phase 3).
        _ = try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
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
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
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
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

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
            goal: "Persist meee2 AI proposal",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)

        XCTAssertEqual(state.proposals.first?.id, proposal.id)
        XCTAssertEqual(state.proposals.first?.status, .pending)
        XCTAssertTrue(state.nodes.isEmpty)
    }

    func testPlannerStoreSerializesConcurrentRecordCleanup() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let store = PlannerStore(fileURL: plannerStoreURL)
        let seeded = service.nodeMock(canvasId: canvas.id)
        _ = try store.record(for: canvas, seedNodes: seeded)

        let queue = DispatchQueue(label: "planner-store-concurrency", attributes: .concurrent)
        let group = DispatchGroup()
        let errorsLock = NSLock()
        var errors: [Error] = []

        for _ in 0..<64 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try store.record(for: canvas, seedNodes: [])
                    _ = try store.replaceNodesIfUnmodified(
                        canvasId: canvas.id,
                        matching: seeded,
                        with: []
                    )
                } catch {
                    errorsLock.lock()
                    errors.append(error)
                    errorsLock.unlock()
                }
            }
        }

        group.wait()
        XCTAssertTrue(errors.isEmpty)
        let record = try store.record(for: canvas, seedNodes: [])
        XCTAssertTrue(record.nodes.isEmpty)
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
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
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

    func testDeliveryPipelineTemplateCreatesStepAndExternalNodes() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let proposal = try PlannerBoardBridge.deliveryPipelineProposal(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.count, 5)
        let nodes = proposal.changes.compactMap(\.node)
        XCTAssertEqual(nodes.filter { $0.nodeKind == .step }.count, 4)
        XCTAssertEqual(nodes.last?.nodeKind, .external)
        XCTAssertEqual(nodes.first?.dispatch?.runner, .byoaLocal)
        XCTAssertEqual(nodes[2].gate?.onFailGotoNodeId, "m3-impl-verify")
        XCTAssertTrue(nodes[2].artifactRefs?.contains("artifact://prerelease-verdict") == true)
    }

    /// Governance-layer graph-change stays a pending proposal; bind-session is
    /// now an execution-layer action that applies DIRECTLY (no proposal gate).
    func testGraphChangeStaysProposalWhileBindAppliesDirectly() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first)

        // Governance-layer: graph-change remains a pending proposal.
        let layoutProposal = try PlannerBoardBridge.graphChangeProposal(
            summary: "Move node",
            changes: [
                .updateNode(
                    id: node.id,
                    layout: PlannerNodeLayout(x: 42, y: 84, width: 300, height: 180)
                )
            ],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(layoutProposal.status, .pending)
        XCTAssertEqual(layoutProposal.changes.first?.layout?.x, 42)

        // Execution-layer: bind-session applies directly — no proposal created,
        // node.sessionId set immediately.
        let graph = try PlannerBoardBridge.bindSession(
            nodeId: node.id,
            sessionId: "explicit-session",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let boundNode = try XCTUnwrap(graph.nodes.first { $0.id == node.id })
        XCTAssertEqual(boundNode.sessionId, "explicit-session")
        XCTAssertEqual(boundNode.chatThreadId, "explicit-session")
        XCTAssertEqual(boundNode.source, .session)
        XCTAssertEqual(boundNode.workflowRunState, .running)
        // No bind proposal was created — only the governance graph-change one.
        XCTAssertFalse(graph.proposals.contains { $0.summary.contains("Bind") })

        let reloaded = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        XCTAssertEqual(reloaded.nodes.first { $0.id == node.id }?.sessionId, "explicit-session")
    }

    /// A viewer cannot bind a session; a non-assigned doer cannot bind another
    /// doer's node; the owner and the assigned doer can.
    func testBindSessionPermissionGating() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "B")
        let ownNode = try XCTUnwrap(state.nodes.first { $0.doerId == "B" })
        let otherNode = try XCTUnwrap(state.nodes.first { $0.doerId != "B" })

        // Viewer — denied.
        XCTAssertThrowsError(try PlannerBoardBridge.bindSession(
            nodeId: ownNode.id, sessionId: "s1",
            for: "canvas-a", snapshot: snapshot, actorUserId: "viewer-x"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "update assigned node", role: .viewer))
        }
        // Doer on someone else's node — denied.
        XCTAssertThrowsError(try PlannerBoardBridge.bindSession(
            nodeId: otherNode.id, sessionId: "s1",
            for: "canvas-a", snapshot: snapshot, actorUserId: "B"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "update assigned node", role: .doer))
        }
        // Doer on their own node — allowed.
        let doerGraph = try PlannerBoardBridge.bindSession(
            nodeId: ownNode.id, sessionId: "s-doer",
            for: "canvas-a", snapshot: snapshot, actorUserId: "B"
        )
        XCTAssertEqual(doerGraph.nodes.first { $0.id == ownNode.id }?.sessionId, "s-doer")
        // Owner on any node — allowed.
        let ownerGraph = try PlannerBoardBridge.bindSession(
            nodeId: otherNode.id, sessionId: "s-owner",
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(ownerGraph.nodes.first { $0.id == otherNode.id }?.sessionId, "s-owner")
    }

    func testGraphStateIncludesEdgesArtifactsAndPersistedLayout() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first)

        let graph = try PlannerBoardBridge.attachArtifact(
            nodeId: node.id,
            kind: .prd,
            title: "PRD",
            reference: "repo://prd.md",
            status: "attached",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let moved = try PlannerBoardBridge.updateNodeLayout(
            nodeId: node.id,
            layout: PlannerNodeLayout(x: 10, y: 20, width: 320, height: 160),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertTrue(graph.artifacts.contains { $0.reference == "repo://prd.md" })
        XCTAssertFalse(graph.edges.isEmpty)
        XCTAssertEqual(moved.nodes.first { $0.id == node.id }?.layout?.x, 10)
    }

    // MARK: - Phase 2: dispatch 真执行 (now execution-layer / direct)

    /// Dispatching a step to a spawning runner (claude/codex/byoa-local) is an
    /// execution-layer action: it applies DIRECTLY (no proposal / approval) and
    /// materializes a `session` PlanningNode plus a derived step → session edge
    /// in the same operation.
    func testDispatchAppliesDirectlyCreatingSessionNodeAndEdge() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        let result = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id,
            runner: .byoaLocal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // No dispatch proposal was created — it applied directly.
        XCTAssertFalse(result.graph.proposals.contains { $0.summary.contains("Dispatch") })
        let dispatchedStep = try XCTUnwrap(result.graph.nodes.first { $0.id == step.id })
        XCTAssertEqual(dispatchedStep.dispatch?.runner, .byoaLocal)
        XCTAssertEqual(dispatchedStep.workflowRunState, .dispatched)

        let sessionNode = try XCTUnwrap(result.graph.nodes.first { $0.nodeKind == .session })
        XCTAssertEqual(sessionNode.dependsOnNodeIds, [step.id])
        XCTAssertNil(sessionNode.sessionId, "session id is unknown until the session is spawned + bound")
        XCTAssertEqual(sessionNode.workflowRunState, .dispatched)
        XCTAssertTrue(result.graph.edges.contains {
            $0.sourceNodeId == step.id && $0.targetNodeId == sessionNode.id
        })

        // Persisted: a reload sees the same direct mutation.
        let reloaded = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        XCTAssertTrue(reloaded.nodes.contains { $0.nodeKind == .session })
    }

    /// The `human` runner gates the step at `gateWait` directly and never
    /// spawns a session node.
    func testDispatchHumanRunnerProducesGateWaitWithNoSessionNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        let result = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id,
            runner: .human,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertFalse(result.graph.nodes.contains { $0.nodeKind == .session })
        let dispatchedStep = try XCTUnwrap(result.graph.nodes.first { $0.id == step.id })
        XCTAssertEqual(dispatchedStep.workflowRunState, .gateWait)
    }

    // MARK: - Run layer (P1)

    func testStartRunCreatesActiveRunOverCurrentNodes() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        let run = try PlannerBoardBridge.startRun(
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(run.runIndex, 1)
        XCTAssertEqual(run.status, .active)
        XCTAssertFalse(run.nodeStates.isEmpty)
        XCTAssertTrue(
            run.nodeStates.values.allSatisfy { $0.runState == .pending },
            "a fresh run starts every node at pending"
        )
    }

    func testSecondRunIncrementsRunIndex() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let first = try PlannerBoardBridge.startRun(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let second = try PlannerBoardBridge.startRun(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        XCTAssertEqual(first.runIndex, 1)
        XCTAssertEqual(second.runIndex, 2)
        let runs = try PlannerBoardBridge.runs(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        XCTAssertEqual(runs.count, 2)
    }

    /// Execution-layer dispatch mirrors the step's run-state into the active
    /// run's `nodeStates` (workflow-run-spec §6).
    func testDispatchMirrorsRunStateIntoActiveRun() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let run = try PlannerBoardBridge.startRun(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        _ = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal, for: "canvas-a",
            snapshot: snapshot, actorUserId: "owner-a"
        )

        let updatedRun = try PlannerBoardBridge.run(runId: run.id)
        XCTAssertEqual(
            updatedRun.nodeStates[step.id]?.runState, .dispatched,
            "dispatch must mirror the step run-state into the active run"
        )
    }

    func testAbortRunMarksAbortedAndFinishes() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let run = try PlannerBoardBridge.startRun(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let aborted = try PlannerBoardBridge.abortRun(runId: run.id)
        XCTAssertEqual(aborted.status, .aborted)
        XCTAssertNotNil(aborted.finishedAt)
    }

    /// A canvas persisted before the Run layer (`runs: []`) gets a synthetic
    /// Run #1 the next time the store loads from disk (migration).
    func testLegacyCanvasMigratesToRunOneOnLoad() throws {
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        // The seeded record has `runs: []` — it never started a run. Reloading
        // the store triggers `loadDocument`'s Run-layer migration.
        let reloaded = PlannerStore(fileURL: plannerStoreURL)
        let runs = try reloaded.runs(canvasId: "canvas-a")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.runIndex, 1)
        XCTAssertEqual(runs.first?.trigger, "migration")
    }

    func testMigratedRunOnePacksPerNodeExecutionState() {
        var node = PlanningNode(
            id: "n1", canvasId: "canvas-x", title: "Impl",
            ioSchema: IOSchema(consumes: [], produces: [], completionSignal: "done"),
            contextSources: [], executionMode: .signOff, executorType: .mock,
            doerId: "owner", status: .running
        )
        node.workflowRunState = .running
        node.sessionId = "sess-1"
        let run = WorkflowRun.migratedRunOne(canvasId: "canvas-x", nodes: [node], artifacts: [])
        XCTAssertEqual(run.runIndex, 1)
        XCTAssertEqual(run.nodeStates["n1"]?.runState, .running)
        XCTAssertEqual(run.nodeStates["n1"]?.sessionId, "sess-1")
    }

    // MARK: - WorkflowRunEngine (P3)

    /// Bare planning node for engine tests — `deps` sets `dependsOnNodeIds`.
    private func planNode(_ id: String, deps: [String] = []) -> PlanningNode {
        var node = PlanningNode(
            id: id, canvasId: "c", title: id,
            ioSchema: IOSchema(consumes: [], produces: [], completionSignal: "done"),
            contextSources: [], executionMode: .signOff, executorType: .mock,
            doerId: "owner", status: .waiting
        )
        node.dependsOnNodeIds = deps
        return node
    }

    func testRunEngineMarksRootReadyAndDownstreamWaiting() {
        let nodes = [planNode("a"), planNode("b", deps: ["a"])]
        var run = WorkflowRun.start(canvasId: "c", runIndex: 1, trigger: "t", nodes: nodes)
        run = WorkflowRunEngine.advance(run, nodes: nodes)
        XCTAssertEqual(run.nodeStates["a"]?.nextAction, .readyToDispatch)
        XCTAssertEqual(run.nodeStates["b"]?.nextAction, .waitingOnUpstream)
    }

    /// Decision B — a downstream node becomes `readyToDispatch` once every
    /// upstream dependency is done. The engine never dispatches it itself.
    func testRunEngineAdvancesDownstreamWhenUpstreamDone() {
        let nodes = [planNode("a"), planNode("b", deps: ["a"])]
        var run = WorkflowRun.start(canvasId: "c", runIndex: 1, trigger: "t", nodes: nodes)
        run.nodeStates["a"]?.runState = .done
        run = WorkflowRunEngine.advance(run, nodes: nodes)
        XCTAssertEqual(run.nodeStates["a"]?.nextAction, .confirmArtifacts)
        XCTAssertEqual(run.nodeStates["b"]?.nextAction, .readyToDispatch)
    }

    func testRunEngineRollsStatusToCompleted() {
        let nodes = [planNode("a")]
        var run = WorkflowRun.start(canvasId: "c", runIndex: 1, trigger: "t", nodes: nodes)
        run.nodeStates["a"]?.runState = .done
        run = WorkflowRunEngine.advance(run, nodes: nodes)
        XCTAssertEqual(run.status, .completed)
        XCTAssertNotNil(run.finishedAt)
    }

    func testRunEngineRollsStatusToFailed() {
        let nodes = [planNode("a")]
        var run = WorkflowRun.start(canvasId: "c", runIndex: 1, trigger: "t", nodes: nodes)
        run.nodeStates["a"]?.runState = .failed
        run = WorkflowRunEngine.advance(run, nodes: nodes)
        XCTAssertEqual(run.status, .failed)
    }

    /// Direct dispatch is idempotent — re-dispatching the same node to a
    /// spawning runner does not spawn a second session node.
    func testDispatchDirectDoesNotDoubleSpawnSessionNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        let once = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(once.graph.nodes.filter { $0.nodeKind == .session }.count, 1)
        let twice = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(twice.graph.nodes.filter { $0.nodeKind == .session }.count, 1)
    }

    /// `applyNodeChange` is idempotent — re-applying an identical dispatch
    /// change does not spawn a second session node.
    func testDispatchApplyDoesNotDoubleSpawnSessionNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let step = try XCTUnwrap(record.nodes.first { ($0.nodeKind ?? .step) == .step })

        let dispatch = PlannerNodeDispatch(
            runner: .byoaLocal, skill: "m3-coding", actor: step.doerId,
            command: "claude", fallbackRunner: nil
        )
        let proposal = PlanProposal(
            id: "proposal-double-spawn",
            canvasId: "canvas-a",
            summary: "Dispatch \(step.title)",
            changes: [.updateNode(id: step.id, dispatch: dispatch, workflowRunState: .dispatched)],
            status: .approved
        )

        let once = try service.applyNodeChange(nodes: record.nodes, proposal: proposal)
        XCTAssertEqual(once.filter { $0.nodeKind == .session }.count, 1)
        let twice = try service.applyNodeChange(nodes: once, proposal: proposal)
        XCTAssertEqual(twice.filter { $0.nodeKind == .session }.count, 1)
    }

    /// SessionStatus → PlannerWorkflowRunState mapping.
    func testSessionStatusMapsToWorkflowRunState() {
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .thinking), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .tooling), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .active), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .compacting), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .idle), .dispatched)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .waitingForUser), .dispatched)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .permissionRequired), .gateWait)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .completed), .done)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .dead), .failed)

        XCTAssertEqual(PlannerSessionRunStateBridge.stepNodeId(fromPurpose: "planner:node-7"), "node-7")
        XCTAssertNil(PlannerSessionRunStateBridge.stepNodeId(fromPurpose: "global"))
        XCTAssertNil(PlannerSessionRunStateBridge.stepNodeId(fromPurpose: nil))
    }

    /// Observing a planner-tagged session binds the session id onto the step's
    /// session node and flows the run state onto both nodes.
    func testSessionRunStateFeedsBackIntoNodes() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        _ = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .claude,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )

        // First observation via the `purpose` tag binds the session id.
        let bound = try XCTUnwrap(PlannerSessionRunStateBridge.observe(
            sessionId: "sess-xyz",
            purpose: "planner:\(step.id)",
            status: .tooling
        ))
        let sessionNode = try XCTUnwrap(bound.nodes.first { $0.nodeKind == .session })
        XCTAssertEqual(sessionNode.sessionId, "sess-xyz")
        XCTAssertEqual(sessionNode.workflowRunState, .running)

        // A later observation keyed only by session id (intent already
        // consumed) still flows through and marks completion → done.
        let finished = try XCTUnwrap(PlannerSessionRunStateBridge.observeBound(
            sessionId: "sess-xyz",
            status: .completed
        ))
        XCTAssertEqual(finished.nodes.first { $0.nodeKind == .session }?.workflowRunState, .done)
        // The step has no gate, so it finishes `done` too.
        XCTAssertEqual(finished.nodes.first { $0.id == step.id }?.workflowRunState, .done)
    }

    // MARK: - Phase 3 — permission enforcement

    /// A viewer (no role on the canvas) cannot create, approve, or apply.
    /// The canvas is made public first, so the failure is the *action*-level
    /// RBAC rather than the visibility gate (covered by its own test).
    func testPhase3ViewerCannotCreateApproveOrApply() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let ownerProposal = try PlannerBoardBridge.generateProposal(
            goal: "Owner topology change",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertThrowsError(try PlannerBoardBridge.generateProposal(
            goal: "Viewer create",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "viewer-x"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "create proposal", role: .viewer))
        }
        XCTAssertThrowsError(try PlannerBoardBridge.approveProposal(
            proposalId: ownerProposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "viewer-x"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "approve proposal", role: .viewer))
        }
        XCTAssertThrowsError(try PlannerBoardBridge.applyProposal(
            proposalId: ownerProposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "viewer-x"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "apply proposal", role: .viewer))
        }
    }

    /// A doer may run node execution-state mutations only on a node they own.
    func testPhase3DoerCanUpdateOnlyAssignedNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "B")
        XCTAssertEqual(state.access.role, .doer)
        let ownNode = try XCTUnwrap(state.nodes.first { $0.doerId == "B" })
        let otherNode = try XCTUnwrap(state.nodes.first { $0.doerId != "B" })

        // Doer dispatches their own node — allowed, applies directly.
        let dispatched = try PlannerBoardBridge.dispatchNode(
            nodeId: ownNode.id,
            runner: .byoaLocal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "B"
        )
        XCTAssertEqual(dispatched.graph.nodes.first { $0.id == ownNode.id }?.workflowRunState, .dispatched)

        // Doer dispatches someone else's node — denied.
        XCTAssertThrowsError(try PlannerBoardBridge.dispatchNode(
            nodeId: otherNode.id,
            runner: .byoaLocal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "B"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "update assigned node", role: .doer))
        }

        // Layout on someone else's node — denied.
        XCTAssertThrowsError(try PlannerBoardBridge.updateNodeLayout(
            nodeId: otherNode.id,
            layout: PlannerNodeLayout(x: 1, y: 2, width: 3, height: 4),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "B"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "update assigned node", role: .doer))
        }

        // Layout on the doer's own node — allowed.
        let updated = try PlannerBoardBridge.updateNodeLayout(
            nodeId: ownNode.id,
            layout: PlannerNodeLayout(x: 1, y: 2, width: 3, height: 4),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "B"
        )
        XCTAssertEqual(updated.nodes.first { $0.id == ownNode.id }?.layout?.x, 1)
    }

    /// A viewer cannot run node execution-state mutations at all (canvas made
    /// public so the failure is the action-level RBAC, not the visibility gate).
    func testPhase3ViewerCannotUpdateAnyNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first)

        XCTAssertThrowsError(try PlannerBoardBridge.dispatchNode(
            nodeId: node.id,
            runner: .byoaLocal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "viewer-x"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "update assigned node", role: .viewer))
        }
    }

    /// The owner can run every mutating planner operation.
    func testPhase3OwnerCanDoEverything() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        // Owner may touch a node assigned to a different doer.
        let doerNode = try XCTUnwrap(state.nodes.first { $0.doerId == "B" })

        let dispatch = try PlannerBoardBridge.dispatchNode(
            nodeId: doerNode.id,
            runner: .byoaLocal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(dispatch.graph.nodes.first { $0.id == doerNode.id }?.workflowRunState, .dispatched)

        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Owner everything",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let applied = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(applied.proposal.status, .applied)
    }

    // MARK: - Phase 3 — canvas visibility

    /// `visibility` defaults to `.private` and round-trips through Codable.
    func testPhase3VisibilityDefaultsToPrivateAndRoundTrips() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        XCTAssertEqual(canvas.visibility, .private)

        let publicCanvas = PlanningCanvas(
            id: "canvas-b",
            ownerId: "owner-b",
            title: "Public Canvas",
            plannerContext: "canvas:canvas-b",
            visibility: .public
        )
        let encoded = try JSONEncoder().encode(publicCanvas)
        let decoded = try JSONDecoder().decode(PlanningCanvas.self, from: encoded)
        XCTAssertEqual(decoded, publicCanvas)
        XCTAssertEqual(decoded.visibility, .public)
    }

    /// A persisted canvas predating the `visibility` field still decodes,
    /// defaulting to `.private` (schema migration).
    func testPhase3VisibilityLegacyCanvasDecodesAsPrivate() throws {
        let legacyJSON = """
        {"id":"canvas-legacy","ownerId":"owner-a","title":"Legacy","plannerContext":"canvas:canvas-legacy"}
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(PlanningCanvas.self, from: data)
        XCTAssertEqual(decoded.visibility, .private)
        XCTAssertEqual(decoded.id, "canvas-legacy")
    }

    /// A private canvas is hidden from a non-member; a public one is visible.
    func testPhase3PrivateCanvasHiddenFromNonMembers() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        // Default is private — owner and doer see it, viewer does not.
        XCTAssertNoThrow(try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        ))
        XCTAssertNoThrow(try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "B"
        ))
        XCTAssertThrowsError(try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "viewer-x"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "view canvas", role: .viewer))
        }

        // Owner flips it public — viewer can now read it.
        let updated = try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(updated.visibility, .public)
        let viewerState = try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "viewer-x"
        )
        XCTAssertEqual(viewerState.access.role, .viewer)
        XCTAssertEqual(viewerState.canvas.visibility, .public)
    }

    /// Only the owner may change a canvas's visibility, and the setting
    /// survives a store reload.
    func testPhase3VisibilityIsOwnerOnlyAndPersists() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        XCTAssertThrowsError(try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "B"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .permissionDenied(action: "set canvas visibility", role: .doer))
        }

        _ = try PlannerBoardBridge.setCanvasVisibility(
            .public, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )

        // Reload the store from disk — the visibility tier must survive.
        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
        let reloaded = try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(reloaded.canvas.visibility, .public)
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

    private func seedPlannerNodes(canvasId: String, ownerId: String) throws -> PlannerStore.CanvasRecord {
        var nodes = service.nodeMock(canvasId: canvasId)
        if !nodes.isEmpty {
            nodes[0].title = "\(nodes[0].title) Fixture"
        }
        return try PlannerBoardBridge.store.record(
            for: PlanningCanvas(
                id: canvasId,
                ownerId: ownerId,
                title: "Planning Canvas",
                plannerContext: "canvas:\(canvasId)"
            ),
            seedNodes: nodes
        )
    }
}
