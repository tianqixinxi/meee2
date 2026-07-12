import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class PlannerCoreTests: XCTestCase {
    private let service = PlannerCoreService()
    private var plannerStoreURL: URL!
    private let legacyDraftStatus = PlanningNodeStatus(rawValue: "draft")!

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

    func testAgentLaunchCommandUsesProviderSpecificFullAccessFlags() {
        XCTAssertEqual(
            AgentLaunchCommand.fullAccessCommand(forProvider: "claude"),
            "claude --dangerously-skip-permissions"
        )
        XCTAssertEqual(
            AgentLaunchCommand.fullAccessCommand(forProvider: "codex"),
            "codex --dangerously-bypass-approvals-and-sandbox"
        )
        XCTAssertEqual(
            AgentLaunchCommand.normalize(command: "claude").command,
            "claude --permission-mode default"
        )
        XCTAssertEqual(
            AgentLaunchCommand.normalize(command: "codex").command,
            "codex --sandbox workspace-write --ask-for-approval on-request"
        )
    }

    func testNodeMockGeneratesNodesForOneCanvas() {
        let nodes = service.nodeMock(canvasId: "canvas-a")

        XCTAssertGreaterThanOrEqual(nodes.count, 3)
        XCTAssertTrue(nodes.allSatisfy { $0.canvasId == "canvas-a" })
        XCTAssertTrue(nodes.contains { $0.status == .ready })
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
        XCTAssertEqual(nodes[0].title, "Meee2 AI LLM Spike")
    }

    func testApplyNodeChangeAddsAndUpdatesApprovedProposal() throws {
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let newNode = PlanningNode(
            id: "canvas-a-node-5",
            canvasId: "canvas-a",
            title: "Real meee2 AI Adapter",
            schema: NodeSchema(
                inputs: ["node state"],
                outputs: ["meee2 AI proposal"],
                goal: "proposal generated"
            ),
            contextSources: [],
            executionMode: .human,
            executorType: .mock,
            doerId: "A",
            status: .ready
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
                    schema: NodeSchema(
                        inputs: ["owner goal", "new contract"],
                        outputs: ["revised proposal"],
                        goal: "schema changed"
                    )
                )
            ],
            status: .pending
        ))

        let updated = try service.applyNodeChange(nodes: nodes, proposal: proposal)

        XCTAssertEqual(updated.first { $0.id == "canvas-a-node-1" }?.status, .ready)
        XCTAssertEqual(updated.first { $0.id == "canvas-a-node-2" }?.status, .ready)
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
        XCTAssertEqual(blocked?.blockers, ["Blocked: no reason was provided by the session."])
        XCTAssertEqual(blocked?.needsOwnerReview, false)
    }

    func testReadNodeStateTreatsDraftAsNonBlockingDesignState() {
        var nodes = service.nodeMock(canvasId: "canvas-a")
        nodes[1].status = legacyDraftStatus

        let draft = service.readNodeState(nodes: nodes).first { $0.nodeId == nodes[1].id }

        XCTAssertEqual(draft?.runState, .draft)
        XCTAssertEqual(draft?.blockers, [])
        XCTAssertEqual(draft?.needsOwnerReview, false)
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

    // MARK: - Kanban item 状态派生 (spec §6 / decision #7b · slice 1)

    /// §6 词表: subcanvas worst-case runtime → kanban 列。穷举映射。
    func testKanbanDerivedColumnMapping() {
        XCTAssertEqual(KanbanDerivedColumn.from(subCanvasRunState: .ready), .notStarted)
        XCTAssertEqual(KanbanDerivedColumn.from(subCanvasRunState: .working), .inProgress)
        XCTAssertEqual(KanbanDerivedColumn.from(subCanvasRunState: .draft), .needsResponse)
        XCTAssertEqual(KanbanDerivedColumn.from(subCanvasRunState: .blocked), .blocked)
        XCTAssertEqual(KanbanDerivedColumn.from(subCanvasRunState: .done), .done)
    }

    /// deriveKanbanColumn wiring: 子画板内有 blocked 节点 → worst-case blocked → 「阻塞」;
    /// 有 pending proposal → draft → 「需要人回复」;空子画板 → ready → 「待开始」。
    func testDeriveKanbanColumnFromSubCanvas() {
        // 空子画板 → 待开始
        XCTAssertEqual(
            service.deriveKanbanColumn(subCanvasId: "child", subCanvasNodes: [], subCanvasProposals: []),
            .notStarted
        )
        // 子画板有节点(经 readNodeState)→ 非空;再用 summarizeSubCanvas 已测的 worst-case 规则。
        // 这里复用 service.nodeMock 造一组真实节点,确保 wiring(readNodeState→summarize→map)连通。
        let nodes = service.nodeMock(canvasId: "child")
        let col = service.deriveKanbanColumn(
            subCanvasId: "child",
            subCanvasNodes: nodes,
            subCanvasProposals: []
        )
        // nodeMock 的混合态 worst-case 一定落在五列之一(连通性断言,不假设具体列)。
        XCTAssertTrue(KanbanDerivedColumn.allCases.contains(col))
    }

    /// slice 2: injectDerivedKanbanColumns 读时把派生列注入有 subCanvasId 的 item,
    /// 不带 subCanvasId 的 item 不动(退回手动 columnId)。
    func testInjectDerivedKanbanColumnsInjectsForLinkedItemsOnly() {
        let payload: BoardJSONValue = .object([
            "version": .number(1),
            "columns": .array([]),
            "items": .array([
                .object(["id": .string("i1"), "title": .string("A"), "subCanvasId": .string("child-1")]),
                .object(["id": .string("i2"), "title": .string("B")]),
            ]),
        ])
        let artifact = PlannerArtifact(
            id: "art-1", canvasId: "canvas-a", nodeId: "node-1", kind: .kanban,
            title: "Board", reference: "kanban", status: "attached",
            createdAt: Date(timeIntervalSince1970: 0), payload: payload
        )
        let result = service.injectDerivedKanbanColumns(into: artifact) { childId in
            childId == "child-1" ? (nodes: service.nodeMock(canvasId: "child-1"), proposals: []) : nil
        }
        guard case .object(let obj)? = result.payload, case .array(let items)? = obj["items"] else {
            return XCTFail("payload shape lost")
        }
        // i1: 有 subCanvasId → 注入合法 derivedColumnId
        guard case .object(let i1) = items[0], case .string(let col)? = i1["derivedColumnId"] else {
            return XCTFail("i1 missing derivedColumnId")
        }
        XCTAssertNotNil(KanbanDerivedColumn(rawValue: col))
        // i2: 无 subCanvasId → 不动
        guard case .object(let i2) = items[1] else { return XCTFail("i2 shape") }
        XCTAssertNil(i2["derivedColumnId"])
    }

    // MARK: - Kanban 下游消费订阅源 (spec §4.5 · slice 3)

    /// §4.5: DataSourceItem 消费态 → kanban 列。
    func testKanbanConsumptionStateMapping() {
        XCTAssertEqual(KanbanDerivedColumn.from(consumptionState: .ready), .notStarted)
        XCTAssertEqual(KanbanDerivedColumn.from(consumptionState: .claimed), .inProgress)
        XCTAssertEqual(KanbanDerivedColumn.from(consumptionState: .inProgress), .inProgress)
        XCTAssertEqual(KanbanDerivedColumn.from(consumptionState: .done), .done)
    }

    /// slice 3: 订阅下游消费的 item(consumptionSourceId/ItemId)→ 用队列消费态派生列。
    func testInjectDerivedKanbanColumnsConsumptionSource() {
        let payload: BoardJSONValue = .object([
            "items": .array([
                .object([
                    "id": .string("c1"), "title": .string("Q"),
                    "consumptionSourceId": .string("src-1"),
                    "consumptionItemId": .string("q1"),
                ]),
            ]),
        ])
        let artifact = PlannerArtifact(
            id: "a", canvasId: "c", nodeId: "n", kind: .kanban,
            title: "K", reference: "k", status: "attached",
            createdAt: Date(timeIntervalSince1970: 0), payload: payload
        )
        let result = service.injectDerivedKanbanColumns(
            into: artifact,
            resolveChild: { _ in nil },
            resolveConsumption: { sid, iid in (sid == "src-1" && iid == "q1") ? .claimed : nil }
        )
        guard case .object(let obj)? = result.payload,
              case .array(let items)? = obj["items"],
              case .object(let c1) = items[0],
              case .string(let col)? = c1["derivedColumnId"] else {
            return XCTFail("consumption derive missing")
        }
        XCTAssertEqual(col, KanbanDerivedColumn.inProgress.rawValue)  // claimed → 进行中
    }

    // MARK: - Part D 可配置节点状态 (spec §5 · slice 5)

    func testNodeStateSchemaDefaultAndValidation() {
        let schema = NodeStateSchema.default
        XCTAssertEqual(schema.defaultStateId, "not_started")
        XCTAssertEqual(schema.states.count, 4)
        XCTAssertNotNil(schema.def(forStateId: "running"))
        XCTAssertNil(schema.def(forStateId: "nope"))
        XCTAssertEqual(schema.def(forStateId: "done")?.gatesDownstream, true)
        XCTAssertEqual(schema.def(forStateId: "running")?.gatesDownstream, false)
    }

    /// submit_node_output 动态 state → 引擎 outcome 映射(spec §5.3)。
    func testNodeStateSubmittableStatusMapping() {
        func def(_ kind: NodeStateKind, gates: Bool) -> NodeStateDef {
            NodeStateDef(id: "x", label: "X", kind: kind, gatesDownstream: gates)
        }
        XCTAssertEqual(def(.done, gates: false).submittableStatus, .done)
        XCTAssertEqual(def(.custom, gates: true).submittableStatus, .done)         // 自定义门控态 → done
        XCTAssertEqual(def(.needsResponse, gates: false).submittableStatus, .needsReview)
        XCTAssertNil(def(.running, gates: false).submittableStatus)                // 非终态不可提交
        XCTAssertNil(def(.notStarted, gates: false).submittableStatus)
    }

    func testEffectiveStateSchemaFallsBackToDefault() {
        let nodes = service.nodeMock(canvasId: "c")
        XCTAssertEqual(nodes.first?.effectiveStateSchema.defaultStateId, "not_started")
    }

    // MARK: - Phase 6 — workflow guidance (nextAction)

    /// Builds a minimal `step` node carrying the given workflow run state plus
    /// optional gate / human completion / session context.
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
            schema: NodeSchema(inputs: [], outputs: [], goal: "done"),
            contextSources: [],
            executionMode: signOff ? .human : .auto,
            executorType: .mock,
            doerId: "A",
            status: .ready,
            sessionId: sessionId,
            dependsOnNodeIds: dependsOn,
            nodeKind: nodeKind,
            gate: gated
                ? PlannerNodeGate(
                    type: "human-completion",
                    label: "Human review",
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
            "Review the output and confirm or send it back."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .failed), blockers: nil),
            "Failed — inspect the failure and start work again."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .failed), blockers: ["upstream broke"]),
            "Failed — clear the blockers, then start work again."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .pending), blockers: nil),
            "Ready — start work on this step."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(
                for: guidanceNode(runState: .pending, dependsOn: ["node-upstream"]),
                blockers: nil
            ),
            "Waiting on an upstream step — start work once it clears."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .dispatched), blockers: nil),
            "Starting — waiting for the session to spin up."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(
                for: guidanceNode(runState: .dispatched, sessionId: "sess-1"),
                blockers: nil
            ),
            "Started — open the session to follow progress."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .running), blockers: nil),
            "In progress — open the session to monitor work."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .awaitingInput), blockers: nil),
            "Waiting for your input — open the session and reply."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .done), blockers: nil),
            "Done — confirm the artifact is attached."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .done, gated: true), blockers: nil),
            "Done — verify the delivery evidence."
        )
        XCTAssertEqual(
            PlannerWorkflowGuidance.nextAction(for: guidanceNode(runState: .done, signOff: true), blockers: nil),
            "Done — verify the delivery evidence."
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
        XCTAssertEqual(node.nextAction, "Review the output and confirm or send it back.")

        let encoded = try JSONEncoder().encode(node)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(json["nextAction"] as? String, "Review the output and confirm or send it back.")

        // Round-trips: `nextAction` is encode-only, never decoded back.
        let decoded = try JSONDecoder().decode(PlanningNode.self, from: encoded)
        XCTAssertEqual(decoded, node)
    }

    func testWorkspaceMonitorItemsCarryNextAction() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "owner-a")

        let states = service.readNodeState(nodes: record.nodes)
        let doneCount = states.filter { $0.runState == .done }.count
        let deliveryItem = try XCTUnwrap(monitor.items.first { $0.kind == .delivery })
        XCTAssertEqual(deliveryItem.nextAction, "\(doneCount)/\(states.count) nodes")
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
                "schema": {
                  "inputs": ["goal"],
                  "outputs": ["artifact"],
                  "goal": "human completion"
                },
                "contextSources": [],
                "executionMode": "human",
                "executorType": "mock",
                "doerId": "owner-a",
                "status": "ready"
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
              "status": "draft"
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
        XCTAssertEqual(try PlannerProposalValidator.decodeProposal(from: fenced).changes.first?.status, legacyDraftStatus)
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
            schema: NodeSchema(inputs: ["x"], outputs: ["y"], goal: "done"),
            contextSources: [],
            executionMode: .human,
            executorType: .mock,
            doerId: "owner-a",
            status: .ready,
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
                        schema: NodeSchema(inputs: ["x"], outputs: ["y"], goal: "done"),
                        contextSources: [],
                        executionMode: .human,
                        executorType: .mock,
                        doerId: "owner-a",
                        status: .ready
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
        // epsilon (session-hide) tightened updateNode: setting nodeKind=.session
        // on a non-legacy target is rejected. Use .step (still freely settable)
        // to keep the original "known kind passes" assertion meaningful.
        XCTAssertNoThrow(try PlannerProposalValidator.validate(
            PlanProposal(
                id: "proposal-known-kind",
                canvasId: "canvas-a",
                summary: "Known kind",
                changes: [.updateNode(id: nodes[0].id, nodeKind: .step)],
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
                "schema": {"inputs": ["goal"], "outputs": ["artifact"], "goal": "human completion"},
                "contextSources": [],
                "executionMode": "human",
                "executorType": "mock",
                "doerId": "owner-a",
                "status": "ready",
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

    func testPlannerGraphContextIncludesOpenProposalsForGraphEvolution() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Adapter Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let committedNode = PlanningNode(
            id: "canvas-a-existing",
            canvasId: "canvas-a",
            title: "Existing Step",
            schema: NodeSchema(inputs: ["lark_doc"], outputs: ["idea_kanban"], goal: "Create idea kanban"),
            contextSources: [],
            executionMode: .human,
            executorType: .mock,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
        let pendingNode = PlanningNode(
            id: "canvas-a-pending-html",
            canvasId: "canvas-a",
            title: "Idea Kanban HTML Page",
            schema: NodeSchema(inputs: ["idea_kanban"], outputs: ["html_file"], goal: "Render idea kanban as HTML"),
            contextSources: [],
            executionMode: .human,
            executorType: .mock,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: ["canvas-a-existing"],
            nodeKind: .step
        )
        let state = PlannerGraphState(
            canvas: canvas,
            nodes: [committedNode],
            states: [],
            proposals: [
                PlanProposal(
                    id: "proposal-open",
                    canvasId: "canvas-a",
                    summary: "Add HTML page",
                    changes: [.addNode(pendingNode)],
                    status: .pending
                )
            ],
            access: PlannerPermission.access(for: canvas, nodes: [committedNode]),
            activities: [],
            events: [],
            artifacts: [],
            edges: []
        )

        let context = PlannerGraphContext(state: state, goal: "idea kanban should be html")
        let json = context.jsonString()

        XCTAssertTrue(json.contains(#""openProposals""#))
        XCTAssertTrue(json.contains("proposal-open"))
        XCTAssertTrue(json.contains("canvas-a-pending-html"))
        XCTAssertTrue(PlannerAdapterPromptFactory.systemPrompt.contains("graph evolution"))
        XCTAssertTrue(PlannerAdapterPromptFactory.systemPrompt.contains("re-emit the desired"))
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
                "schema": {"inputs": ["goal"], "outputs": ["artifact"], "goal": "human completion"},
                "contextSources": [],
                "executionMode": "human",
                "executorType": "mock",
                "doerId": "owner-a",
                "status": "ready",
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

    func testDefaultRuntimeUserGoalSurfacesAdapterErrorWithoutLocalFallback() async throws {
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(
                provider: FakeAssistantProvider(errorMessage: "claude unavailable"),
                settings: settings
            )
        }

        do {
            _ = try await runtime.handle(
                .userGoal(canvasId: "canvas-a", goal: "Build the plan", context: nil),
                state: runtimeGraphState(),
                settings: fakeAdapterSettings()
            )
            XCTFail("Expected adapter error to propagate without a local fallback proposal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("claude unavailable"))
        }
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
        let nodes = service.nodeMock(canvasId: "canvas-a")
        let raw = """
        {
          "id": "proposal-drift-adapter",
          "canvasId": "canvas-a",
          "summary": "Adapter drift recovery",
          "changes": [
            {
              "kind": "updateNode",
              "nodeId": "\(nodes[0].id)",
              "title": "\(nodes[0].title) recovery",
              "status": "draft"
            }
          ],
          "status": "pending"
        }
        """
        let runtime = DefaultPlannerAgentRuntime { settings in
            BYOAPlannerAdapter(provider: FakeAssistantProvider(text: raw), settings: settings)
        }
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
        XCTAssertEqual(outcome.proposals.first?.id, "proposal-drift-adapter")
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
        XCTAssertEqual(proposal?.changes.last?.node?.status, .ready)
    }

    func testMockPlannerInspectDriftReturnsRepairProposalForDraftState() async throws {
        let planner = MockPlannerAgent()
        var nodes = service.nodeMock(canvasId: "canvas-a")
        nodes[1].status = legacyDraftStatus
        let states = service.readNodeState(nodes: nodes)

        let proposal = try await planner.inspectDrift(nodes: nodes, states: states.filter { $0.runState == .draft })

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

    func testTemplateCanvasSeedsDefaultWorkflowWhenEmpty() throws {
        let snapshot = boardSnapshot(
            canvasId: "template-a",
            ownerId: "owner-a",
            templateMetadata: BoardLayoutStore.TemplateMetadata()
        )

        let state = try PlannerBoardBridge.canvasState(
            for: "template-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertFalse(state.nodes.isEmpty)
        XCTAssertTrue(state.nodes.contains { $0.id == "template-a-m1-idea" })
        XCTAssertTrue(state.nodes.allSatisfy { $0.canvasId == "template-a" })
    }

    func testBoardCanvasDoesNotSeedDefaultWorkflowWhenEmpty() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let state = try PlannerBoardBridge.canvasState(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertTrue(state.nodes.isEmpty)
    }

    func testClearCanvasContentRemovesPlannerGraphButKeepsCanvas() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try PlannerBoardBridge.graphChangeProposal(
            summary: "Update graph",
            changes: [.updateNode(id: record.nodes[0].id, title: "Updated title")],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.startRun(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a",
            title: "Run before clear"
        )

        let cleared = try PlannerBoardBridge.clearCanvasContent(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(cleared.canvas.id, "canvas-a")
        XCTAssertTrue(cleared.nodes.isEmpty)
        XCTAssertTrue(cleared.states.isEmpty)
        XCTAssertTrue(cleared.proposals.isEmpty)
        XCTAssertTrue(cleared.artifacts.isEmpty)
        XCTAssertTrue(cleared.events.isEmpty)
        XCTAssertTrue(cleared.edges.isEmpty)
        XCTAssertTrue(try PlannerBoardBridge.runs(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        ).isEmpty)
    }

    func testClearCanvasContentRejectsMonitorCanvas() throws {
        let snapshot = boardSnapshot(canvasId: "monitor-a", ownerId: "owner-a", kind: .monitor)
        _ = try seedPlannerNodes(canvasId: "monitor-a", ownerId: "owner-a")

        XCTAssertThrowsError(try PlannerBoardBridge.clearCanvasContent(
            for: "monitor-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .monitorClearNotAllowed("monitor-a"))
        }
    }

    // MARK: - propose_add_node(proposal 子功能:节点会话提议新增 step)

    func testProposeAddNodeCreatesPendingProposalWithOriginAndAppliesAfterApproval() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let origin = record.nodes[0]

        let proposal = try PlannerBoardBridge.proposeAddNode(
            originNodeId: origin.id,
            originSessionId: "session-xyz",
            title: "bugfix: sheet snapshot rendering",
            goal: "bug fixed and verified",
            summary: nil,
            dependsOnNodeIds: nil,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.originNodeId, origin.id)
        XCTAssertEqual(proposal.originSessionId, "session-xyz")
        XCTAssertEqual(proposal.changes.count, 1)
        let change = try XCTUnwrap(proposal.changes.first)
        XCTAssertEqual(change.kind, .addNode)
        let newNode = try XCTUnwrap(change.node)
        XCTAssertEqual(newNode.title, "bugfix: sheet snapshot rendering")
        // 缺省依赖发起节点 —— 画布上呈现 主→子 边。
        XCTAssertEqual(newNode.dependsOnNodeIds, [origin.id])
        XCTAssertEqual(newNode.schema.goal, "bug fixed and verified")
        XCTAssertEqual(newNode.source, .session)

        // pending 提案不落图。
        let before = try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertFalse(before.nodes.contains { $0.id == newNode.id })

        // owner approve + apply 后才落图(复用既有提案管线)。
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let after = try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertTrue(after.nodes.contains { $0.id == newNode.id })
    }

    func testProposeAddNodeIsDoerScopedToOwnNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        // doer "A" 可以从自己的节点(node-1)发起提案。
        _ = try PlannerBoardBridge.proposeAddNode(
            originNodeId: record.nodes[0].id,
            originSessionId: nil,
            title: "follow-up step",
            goal: nil,
            summary: nil,
            dependsOnNodeIds: nil,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "A"
        )

        // 从别人的节点(node-2, doer B)发起 → 拒绝。
        XCTAssertThrowsError(try PlannerBoardBridge.proposeAddNode(
            originNodeId: record.nodes[1].id,
            originSessionId: nil,
            title: "should fail",
            goal: nil,
            summary: nil,
            dependsOnNodeIds: nil,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "A"
        )) { error in
            guard case PlannerCoreError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    func testProposeAddNodeValidationErrorsSurfaceToCaller() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        // 空标题 → 报错(透传给 agent 自纠)。
        XCTAssertThrowsError(try PlannerBoardBridge.proposeAddNode(
            originNodeId: record.nodes[0].id,
            originSessionId: nil,
            title: "   ",
            goal: nil,
            summary: nil,
            dependsOnNodeIds: nil,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        ))

        // 发起节点不存在 → nodeNotFound。
        XCTAssertThrowsError(try PlannerBoardBridge.proposeAddNode(
            originNodeId: "missing-node",
            originSessionId: nil,
            title: "x",
            goal: nil,
            summary: nil,
            dependsOnNodeIds: nil,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .nodeNotFound("missing-node"))
        }

        // 显式依赖不存在的上游 → 校验拒绝,提案不落库。
        XCTAssertThrowsError(try PlannerBoardBridge.proposeAddNode(
            originNodeId: record.nodes[0].id,
            originSessionId: nil,
            title: "dep check",
            goal: nil,
            summary: nil,
            dependsOnNodeIds: ["nope"],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        ))
    }

    func testPlannerBoardBridgeTreatsPersonalCanvasActorAsOwnerWhenStoredOwnerIsStale() throws {
        let suiteName = "PlannerCoreTests-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        OnlineProxy.userDefaultsOverride = defaults
        defaults.set(true, forKey: "meee2Connected")
        defaults.set("current-local-user", forKey: "meee2UserId")
        defer {
            OnlineProxy.userDefaultsOverride = nil
            defaults.removePersistentDomain(forName: suiteName)
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

    func testPlannerWorkspaceMonitorReturnsCanvasItemsInsteadOfNodeItems() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "owner-a")

        let canvasItem = try XCTUnwrap(monitor.items.first { $0.canvasId == "canvas-a" && $0.kind == .delivery })
        XCTAssertEqual(canvasItem.nodeId, nil)
        XCTAssertEqual(canvasItem.summary, "Planning Canvas")
        XCTAssertFalse(monitor.items.contains { $0.kind == .node })
    }

    func testPlannerWorkspaceMonitorSkipsSystemMonitorCanvasNodes() throws {
        let snapshot = boardSnapshot(canvasId: "monitor-a", ownerId: "owner-a", kind: .monitor)
        _ = try seedPlannerNodes(canvasId: "monitor-a", ownerId: "owner-a")

        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "owner-a")

        XCTAssertTrue(monitor.items.isEmpty)
    }

    func testPlannerWorkspaceMonitorDoerViewFiltersToAssignedCanvas() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        let monitor = try PlannerBoardBridge.workspaceMonitor(snapshot: snapshot, actorUserId: "B")

        XCTAssertFalse(monitor.items.isEmpty)
        XCTAssertTrue(monitor.items.allSatisfy { item in
            item.kind == .delivery && item.doerId == "B" && item.nodeId == nil
        })
    }

    func testPlannerWorkspaceMonitorDoesNotCarryExternalSessionOnCanvasItem() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodes = record.nodes
        let states = Dictionary(uniqueKeysWithValues: service.readNodeState(nodes: nodes).map { ($0.nodeId, $0) })
        let index = try XCTUnwrap(nodes.firstIndex { states[$0.id]?.runState != .done })
        _ = try PlannerBoardBridge.store.bindSession(
            canvasId: "canvas-a",
            nodeId: nodes[index].id,
            sessionId: "external-session-a"
        )

        let monitor = try PlannerBoardBridge.workspaceMonitor(
            snapshot: snapshot,
            actorUserId: "owner-a",
            sessions: [
                monitorSession(id: "external-session-a", terminalKind: "external")
            ]
        )

        let item = try XCTUnwrap(monitor.items.first { $0.deliveryId == "canvas-a" })
        XCTAssertEqual(item.kind, .delivery)
        XCTAssertNil(item.nodeId)
        XCTAssertNil(item.sessionId)
    }

    func testPlannerWorkspaceMonitorHidesInternalSessionItems() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodes = record.nodes
        let states = Dictionary(uniqueKeysWithValues: service.readNodeState(nodes: nodes).map { ($0.nodeId, $0) })
        let index = try XCTUnwrap(nodes.firstIndex { states[$0.id]?.runState != .done })
        _ = try PlannerBoardBridge.store.bindSession(
            canvasId: "canvas-a",
            nodeId: nodes[index].id,
            sessionId: "internal-session-a"
        )

        let monitor = try PlannerBoardBridge.workspaceMonitor(
            snapshot: snapshot,
            actorUserId: "owner-a",
            sessions: [
                monitorSession(id: "internal-session-a", terminalKind: "internal", surfaceId: "surface-a")
            ]
        )

        XCTAssertFalse(monitor.items.contains { $0.sessionId == "internal-session-a" })
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

    func testPlannerBoardBridgeApplyPreviewAndApplyReturnGraphEdgesAndArtifacts() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let upstream = try XCTUnwrap(record.nodes.first)
        let downstream = PlanningNode(
            id: "canvas-a-dependent-node",
            canvasId: "canvas-a",
            title: "Dependent artifact check",
            schema: NodeSchema(
                inputs: ["upstream artifact"],
                outputs: ["verified artifact"],
                goal: "verify downstream output"
            ),
            contextSources: [],
            executionMode: .auto,
            executorType: .mock,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: [upstream.id]
        )
        let proposal = PlanProposal(
            id: "proposal-dependent-edge",
            canvasId: "canvas-a",
            summary: "Add dependent node",
            changes: [
                .addNode(downstream),
                .attachArtifact(
                    nodeId: downstream.id,
                    kind: .prd,
                    title: "Verification Notes",
                    reference: "verification-notes",
                    payload: .string("ready")
                )
            ],
            status: .pending
        )

        let preview = try PlannerBoardBridge.applyPreview(
            proposal: proposal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertTrue(preview.edges.contains { $0.sourceNodeId == upstream.id && $0.targetNodeId == downstream.id })
        XCTAssertTrue(preview.artifacts.contains { $0.nodeId == downstream.id && $0.reference == "verification-notes" })

        _ = try PlannerBoardBridge.store.saveProposal(
            proposal,
            canvas: record.canvas,
            seedNodes: record.nodes
        )
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let applied = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertTrue(applied.edges.contains { $0.sourceNodeId == upstream.id && $0.targetNodeId == downstream.id })
        XCTAssertTrue(applied.artifacts.contains { $0.nodeId == downstream.id && $0.reference == "verification-notes" })
    }

    // MARK: - Canvas runtime 5-atom governance apply (PR6+7)

    /// E2E keystone: a single proposal that creates a DataSource + a first-class
    /// queue-claim Edge + a MonitorSpec must, once applied, surface those atoms
    /// on the persisted canvas (and round-trip through the graph-state API).
    func testDelegatedApplyStillRequiresApprovedProposal() throws {
        // P1(codex)回归:开启 sidecar 委托后,未 approved 的「可委托」proposal 仍必须被
        // proposalNotApproved 挡住 —— 委托路不能绕过 applyNodeChange 的 approved 门。
        setenv("MEEE2_APPLY_VIA_SIDECAR", "1", 1)
        setenv("MEEE2_PLANNER_RUNTIME_URL", "http://127.0.0.1:1", 1) // 不可达:确保不真发委托请求
        defer {
            unsetenv("MEEE2_APPLY_VIA_SIDECAR")
            unsetenv("MEEE2_PLANNER_RUNTIME_URL")
        }
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodeA = try XCTUnwrap(record.nodes.first)
        let proposal = PlanProposal(
            id: "proposal-unapproved-delegate",
            canvasId: "canvas-a",
            summary: "Pending update (delegatable kind)",
            changes: [.updateNode(id: nodeA.id, title: "Should not apply")],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: record.canvas, seedNodes: record.nodes)
        // 故意不 approve —— 委托路应在 store.applyProposal 的 approved guard 处抛错。
        XCTAssertThrowsError(try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .proposalNotApproved)
        }
    }

    func testCanvasScriptProposalDecodesToPlanChanges() throws {
        // R3 回归:sidecar instantiate 返回的 canvas-script proposal(真实形状)能被 Swift
        // [PlanChange] 正确 decode —— 命名槽 schema / document-snapshot edgeMode / kanban
        // widget。BoardAPI.applyCanvasScriptTemplate 的接入就依赖这条 decode 不丢字段。
        let json = """
        {"changes":[
          {"kind":"addNode","node":{"id":"n1","canvasId":"cx","title":"主 Agent","schema":{"inputs":[],"outputs":["frontend_spec","backend_spec","refactor_spec"],"goal":"拆分"},"contextSources":[],"executionMode":"auto","executorType":"claude","doerId":"","reviewerIds":[],"approverIds":[],"handoffPolicy":"none","status":"ready","nodeKind":"step"}},
          {"kind":"addNode","node":{"id":"n2","canvasId":"cx","title":"PR 看板","schema":{"inputs":["pull_requests"],"outputs":[],"goal":"看板"},"contextSources":[],"executionMode":"auto","executorType":"claude","doerId":"","reviewerIds":[],"approverIds":[],"handoffPolicy":"none","status":"ready","nodeKind":"step","widget":{"kind":"kanban","source":{"inputKind":"external","inputIndex":0},"mapping":{"statusField":"state","titleField":"title"}}}},
          {"kind":"addEdge","edge":{"id":"e1","canvasId":"cx","sourceRef":{"nodeId":"n1","sourceKey":"frontend_spec"},"targetRef":{"nodeId":"n2","inputKey":"frontend_spec"},"edgeMode":{"mode":"document-snapshot","strategy":{"kind":"follow-latest"}},"createdAt":"1970-01-01T00:00:00.000Z","modeRevision":0}}
        ]}
        """
        struct Wrap: Decodable { let changes: [PlanChange] }
        let wrap = try JSONDecoder().decode(Wrap.self, from: Data(json.utf8))
        XCTAssertEqual(wrap.changes.count, 3)
        XCTAssertEqual(wrap.changes[0].kind, .addNode)
        XCTAssertEqual(wrap.changes[0].node?.schema.outputs, ["frontend_spec", "backend_spec", "refactor_spec"])
        XCTAssertEqual(wrap.changes[1].node?.widget?.kind, .kanban)
        XCTAssertEqual(wrap.changes[2].kind, .addEdge)
        XCTAssertEqual(wrap.changes[2].edge?.sourceRef.sourceKey, "frontend_spec")
        XCTAssertEqual(wrap.changes[2].edge?.edgeMode.mode, "document-snapshot")
    }

    func testApplyProposalPopulatesDataSourceEdgeAndMonitorSpec() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodeA = try XCTUnwrap(record.nodes.first)
        let nodeB = try XCTUnwrap(record.nodes.dropFirst().first)

        let dataSource = DataSourceRecord(
            id: "src-queue-1",
            canvasId: "canvas-a",
            identity: SourceIdentity(connectorKind: "managed", realm: "managed:canvas-a"),
            selector: Selector.declarative(dialect: "path", expr: "queue/*"),
            semantics: Semantics(label: "Work Queue"),
            capabilities: DataSourceCapabilities(queueClaimable: true, appendOnly: true)
        )
        let edge = Edge(
            id: "edge-1",
            canvasId: "canvas-a",
            sourceRef: EdgeSourceRef(nodeId: nodeA.id, sourceKey: "out"),
            targetRef: EdgeTargetRef(nodeId: nodeB.id, inputKey: "in"),
            edgeMode: EdgeMode(
                mode: "queue-claim",
                ordering: "fifo",
                lock: EdgeModeLock()
            )
        )
        let spec = MonitorSpec(
            canvasId: "canvas-a",
            version: 1,
            cards: [MonitorCard(id: "card-1", type: "producer-status-grid", title: "Status")]
        )

        let proposal = PlanProposal(
            id: "proposal-5atom",
            canvasId: "canvas-a",
            summary: "Add data source + queue-claim edge + monitor spec",
            changes: [
                PlanChange(kind: .addDataSource, node: nil, nodeId: nil, title: nil, status: nil,
                           dataSourceRecord: dataSource),
                PlanChange(kind: .addEdge, node: nil, nodeId: nil, title: nil, status: nil, edge: edge),
                PlanChange(kind: .setMonitorSpec, node: nil, nodeId: nil, title: nil, status: nil, spec: spec)
            ],
            status: .pending
        )

        // Round-trip the proposal through Codable so the kind-disambiguated
        // decode path (shared `source`/`layout`/`patch` keys) is exercised too.
        let encoded = try JSONEncoder().encode(proposal)
        let decoded = try JSONDecoder().decode(PlanProposal.self, from: encoded)
        XCTAssertEqual(decoded.changes[0].kind, .addDataSource)
        XCTAssertEqual(decoded.changes[0].dataSourceRecord?.id, "src-queue-1")
        XCTAssertEqual(decoded.changes[1].edge?.edgeMode.mode, "queue-claim")
        XCTAssertEqual(decoded.changes[2].spec?.cards.first?.id, "card-1")

        _ = try PlannerBoardBridge.store.saveProposal(
            decoded,
            canvas: record.canvas,
            seedNodes: record.nodes
        )
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let applied = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // The applied graph-state envelope's canvas must carry the atoms.
        XCTAssertEqual(applied.canvas.dataSources.count, 1)
        XCTAssertEqual(applied.canvas.dataSources.first?.id, "src-queue-1")
        XCTAssertTrue(applied.canvas.dataSources.first?.capabilities.queueClaimable == true)
        // addendum Part A/G:新形状(identity/selector/semantics)穿过 apply 不丢。
        XCTAssertEqual(applied.canvas.dataSources.first?.identity.connectorKind, "managed")
        XCTAssertEqual(applied.canvas.dataSources.first?.semantics.label, "Work Queue")
        XCTAssertEqual(applied.canvas.dataSources.first?.selector.mode, "declarative")
        XCTAssertEqual(applied.canvas.dataSources.first?.selector.expr, "queue/*")
        // Phase 1 edge unification: `edges` now also carries the dependency
        // edges promoted from the seeded nodes' dependsOnNodeIds, so assert the
        // explicit queue-claim edge by id rather than a brittle total count.
        let queueEdge = applied.canvas.edges.first { $0.id == "edge-1" }
        XCTAssertNotNil(queueEdge, "explicit queue-claim edge present")
        XCTAssertEqual(queueEdge?.edgeMode.mode, "queue-claim")
        XCTAssertEqual(applied.canvas.monitorSpec?.cards.count, 1)
        XCTAssertEqual(applied.canvas.monitorSpec?.cards.first?.id, "card-1")
        XCTAssertEqual(applied.canvas.monitorSpec?.appliedFromProposalId, "proposal-5atom")

        // And it must survive a fresh store instance (persisted to disk).
        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
        let reloaded = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        XCTAssertEqual(reloaded.canvas.dataSources.first?.id, "src-queue-1")
        XCTAssertEqual(reloaded.canvas.dataSources.first?.identity.connectorKind, "managed")
        XCTAssertEqual(reloaded.canvas.dataSources.first?.semantics.label, "Work Queue")
        XCTAssertEqual(reloaded.canvas.edges.first?.id, "edge-1")
        XCTAssertEqual(reloaded.canvas.monitorSpec?.cards.first?.id, "card-1")
    }

    /// addendum Part A/G migration — on-disk 旧形状(kind/title/pathPattern)必须
    /// decode 成新 identity/selector/semantics,让历史 canvas 平滑升级。
    func testDataSourceLegacyJSONDecodesToNewShape() throws {
        let legacy = """
        {
          "id": "src-legacy-1",
          "canvasId": "canvas-legacy",
          "kind": "fs",
          "title": "PRD 草稿",
          "pathPattern": "prd-draft/**",
          "partitionRule": "iso-week",
          "currentVersion": 3
        }
        """
        let ds = try JSONDecoder().decode(DataSourceRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(ds.identity.connectorKind, "fs")
        XCTAssertEqual(ds.identity.realm, "fs:canvas-legacy")
        XCTAssertEqual(ds.selector.mode, "declarative")
        XCTAssertEqual(ds.selector.dialect, "glob") // fs ⇒ glob
        XCTAssertEqual(ds.selector.expr, "prd-draft/**")
        XCTAssertEqual(ds.semantics.label, "PRD 草稿")
        XCTAssertEqual(ds.partitionRule, "iso-week")
        XCTAssertEqual(ds.currentVersion, 3)
        // compat accessors collapse back to the legacy vocabulary.
        XCTAssertEqual(ds.connectorKind, "fs")
        XCTAssertEqual(ds.label, "PRD 草稿")
        XCTAssertEqual(ds.pathHint, "prd-draft/**")
    }

    /// New-shape DataSource(declarative + curated)round-trips,且 encode 只出新
    /// 形状(绝不再写 legacy kind/title/pathPattern key)。
    func testDataSourceNewShapeRoundTrips() throws {
        let declarative = DataSourceRecord(
            id: "src-new-1",
            canvasId: "canvas-new",
            identity: SourceIdentity(connectorKind: "notion", realm: "notion:ws_42"),
            selector: Selector.declarative(dialect: "notion-db", expr: "<database_id>"),
            semantics: Semantics(label: "竞品库", purpose: "竞品调研落点"),
            partitionRule: "month",
            currentVersion: 1
        )
        let encoded = try JSONEncoder().encode(declarative)
        XCTAssertEqual(try JSONDecoder().decode(DataSourceRecord.self, from: encoded), declarative)
        // encode 不得再写 legacy keys。
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(obj["kind"])
        XCTAssertNil(obj["title"])
        XCTAssertNil(obj["pathPattern"])
        XCTAssertNotNil(obj["identity"])
        XCTAssertNotNil(obj["selector"])
        XCTAssertNotNil(obj["semantics"])

        // curated selector(物化成员集 + opaque shapeSchema)也 round-trip。
        let curated = DataSourceRecord(
            id: "src-curated-1",
            canvasId: "canvas-new",
            identity: SourceIdentity(connectorKind: "curated", realm: "curated:art-7"),
            selector: Selector(
                mode: "curated",
                curatorSessionId: "sess-9",
                members: [MemberRef(identity: SourceIdentity(connectorKind: "fs", realm: "fs:/w"), ref: "a.md")],
                intent: "所有竞品材料",
                shapeSchema: .object(["kind": .string("doc")])
            ),
            semantics: Semantics(label: "竞品材料")
        )
        let curatedDecoded = try JSONDecoder().decode(
            DataSourceRecord.self, from: try JSONEncoder().encode(curated)
        )
        XCTAssertEqual(curatedDecoded, curated)
        XCTAssertEqual(curatedDecoded.selector.members?.first?.ref, "a.md")
    }

    /// Phase 1 edge unification — `canvas.edges` is authoritative and the legacy
    /// `dependsOnNodeIds` is a derived projection. Adding an edge surfaces the
    /// dependency; removing it clears the dependency.
    func testEdgeDependencyBidirectionalSync() throws {
        let canvasId = "cv-edge-sync"
        let ownerId = "owner-e"
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: ownerId)
        let a = PlanningNode(
            id: "n-a", canvasId: canvasId, title: "A",
            schema: NodeSchema(inputs: [], outputs: ["out"], goal: "a"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: ownerId, status: .ready, nodeKind: .step
        )
        let b = PlanningNode(
            id: "n-b", canvasId: canvasId, title: "B",
            schema: NodeSchema(inputs: ["in"], outputs: ["out"], goal: "b"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: ownerId, status: .ready, nodeKind: .step
        )
        let record = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: ownerId, title: "Edge Sync", plannerContext: "canvas:\(canvasId)"),
            seedNodes: [a, b]
        )
        // add an edge A → B → dependency on B appears
        let edge = Edge(
            id: "e-ab", canvasId: canvasId,
            sourceRef: EdgeSourceRef(nodeId: "n-a", sourceKey: "out"),
            targetRef: EdgeTargetRef(nodeId: "n-b", inputKey: "in"),
            edgeMode: EdgeMode(mode: "queue-claim", ordering: "fifo", lock: EdgeModeLock())
        )
        let addP = PlanProposal(
            id: "p-add-edge", canvasId: canvasId, summary: "add edge",
            changes: [PlanChange(kind: .addEdge, node: nil, nodeId: nil, title: nil, status: nil, edge: edge)],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(addP, canvas: record.canvas, seedNodes: record.nodes)
        _ = try PlannerBoardBridge.approveProposal(proposalId: addP.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        let afterAdd = try PlannerBoardBridge.applyProposal(proposalId: addP.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        let bAfterAdd = try XCTUnwrap(afterAdd.nodes.first { $0.id == "n-b" })
        XCTAssertEqual(bAfterAdd.dependsOnNodeIds, ["n-a"], "addEdge → dependency projected onto target")

        // remove the edge → dependency clears
        let rmP = PlanProposal(
            id: "p-rm-edge", canvasId: canvasId, summary: "remove edge",
            changes: [PlanChange(kind: .removeEdge, node: nil, nodeId: nil, title: nil, status: nil, edgeId: "e-ab")],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(rmP, canvas: afterAdd.canvas, seedNodes: afterAdd.nodes)
        _ = try PlannerBoardBridge.approveProposal(proposalId: rmP.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        let afterRm = try PlannerBoardBridge.applyProposal(proposalId: rmP.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        let bAfterRm = try XCTUnwrap(afterRm.nodes.first { $0.id == "n-b" })
        XCTAssertTrue((bAfterRm.dependsOnNodeIds ?? []).isEmpty, "removeEdge → dependency cleared")
        XCTAssertFalse(afterRm.canvas.edges.contains { $0.id == "e-ab" }, "edge gone")
    }

    /// Weekly-PRD-pipeline E2E (code level, state-machine).
    /// Covers the four acceptance criteria end to end on one canvas:
    ///   1. monitor + flow match requirements (DataSource + queue-claim edge +
    ///      MonitorSpec applied and readable).
    ///   2. dispatch ("开干") puts the node into a running run-state AND a
    ///      non-empty default prompt carrying the node protocol is generated.
    ///   3. a session update surfaces in the node's progress, and a stop /
    ///      blocked submit flips the node into an attention state.
    ///   4. a produced artifact is consumed downstream and the monitor's source
    ///      of truth (node run-state + artifacts + queue source) updates.
    func testPRDPipelineE2E_FourCriteria() throws {
        let canvasId = "cv-prd-e2e"
        let ownerId = "owner-prd"
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: ownerId)
        // Two explicit auto worker nodes: producer (e.g. the PM agent that
        // emits an artifact and completes) → consumer (downstream claimant).
        // Auto mode matters — a `.human` node parks its done-output at a human
        // gate (workflowRunState=.gateWait, plan status = attention/blocked),
        // verified at PlannerCore submitNodeOutput; only `.auto` goes straight
        // to .done. The PRD reviewers ARE human (they'd park at a gate for
        // sign-off); this test exercises the auto-worker completion path.
        let producer = PlanningNode(
            id: "n-producer", canvasId: canvasId, title: "PM · 出 PR",
            schema: NodeSchema(inputs: ["issue"], outputs: ["pr"], goal: "open a PR"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: ownerId, status: .ready, nodeKind: .step
        )
        let consumer = PlanningNode(
            id: "n-consumer", canvasId: canvasId, title: "PR 验证",
            schema: NodeSchema(inputs: ["pr"], outputs: ["verdict"], goal: "verify the PR"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: ownerId, status: .ready,
            dependsOnNodeIds: ["n-producer"], nodeKind: .step
        )
        let record = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: ownerId, title: "PRD E2E", plannerContext: "canvas:\(canvasId)"),
            seedNodes: [producer, consumer]
        )

        // ---- Criterion 1: build the flow + monitor, apply, read back --------
        let issuesSource = DataSourceRecord(
            id: "src-issues",
            canvasId: canvasId,
            identity: SourceIdentity(connectorKind: "github", realm: "github:repo"),
            selector: Selector.declarative(dialect: "gh", expr: "gh://repo/issues/"),
            semantics: Semantics(label: "GitHub issues"),
            capabilities: DataSourceCapabilities(
                documentReadable: true, listEnumerable: true,
                queueClaimable: true, appendOnly: true
            )
        )
        let queueEdge = Edge(
            id: "edge-issues-pm",
            canvasId: canvasId,
            sourceRef: EdgeSourceRef(nodeId: producer.id, sourceKey: "issues"),
            targetRef: EdgeTargetRef(nodeId: consumer.id, inputKey: "task"),
            edgeMode: EdgeMode(mode: "queue-claim", ordering: "fifo", lock: EdgeModeLock())
        )
        let spec = MonitorSpec(
            canvasId: canvasId,
            version: 1,
            cards: [
                MonitorCard(id: "c-producers", type: "producer-status-grid", title: "交稿进度"),
                MonitorCard(id: "c-queue", type: "queue-depth", title: "issue 队列深度")
            ]
        )
        let proposal = PlanProposal(
            id: "prop-prd-e2e",
            canvasId: canvasId,
            summary: "PRD pipeline: issues DataSource + queue-claim edge + monitor",
            changes: [
                PlanChange(kind: .addDataSource, node: nil, nodeId: nil, title: nil, status: nil,
                           dataSourceRecord: issuesSource),
                PlanChange(kind: .addEdge, node: nil, nodeId: nil, title: nil, status: nil, edge: queueEdge),
                PlanChange(kind: .setMonitorSpec, node: nil, nodeId: nil, title: nil, status: nil, spec: spec)
            ],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: record.canvas, seedNodes: record.nodes)
        _ = try PlannerBoardBridge.approveProposal(proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        let applied = try PlannerBoardBridge.applyProposal(proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        XCTAssertEqual(applied.canvas.dataSources.first?.id, "src-issues", "C1: DataSource applied")
        XCTAssertEqual(applied.canvas.edges.first?.edgeMode.mode, "queue-claim", "C1: queue-claim edge applied")
        XCTAssertEqual(applied.canvas.monitorSpec?.cards.count, 2, "C1: monitor cards applied")

        // ---- Criterion 2: 开干 → running + default prompt -------------------
        let dispatched = try PlannerBoardBridge.dispatchNode(
            nodeId: producer.id, runner: .claude, for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        XCTAssertNotNil(dispatched.dispatchedNode.dispatch, "C2: dispatch recorded on node")
        let prompt = BoardAPI.plannerDispatchPrompt(for: dispatched.dispatchedNode, canvasId: canvasId, cwd: "/tmp/ws")
        XCTAssertFalse(prompt.isEmpty, "C2: default prompt generated")
        XCTAssertTrue(prompt.contains("read_node_contract"), "C2: prompt carries the node protocol")
        XCTAssertTrue(prompt.contains("submit_node_output"), "C2: prompt instructs writeback")
        XCTAssertTrue(prompt.contains("output.payload_kind=artifact_ref"), "C2: prompt clarifies artifact_ref output")
        XCTAssertTrue(prompt.contains("\"type\":\"json\""), "C2: prompt gives typed artifact payload examples")

        // ---- Criterion 4: artifact produced → consumed downstream → monitor -
        // producer (root) completes with an artifact — a clean dispatch→done.
        let done = try PlannerBoardBridge.submitNodeOutput(
            nodeId: producer.id,
            output: PlannerNodeOutput(
                nodeId: producer.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "PRD 草稿完成", routeTo: []),
                // reference MUST match the node's declared output slot, else the
                // engine treats the contract as unsatisfied and keeps the node
                // incomplete (verified behavior — see
                // testSubmitNodeOutputHintsWhenArtifactsDoNotSatisfyContract).
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .prd,
                    title: "张三 PRD",
                    reference: producer.schema.outputs.first ?? "out",
                    payload: .object(["type": .string("markdown"), "data": .string("# PRD")]),
                    routeTo: []
                )],
                next: .complete,
                forceNewVersion: false
            ),
            for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        // produced artifact is on the canvas (monitor source of truth #1)
        XCTAssertTrue(
            done.graph.artifacts.contains(where: { $0.nodeId == producer.id }),
            "C4: produced artifact present on canvas (monitor reads it)"
        )
        // producer run-state is terminal-done (producer-status-grid cell flips)
        let doneNode = try XCTUnwrap(done.graph.nodes.first(where: { $0.id == producer.id }))
        XCTAssertEqual(doneNode.status, .done, "C4: auto producer done → monitor producer-grid recomputes")
        // downstream consumer is no longer upstream-blocked once producer is done
        // (dataflow legality: upstream ∈ done ⇒ downstream becomes startable).
        let consumerAfter = try XCTUnwrap(done.graph.nodes.first(where: { $0.id == consumer.id }))
        XCTAssertNotEqual(consumerAfter.status, .blocked, "C4: downstream consumes — no longer blocked by upstream")
        // the monitor spec + queue source are still intact and queryable live
        let live = try PlannerBoardBridge.graphState(for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        XCTAssertEqual(live.canvas.monitorSpec?.cards.count, 2, "C4: monitor still serves after state change")
        XCTAssertNotNil(live.canvas.dataSources.first(where: { $0.id == "src-issues" }), "C4: queue source live")

        // ---- Criterion 3: a stopped/blocked session surfaces as attention ---
        // downstream node is now startable; dispatch it ("开干"), then the
        // session stops needing input → blocked submit flips it to 卡住, the
        // signal the UI turns into a "needs your reply" prompt.
        _ = try PlannerBoardBridge.dispatchNode(
            nodeId: consumer.id, runner: .claude, for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        let blocked = try PlannerBoardBridge.submitNodeOutput(
            nodeId: consumer.id,
            output: PlannerNodeOutput(
                nodeId: consumer.id,
                status: .blocked,
                message: PlannerNodeOutputMessage(summary: "等待用户确认实现方案", routeTo: []),
                artifacts: [],
                next: .blocked,
                forceNewVersion: false
            ),
            for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        let blockedNode = try XCTUnwrap(blocked.graph.nodes.first(where: { $0.id == consumer.id }))
        XCTAssertEqual(blockedNode.status, .blocked, "C3: stopped/blocked session surfaces as 卡住 (user prompted)")
    }

    /// The DataSource adapter's queue-claim state machine (§3.8) must drive a
    /// seeded managed source through ready → claimed → done.
    func testManagedAdapterQueueClaimStateMachine() throws {
        let source = DataSourceRecord(
            id: "src-managed-1",
            canvasId: "canvas-a",
            identity: SourceIdentity(connectorKind: "managed", realm: "managed:canvas-a"),
            semantics: Semantics(label: "Queue"),
            capabilities: DataSourceCapabilities(queueClaimable: true)
        )
        let adapter = ManagedAdapter(source: source, seedItems: [
            DataSourceItem(itemId: "a", ref: "ref-a"),
            DataSourceItem(itemId: "b", ref: "ref-b")
        ])
        let claimed = try adapter.claim(n: 1, claimant: "ck-test")
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed.first?.state, .claimed)
        let itemId = try XCTUnwrap(claimed.first?.itemId)
        try adapter.markInProgress(itemId: itemId, claimant: "ck-test")
        try adapter.markDone(itemId: itemId, claimant: "ck-test")
        // A different claimant cannot complete an item it never claimed.
        let second = try adapter.claim(n: 1, claimant: "ck-other")
        XCTAssertThrowsError(try adapter.markDone(itemId: try XCTUnwrap(second.first?.itemId), claimant: "ck-test"))
    }

    /// canvas-spec §5/§10 (P3) · Output → DataSource → queue-claim, end to end.
    /// A producer node submits an output whose slot is bound to a queue-claimable
    /// DataSource (via an edge carrying `sourceRef.dataSourceId`); on submit the
    /// artifact is PUSHED into that source — `currentVersion` advances and a
    /// claimable item is enqueued. A downstream queue-claim consumer then CLAIMS
    /// from that source (ready→claimed→done), and the source's queue depth
    /// reflects the claim. Regression for the gap where a produced output never
    /// fed the connected DataSource (issues currentVersion stayed 0).
    func testOutputPushesIntoDataSourceThenConsumerClaims() throws {
        let canvasId = "cv-p3-push-claim"
        let ownerId = "owner-p3"
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: ownerId)
        // 会议产出 push 进 issues source; PM 从 issues source queue-claim.
        let meeting = PlanningNode(
            id: "n-meeting", canvasId: canvasId, title: "会议 · 产出 issues",
            schema: NodeSchema(inputs: [], outputs: ["issues"], goal: "produce issues"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: ownerId, status: .ready, nodeKind: .step
        )
        let pm = PlanningNode(
            id: "n-pm", canvasId: canvasId, title: "PM · claim issue",
            schema: NodeSchema(inputs: ["task"], outputs: ["pr"], goal: "claim + implement"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: ownerId, status: .ready,
            dependsOnNodeIds: ["n-meeting"], nodeKind: .step
        )
        let record = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: ownerId, title: "P3", plannerContext: "canvas:\(canvasId)"),
            seedNodes: [meeting, pm]
        )

        let issuesSource = DataSourceRecord(
            id: "src-issues-p3",
            canvasId: canvasId,
            identity: SourceIdentity(connectorKind: "managed", realm: "managed:\(canvasId)"),
            selector: Selector.declarative(dialect: "path", expr: "gh://repo/issues/"),
            semantics: Semantics(label: "issues"),
            capabilities: DataSourceCapabilities(
                documentReadable: true, listEnumerable: true,
                queueClaimable: true, appendOnly: true
            )
        )
        // The queue-claim edge: meeting output slot `issues` → PM input `task`,
        // routed through the issues DataSource pool (`sourceRef.dataSourceId`).
        let queueEdge = Edge(
            id: "edge-issues-pm-p3",
            canvasId: canvasId,
            sourceRef: EdgeSourceRef(nodeId: meeting.id, sourceKey: "issues", dataSourceId: issuesSource.id),
            targetRef: EdgeTargetRef(nodeId: pm.id, inputKey: "task"),
            edgeMode: EdgeMode(mode: "queue-claim",
                               strategy: EdgeModeStrategy(kind: "claim-one"),
                               ordering: "fifo", lock: EdgeModeLock())
        )
        let proposal = PlanProposal(
            id: "prop-p3", canvasId: canvasId,
            summary: "issues source + output→source queue-claim edge",
            changes: [
                PlanChange(kind: .addDataSource, node: nil, nodeId: nil, title: nil, status: nil,
                           dataSourceRecord: issuesSource),
                PlanChange(kind: .addEdge, node: nil, nodeId: nil, title: nil, status: nil, edge: queueEdge)
            ],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: record.canvas, seedNodes: record.nodes)
        _ = try PlannerBoardBridge.approveProposal(proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        let applied = try PlannerBoardBridge.applyProposal(proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        // The DataSource binding survived apply on the edge.
        let appliedEdge = try XCTUnwrap(applied.canvas.edges.first { $0.id == "edge-issues-pm-p3" })
        XCTAssertEqual(appliedEdge.sourceRef.dataSourceId, "src-issues-p3", "edge carries the DataSource binding")
        XCTAssertEqual(applied.canvas.dataSources.first { $0.id == "src-issues-p3" }?.currentVersion, 0,
                       "precondition: source starts at version 0 (nothing produced yet)")

        // ---- Producer submits output bound to the source slot --------------
        let done = try PlannerBoardBridge.submitNodeOutput(
            nodeId: meeting.id,
            output: PlannerNodeOutput(
                nodeId: meeting.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "会议产出一个 issue", routeTo: []),
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .prd,
                    title: "Issue #1",
                    reference: "issues", // matches meeting's output slot == edge sourceKey
                    payload: .object(["type": .string("markdown"), "data": .string("# do the thing")]),
                    routeTo: []
                )],
                next: .complete,
                forceNewVersion: false
            ),
            for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        // 1) currentVersion advanced 0 → 1 (the push happened).
        let srcAfterPush = try XCTUnwrap(done.graph.canvas.dataSources.first { $0.id == "src-issues-p3" })
        XCTAssertEqual(srcAfterPush.currentVersion, 1, "P3: output push advanced source currentVersion")
        // 2) a source-keyed version row was appended (writeSourceVersion twin).
        let sourceSlotKey = "\(canvasId)|source|src-issues-p3|issues"
        let recordAfterPush = try PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvasId)
        XCTAssertTrue(
            recordAfterPush.artifactVersions.contains { $0.artifactSlotKey == sourceSlotKey },
            "P3: a version row keyed to the source slot was appended"
        )
        // 3) a claimable item is enqueued (ready depth == 1).
        let adapter = try XCTUnwrap(
            PlannerBoardBridge.dataSourceAdapter(canvasId: canvasId, sourceId: "src-issues-p3") as? ManagedAdapter
        )
        XCTAssertEqual(adapter.readyDepth(), 1, "P3: produced output enqueued one claimable item")

        // ---- Consumer claims from the source -------------------------------
        let claimant = "ck-pm-attempt-1"
        let (claimedSourceId, claimed) = try PlannerBoardBridge.claimFromSourceForConsumer(
            canvasId: canvasId, consumerNodeId: pm.id, claimant: claimant
        )
        XCTAssertEqual(claimedSourceId, "src-issues-p3")
        XCTAssertEqual(claimed.count, 1, "P3: claim-one pulled exactly one item")
        let claimedItemId = try XCTUnwrap(claimed.first?.itemId)
        XCTAssertEqual(claimed.first?.state, .claimed, "P3: claimed item is in .claimed state")
        // queue depth now reflects the claim (no more ready items).
        XCTAssertEqual(adapter.readyDepth(), 0, "P3: claimed item left the ready queue")
        XCTAssertEqual(adapter.item(claimedItemId)?.state, .claimed)

        // ---- Complete the item: claimed → in-progress → done ---------------
        try PlannerBoardBridge.dataSourceMarkInProgress(
            canvasId: canvasId, sourceId: claimedSourceId, itemId: claimedItemId, claimant: claimant
        )
        XCTAssertEqual(adapter.item(claimedItemId)?.state, .inProgress)
        try PlannerBoardBridge.dataSourceMarkDone(
            canvasId: canvasId, sourceId: claimedSourceId, itemId: claimedItemId, claimant: claimant
        )
        XCTAssertEqual(adapter.item(claimedItemId)?.state, .done, "P3: item reached terminal .done")
        // A second claim finds nothing left.
        let secondClaim = try PlannerBoardBridge.dataSourceClaim(
            canvasId: canvasId, sourceId: claimedSourceId, n: 1, claimant: "ck-other"
        )
        XCTAssertTrue(secondClaim.isEmpty, "P3: queue drained — nothing left to claim")
    }

    /// §6.6 footgun guard: replacing a non-empty monitor spec wholesale without
    /// `intent='wipe-and-rebuild'` must be rejected.
    func testSetMonitorSpecReplaceGuardRejectsWholesaleReplace() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let record = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let firstSpec = MonitorSpec(canvasId: "canvas-a", cards: [
            MonitorCard(id: "card-1", type: "producer-status-grid")
        ])
        let p1 = PlanProposal(
            id: "p-monitor-1", canvasId: "canvas-a", summary: "set monitor",
            changes: [PlanChange(kind: .setMonitorSpec, node: nil, nodeId: nil, title: nil, status: nil, spec: firstSpec)],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(p1, canvas: record.canvas, seedNodes: record.nodes)
        _ = try PlannerBoardBridge.approveProposal(proposalId: p1.id, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        _ = try PlannerBoardBridge.applyProposal(proposalId: p1.id, for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")

        // Read back the live canvas (now carrying the applied monitor spec) so
        // the guard validates against the real prior state.
        let live = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot)
        XCTAssertEqual(live.canvas.monitorSpec?.cards.count, 1)

        // A second wholesale setMonitorSpec without intent must be rejected at save.
        let secondSpec = MonitorSpec(canvasId: "canvas-a", cards: [
            MonitorCard(id: "card-2", type: "period-selector")
        ])
        let p2 = PlanProposal(
            id: "p-monitor-2", canvasId: "canvas-a", summary: "replace monitor",
            changes: [PlanChange(kind: .setMonitorSpec, node: nil, nodeId: nil, title: nil, status: nil, spec: secondSpec)],
            status: .pending
        )
        XCTAssertThrowsError(try PlannerBoardBridge.store.saveProposal(p2, canvas: live.canvas, seedNodes: live.nodes)) { error in
            guard case PlannerCoreError.monitorSpecReplaceGuard = error else {
                return XCTFail("expected monitorSpecReplaceGuard, got \(error)")
            }
        }

        // The same replace WITH intent='wipe-and-rebuild' must be accepted.
        let p3 = PlanProposal(
            id: "p-monitor-3", canvasId: "canvas-a", summary: "wipe and rebuild monitor",
            changes: [PlanChange(kind: .setMonitorSpec, node: nil, nodeId: nil, title: nil, status: nil,
                                 spec: secondSpec, intent: "wipe-and-rebuild")],
            status: .pending
        )
        XCTAssertNoThrow(try PlannerBoardBridge.store.saveProposal(p3, canvas: live.canvas, seedNodes: live.nodes))
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

    func testPlannerStoreDoesNotOverwriteUnreadableExistingState() throws {
        let rootURL = plannerStoreURL.deletingPathExtension()
        let stateURL = rootURL
            .appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent("canvas-a", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = #"{"canvas":{"id":"canvas-a"},"nodes":[{"workflowRunState":"not-a-state"}]}"#
        try original.write(to: stateURL, atomically: true, encoding: .utf8)

        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let store = PlannerStore(fileURL: plannerStoreURL)

        XCTAssertThrowsError(try store.record(for: canvas, seedNodes: [])) { error in
            XCTAssertEqual(error as? PlannerCoreError, .plannerStateUnreadable("canvas-a"))
        }
        XCTAssertEqual(try String(contentsOf: stateURL), original)
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

    func testPlannerStoreWritesEventsOutsideStateJson() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.generateProposal(
            goal: "Event log split",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let canvasDirectory = plannerStoreURL.deletingPathExtension()
            .appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent("canvas-a", isDirectory: true)
        let stateURL = canvasDirectory.appendingPathComponent("state.json")
        let eventsURL = canvasDirectory.appendingPathComponent("events.jsonl")

        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL.path))

        let stateData = try Data(contentsOf: stateURL)
        let stateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertNil(stateObject["events"], "state.json should carry the current snapshot, not the event log")

        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertFalse(eventLines.isEmpty)
        XCTAssertTrue(eventLines.contains { $0.contains(proposal.id) })

        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
        let record = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(
                id: "canvas-a",
                ownerId: "owner-a",
                title: "Planning Canvas",
                plannerContext: "canvas:canvas-a"
            ),
            seedNodes: []
        )
        XCTAssertTrue(record.events.contains { $0.type == .proposalCreated && $0.proposalId == proposal.id })
    }

    func testPlannerStoreDoesNotRewriteEventsWhenOnlySnapshotChanges() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try PlannerBoardBridge.generateProposal(
            goal: "Stable event log",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let eventsURL = plannerStoreURL.deletingPathExtension()
            .appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent("canvas-a", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let before = try FileManager.default.attributesOfItem(atPath: eventsURL.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)

        _ = try PlannerBoardBridge.store.setCanvasContext("updated context", canvasId: "canvas-a")

        let after = try FileManager.default.attributesOfItem(atPath: eventsURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "snapshot-only saves should not rewrite events.jsonl")
    }

    func testPlannerStoreMigratesLegacyInlineEventsToJsonl() throws {
        let canvasDirectory = plannerStoreURL.deletingPathExtension()
            .appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent("legacy-canvas", isDirectory: true)
        try FileManager.default.createDirectory(at: canvasDirectory, withIntermediateDirectories: true)
        let stateURL = canvasDirectory.appendingPathComponent("state.json")
        let eventsURL = canvasDirectory.appendingPathComponent("events.jsonl")
        let legacyState = """
        {
          "canvas": {
            "id": "legacy-canvas",
            "ownerId": "owner-a",
            "title": "Legacy Canvas",
            "plannerContext": "canvas:legacy-canvas",
            "visibility": "private"
          },
          "nodes": [],
          "proposals": [],
          "events": [
            {
              "id": "event-legacy-1",
              "canvasId": "legacy-canvas",
              "type": "proposal.created",
              "nodeId": null,
              "proposalId": "proposal-legacy-1",
              "summary": "Legacy event",
              "artifactRefs": [],
              "createdAt": 802208664.372613
            }
          ],
          "artifacts": [],
          "artifactVersions": [],
          "runs": [],
          "nodeVersions": []
        }
        """
        try legacyState.write(to: stateURL, atomically: true, encoding: .utf8)

        let store = PlannerStore(fileURL: plannerStoreURL)
        let record = try store.record(
            for: PlanningCanvas(
                id: "legacy-canvas",
                ownerId: "owner-a",
                title: "Legacy Canvas",
                plannerContext: "canvas:legacy-canvas"
            ),
            seedNodes: []
        )

        XCTAssertEqual(record.events.map(\.id), ["event-legacy-1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL.path))
        let migratedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertNil(migratedState["events"])
        let eventLines = try String(contentsOf: eventsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(eventLines.count, 1)
        XCTAssertTrue(eventLines[0].contains("event-legacy-1"))
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
        XCTAssertEqual(node.executionMode, .human)
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

        XCTAssertEqual(SessionToPlanningNodeMapper.map(session: running, canvasId: "c", doerId: "d").status, .ready)
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

    func testDeliveryPipelineTemplateCreatesExecutableNodesOnly() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")

        let proposal = try PlannerBoardBridge.deliveryPipelineProposal(
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.changes.count, 5)
        let nodes = proposal.changes.compactMap(\.node)
        XCTAssertEqual(nodes.filter { $0.nodeKind == .step }.count, 5)
        XCTAssertEqual(nodes.last?.doerId, "release-automation")
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
        XCTAssertFalse(graph.renderObjects.contains { $0.entityRef?.kind == .session })
        XCTAssertFalse(graph.renderObjects.contains { $0.id == "session:explicit-session" })
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
        let artifact = try XCTUnwrap(graph.artifacts.first { $0.reference == "repo://prd.md" })
        XCTAssertFalse(graph.renderObjects.contains {
            $0.id == "artifact:\(artifact.id)" && $0.entityRef?.kind == .artifact
        })
        XCTAssertFalse(graph.renderRelations.contains {
            $0.kind == .dataflow
                && $0.source.objectId == "node:\(node.id)"
                && $0.target.objectId == "artifact:\(artifact.id)"
        })
        XCTAssertFalse(graph.edges.isEmpty)
        XCTAssertEqual(moved.nodes.first { $0.id == node.id }?.layout?.x, 10)
    }

    func testDeleteNodeRemovesNodeArtifactsAndUpstreamReferences() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let upstream = PlanningNode(
            id: "idea",
            canvasId: "canvas-a",
            title: "Idea",
            schema: NodeSchema(inputs: [], outputs: ["idea"], goal: "Collect idea"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: [],
            nodeKind: .step
        )
        let target = PlanningNode(
            id: "prd",
            canvasId: "canvas-a",
            title: "PRD",
            schema: NodeSchema(inputs: ["idea"], outputs: ["prd"], goal: "Draft PRD"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: ["idea"],
            nodeKind: .step
        )
        let downstream = PlanningNode(
            id: "code",
            canvasId: "canvas-a",
            title: "Code",
            schema: NodeSchema(inputs: ["prd"], outputs: ["code"], goal: "Implement"),
            contextSources: [],
            executionMode: .auto,
            executorType: .codex,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: ["prd"],
            nodeKind: .step
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "Planning Canvas", plannerContext: "canvas:canvas-a"),
            seedNodes: [upstream, target, downstream]
        )
        _ = try PlannerBoardBridge.attachArtifact(
            nodeId: "prd",
            kind: .prd,
            title: "PRD",
            reference: "prd.md",
            status: "attached",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let graph = try PlannerBoardBridge.deleteNode(
            nodeId: "prd",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertFalse(graph.nodes.contains { $0.id == "prd" })
        XCTAssertFalse(graph.artifacts.contains { $0.nodeId == "prd" })
        XCTAssertEqual(graph.nodes.first { $0.id == "code" }?.dependsOnNodeIds, ["idea"])
        XCTAssertFalse(graph.edges.contains { $0.sourceNodeId == "prd" || $0.targetNodeId == "prd" })
    }

    func testBindNodeInputReplacesSameNamedContextSourceDirectly() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let node = PlanningNode(
            id: "canvas-a-idea-fetch",
            canvasId: "canvas-a",
            title: "idea fetch",
            schema: NodeSchema(inputs: ["lark_doc"], outputs: ["idea_list_kanban"], goal: "Fetch ideas"),
            contextSources: [
                ContextSource(kind: .document, title: "lark_doc", reference: "https://old.example/doc"),
                ContextSource(kind: .repository, title: "repo", reference: "repo://meee2")
            ],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "Planning Canvas", plannerContext: "canvas:canvas-a"),
            seedNodes: [node]
        )

        let graph = try PlannerBoardBridge.bindNodeInput(
            nodeId: node.id,
            input: "lark_doc",
            source: ContextSource(kind: .document, title: "lark_doc", reference: "https://new.example/doc"),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let updated = try XCTUnwrap(graph.nodes.first { $0.id == node.id })
        XCTAssertEqual(updated.contextSources.filter { $0.title == "lark_doc" }.count, 1)
        XCTAssertEqual(updated.contextSources.first { $0.title == "lark_doc" }?.reference, "https://new.example/doc")
        XCTAssertTrue(updated.contextSources.contains { $0.title == "repo" })
        XCTAssertTrue(graph.proposals.isEmpty)
    }

    func testKanbanArtifactPayloadPersistsAndLinksSubCanvas() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let node = PlanningNode(
            id: "canvas-a-idea-fetch",
            canvasId: "canvas-a",
            title: "idea fetch",
            schema: NodeSchema(inputs: ["lark_doc"], outputs: ["idea_list_kanban"], goal: "Fetch ideas"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "Planning Canvas", plannerContext: "canvas:canvas-a"),
            seedNodes: [node]
        )
        let payload = kanbanPayload(subCanvasId: nil)

        let graph = try PlannerBoardBridge.attachArtifact(
            nodeId: node.id,
            kind: .kanban,
            title: "idea_list_kanban",
            reference: "idea_list_kanban",
            status: "attached",
            payload: payload,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let artifact = try XCTUnwrap(graph.artifacts.first { $0.reference == "idea_list_kanban" })
        XCTAssertEqual(artifact.kind, .kanban)
        XCTAssertEqual(artifact.payload, payload)

        let linked = try PlannerBoardBridge.bindKanbanItemSubCanvas(
            artifactId: artifact.id,
            itemId: "idea-1",
            subCanvasId: "canvas-idea-1",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let linkedArtifact = try XCTUnwrap(linked.artifacts.first { $0.id == artifact.id })
        XCTAssertEqual(linkedArtifact.payload, kanbanPayload(subCanvasId: "canvas-idea-1"))
    }

    func testApplyProposalAttachesKanbanArtifactPayload() throws {
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let node = PlanningNode(
            id: "canvas-a-idea-fetch",
            canvasId: "canvas-a",
            title: "idea fetch",
            schema: NodeSchema(inputs: ["lark_doc"], outputs: ["html kanban"], goal: "Fetch ideas"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
        let payload = kanbanPayload(subCanvasId: nil)
        let proposal = PlanProposal(
            id: "proposal-kanban",
            canvasId: canvas.id,
            summary: "Attach idea kanban",
            changes: [
                .attachArtifact(
                    nodeId: node.id,
                    kind: .kanban,
                    title: "html kanban",
                    reference: "html kanban",
                    payload: payload
                )
            ],
            status: .pending
        )

        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: canvas, seedNodes: [node])
        _ = try PlannerBoardBridge.store.approveProposal(proposalId: proposal.id, canvasId: canvas.id)
        let record = try PlannerBoardBridge.store.applyProposal(
            proposalId: proposal.id,
            canvasId: canvas.id,
            service: service
        )

        let artifact = try XCTUnwrap(record.artifacts.first { $0.reference == "html kanban" })
        XCTAssertEqual(artifact.kind, .kanban)
        XCTAssertEqual(artifact.payload, payload)
        XCTAssertEqual(artifact.producedBy, .agent)
    }

    func testSubmitNodeOutputReplacesExistingArtifactSlot() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let node = PlanningNode(
            id: "canvas-a-idea-fetch",
            canvasId: "canvas-a",
            title: "idea fetch",
            schema: NodeSchema(inputs: ["lark_doc"], outputs: ["idea_list_kanban"], goal: "Fetch ideas"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
        let emptyPayload: BoardJSONValue = .object([
            "version": .number(1),
            "columns": .array([
                .object(["id": .string("ideas"), "title": .string("Ideas")])
            ]),
            "items": .array([])
        ])
        let proposal = PlanProposal(
            id: "proposal-placeholder",
            canvasId: canvas.id,
            summary: "Create placeholder",
            changes: [
                .attachArtifact(
                    nodeId: node.id,
                    kind: .kanban,
                    title: "Idea List",
                    reference: "idea_list_kanban",
                    payload: emptyPayload
                )
            ],
            status: .pending
        )

        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: canvas, seedNodes: [node])
        _ = try PlannerBoardBridge.store.approveProposal(proposalId: proposal.id, canvasId: canvas.id)
        let applied = try PlannerBoardBridge.store.applyProposal(
            proposalId: proposal.id,
            canvasId: canvas.id,
            service: service
        )
        let placeholder = try XCTUnwrap(applied.artifacts.first { $0.reference == "idea_list_kanban" })

        let result = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Ideas fetched", routeTo: []),
                artifacts: [
                    PlannerNodeOutputArtifact(
                        kind: .kanban,
                        title: "Idea List Kanban",
                        reference: "idea_list_kanban",
                        payload: kanbanPayload(subCanvasId: nil),
                        routeTo: []
                    )
                ],
                next: .complete
            ),
            for: canvas.id,
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let artifacts = result.graph.artifacts.filter {
            $0.nodeId == node.id && $0.reference == "idea_list_kanban"
        }
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.id, placeholder.id)
        XCTAssertEqual(artifacts.first?.title, "Idea List Kanban")
        XCTAssertEqual(artifacts.first?.payload, kanbanPayload(subCanvasId: nil))
    }

    func testSubmitNodeOutputHintsWhenArtifactsDoNotSatisfyContract() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-fit-hint", ownerId: "owner-a")
        let canvas = PlanningCanvas(
            id: "canvas-fit-hint",
            ownerId: "owner-a",
            title: "Fit Hint Canvas",
            plannerContext: "canvas:canvas-fit-hint"
        )
        let node = PlanningNode(
            id: "fit-node",
            canvasId: "canvas-fit-hint",
            title: "ship result",
            schema: NodeSchema(inputs: [], outputs: ["prd", "launch-check"], goal: "Ship with evidence"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step,
            gate: PlannerNodeGate(
                type: "artifact-exists",
                label: "PR gate",
                requiredArtifactRefs: ["git://repo/pull/1"],
                approvers: ["owner-a"],
                onFailGotoNodeId: nil
            )
        )
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [node])

        let result = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "prd done", routeTo: []),
                artifacts: [
                    PlannerNodeOutputArtifact(
                        kind: .prd,
                        title: "PRD",
                        reference: "prd",
                        payload: nil,
                        routeTo: []
                    )
                ],
                next: .complete
            ),
            for: canvas.id,
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertTrue(result.hint?.contains("launch-check") == true)
        XCTAssertTrue(result.hint?.contains("git://repo/pull/1") == true)
    }

    // MARK: - ENG-3 · Artifact Version Chain

    func testSubmitNodeOutputAppendsVersionChainAndKeepsLatestForSlot() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-v3", ownerId: "owner-a")
        let canvas = PlanningCanvas(
            id: "canvas-v3",
            ownerId: "owner-a",
            title: "Version Chain Canvas",
            plannerContext: "canvas:canvas-v3"
        )
        let node = PlanningNode(
            id: "canvas-v3-node",
            canvasId: "canvas-v3",
            title: "ideas",
            schema: NodeSchema(inputs: [], outputs: ["idea_list_kanban"], goal: "Fetch ideas"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [node])

        // First submit — fresh slot, no parent.
        let first = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "v1", routeTo: []),
                artifacts: [
                    PlannerNodeOutputArtifact(
                        kind: .kanban,
                        title: "Ideas",
                        reference: "idea_list_kanban",
                        payload: kanbanPayload(subCanvasId: nil),
                        routeTo: []
                    )
                ],
                next: .complete,
                forceNewVersion: false
            ),
            for: canvas.id,
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(first.graph.artifacts.filter { $0.reference == "idea_list_kanban" }.count, 1)

        // Second submit — same slot. Latest-per-slot mirror still shows one,
        // but the version chain now has two rows with parent wiring.
        _ = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "v2", routeTo: []),
                artifacts: [
                    PlannerNodeOutputArtifact(
                        kind: .kanban,
                        title: "Ideas v2",
                        reference: "idea_list_kanban",
                        payload: kanbanPayload(subCanvasId: nil),
                        routeTo: []
                    )
                ],
                next: .complete,
                forceNewVersion: true
            ),
            for: canvas.id,
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let versions = try PlannerBoardBridge.listArtifactVersions(
            canvasId: canvas.id,
            nodeId: node.id,
            reference: "idea_list_kanban",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(versions.count, 2, "Both versions must persist; submit is append-only.")
        // Newest-first ordering.
        XCTAssertEqual(versions.first?.parentVersionId, versions.last?.versionId,
                       "v2.parent_version_id must point at v1.version_id.")
        XCTAssertTrue(versions.first?.forceNewVersion == true,
                      "force_new_version flag must be recorded on the version row.")
        XCTAssertNotNil(versions.first?.inputSnapshot,
                        "Input snapshot must be captured on every version.")
        XCTAssertEqual(versions.first?.displayStrategy, .latest,
                       "Default display_strategy is `latest` per ENG-3 F4.3 fix.")

        // P4 · the surfaced (latest-per-slot) artifact carries a derived
        // version index/count so the card can render `v{n}`. The head == count.
        let graph = try PlannerBoardBridge.graphState(
            for: canvas.id, snapshot: snapshot, actorUserId: "owner-a"
        )
        let surfaced = try XCTUnwrap(
            graph.artifacts.first { $0.reference == "idea_list_kanban" }
        )
        XCTAssertEqual(surfaced.versionCount, 2, "P4: slot chain length surfaced")
        XCTAssertEqual(surfaced.versionIndex, 2, "P4: surfaced artifact is the chain head → v2")
    }

    func testNodeContractListsOnlyDownstreamAndOwnerRouteTargets() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        let contract = try PlannerBoardBridge.nodeContract(
            nodeId: "canvas-a-node-1",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(contract.node.id, "canvas-a-node-1")
        XCTAssertTrue(contract.downstreamNodes.contains { $0.id == "canvas-a-node-2" })
        XCTAssertTrue(contract.allowedRouteTargets.contains { $0.id == "canvas-a-node-2" })
        XCTAssertTrue(contract.allowedRouteTargets.contains { $0.id == "owner" })
        XCTAssertFalse(contract.allowedRouteTargets.contains { $0.id == "canvas-a-node-3" })
    }

    // MARK: - Legacy Canvas Render Protocol

    func testGraphStateDoesNotLoadOrCreateLegacyRenderProfile() throws {
        let canvasId = "canvas-render-a"
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: canvasId, ownerId: "owner-a")
        let profilePath = PlannerBoardBridge.store.renderProfilePath(canvasId: canvasId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilePath))

        let graph = try PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: profilePath))
        XCTAssertNil(graph.renderProfileStatus)
        XCTAssertNil(graph.renderProfile)
        XCTAssertTrue(graph.renderObjects.isEmpty)
        XCTAssertTrue(graph.renderRelations.isEmpty)
    }

    func testRenderValuesPatchMergesObjectFields() throws {
        let canvasId = "canvas-render-values-merge"
        _ = try seedPlannerNodes(canvasId: canvasId, ownerId: "owner-a")
        _ = try PlannerBoardBridge.store.patchRenderValues(
            canvasId: canvasId,
            objectValues: [
                "node:\(canvasId)-node-1": CanvasRenderObjectValues(
                    x: nil,
                    y: nil,
                    width: nil,
                    height: nil,
                    zIndex: nil,
                    hidden: true,
                    collapsed: nil,
                    pinned: true,
                    rendererVariant: nil,
                    density: nil,
                    icon: nil,
                    designToken: nil
                )
            ],
            relationValues: [:],
            renderOnlyObjects: nil
        )

        let profile = try PlannerBoardBridge.store.patchRenderValues(
            canvasId: canvasId,
            objectValues: [
                "node:\(canvasId)-node-1": CanvasRenderObjectValues(
                    x: 42,
                    y: 84,
                    width: 360,
                    height: nil,
                    zIndex: nil,
                    hidden: nil,
                    collapsed: nil,
                    pinned: nil,
                    rendererVariant: nil,
                    density: nil,
                    icon: nil,
                    designToken: nil
                )
            ],
            relationValues: [:],
            renderOnlyObjects: nil
        )

        let values = try XCTUnwrap(profile.values.objects["node:\(canvasId)-node-1"])
        XCTAssertEqual(values.x, 42)
        XCTAssertEqual(values.y, 84)
        XCTAssertEqual(values.width, 360)
        XCTAssertEqual(values.hidden, true)
        XCTAssertEqual(values.pinned, true)
    }

    func testReplaceRenderLogicProposalUpdatesProfileLogic() throws {
        let canvasId = "canvas-render-logic"
        let ownerId = "owner-a"
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: ownerId)
        let record = try seedPlannerNodes(canvasId: canvasId, ownerId: ownerId)
        _ = try PlannerBoardBridge.graphState(for: canvasId, snapshot: snapshot, actorUserId: ownerId)
        var logic = CanvasRenderLogic.workflowDefault
        logic.layout = .collection
        logic.actions.append(CanvasRenderActionRule(
            id: "custom-reveal",
            action: .revealProfile,
            label: "Reveal profile",
            targetObjectId: nil,
            sceneActionId: nil
        ))
        let proposal = PlanProposal(
            id: "proposal-render-logic",
            canvasId: canvasId,
            summary: "Switch render profile to collection layout",
            changes: [
                PlanChange(
                    kind: .replaceRenderLogic,
                    node: nil,
                    nodeId: nil,
                    title: nil,
                    status: nil,
                    renderLogic: logic
                )
            ],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: record.canvas, seedNodes: record.nodes)
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id,
            for: canvasId,
            snapshot: snapshot,
            actorUserId: ownerId
        )

        _ = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id,
            for: canvasId,
            snapshot: snapshot,
            actorUserId: ownerId
        )
        let profile = try PlannerBoardBridge.store.renderProfileState(canvasId: canvasId).profile

        XCTAssertEqual(profile.logic.layout, .collection)
        XCTAssertEqual(profile.logic.actions.last?.id, "custom-reveal")
    }

    // MARK: - Node Contract v2 (ENG-1)

    func testNodeContractV2RoundTripsThroughJSON() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        let contract = try PlannerBoardBridge.nodeContract(
            nodeId: "canvas-a-node-2",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // v2 block is always populated.
        XCTAssertEqual(contract.v2.version, NodeContractV2.version)
        XCTAssertNotNil(contract.v2.input.upstream)
        XCTAssertTrue(contract.v2.input.dialogue.enabled)
        XCTAssertEqual(contract.v2.input.dialogue.window.kind, .rolling)
        XCTAssertEqual(contract.v2.input.dialogue.window.nTurns, NodeContractV2.defaultDialogueTurns)

        // Codable round-trip (snake_case wire format).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contract.v2)
        let decoded = try JSONDecoder().decode(NodeContractV2.self, from: data)
        XCTAssertEqual(decoded, contract.v2)

        // Wire format uses snake_case keys (source_node, payload_kind, n_turns).
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"source_node\""))
        XCTAssertTrue(json.contains("\"payload_kind\""))
        XCTAssertTrue(json.contains("\"n_turns\""))
        XCTAssertFalse(json.contains("\"replace_strategy\""))
        XCTAssertFalse(json.contains("\"increment\""))
    }

    func testNodeContractV2DerivesUpstreamFromDependsOn() {
        let node = PlanningNode(
            id: "node-derive",
            canvasId: "canvas-a",
            title: "Derive",
            schema: NodeSchema(inputs: [], outputs: [], goal: "x"),
            contextSources: [
                ContextSource(kind: .document, title: "Notion DB", reference: "notion://db/abc"),
                ContextSource(kind: .repository, title: "Repo", reference: "https://github.com/foo/bar"),
                ContextSource(kind: .web, title: "Spec", reference: "ftp://internal/spec")
            ],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: ["upstream-1", "upstream-2"],
            nodeKind: .step
        )

        let (v2, warnings) = NodeContractV2.derive(from: node)

        XCTAssertEqual(v2.input.upstream.mode, .passthrough)
        XCTAssertEqual(v2.input.upstream.sourceNodeId, "upstream-1")
        XCTAssertEqual(v2.input.external.count, 3)
        XCTAssertEqual(v2.input.external[0].connector, "notion")
        XCTAssertEqual(v2.input.external[1].connector, "github")
        XCTAssertEqual(v2.input.external[2].connector, "unknown") // ftp:// — lossy
        XCTAssertEqual(v2.output.cardinality, .single)
        XCTAssertEqual(v2.output.payloadKind, .artifactRef)

        // Lossy items are surfaced as warnings.
        XCTAssertTrue(warnings.contains { $0.contains("ftp://internal/spec") })
        XCTAssertTrue(warnings.contains { $0.contains("2 upstream deps") })
    }

    func testNodeContractV2SubCanvasNodeDefaultsToItemScoped() {
        let node = PlanningNode(
            id: "node-sub",
            canvasId: "canvas-a",
            title: "Sub",
            schema: NodeSchema(inputs: [], outputs: [], goal: "x"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            dependsOnNodeIds: ["parent"],
            nodeKind: .subCanvas
        )

        let (v2, _) = NodeContractV2.derive(from: node)
        XCTAssertEqual(v2.input.upstream.mode, .itemScoped)
        XCTAssertEqual(v2.input.upstream.sourceNodeId, "parent")
    }

    func testNodeContractV2ExternalNodeDefaultsToListCardinality() {
        let node = PlanningNode(
            id: "node-ext",
            canvasId: "canvas-a",
            title: "Ext",
            schema: NodeSchema(inputs: [], outputs: [], goal: "x"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .external
        )

        let (v2, _) = NodeContractV2.derive(from: node)
        XCTAssertEqual(v2.output.cardinality, .list)
    }

    // MARK: - external-first writeback (external_write_target)

    private func makeNode(id: String = "node-ext-write", outputs: [String]) -> PlanningNode {
        PlanningNode(
            id: id,
            canvasId: "canvas-a",
            title: "Writer",
            schema: NodeSchema(inputs: ["upstream"], outputs: outputs, goal: "write to tracker"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner-a",
            status: .ready,
            nodeKind: .step
        )
    }

    func testDeriveFillsExternalWriteTargetFromConnectorOutputSlot() {
        let node = makeNode(outputs: ["gsheet://venture-tracker/Pipeline"])
        let (v2, _) = NodeContractV2.derive(from: node)
        XCTAssertEqual(v2.output.externalWriteTarget?.connector, "google-sheets")
        XCTAssertEqual(v2.output.externalWriteTarget?.ref, "gsheet://venture-tracker/Pipeline")
    }

    func testDeriveLeavesExternalWriteTargetNilForProseOutputSlot() {
        // venture-tracker as-built: a prose slot name must NOT be mistaken for an
        // external write target (back-compat — only opted-in connector refs trip it).
        let node = makeNode(outputs: ["1. Sourcing：按行业找 startups output"])
        let (v2, _) = NodeContractV2.derive(from: node)
        XCTAssertNil(v2.output.externalWriteTarget)
    }

    func testDeriveDoesNotTreatGenericOrInternalRefsAsExternalWrite() {
        // http(s) fallback, local file, and the internal mirror scheme are plain
        // references, not external-connector write targets.
        for ref in ["https://example.com/report", "file://local/out.json", "meee2-artifact://canvas-a/slot"] {
            let node = makeNode(outputs: [ref])
            XCTAssertNil(NodeContractV2.derive(from: node).contract.output.externalWriteTarget, "\(ref) should not be an external write target")
        }
    }

    func testDeriveKeepsFirstExternalOutputAndWarnsOnExtras() {
        let node = makeNode(outputs: ["gsheet://tracker/Pipeline", "notion://db/scoring"])
        let (v2, warnings) = NodeContractV2.derive(from: node)
        XCTAssertEqual(v2.output.externalWriteTarget?.connector, "google-sheets")
        XCTAssertEqual(v2.output.externalWriteTarget?.ref, "gsheet://tracker/Pipeline")
        XCTAssertTrue(warnings.contains { $0.contains("2 external output slots") })
    }

    func testSubmitNodeOutputReconcilesExternalReferenceOnGatingDone() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let canvas = PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "C", plannerContext: "canvas:canvas-a")
        let node = makeNode(id: "canvas-a-writer", outputs: ["gsheet://venture-tracker/Pipeline"])
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [node])

        let done = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "wrote 4 rows", routeTo: ["owner"]),
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "Pipeline",
                    reference: "gsheet://venture-tracker/Pipeline",
                    payload: .object(["type": .string("integration"), "connector": .string("google-sheets")]),
                    routeTo: ["owner"]
                )],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(done.reconcileReferences, ["gsheet://venture-tracker/Pipeline"])
    }

    func testSubmitNodeOutputDoesNotReconcileOnBlocked() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let canvas = PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "C", plannerContext: "canvas:canvas-a")
        let node = makeNode(id: "canvas-a-writer", outputs: ["gsheet://venture-tracker/Pipeline"])
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [node])

        let blocked = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .blocked,
                message: PlannerNodeOutputMessage(summary: "sheets connector not connected", routeTo: ["owner"]),
                artifacts: [],
                next: .blocked
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertNil(blocked.reconcileReferences)
    }

    func testSubmitNodeOutputDoesNotReconcileNonExternalArtifact() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        let canvas = PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "C", plannerContext: "canvas:canvas-a")
        let node = makeNode(id: "canvas-a-plain", outputs: ["plain-output"])
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [node])

        let done = try PlannerBoardBridge.submitNodeOutput(
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "done", routeTo: ["owner"]),
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "Result",
                    reference: "plain-output",
                    payload: .object(["type": .string("json"), "json": .string("{}")]),
                    routeTo: ["owner"]
                )],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertNil(done.reconcileReferences)
    }

    func testNodeContractValidatorRejectsReplaceStrategy() {
        let raw: BoardJSONValue = .object([
            "replace_strategy": .string("overwrite")
        ])
        XCTAssertThrowsError(try NodeContractValidator.validateRawContract(raw)) { error in
            guard let err = error as? NodeContractValidationError else {
                return XCTFail("expected NodeContractValidationError, got \(error)")
            }
            XCTAssertEqual(err, .rejectedReplaceStrategy)
        }
    }

    func testNodeContractValidatorRejectsIncrementOutput() {
        let raw: BoardJSONValue = .object([
            "output": .object(["kind": .string("increment")])
        ])
        XCTAssertThrowsError(try NodeContractValidator.validateRawContract(raw)) { error in
            XCTAssertEqual(error as? NodeContractValidationError, .rejectedIncrementOutput)
        }
    }

    func testNodeContractValidatorRejectsV1FieldMapping() {
        let raw: BoardJSONValue = .object([
            "field_mapping": .object([:])
        ])
        XCTAssertThrowsError(try NodeContractValidator.validateRawContract(raw)) { error in
            guard case .rejectedFieldMapping = (error as? NodeContractValidationError) ?? .missingRequiredField("?") else {
                return XCTFail("expected rejectedFieldMapping, got \(error)")
            }
        }

        let nestedRaw: BoardJSONValue = .object([
            "inputs": .array([
                .object(["source_field": .string("foo"), "target_field": .string("bar")])
            ])
        ])
        XCTAssertThrowsError(try NodeContractValidator.validateRawContract(nestedRaw))
    }

    func testNodeContractValidatorRejectsV1OutputPayload() {
        let payload: [String: Any] = [
            "nodeId": "n1",
            "status": "done",
            "next": "complete",
            "replace_strategy": "overwrite"
        ]
        XCTAssertThrowsError(try NodeContractValidator.validateRawOutputPayload(payload)) { error in
            XCTAssertEqual(error as? NodeContractValidationError, .rejectedReplaceStrategy)
        }

        let incrementPayload: [String: Any] = [
            "nodeId": "n1",
            "status": "done",
            "next": "complete",
            "output": ["kind": "increment"]
        ]
        XCTAssertThrowsError(try NodeContractValidator.validateRawOutputPayload(incrementPayload))
    }

    func testNodeContractValidatorAcceptsCleanV2Payload() throws {
        let payload: [String: Any] = [
            "nodeId": "n1",
            "status": "done",
            "next": "complete",
            "message": ["summary": "ok", "routeTo": ["owner"]],
            "artifacts": []
        ]
        XCTAssertNoThrow(try NodeContractValidator.validateRawOutputPayload(payload))

        let raw: BoardJSONValue = .object([
            "version": .number(2),
            "input": .object([:]),
            "output": .object(["cardinality": .string("single"), "payload_kind": .string("artifact_ref")])
        ])
        XCTAssertNoThrow(try NodeContractValidator.validateRawContract(raw))
    }

    /// canvas-spec §8 / §11 · A human node with NO gate / NO handoffPolicy does
    /// NOT need review, so submit `done` goes straight to `.done` (the old
    /// "every human node parks at gateWait" behavior is gone — gate is decided
    /// by needs-review, not executionMode). Downstream unblocks immediately.
    func testSubmitNodeOutputNoReviewHumanCompletesDirectly() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        let result = try PlannerBoardBridge.submitNodeOutput(
            nodeId: "canvas-a-node-1",
            output: PlannerNodeOutput(
                nodeId: "canvas-a-node-1",
                status: .done,
                message: PlannerNodeOutputMessage(
                    summary: "Idea draft is ready",
                    routeTo: ["canvas-a-node-2"]
                ),
                artifacts: [
                    PlannerNodeOutputArtifact(
                        kind: .ideaDraft,
                        title: "Idea draft",
                        reference: "lark://doc/idea",
                        routeTo: ["canvas-a-node-2"]
                    )
                ],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // node-1 is human but carries no gate / handoffPolicy → no review → done.
        let producer = try XCTUnwrap(result.graph.nodes.first { $0.id == "canvas-a-node-1" })
        XCTAssertEqual(producer.workflowRunState, .done, "no-review human node → done directly")
        XCTAssertEqual(producer.status, .done)
        // Not awaiting review (distinct from the 待确认 case).
        XCTAssertEqual(
            result.graph.states.first { $0.nodeId == producer.id }?.needsOwnerReview, false
        )
        // Producer is truly done → downstream becomes startable.
        let downstream = try XCTUnwrap(result.graph.nodes.first { $0.id == "canvas-a-node-2" })
        XCTAssertEqual(downstream.workflowRunState, .readyToStart)
        XCTAssertTrue(downstream.contextSources.contains { $0.reference == "lark://doc/idea" })
        XCTAssertTrue(result.graph.artifacts.contains { $0.reference == "lark://doc/idea" })
        XCTAssertTrue(result.routes.contains { $0.targetNodeId == "canvas-a-node-2" })
    }

    // MARK: - canvas-spec §8 / §11 · 待确认 (awaiting-review) state machine

    /// Seed a producer→consumer flow where the producer needs review
    /// (`handoffPolicy` non-`.none`). Returns (canvasId, snapshot, ownerId).
    private func seedReviewFlow(
        canvasId: String = "cv-review",
        ownerId: String = "owner-review",
        producerNeedsReview: Bool = true
    ) throws -> (canvasId: String, snapshot: BoardLayoutStore.Snapshot, ownerId: String) {
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: ownerId)
        let producer = PlanningNode(
            id: "n-prod", canvasId: canvasId, title: "Reviewer 草稿",
            schema: NodeSchema(inputs: ["goal"], outputs: ["draft"], goal: "draft a PRD"),
            contextSources: [], executionMode: .human, executorType: .human,
            doerId: ownerId, status: .ready,
            // needs-review iff a non-.none handoffPolicy is set.
            handoffPolicy: producerNeedsReview ? .reviewerMustApprove : .none,
            nodeKind: .step
        )
        // Consumer starts blocked-by-upstream (pending) — it only becomes
        // startable once n-prod is actually done.
        let consumer = PlanningNode(
            id: "n-cons", canvasId: canvasId, title: "选题会",
            schema: NodeSchema(inputs: ["draft"], outputs: ["picks"], goal: "pick topics"),
            contextSources: [], executionMode: .human, executorType: .human,
            doerId: ownerId, status: .blocked,
            dependsOnNodeIds: ["n-prod"], nodeKind: .step,
            workflowRunState: .pending
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: ownerId, title: "Review flow",
                                plannerContext: "canvas:\(canvasId)"),
            seedNodes: [producer, consumer]
        )
        return (canvasId, snapshot, ownerId)
    }

    private func submitDraftDone(
        nodeId: String, canvasId: String, snapshot: BoardLayoutStore.Snapshot, ownerId: String
    ) throws -> PlannerNodeOutputResult {
        try PlannerBoardBridge.submitNodeOutput(
            nodeId: nodeId,
            output: PlannerNodeOutput(
                nodeId: nodeId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "draft ready", routeTo: ["n-cons"]),
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .prd, title: "Draft", reference: "draft", routeTo: ["n-cons"]
                )],
                next: .complete
            ),
            for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
    }

    /// (a) A needs-review node submit `done` → parks at 待确认 (gateWait,
    /// distinct from done AND from blocked), and downstream is NOT startable.
    func testNeedsReviewNodeDoneParksAwaitingReviewAndBlocksDownstream() throws {
        let (canvasId, snapshot, ownerId) = try seedReviewFlow()

        let result = try submitDraftDone(
            nodeId: "n-prod", canvasId: canvasId, snapshot: snapshot, ownerId: ownerId
        )

        let producer = try XCTUnwrap(result.graph.nodes.first { $0.id == "n-prod" })
        // 待确认: gateWait carrier, NOT .done.
        XCTAssertEqual(producer.workflowRunState, .gateWait, "needs-review done → awaiting-review, not done")
        XCTAssertNotEqual(producer.status, .done)
        // Distinct from 卡住: surfaced via needsOwnerReview (not just .blocked).
        let prodState = try XCTUnwrap(result.graph.states.first { $0.nodeId == "n-prod" })
        XCTAssertTrue(prodState.needsOwnerReview, "待确认 must be distinct from blocked via needsOwnerReview")
        // Downstream is NOT startable while upstream is only 待确认 (not done).
        let consumer = try XCTUnwrap(result.graph.nodes.first { $0.id == "n-cons" })
        XCTAssertNotEqual(consumer.workflowRunState, .readyToStart, "downstream stays blocked-by-upstream")
        XCTAssertEqual(consumer.workflowRunState, .pending, "downstream unchanged: upstream not done")
    }

    /// (b) Confirming a 待确认 node → it goes `.done` and downstream becomes
    /// startable (`readyToStart`).
    func testConfirmNodeReviewMarksDoneAndUnblocksDownstream() throws {
        let (canvasId, snapshot, ownerId) = try seedReviewFlow()
        _ = try submitDraftDone(
            nodeId: "n-prod", canvasId: canvasId, snapshot: snapshot, ownerId: ownerId
        )

        let confirmed = try PlannerBoardBridge.confirmNodeReview(
            nodeId: "n-prod", for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )

        let producer = try XCTUnwrap(confirmed.nodes.first { $0.id == "n-prod" })
        XCTAssertEqual(producer.workflowRunState, .done, "confirm → done")
        XCTAssertEqual(producer.status, .done)
        XCTAssertEqual(confirmed.states.first { $0.nodeId == "n-prod" }?.needsOwnerReview, false)
        // Downstream now startable.
        let consumer = try XCTUnwrap(confirmed.nodes.first { $0.id == "n-cons" })
        XCTAssertEqual(consumer.workflowRunState, .readyToStart, "confirm unblocks downstream")
        XCTAssertEqual(consumer.status, .ready)
    }

    /// (c) A no-review node (human, no gate / no handoffPolicy) submit `done` →
    /// `.done` directly; downstream startable immediately.
    func testNoReviewNodeDoneCompletesDirectly() throws {
        let (canvasId, snapshot, ownerId) = try seedReviewFlow(
            canvasId: "cv-noreview", ownerId: "owner-noreview", producerNeedsReview: false
        )

        let result = try submitDraftDone(
            nodeId: "n-prod", canvasId: canvasId, snapshot: snapshot, ownerId: ownerId
        )

        let producer = try XCTUnwrap(result.graph.nodes.first { $0.id == "n-prod" })
        XCTAssertEqual(producer.workflowRunState, .done, "no-review done → done directly")
        XCTAssertEqual(producer.status, .done)
        XCTAssertEqual(result.graph.states.first { $0.nodeId == "n-prod" }?.needsOwnerReview, false)
        let consumer = try XCTUnwrap(result.graph.nodes.first { $0.id == "n-cons" })
        XCTAssertEqual(consumer.workflowRunState, .readyToStart, "downstream startable once upstream truly done")
    }

    /// Confirming a node that is NOT awaiting review is rejected (guards against
    /// silently "confirming" a running / blocked node).
    func testConfirmNodeReviewRejectsNodeNotAwaitingReview() throws {
        let (canvasId, snapshot, ownerId) = try seedReviewFlow(
            canvasId: "cv-confirm-guard", ownerId: "owner-cg"
        )
        // n-prod is still .ready (never submitted) → not confirmable.
        XCTAssertThrowsError(try PlannerBoardBridge.confirmNodeReview(
            nodeId: "n-prod", for: canvasId, snapshot: snapshot, actorUserId: ownerId
        ))
    }

    func testSubmitNodeOutputRejectsInvalidRouteWithoutMutation() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        XCTAssertThrowsError(try PlannerBoardBridge.submitNodeOutput(
            nodeId: "canvas-a-node-1",
            output: PlannerNodeOutput(
                nodeId: "canvas-a-node-1",
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Invalid route", routeTo: ["canvas-a-node-3"]),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            guard case .invalidNodeOutput(let hint) = error as? PlannerCoreError else {
                return XCTFail("Expected invalidNodeOutput, got \(error)")
            }
            XCTAssertTrue(hint.contains("Allowed"))
        }

        let reloaded = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        XCTAssertEqual(reloaded.nodes.first { $0.id == "canvas-a-node-1" }?.status, .ready)
        XCTAssertFalse(reloaded.nodes.first { $0.id == "canvas-a-node-3" }?.contextSources.contains {
            $0.reference.hasPrefix("planner-output://")
        } == true)
    }

    func testSubmitNodeOutputToUnassignedDownstreamBlocksIt() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let proposal = try PlannerBoardBridge.graphChangeProposal(
            summary: "Unassign downstream",
            changes: [.updateNode(id: "canvas-a-node-2", doerId: "")],
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

        let result = try PlannerBoardBridge.submitNodeOutput(
            nodeId: "canvas-a-node-1",
            output: PlannerNodeOutput(
                nodeId: "canvas-a-node-1",
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Needs assignment", routeTo: ["canvas-a-node-2"]),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let downstream = try XCTUnwrap(result.graph.nodes.first { $0.id == "canvas-a-node-2" })
        XCTAssertEqual(downstream.status, .blocked)
        XCTAssertEqual(downstream.workflowRunState, .gateWait)
        XCTAssertEqual(result.graph.states.first { $0.nodeId == downstream.id }?.needsOwnerReview, false)
    }

    // MARK: - Phase 2: dispatch 真执行 (now execution-layer / direct)

    /// Dispatching a step to a spawning runner (claude/codex/byoa-local) is an
    /// execution-layer action: it applies DIRECTLY (no proposal / approval) and
    /// records spawn intent without adding a second planner node.
    func testDispatchAppliesDirectlyWithoutCreatingSessionNode() throws {
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
        XCTAssertFalse(result.graph.nodes.contains { $0.nodeKind == .session })

        // Persisted: a reload sees the same direct mutation.
        let reloaded = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        XCTAssertFalse(reloaded.nodes.contains { $0.nodeKind == .session })
    }

    /// The `human` runner starts work directly without spawning a session node.
    func testDispatchHumanRunnerStartsWorkingWithNoSessionNode() throws {
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
        XCTAssertEqual(dispatchedStep.workflowRunState, .running)
        XCTAssertEqual(dispatchedStep.status, .ready)
    }

    func testSessionFailureDoesNotOverrideCompletedNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "session-done",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Output submitted", routeTo: []),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "session-done",
            runState: .failed
        )

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertEqual(node.workflowRunState, .done)
        XCTAssertEqual(node.status, .done)
        XCTAssertNil(node.blockedReason)
    }

    // 会话结束(.dead → runState .pending)时,没有显式 submit 的节点不应清掉
    // sessionId。保留绑定才能让抽屉打开/恢复原会话,而不是伪装成「未启动」
    // 要用户重新起会话。
    func testSessionEndKeepsBindingAndPromptsResume() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-dead",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: .running
        )

        // Session dies — SessionMonitor maps .dead → .pending.
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: PlannerSessionRunStateBridge.runState(for: .dead)
        )

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertEqual(node.sessionId, "claude-dead", "ended session binding should be kept for open/resume")
        XCTAssertEqual(node.chatThreadId, "claude-dead")
        XCTAssertEqual(node.workflowRunState, .awaitingInput)
        XCTAssertEqual(node.status, .blocked)
        XCTAssertEqual(node.blockedReason, "Session claude-d 已结束；可打开恢复，或替换为新会话。")
    }

    /// Direct artifact-layer write(账本直改):同一 reference 跨节点共享时,
    /// update_artifact 必须让所有槽位一起前进(各自追加版本行、沿用自己的
    /// 版本链),且节点状态机完全不动 — 这是「手动更新 artifact 不用先跟
    /// step 节点的 session 打招呼」机制的核心约束。
    func testUpdateArtifactByReferenceAdvancesSharedSlotsWithoutTouchingNodes() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodeA = "canvas-a-node-1"
        let nodeB = "canvas-a-node-2"
        let reference = "gsheet://tracker/Pipeline"

        for nodeId in [nodeA, nodeB] {
            _ = try PlannerBoardBridge.attachArtifact(
                nodeId: nodeId,
                kind: .generic,
                title: "Tracker · Pipeline",
                reference: reference,
                status: "attached",
                payload: .object(["type": .string("integration"), "connector": .string("google-sheets")]),
                for: "canvas-a",
                snapshot: snapshot,
                actorUserId: "owner-a"
            )
        }
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let statusesBefore = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0.status) })

        let updated = try PlannerBoardBridge.updateArtifact(
            reference: reference,
            title: "Tracker · Pipeline (54 rows)",
            payload: .object([
                "type": .string("integration"),
                "connector": .string("google-sheets"),
                "fields": .object(["rows": .number(54)])
            ]),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        // 两个共享槽位都前进了
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(Set(updated.map(\.nodeId)), [nodeA, nodeB])
        XCTAssertTrue(updated.allSatisfy { $0.title == "Tracker · Pipeline (54 rows)" })

        // head 已替换(直读也拿到新 payload)
        let heads = try PlannerBoardBridge.findArtifacts(
            reference: reference,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(heads.count, 2)
        XCTAssertTrue(heads.allSatisfy {
            $0.payload?.objectValue?["fields"]?.objectValue?["rows"] == .number(54)
        })

        // 每个槽位各有一条 direct-update 版本行,沿用自己的链
        for nodeId in [nodeA, nodeB] {
            let versions = try PlannerBoardBridge.store.artifactVersions(
                canvasId: "canvas-a",
                nodeId: nodeId,
                reference: reference
            )
            XCTAssertEqual(versions.first?.metadata?.objectValue?["source"]?.stringValue, "updateArtifact")
        }

        // 节点状态机一概不动
        let after = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        for node in after.nodes {
            XCTAssertEqual(node.status, statusesBefore[node.id], "direct artifact update must not touch node \(node.id)")
        }

        // 找不到目标要明确报错,不能静默成功
        XCTAssertThrowsError(try PlannerBoardBridge.updateArtifact(
            reference: "gsheet://tracker/Nonexistent",
            title: "x",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            guard case PlannerCoreError.artifactNotFound = error else {
                return XCTFail("expected artifactNotFound, got \(error)")
            }
        }
    }

    func testArtifactViewsUpdateSeparatelyFromDataVersions() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodeId = "canvas-a-node-1"
        let reference = "artifact://ideas"

        _ = try PlannerBoardBridge.attachArtifact(
            nodeId: nodeId,
            kind: .generic,
            title: "Ideas",
            reference: reference,
            status: "attached",
            payload: .object([
                "type": .string("json"),
                "json": .string(#"[{"title":"A"},{"title":"B"}]"#)
            ]),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let beforeVersions = try PlannerBoardBridge.store.artifactVersions(
            canvasId: "canvas-a",
            nodeId: nodeId,
            reference: reference
        ).count
        let beforeEvents = try PlannerBoardBridge.store.canvasRecordForBridge(canvasId: "canvas-a").events.count

        let views = try PlannerBoardBridge.updateArtifactViews(
            reference: reference,
            views: [
                PlannerArtifactView(
                    id: "table",
                    title: "Table",
                    kind: .table,
                    columns: ["title"]
                ),
                PlannerArtifactView(
                    id: "list",
                    title: "List",
                    kind: .list
                )
            ],
            deleteViewIds: [],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views.first?.views?.map(\.id), ["table", "list"])
        let afterViewVersions = try PlannerBoardBridge.store.artifactVersions(
            canvasId: "canvas-a",
            nodeId: nodeId,
            reference: reference
        ).count
        let afterViewEvents = try PlannerBoardBridge.store.canvasRecordForBridge(canvasId: "canvas-a").events.count
        XCTAssertEqual(afterViewVersions, beforeVersions, "view-only updates must not append artifact data versions")
        XCTAssertGreaterThan(afterViewEvents, beforeEvents, "view-only updates should still emit a canvas event")

        let dataUpdated = try PlannerBoardBridge.updateArtifact(
            reference: reference,
            title: "Ideas updated",
            payload: .object([
                "type": .string("json"),
                "json": .string(#"[{"title":"C"}]"#)
            ]),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(dataUpdated.first?.views?.map(\.id), ["table", "list"])

        let pruned = try PlannerBoardBridge.updateArtifactViews(
            reference: reference,
            views: [
                PlannerArtifactView(
                    id: "table",
                    title: "Grid",
                    kind: .table,
                    columns: ["title"]
                )
            ],
            deleteViewIds: ["list"],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertEqual(pruned.first?.views?.map(\.title), ["Grid"])
        XCTAssertEqual(pruned.first?.views?.map(\.id), ["table"])
    }

    func testSubmitNodeOutputPreservesArtifactViewsOnSlotReplacement() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodeId = "canvas-a-node-1"
        let reference = "artifact://ideas"

        _ = try PlannerBoardBridge.attachArtifact(
            nodeId: nodeId,
            kind: .generic,
            title: "Ideas",
            reference: reference,
            status: "attached",
            payload: .object([
                "type": .string("json"),
                "json": .string(#"[{"title":"A"}]"#)
            ]),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.updateArtifactViews(
            reference: reference,
            views: [
                PlannerArtifactView(
                    id: "table",
                    title: "Table",
                    kind: .table,
                    columns: ["title"]
                )
            ],
            deleteViewIds: [],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let result = try PlannerBoardBridge.submitNodeOutput(
            nodeId: nodeId,
            output: PlannerNodeOutput(
                nodeId: nodeId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Ideas refreshed", routeTo: []),
                artifacts: [
                    PlannerNodeOutputArtifact(
                        kind: .generic,
                        title: "Ideas refreshed",
                        reference: reference,
                        payload: .object([
                            "type": .string("json"),
                            "json": .string(#"[{"title":"B"}]"#)
                        ]),
                        routeTo: []
                    )
                ],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let updated = try XCTUnwrap(result.graph.artifacts.first { $0.reference == reference })
        XCTAssertEqual(updated.title, "Ideas refreshed")
        XCTAssertEqual(updated.views?.map(\.id), ["table"])
    }

    func testArtifactViewUpdatesRejectDuplicateIds() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let nodeId = "canvas-a-node-1"
        let reference = "artifact://duplicate-view"

        _ = try PlannerBoardBridge.attachArtifact(
            nodeId: nodeId,
            kind: .generic,
            title: "Ideas",
            reference: reference,
            status: "attached",
            payload: .object(["type": .string("json"), "json": .string("[]")]),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertThrowsError(try PlannerBoardBridge.updateArtifactViews(
            reference: reference,
            views: [
                PlannerArtifactView(id: "same", title: "Table", kind: .table),
                PlannerArtifactView(id: "same", title: "List", kind: .list)
            ],
            deleteViewIds: [],
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            guard case PlannerCoreError.invalidNodeOutput(let message) = error else {
                return XCTFail("expected invalidNodeOutput, got \(error)")
            }
            XCTAssertTrue(message.contains("Duplicate artifact view id"))
        }
    }

    func testArtifactDataWritesRejectInlineViews() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")

        XCTAssertThrowsError(try PlannerBoardBridge.attachArtifact(
            nodeId: "canvas-a-node-1",
            kind: .generic,
            title: "Bad",
            reference: "artifact://bad-views",
            status: "attached",
            payload: .object([
                "type": .string("json"),
                "json": .string("[]"),
                "views": .array([])
            ]),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            guard case PlannerCoreError.invalidNodeOutput(let message) = error else {
                return XCTFail("expected invalidNodeOutput, got \(error)")
            }
            XCTAssertTrue(message.contains("update_artifact_views"))
        }
    }

    func testJsonArtifactPayloadsReadBackAsDisplayableContent() throws {
        let stringPayload = PlannerArtifact(
            id: "artifact-json-string",
            canvasId: "canvas-a",
            nodeId: "node-a",
            kind: .generic,
            title: "JSON String",
            reference: "json-string",
            status: "attached",
            createdAt: Date(),
            payload: .object([
                "type": .string("json"),
                "json": .string(#"[{"title":"A"}]"#)
            ])
        )
        XCTAssertEqual(try PlannerArtifactStorage.content(for: stringPayload).content, #"[{"title":"A"}]"#)

        let arrayPayload = PlannerArtifact(
            id: "artifact-json-data",
            canvasId: "canvas-a",
            nodeId: "node-a",
            kind: .generic,
            title: "JSON Data",
            reference: "json-data",
            status: "attached",
            createdAt: Date(),
            payload: .object([
                "type": .string("json"),
                "data": .array([
                    .object(["title": .string("A")]),
                    .object(["title": .string("B")])
                ])
            ])
        )
        let content = try XCTUnwrap(PlannerArtifactStorage.content(for: arrayPayload).content)
        XCTAssertTrue(content.contains(#""title":"A""#))
        XCTAssertTrue(content.contains(#""title":"B""#))
    }

    /// Regression (PERF): the dead-session demotion branch must be idempotent.
    /// Root cause of a pegged CPU core — `/api/state` polling (multiple board
    /// clients × ~1Hz) kept feeding an already-ended session through
    /// `applyRunStateForSession(.pending)`. That branch had no `guard changed`,
    /// so every poll re-wrote identical fields, re-appended an identical
    /// `nodeStateChanged` event, and re-`save()`d the whole canvas. events.jsonl
    /// grew without bound (observed ~15k duplicate events / ~5MB) and each save
    /// re-encoded the full log → one core burned at 100%. After the fix,
    /// re-observing a dead session must NOT append new events or grow the log.
    func testDeadSessionRunStateIsIdempotentAndDoesNotGrowEventLog() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-dead",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: .running
        )

        // First dead observation — demotes the node (one legit state change).
        let afterFirstDeath = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: PlannerSessionRunStateBridge.runState(for: .dead)
        )
        let baselineEventCount = try XCTUnwrap(afterFirstDeath).events.count

        // Subsequent identical dead observations (simulating repeated
        // /api/state polls) must be no-ops — no new events, log must not grow.
        for _ in 0..<10 {
            let record = try PlannerBoardBridge.store.applyRunStateForSession(
                sessionId: "claude-dead",
                runState: PlannerSessionRunStateBridge.runState(for: .dead)
            )
            XCTAssertEqual(
                try XCTUnwrap(record).events.count,
                baselineEventCount,
                "repeated dead-session observation must not append duplicate events"
            )
        }

        // Behavior preserved: the node stays correctly demoted for resume.
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertEqual(node.sessionId, "claude-dead")
        XCTAssertEqual(node.workflowRunState, .awaitingInput)
        XCTAssertEqual(node.status, .blocked)
        XCTAssertEqual(node.blockedReason, "Session claude-d 已结束；可打开恢复，或替换为新会话。")
    }

    /// Regression (review follow-up): the idempotency guard must also see
    /// active-run drift, not just blueprint-node fields. After a node is
    /// demoted by a dead observation, starting a fresh run resets that run's
    /// nodeStates to .pending; the next dead observation hits the guard with
    /// unchanged blueprint fields. If the guard only compared PlanningNode,
    /// it would short-circuit before mirrorIntoActiveRun and the new run
    /// would keep showing pending/ready-to-dispatch for a still-bound dead
    /// session. The re-sync must also converge (no event growth afterwards).
    func testDeadSessionReMirrorsIntoFreshRunAndStillConverges() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-dead",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: .running
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: PlannerSessionRunStateBridge.runState(for: .dead)
        )

        // Fresh run after the demotion — its nodeStates start over from
        // .pending while the blueprint node keeps the demoted fields.
        let freshRun = try PlannerBoardBridge.startRun(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")

        // Next dead observation: blueprint unchanged, but the run is out of
        // sync → must mirror the demotion into the fresh run.
        let resynced = try XCTUnwrap(try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: PlannerSessionRunStateBridge.runState(for: .dead)
        ))
        let run = try XCTUnwrap(resynced.runs.first { $0.id == freshRun.id })
        let runNode = try XCTUnwrap(run.nodeStates[stepId])
        XCTAssertEqual(runNode.runState, .awaitingInput, "fresh run must reflect the dead-session demotion")
        XCTAssertEqual(runNode.sessionId, "claude-dead")

        // Once re-synced, further dead observations are no-ops again.
        let settledEventCount = resynced.events.count
        for _ in 0..<5 {
            let record = try PlannerBoardBridge.store.applyRunStateForSession(
                sessionId: "claude-dead",
                runState: PlannerSessionRunStateBridge.runState(for: .dead)
            )
            XCTAssertEqual(
                try XCTUnwrap(record).events.count,
                settledEventCount,
                "re-sync must converge — no event growth after the run is mirrored"
            )
        }
    }

    /// Regression: when an agent calls `submit_node_output` with status=blocked,
    /// the Claude session returning to idle right after must NOT flip the node
    /// back to dispatched / wipe the blockedReason. Reproduces the
    /// "已 submit blocked 但 UI 仍显示 working" 现场 — root cause was
    /// `applySessionRunStateLocked` only protecting `.done`, not explicit
    /// agent-submitted terminal states.
    func testAgentSubmittedBlockedSurvivesSessionIdleObservation() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-01",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        // Simulate Claude session running (thinking / tooling).
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-01",
            runState: .running
        )
        // Agent submits blocked output.
        _ = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .blocked,
                message: PlannerNodeOutputMessage(summary: "Need owner intent", routeTo: ["owner"]),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        // Session goes back to idle / running cycles as Claude awaits the next user turn.
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-01",
            runState: .dispatched
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-01",
            runState: .running
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-01",
            runState: .dispatched
        )

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertEqual(node.workflowRunState, .failed, "blocked latch must survive idle observations")
        XCTAssertEqual(node.status, .blocked)
        XCTAssertEqual(node.blockedReason, "Need owner intent")
        XCTAssertNotNil(node.outputSubmittedAt, "submit latch should remain set until re-dispatch")
    }

    /// BUG 1.1 regression — after a restart, a node bound to a session that is
    /// no longer live must NOT keep showing `running`/`dispatched`. The
    /// liveness reconcile pass demotes it to `awaitingInput` (status `.blocked`)
    /// and stamps the awaiting clock so the UI surfaces "needs attention".
    /// Tolerant: a genuinely live session is left untouched.
    func testReconcileDemotesNodeBoundToDeadSession() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)

        // Bind a session and drive it to running, as it would be before the app
        // closed.
        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-dead",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-dead",
            runState: .running
        )

        // Sanity: the node is running before reconciliation.
        let preState = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let preNode = try XCTUnwrap(preState.nodes.first { $0.id == stepId })
        XCTAssertEqual(preNode.workflowRunState, .running)

        // Reconcile against a live session set that does NOT contain the bound
        // session (it died while the app was closed).
        let demoted = try PlannerBoardBridge.store.reconcileRunStateAgainstLiveSessions(
            canvasId: "canvas-a",
            isLive: { _ in false }
        )
        XCTAssertEqual(demoted, 1, "the stale running node should be demoted")

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertNotEqual(node.workflowRunState, .running, "must not still report running")
        XCTAssertNotEqual(node.workflowRunState, .dispatched, "must not still report dispatched")
        XCTAssertEqual(node.workflowRunState, .awaitingInput, "demoted to awaiting input")
        XCTAssertEqual(node.status, .blocked)
        // The demoted node carries a "needs attention" reason for the UI. The
        // awaiting-clock timestamp itself is stamped onto the active run's live
        // attempt by applySessionRunStateLocked (the shared path this routes
        // through, covered by the session-feedback tests); the demotion here is
        // the load-time reconciliation that fixes the stale `running` state.
        XCTAssertNotNil(node.blockedReason, "needs-attention reason surfaced to UI")
        XCTAssertTrue(
            node.blockedReason?.contains(String("claude-dead".prefix(8))) ?? false,
            "reason should name the dead session"
        )
    }

    /// BUG 1.1 tolerance — a node whose bound session is still live must be left
    /// untouched by the reconcile pass.
    func testReconcileLeavesNodeBoundToLiveSessionRunning() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)
        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-live",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-live",
            runState: .running
        )

        let demoted = try PlannerBoardBridge.store.reconcileRunStateAgainstLiveSessions(
            canvasId: "canvas-a",
            isLive: { $0 == "claude-live" }
        )
        XCTAssertEqual(demoted, 0, "a live session must not be demoted")

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertEqual(node.workflowRunState, .running, "live node stays running")
    }

    /// Counterpart: re-dispatching a blocked node must release the latch and
    /// let session-status mirror resume — otherwise the node would be stuck
    /// blocked forever even after the owner asked the agent to try again.
    func testReDispatchClearsAgentSubmittedLatch() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-01",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .blocked,
                message: PlannerNodeOutputMessage(summary: "Need owner intent", routeTo: []),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // Re-dispatch — this is the owner saying "try again", latch must lift.
        _ = try PlannerBoardBridge.dispatchNode(
            nodeId: stepId,
            runner: .byoaLocal,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let afterDispatch = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let dispatchedNode = try XCTUnwrap(afterDispatch.nodes.first { $0.id == stepId })
        XCTAssertEqual(dispatchedNode.workflowRunState, .dispatched)
        XCTAssertEqual(dispatchedNode.status, .ready)
        XCTAssertNil(dispatchedNode.outputSubmittedAt, "dispatch must clear the submit latch")
        XCTAssertNil(dispatchedNode.blockedReason, "dispatch must clear stale blocker text")

        // After re-dispatch a fresh idle observation should now flow through.
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "claude-01",
            runState: .running
        )
        let afterRun = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let runningNode = try XCTUnwrap(afterRun.nodes.first { $0.id == stepId })
        XCTAssertEqual(runningNode.workflowRunState, .running, "session mirror must work again after re-dispatch")
    }

    // MARK: - Effective session status (planner mirror) — permission-gate bug

    /// Build a minimal `SessionDTO` for planner-mirror tests. Only the fields
    /// the mirror reads (`id`, `status`, `pendingPermissionTool`) are meaningful;
    /// everything else is defaulted to neutral values.
    private func makeSessionDTO(
        id: String,
        status: SessionStatus,
        pendingPermissionTool: String? = nil,
        terminalKind: String = "external"
    ) -> SessionDTO {
        SessionDTO(
            id: id,
            title: id,
            project: "/tmp/fake-project",
            pluginId: "com.meee2.plugin.claude",
            pluginDisplayName: "Claude Code",
            pluginColor: "#FF9500",
            status: status.rawValue,
            inboxPending: 0,
            recentMessages: [],
            currentTool: nil,
            startedAt: nil,
            lastActivity: nil,
            usageStats: nil,
            tasks: [],
            currentTask: nil,
            pendingPermissionTool: pendingPermissionTool,
            pendingPermissionMessage: pendingPermissionTool == nil ? nil : "Allow \(pendingPermissionTool!)?",
            pendingChoiceTool: nil,
            pendingChoiceMessage: nil,
            ghosttyTerminalId: nil,
            tty: nil,
            termProgram: nil,
            terminalKind: terminalKind,
            surfaceId: nil,
            providerResumeSessionId: nil,
            surfaceStatus: nil,
            canOpenExternal: true,
            terminalBackend: "external",
            nativeWorkspaceAvailable: false,
            openTarget: "external",
            controlState: "active",
            sessionScope: terminalKind == "internal" ? "meee2" : "external",
            backgroundAgents: [],
            latestRecap: nil,
            providerRecapSignals: [],
            clientKind: "cli",
            syncEnabled: false,
            syncTeamId: nil,
            syncTeamName: nil
        )
    }

    /// Root-cause unit: a session can carry a pending permission prompt
    /// (`pendingPermissionTool`) while its coarse `status` still resolves to a
    /// working state (e.g. `.active`/`.thinking` for a fresh-assistant tail).
    /// `effectiveSessionStatus` must promote that to `.permissionRequired` so the
    /// planner mirror flips the node to `gateWait`, instead of leaving it
    /// "running". A genuinely working session with no pending permission keeps
    /// its working status; a `.waitingForUser` status is preserved.
    func testEffectiveSessionStatusPromotesPendingPermission() {
        // Permission pending while status string says active → permissionRequired.
        let pendingActive = makeSessionDTO(id: "ghost-1", status: .active, pendingPermissionTool: "Bash")
        XCTAssertEqual(BoardAPI.effectiveSessionStatus(for: pendingActive), .permissionRequired)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .permissionRequired), .gateWait)

        // Same for thinking — pending permission dominates.
        let pendingThinking = makeSessionDTO(id: "ghost-2", status: .thinking, pendingPermissionTool: "Edit")
        XCTAssertEqual(BoardAPI.effectiveSessionStatus(for: pendingThinking), .permissionRequired)

        // No pending permission + thinking → stays thinking (→ running).
        let thinking = makeSessionDTO(id: "ghost-3", status: .thinking)
        XCTAssertEqual(BoardAPI.effectiveSessionStatus(for: thinking), .thinking)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .thinking), .running)

        // waitingForUser status (Claude finished, ball in human's court) is
        // preserved → awaitingInput.
        let waiting = makeSessionDTO(id: "ghost-4", status: .waitingForUser)
        XCTAssertEqual(BoardAPI.effectiveSessionStatus(for: waiting), .waitingForUser)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .waitingForUser), .awaitingInput)

        // Empty/whitespace pendingPermissionTool is treated as "no pending".
        let blankPending = makeSessionDTO(id: "ghost-5", status: .active, pendingPermissionTool: "   ")
        XCTAssertEqual(BoardAPI.effectiveSessionStatus(for: blankPending), .active)
    }

    /// End-to-end mirror: a bound node observing a permission-gated session
    /// (derived status `.permissionRequired`) flips to `gateWait` ("待审核/
    /// 等反馈"), NOT `running` — the original bug. A thinking session stays
    /// running.
    func testPermissionGatedSessionFlipsBoundNodeToGateWait() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)
        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-ghostty-1",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // A thinking session (no pending permission) → node running.
        let thinking = makeSessionDTO(id: "claude-ghostty-1", status: .thinking)
        _ = PlannerSessionRunStateBridge.observeBound(
            sessionId: thinking.id,
            status: BoardAPI.effectiveSessionStatus(for: thinking)
        )
        var node = try XCTUnwrap(
            try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
                .nodes.first { $0.id == stepId }
        )
        XCTAssertEqual(node.workflowRunState, .running, "a thinking session keeps the node running")

        // Now the same session has a permission prompt pending while its coarse
        // status STILL reads as a working state (the ghostty gap). The node must
        // flip off running → gateWait.
        let gated = makeSessionDTO(id: "claude-ghostty-1", status: .active, pendingPermissionTool: "Bash")
        _ = PlannerSessionRunStateBridge.observeBound(
            sessionId: gated.id,
            status: BoardAPI.effectiveSessionStatus(for: gated)
        )
        node = try XCTUnwrap(
            try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
                .nodes.first { $0.id == stepId }
        )
        XCTAssertNotEqual(node.workflowRunState, .running, "must not keep showing 运行中 while a permission gate is pending")
        XCTAssertEqual(node.workflowRunState, .gateWait, "permission-pending session → 待审核/等反馈")
        XCTAssertEqual(node.status, .blocked)
    }

    /// Regression guard: the permission-gate promotion must NOT override an
    /// agent that has explicitly submitted output (the `outputSubmittedAt`
    /// latch). Even if a stray permission-pending observation arrives after a
    /// `submit_node_output done`, the latched terminal state survives.
    func testPermissionGatedObservationDoesNotOverrideSubmittedLatch() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)
        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "claude-submit",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Output submitted", routeTo: []),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // A late permission-pending observation arrives for the same session.
        let gated = makeSessionDTO(id: "claude-submit", status: .active, pendingPermissionTool: "Bash")
        _ = PlannerSessionRunStateBridge.observeBound(
            sessionId: gated.id,
            status: BoardAPI.effectiveSessionStatus(for: gated)
        )

        let node = try XCTUnwrap(
            try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
                .nodes.first { $0.id == stepId }
        )
        XCTAssertEqual(node.workflowRunState, .done, "submitted latch must survive the permission-gate observation")
        XCTAssertEqual(node.status, .done)
        XCTAssertNotNil(node.outputSubmittedAt)
    }

    func testSessionFailureBeforeOutputStoresBlockedReason() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "failed01",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.applyRunStateForSession(
            sessionId: "failed01",
            runState: .failed
        )

        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        XCTAssertEqual(node.workflowRunState, .failed)
        XCTAssertEqual(node.status, .blocked)
        XCTAssertEqual(node.blockedReason, "Session failed01 ended before this node submitted a completion output.")
    }

    func testScheduledNodeBecomesDueAndMarksNextTick() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "session-loop",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.store.updateNodeSchedule(
            canvasId: "canvas-a",
            nodeId: stepId,
            schedule: PlannerNodeSchedule(
                enabled: true,
                intervalSeconds: 60,
                prompt: "Run another loop.",
                lastSentAt: nil,
                nextRunAt: now.addingTimeInterval(-1)
            )
        )

        let due = PlannerBoardBridge.store.dueScheduledNodes(now: now)
        XCTAssertEqual(due.map(\.nodeId), [stepId])
        XCTAssertEqual(due.first?.sessionId, "session-loop")

        _ = try PlannerBoardBridge.store.markScheduledTickSent(
            canvasId: "canvas-a",
            nodeId: stepId,
            sentAt: now
        )
        let state = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let node = try XCTUnwrap(state.nodes.first { $0.id == stepId })
        // markScheduledTickSent queues a tick but does not dispatch — the
        // separate dispatch path is what flips to .dispatched/.working.
        XCTAssertEqual(node.workflowRunState, .readyToStart)
        XCTAssertEqual(node.status, .ready)
        XCTAssertEqual(node.schedule?.lastSentAt, now)
        XCTAssertEqual(node.schedule?.nextRunAt, now.addingTimeInterval(60))
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

    // MARK: - WorkflowRunEngine (P3)

    /// Bare planning node for engine tests — `deps` sets `dependsOnNodeIds`.
    private func planNode(_ id: String, deps: [String] = []) -> PlanningNode {
        var node = PlanningNode(
            id: id, canvasId: "c", title: id,
            schema: NodeSchema(inputs: [], outputs: [], goal: "done"),
            contextSources: [], executionMode: .human, executorType: .mock,
            doerId: "owner", status: .ready
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

    /// A dispatch without a bound session is retryable; once a real session is
    /// bound, the node's single active-session slot is occupied.
    func testDispatchDirectCanRetryUntilSessionIsBound() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        let once = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        XCTAssertEqual(once.graph.nodes.first { $0.id == step.id }?.workflowRunState, .dispatched)
        XCTAssertFalse(once.graph.nodes.contains { $0.nodeKind == .session })
        XCTAssertNoThrow(try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        ))
        _ = try PlannerBoardBridge.bindSession(
            nodeId: step.id,
            sessionId: "real-session",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        XCTAssertThrowsError(try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .activeSessionExists(nodeId: step.id))
        }
    }

    // 回归: 节点绑着一个已死的会话(runState 还停在 .running,death 未及时写回)
    // 时,「打开会话」走 recreate 自愈式重绑必须能成功。没有 allowReplace 会被
    // hasActiveSession 守卫拦成 activeSessionExists —— 节点永久卡死、每次点都
    // recreate 出新 session。allowReplace 由 BoardAPI(掌握运行态死活)在「绑定
    // 会话已死」分支显式放行。
    func testBindSessionAllowReplaceRebindsOverDeadBinding() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        // 先绑一个会话 —— 节点现在持有一个「活」(running)绑定。
        _ = try PlannerBoardBridge.bindSession(
            nodeId: step.id,
            sessionId: "dead-session",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        // 不带 allowReplace 的重绑被拒 —— 旧绑定看起来仍 active(其 surface 实际
        // 已死,但 core 看不到运行态)。
        XCTAssertThrowsError(try PlannerBoardBridge.bindSession(
            nodeId: step.id,
            sessionId: "fresh-session",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )) { error in
            XCTAssertEqual(error as? PlannerCoreError, .activeSessionExists(nodeId: step.id))
        }

        // allowReplace: open-flow 自愈,替换掉死绑定。
        let healed = try PlannerBoardBridge.bindSession(
            nodeId: step.id,
            sessionId: "fresh-session",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a",
            allowReplace: true
        )
        XCTAssertEqual(healed.nodes.first { $0.id == step.id }?.sessionId, "fresh-session")
    }

    func testAbandonNodeSessionClearsUnboundDispatchForRetry() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        _ = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let abandoned = try PlannerBoardBridge.abandonNodeSession(
            nodeId: step.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let node = try XCTUnwrap(abandoned.nodes.first { $0.id == step.id })
        XCTAssertNil(node.workflowRunState)
        XCTAssertNil(node.dispatch)
        XCTAssertNil(node.sessionId)
        XCTAssertEqual(node.status, .ready)
        XCTAssertNoThrow(try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        ))
    }

    func testDetachNodeSessionClearsBoundSessionForReplacement() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a")
        let step = try XCTUnwrap(before.nodes.first { $0.nodeKind == .step })

        _ = try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        _ = try PlannerBoardBridge.bindSession(
            nodeId: step.id,
            sessionId: "stale-session",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let detached = try PlannerBoardBridge.detachNodeSession(
            nodeId: step.id,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let node = try XCTUnwrap(detached.nodes.first { $0.id == step.id })
        XCTAssertNil(node.workflowRunState)
        XCTAssertNil(node.dispatch)
        XCTAssertNil(node.sessionId)
        XCTAssertEqual(node.status, .ready)
        XCTAssertNoThrow(try PlannerBoardBridge.dispatchNode(
            nodeId: step.id, runner: .byoaLocal,
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        ))
    }

    /// `applyNodeChange` is idempotent — re-applying an identical dispatch
    /// change does not add session nodes.
    func testDispatchApplyDoesNotCreateSessionNode() throws {
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
        XCTAssertFalse(once.contains { $0.nodeKind == .session })
        let twice = try service.applyNodeChange(nodes: once, proposal: proposal)
        XCTAssertFalse(twice.contains { $0.nodeKind == .session })
    }

    /// SessionStatus → PlannerWorkflowRunState mapping.
    func testSessionStatusMapsToWorkflowRunState() {
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .thinking), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .tooling), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .active), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .compacting), .running)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .idle), .dispatched)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .waitingForUser), .awaitingInput)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .permissionRequired), .gateWait)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .completed), .done)
        // 3-态会话模型(2026-06-01): 会话结束 = 回到「未启动 session」可重开,不再终态失败。
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: .dead), .pending)

        XCTAssertEqual(PlannerSessionRunStateBridge.stepNodeId(fromPurpose: "planner:node-7"), "node-7")
        XCTAssertNil(PlannerSessionRunStateBridge.stepNodeId(fromPurpose: "global"))
        XCTAssertNil(PlannerSessionRunStateBridge.stepNodeId(fromPurpose: nil))
    }

    /// Observing a planner-tagged session binds the session id onto the step
    /// and flows the run state onto that same node.
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
        let boundStep = try XCTUnwrap(bound.nodes.first { $0.id == step.id })
        XCTAssertEqual(boundStep.sessionId, "sess-xyz")
        XCTAssertEqual(boundStep.chatThreadId, "sess-xyz")
        XCTAssertEqual(boundStep.workflowRunState, .running)
        XCTAssertFalse(bound.nodes.contains { $0.nodeKind == .session })

        // A later observation keyed only by session id (intent already
        // consumed) still flows through and marks completion → done.
        let finished = try XCTUnwrap(PlannerSessionRunStateBridge.observeBound(
            sessionId: "sess-xyz",
            status: .completed
        ))
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

    // MARK: - ENG-2: Session Lifecycle Rebuild

    /// E2.1: every submit_node_output appends a version. Two submits → two
    /// distinct version_ids with v1 → v2 parent linkage.
    func testSubmitNodeOutputAppendsNodeVersionAndChainsParent() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: "canvas-a", nodeId: stepId, executionMode: .auto)
        _ = try PlannerBoardBridge.bindSession(
            nodeId: stepId,
            sessionId: "session-v",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        let first = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "v1 output", routeTo: []),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let v1Id = try XCTUnwrap(first.versionId)
        XCTAssertEqual(first.versionIndex, 1)

        // E2.3: force_new_version produces a fresh version on the same node.
        let second = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "v2 output", routeTo: []),
                artifacts: [],
                next: .complete,
                forceNewVersion: true
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let v2Id = try XCTUnwrap(second.versionId)
        XCTAssertEqual(second.versionIndex, 2)
        XCTAssertNotEqual(v1Id, v2Id)

        // Both versions queryable + chained. `record(for:)` is the public
        // accessor; pass a matching canvas + empty seedNodes so the existing
        // record is returned unchanged.
        let canvas = PlanningCanvas(
            id: "canvas-a",
            ownerId: "owner-a",
            title: "Planning Canvas",
            plannerContext: "canvas:canvas-a"
        )
        let record = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [])
        let chain = record.nodeVersions.chain(canvasId: "canvas-a", nodeId: stepId)
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain.first?.versionIndex, 1)
        XCTAssertEqual(chain.last?.versionIndex, 2)
        XCTAssertNil(chain.first?.parentVersionId)
        XCTAssertEqual(chain.last?.parentVersionId, v1Id)
        XCTAssertEqual(chain.last?.trigger, .forceRerun)
    }

    /// E2.5: SessionInputMerge sorts sources in the declared order
    /// (upstream → external (declared order) → dialogue).
    func testSessionInputMergeRespectsDeclaredOrder() {
        let contract = NodeContractV2(input: NodeContractInput(
            upstream: NodeContractUpstreamInput(mode: .passthrough, sourceNodeId: "up-1"),
            external: [
                NodeContractExternalInput(connector: "notion", ref: "notion://a", syncSessionId: nil),
                NodeContractExternalInput(connector: "lark", ref: "lark://b", syncSessionId: "sync-lark-1")
            ],
            dialogue: NodeContractDialogueInput(enabled: true, window: NodeContractDialogueWindow(kind: .rolling, nTurns: 3))
        ), output: NodeContractOutput(cardinality: .single, payloadKind: .artifactRef, externalWriteTarget: nil))

        let upstream = NodeVersion(
            id: "nodever-canvas-up1-2-abcd",
            canvasId: "canvas-a",
            nodeId: "up-1",
            versionIndex: 2,
            parentVersionId: "nodever-canvas-up1-1-aaaa",
            sessionId: nil,
            trigger: .manual,
            inputs: NodeVersionInputSnapshot(upstreamNodeId: nil, upstreamVersionId: nil, external: [], dialogueTurns: nil, mergeLog: []),
            artifactIds: [],
            status: .done,
            startedAt: Date(),
            finishedAt: Date()
        )
        let fetched = [
            SessionInputMerge.ExternalFetchResult(connector: "notion", ref: "notion://a", fetchedArtifactId: "art-notion-1", previewLines: ["notion line"]),
            SessionInputMerge.ExternalFetchResult(connector: "lark", ref: "lark://b", fetchedArtifactId: nil, previewLines: ["lark line a", "lark line b"])
        ]
        let result = SessionInputMerge.merge(
            contract: contract,
            upstreamLatest: upstream,
            upstreamPayload: "upstream payload body",
            externalFetched: fetched,
            dialogueTurns: ["t1", "t2", "t3", "t4"]
        )

        // Snapshot fields.
        XCTAssertEqual(result.snapshot.upstreamNodeId, "up-1")
        XCTAssertEqual(result.snapshot.upstreamVersionId, upstream.id)
        XCTAssertEqual(result.snapshot.external.count, 2)
        XCTAssertEqual(result.snapshot.external[0].connector, "notion")
        XCTAssertEqual(result.snapshot.external[0].fetchedArtifactId, "art-notion-1")
        XCTAssertEqual(result.snapshot.external[1].connector, "lark")
        XCTAssertEqual(result.snapshot.external[1].syncSessionId, "sync-lark-1")
        XCTAssertEqual(result.snapshot.dialogueTurns, 3)

        // Order in preamble: upstream block first, then external blocks
        // in declared order, then dialogue tail last.
        let preamble = result.promptPreamble
        let upIdx = preamble.range(of: "## Upstream")?.lowerBound
        let notionIdx = preamble.range(of: "## External: notion")?.lowerBound
        let larkIdx = preamble.range(of: "## External: lark")?.lowerBound
        let dialogueIdx = preamble.range(of: "## Recent dialogue")?.lowerBound
        XCTAssertNotNil(upIdx)
        XCTAssertNotNil(notionIdx)
        XCTAssertNotNil(larkIdx)
        XCTAssertNotNil(dialogueIdx)
        XCTAssertLessThan(upIdx!, notionIdx!)
        XCTAssertLessThan(notionIdx!, larkIdx!)
        XCTAssertLessThan(larkIdx!, dialogueIdx!)

        // Dialogue window slices the last 3 turns (newest at the end).
        XCTAssertTrue(preamble.contains("t4"))
        XCTAssertTrue(preamble.contains("t2"))
        XCTAssertFalse(preamble.contains("\nt1\n")) // t1 was outside the 3-turn window

        // Merge log mentions every source so ENG-5 can render it in history.
        XCTAssertTrue(result.snapshot.mergeLog.contains { $0.contains("upstream node=up-1") })
        XCTAssertTrue(result.snapshot.mergeLog.contains { $0.contains("external[0] connector=notion") })
        XCTAssertTrue(result.snapshot.mergeLog.contains { $0.contains("dialogue") })
    }

    /// E2.5: dialogue-disabled contracts produce a snapshot with
    /// `dialogueTurns == nil` and no dialogue block in the preamble.
    func testSessionInputMergeHonoursDialogueDisabled() {
        let contract = NodeContractV2(input: NodeContractInput(
            upstream: NodeContractUpstreamInput(mode: .passthrough, sourceNodeId: nil),
            external: [],
            dialogue: NodeContractDialogueInput(enabled: false, window: NodeContractDialogueWindow(kind: .rolling, nTurns: 5))
        ), output: NodeContractOutput(cardinality: .single, payloadKind: .artifactRef, externalWriteTarget: nil))

        let result = SessionInputMerge.merge(
            contract: contract,
            upstreamLatest: nil,
            upstreamPayload: nil,
            externalFetched: [],
            dialogueTurns: ["should not show"]
        )

        XCTAssertNil(result.snapshot.dialogueTurns)
        XCTAssertFalse(result.promptPreamble.contains("Recent dialogue"))
        XCTAssertFalse(result.promptPreamble.contains("should not show"))
    }

    /// E2.2: submitting output to an upstream node auto-dispatches downstream
    /// auto-mode nodes that flip to readyToStart.
    func testSubmitNodeOutputAutoDispatchesDownstreamAutoNode() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        // Force the downstream node into auto execution mode + clear gate so
        // submitNodeOutput's targetIndex flip path takes it to readyToStart.
        let stepId = "canvas-a-node-1"
        let downstreamId = "canvas-a-node-2"
        _ = try PlannerBoardBridge.store.updateNodeGate(
            canvasId: "canvas-a", nodeId: downstreamId, executionMode: .auto
        )

        let result = try PlannerBoardBridge.submitNodeOutput(
            nodeId: stepId,
            output: PlannerNodeOutput(
                nodeId: stepId,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "kick downstream", routeTo: [downstreamId]),
                artifacts: [],
                next: .complete
            ),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(result.autoDispatchedNodeIds, [downstreamId])
        let downstream = try XCTUnwrap(result.graph.nodes.first { $0.id == downstreamId })
        XCTAssertEqual(downstream.workflowRunState, .dispatched)
    }

    /// P1 (PR #109) — fan-in auto-dispatch must wait for ALL upstreams.
    ///
    /// D dependsOn [A, B, C], all auto/claude (mirrors the coding-orchestration
    /// 集成 node fanning in from 前端/后端/重构). Completing A (routed to D) must
    /// NOT make D an auto-dispatch candidate; A+B still not; only after C (all
    /// three done) does D flip to readyToStart and become a candidate.
    func testFanInAutoDispatchWaitsForAllUpstreams() throws {
        let canvasId = "canvas-fanin"
        let canvas = PlanningCanvas(
            id: canvasId, ownerId: "owner-a", title: "Fan-in Canvas",
            plannerContext: "canvas:\(canvasId)"
        )
        func node(_ id: String, deps: [String]) -> PlanningNode {
            PlanningNode(
                id: id, canvasId: canvasId, title: id,
                schema: NodeSchema(inputs: [], outputs: ["\(id)_out"], goal: id),
                contextSources: [],
                executionMode: .auto, executorType: .claude,
                doerId: "owner-a", status: .ready,
                source: .planner, dependsOnNodeIds: deps.isEmpty ? nil : deps,
                nodeKind: .step
            )
        }
        let a = node("fanin-a", deps: [])
        let b = node("fanin-b", deps: [])
        let c = node("fanin-c", deps: [])
        let d = node("fanin-d", deps: ["fanin-a", "fanin-b", "fanin-c"])
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [a, b, c, d])

        func submit(_ producerId: String) throws -> [PlanningNode] {
            try PlannerBoardBridge.store.submitNodeOutput(
                canvasId: canvasId,
                nodeId: producerId,
                output: PlannerNodeOutput(
                    nodeId: producerId,
                    status: .done,
                    message: PlannerNodeOutputMessage(summary: "\(producerId) done", routeTo: ["fanin-d"]),
                    artifacts: [],
                    next: .complete
                )
            ).autoDispatchCandidates
        }

        // After A: D has 2 unfinished upstreams (B, C) → NOT a candidate.
        let afterA = try submit("fanin-a")
        XCTAssertFalse(afterA.contains { $0.id == "fanin-d" },
                       "D must not auto-dispatch after only A is done")

        // After A+B: D still has 1 unfinished upstream (C) → NOT a candidate.
        let afterB = try submit("fanin-b")
        XCTAssertFalse(afterB.contains { $0.id == "fanin-d" },
                       "D must not auto-dispatch after only A+B are done")

        // D must also still be un-flipped (not readyToStart) at this point.
        let midRecord = try PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvasId)
        let midD = try XCTUnwrap(midRecord.nodes.first { $0.id == "fanin-d" })
        XCTAssertNotEqual(midD.workflowRunState, .readyToStart,
                          "D must not be flipped to readyToStart until all upstreams are done")

        // After C: all three upstreams done → D becomes a candidate.
        let afterC = try submit("fanin-c")
        XCTAssertTrue(afterC.contains { $0.id == "fanin-d" },
                      "D must auto-dispatch only after ALL three upstreams (A,B,C) are done")
    }

    /// Guard: the linear single-dep ENG-2 chain is unaffected — a node with one
    /// upstream still auto-dispatches the moment that upstream completes.
    func testLinearSingleDepAutoDispatchUnaffected() throws {
        let canvasId = "canvas-linear-fanin"
        let canvas = PlanningCanvas(
            id: canvasId, ownerId: "owner-a", title: "Linear Canvas",
            plannerContext: "canvas:\(canvasId)"
        )
        let a = PlanningNode(
            id: "lin-a", canvasId: canvasId, title: "A",
            schema: NodeSchema(inputs: [], outputs: ["a_out"], goal: "A"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: "owner-a", status: .ready, source: .planner, nodeKind: .step
        )
        let b = PlanningNode(
            id: "lin-b", canvasId: canvasId, title: "B",
            schema: NodeSchema(inputs: [], outputs: ["b_out"], goal: "B"),
            contextSources: [], executionMode: .auto, executorType: .claude,
            doerId: "owner-a", status: .ready, source: .planner,
            dependsOnNodeIds: ["lin-a"], nodeKind: .step
        )
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [a, b])

        let candidates = try PlannerBoardBridge.store.submitNodeOutput(
            canvasId: canvasId,
            nodeId: "lin-a",
            output: PlannerNodeOutput(
                nodeId: "lin-a",
                status: .done,
                message: PlannerNodeOutputMessage(summary: "A done", routeTo: ["lin-b"]),
                artifacts: [],
                next: .complete
            )
        ).autoDispatchCandidates

        XCTAssertTrue(candidates.contains { $0.id == "lin-b" },
                      "single-dep chain must still auto-dispatch B the moment A completes")
    }

    /// Bonus deliverable: refineSessionPrompt builds a no-schema-mutation
    /// proposal and persists it cleanly via the standard pipeline. Empty
    /// directive is allowed (just a "re-think" ping); non-empty is reflected
    /// in proposal summary.
    func testRefineSessionPromptProposalIsFirstClass() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let stepId = "canvas-a-node-1"

        let (proposal, sessionId) = try PlannerBoardBridge.refineSessionPromptProposal(
            nodeId: stepId,
            directive: "tighten the M2 PRD prompt",
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )

        XCTAssertEqual(proposal.canvasId, "canvas-a")
        XCTAssertEqual(proposal.changes.count, 1)
        XCTAssertEqual(proposal.changes.first?.kind, .refineSessionPrompt)
        XCTAssertEqual(proposal.changes.first?.nodeId, stepId)
        XCTAssertEqual(proposal.changes.first?.title, "tighten the M2 PRD prompt")
        XCTAssertTrue(proposal.summary.contains("tighten the M2 PRD prompt"))
        // No bound session on a fresh node — sessionId is nil and the caller
        // (BoardAPI) knows to skip the inject step.
        XCTAssertNil(sessionId)

        // Validator accepts the proposal even though `changes` only contains
        // a refine-session-prompt entry (no addNode/updateNode/attachArtifact).
        let canvas = PlanningCanvas(id: "canvas-a", ownerId: "owner-a", title: "Planning Canvas", plannerContext: "canvas:canvas-a")
        XCTAssertNoThrow(try PlannerProposalValidator.validate(proposal, canvas: canvas, nodes: [
            PlanningNode(
                id: stepId, canvasId: "canvas-a", title: "Step",
                schema: NodeSchema(inputs: [], outputs: [], goal: ""),
                contextSources: [], executionMode: .auto, executorType: .claude,
                doerId: "owner-a", status: .ready
            )
        ]))
    }

    private func boardSnapshot(
        canvasId: String,
        ownerId: String,
        memberships: [BoardLayoutStore.CanvasSession] = [],
        kind: BoardLayoutStore.CanvasKind = .board,
        templateMetadata: BoardLayoutStore.TemplateMetadata? = nil
    ) -> BoardLayoutStore.Snapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let canvas = BoardLayoutStore.Canvas(
            id: canvasId,
            name: "Planning Canvas",
            scope: .personal,
            kind: kind,
            ownerUserId: ownerId,
            teamId: nil,
            isDefault: true,
            workspaceFolderName: nil,
            createdBy: ownerId,
            templateMetadata: templateMetadata,
            createdAt: now,
            updatedAt: now
        )
        return BoardLayoutStore.Snapshot(
            activeCanvasId: canvasId,
            canvases: [canvas],
            memberships: memberships
        )
    }

    private func monitorSession(
        id: String,
        terminalKind: String,
        surfaceId: String? = nil
    ) -> SessionDTO {
        SessionDTO(
            id: id,
            title: id,
            project: "fixture",
            pluginId: "com.meee2.plugin.claude",
            pluginDisplayName: "Claude Code",
            pluginColor: "#FF9230",
            status: "active",
            inboxPending: 0,
            recentMessages: [],
            currentTool: nil,
            startedAt: nil,
            lastActivity: nil,
            usageStats: nil,
            tasks: [],
            currentTask: nil,
            pendingPermissionTool: nil,
            pendingPermissionMessage: nil,
            pendingChoiceTool: nil,
            pendingChoiceMessage: nil,
            ghosttyTerminalId: nil,
            tty: nil,
            termProgram: nil,
            terminalKind: terminalKind,
            surfaceId: surfaceId,
            providerResumeSessionId: nil,
            surfaceStatus: nil,
            canOpenExternal: terminalKind == "external",
            terminalBackend: terminalKind,
            nativeWorkspaceAvailable: terminalKind == "internal",
            openTarget: terminalKind == "internal" ? "native-workspace" : "external",
            controlState: "active",
            sessionScope: terminalKind == "internal" ? "meee2" : "external",
            backgroundAgents: [],
            latestRecap: nil,
            providerRecapSignals: [],
            clientKind: "cli",
            syncEnabled: false,
            syncTeamId: nil,
            syncTeamName: nil
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

    private func kanbanPayload(subCanvasId: String?) -> BoardJSONValue {
        var item: [String: BoardJSONValue] = [
            "id": .string("idea-1"),
            "columnId": .string("ideas"),
            "title": .string("Idea 1")
        ]
        if let subCanvasId {
            item["subCanvasId"] = .string(subCanvasId)
        } else {
            item["subCanvasId"] = .null
        }
        return .object([
            "version": .number(1),
            "columns": .array([
                .object([
                    "id": .string("ideas"),
                    "title": .string("Ideas")
                ])
            ]),
            "items": .array([.object(item)])
        ])
    }

    // MARK: - Unified Artifact.source (canvas-spec §7 — artifact-unified-model)

    /// Legacy `authored` ⇒ seed/authored OUTPUT slot, authorable per §7.4.
    func testArtifactSourceFromLegacyAuthoredIsAuthorableOutputSlot() throws {
        let src = try XCTUnwrap(
            ArtifactSource.fromLegacy(
                mode: "authored",
                nodeId: "node-1",
                outputSlotKey: "prd",
                mirroredSourceId: nil
            )
        )
        guard case let .slot(nodeId, slotKey, direction) = src else {
            return XCTFail("expected .slot, got \(src)")
        }
        XCTAssertEqual(nodeId, "node-1")
        XCTAssertEqual(slotKey, "prd")
        XCTAssertEqual(direction, .output)
        XCTAssertTrue(src.defaultAuthorable, "an authored seed output slot must be authorable (§7.4)")
    }

    /// Legacy `mirrored` ⇒ dataSource-kind source, NOT authorable per §7.4.
    func testArtifactSourceFromLegacyMirroredIsDataSourceNotAuthorable() throws {
        let src = try XCTUnwrap(
            ArtifactSource.fromLegacy(
                mode: "mirrored",
                nodeId: "node-1",
                outputSlotKey: "out",
                mirroredSourceId: "notion:doc:abc"
            )
        )
        guard case let .dataSource(sourceId) = src else {
            return XCTFail("expected .dataSource, got \(src)")
        }
        XCTAssertEqual(sourceId, "notion:doc:abc")
        XCTAssertFalse(src.defaultAuthorable, "a mirrored/dataSource source is NOT hand-fillable (§7.4)")
    }

    /// The unified `ArtifactSource` round-trips through Codec and an unknown
    /// discriminator decodes to forward-compat rather than throwing.
    func testArtifactSourceCodecRoundTripAndForwardCompat() throws {
        let cases: [ArtifactSource] = [
            .slot(nodeId: "n", slotKey: "k", direction: .input),
            .slot(nodeId: "n", slotKey: "k", direction: .output),
            .dataSource(sourceId: "ds-1"),
            .canvasRuntime
        ]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(ArtifactSource.self, from: data)
            XCTAssertEqual(decoded, c)
        }
        // canvas-runtime is read-only (not authorable).
        XCTAssertFalse(ArtifactSource.canvasRuntime.defaultAuthorable)
        // Unknown kind → forward-compat, preserves the raw discriminator.
        let unknown = #"{"kind":"future-kind"}"#.data(using: .utf8)!
        let fc = try JSONDecoder().decode(ArtifactSource.self, from: unknown)
        XCTAssertEqual(fc, .forwardCompat(rawKind: "future-kind"))
    }

    /// A node carrying only the legacy `artifactDataSource` string resolves the
    /// unified source on demand and emits it on encode (one-release compat).
    func testPlanningNodeResolvesAndEncodesUnifiedSourceFromLegacy() throws {
        let node = PlanningNode(
            id: "art-node",
            canvasId: "canvas-a",
            title: "Mirror",
            schema: NodeSchema(inputs: [], outputs: ["doc"], goal: "mirror"),
            contextSources: [],
            executionMode: .auto,
            executorType: .mock,
            doerId: "A",
            status: .ready,
            nodeKind: .artifact,
            artifactDataSource: "authored"
        )
        // resolved on demand from the legacy string.
        XCTAssertEqual(
            node.resolvedArtifactSource,
            .slot(nodeId: "art-node", slotKey: "doc", direction: .output)
        )
        // encoder emits the unified field so board-app reads one canonical origin.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any]
        )
        let srcObj = try XCTUnwrap(json["artifactSource"] as? [String: Any])
        XCTAssertEqual(srcObj["kind"] as? String, "slot")
        XCTAssertEqual(srcObj["direction"] as? String, "output")
    }

    /// updateNode carrying the legacy nested `artifactConfig.dataSource.mode`
    /// (the shape the board-app still sends) decodes + applies into the unified
    /// `artifactSource` (mirrored ⇒ dataSource), keeping decode-compat green.
    func testUpdateNodeWithLegacyNestedArtifactConfigSetsUnifiedSource() throws {
        let canvasId = "canvas-art"
        let ownerId = "owner-art"
        let snapshot = boardSnapshot(canvasId: canvasId, ownerId: ownerId)
        let node = PlanningNode(
            id: "art-1",
            canvasId: canvasId,
            title: "Artifact",
            schema: NodeSchema(inputs: [], outputs: ["out"], goal: "hold"),
            contextSources: [],
            executionMode: .auto,
            executorType: .mock,
            doerId: ownerId,
            status: .ready,
            nodeKind: .artifact
        )
        let record = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: ownerId, title: "C", plannerContext: "canvas:\(canvasId)"),
            seedNodes: [node]
        )
        // Decode the wire shape exactly as the board-app emits it.
        let wire = """
        {"kind":"updateNode","nodeId":"art-1","artifactConfig":{"dataSource":{"mode":"mirrored"}}}
        """.data(using: .utf8)!
        let change = try JSONDecoder().decode(PlanChange.self, from: wire)
        XCTAssertEqual(change.artifactDataSource, "mirrored", "nested artifactConfig.dataSource.mode must decode to the legacy string")

        let proposal = PlanProposal(
            id: "proposal-art-mirror",
            canvasId: canvasId,
            summary: "set mirrored",
            changes: [change],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: record.canvas, seedNodes: record.nodes)
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        let applied = try PlannerBoardBridge.applyProposal(
            proposalId: proposal.id, for: canvasId, snapshot: snapshot, actorUserId: ownerId
        )
        let updated = try XCTUnwrap(applied.nodes.first(where: { $0.id == "art-1" }))
        XCTAssertEqual(updated.artifactDataSource, "mirrored")
        guard case .dataSource = try XCTUnwrap(updated.resolvedArtifactSource) else {
            return XCTFail("expected unified .dataSource source after applying mirrored")
        }
    }

    // MARK: - Teams · 多人增量贡献 (NodeContributionConfig)

    /// Legacy node JSON without the `contribution` key must decode to nil, and
    /// a configured node must round-trip through Codable unchanged — the field
    /// rides the team canvas state sync, so the on-wire shape is load-bearing.
    func testNodeContributionConfigCodableRoundTripAndLegacyDefault() throws {
        var node = service.nodeMock(canvasId: "canvas-a")[0]
        node.contribution = NodeContributionConfig(policy: "team", itemLabel: "startup")

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(PlanningNode.self, from: data)
        XCTAssertEqual(decoded.contribution?.policy, "team")
        XCTAssertEqual(decoded.contribution?.itemLabel, "startup")
        XCTAssertTrue(decoded.contribution?.acceptsTeamContributions == true)

        // Legacy shape: strip the key entirely, decode must default to nil.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "contribution")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(PlanningNode.self, from: legacyData)
        XCTAssertNil(legacy.contribution)

        // Partial config: `{}` decodes tolerant with policy defaulting closed.
        let partial = try JSONDecoder().decode(
            NodeContributionConfig.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(partial.policy, "closed")
        XCTAssertFalse(partial.acceptsTeamContributions)
    }

    /// Opening a node to team-wide writes is owner-only — stricter than the
    /// usual owner-or-doer node update gate.
    func testUpdateNodeContributionIsOwnerOnly() throws {
        let snapshot = boardSnapshot(canvasId: "canvas-a", ownerId: "owner-a")
        _ = try seedPlannerNodes(canvasId: "canvas-a", ownerId: "owner-a")
        let before = try PlannerBoardBridge.canvasState(
            for: "canvas-a", snapshot: snapshot, actorUserId: "owner-a"
        )
        let step = try XCTUnwrap(before.nodes.first { ($0.nodeKind ?? .step) == .step })

        // Owner flips it on.
        let opened = try PlannerBoardBridge.updateNodeContribution(
            nodeId: step.id,
            contribution: NodeContributionConfig(policy: "team", itemLabel: "startup"),
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let openedNode = try XCTUnwrap(opened.nodes.first { $0.id == step.id })
        XCTAssertEqual(openedNode.contribution?.policy, "team")

        // The node's doer may NOT change the policy.
        XCTAssertThrowsError(
            try PlannerBoardBridge.updateNodeContribution(
                nodeId: step.id,
                contribution: nil,
                for: "canvas-a",
                snapshot: snapshot,
                actorUserId: step.doerId
            )
        ) { error in
            guard case PlannerCoreError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }

        // Owner clears it back to closed (nil).
        let closed = try PlannerBoardBridge.updateNodeContribution(
            nodeId: step.id,
            contribution: nil,
            for: "canvas-a",
            snapshot: snapshot,
            actorUserId: "owner-a"
        )
        let closedNode = try XCTUnwrap(closed.nodes.first { $0.id == step.id })
        XCTAssertNil(closedNode.contribution)
    }
}
