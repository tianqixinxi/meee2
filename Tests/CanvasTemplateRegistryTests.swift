import XCTest
@testable import meee2Kit

/// Coverage for the canvas-template seed path, focused on the
/// `coding-orchestration` orchestration template: dependency edges, executor /
/// execution-mode, and the schema fields `materializeNodes` now threads through.
final class CanvasTemplateRegistryTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-template-tests-\(UUID().uuidString)")
            .appendingPathComponent("planner-canvases.json")
        PlannerBoardBridge.store = PlannerStore(fileURL: storeURL)
    }

    override func tearDownWithError() throws {
        PlannerBoardBridge.store = PlannerStore.shared
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        storeURL = nil
    }

    /// Run the same seed path `applyOfficialCanvasTemplate` uses: record the
    /// canvas, then `seedNodesIfEmpty` (which now reconciles dependency edges).
    private func seedTemplate(
        _ template: CanvasTemplate,
        canvasId: String,
        ownerId: String,
        plannerContext: String? = nil
    ) throws -> PlannerStore.CanvasRecord {
        let canvas = PlanningCanvas(
            id: canvasId,
            ownerId: ownerId,
            title: template.name,
            plannerContext: plannerContext ?? "template:\(template.id)",
            sceneSpec: CanvasTemplateRegistry.materializeSceneSpec(
                template: template,
                canvasId: canvasId
            )
        )
        let seedNodes = CanvasTemplateRegistry.materializeNodes(
            template: template,
            canvasId: canvasId,
            ownerId: ownerId
        )
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [])
        let record = try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: seedNodes)
        try PlannerBoardBridge.store.writeRenderProfile(
            CanvasTemplateRegistry.materializeRenderProfile(template: template, canvasId: canvasId),
            canvasId: canvasId
        )
        try PlannerBoardBridge.store.writeOrchestrationProfile(
            CanvasTemplateRegistry.materializeOrchestrationProfile(template: template, canvasId: canvasId),
            canvasId: canvasId
        )
        return record
    }

    func testCodingOrchestrationIsRegistered() {
        let template = CanvasTemplateRegistry.get("coding-orchestration")
        XCTAssertNotNil(template, "coding-orchestration must be registered in CanvasTemplateRegistry.all")
        XCTAssertEqual(template?.category, "engineering")
        XCTAssertEqual(template?.defaultNodes.count, 5)
        XCTAssertTrue(
            CanvasTemplateRegistry.all.contains { $0.id == "coding-orchestration" },
            "must appear in the catalog that backs GET /api/templates"
        )
    }

    func testSceneTemplatesAreRegistered() {
        let travel = CanvasTemplateRegistry.get("travel-squad")
        XCTAssertNotNil(travel, "travel-squad must be registered")
        XCTAssertEqual(travel?.sceneSpec?.kind, "travel-squad")
        XCTAssertEqual(travel?.defaultNodes.count, 5)

        let poker = CanvasTemplateRegistry.get("poker-table")
        XCTAssertNotNil(poker, "poker-table must be registered")
        XCTAssertEqual(poker?.sceneSpec?.kind, "poker-table")
        XCTAssertEqual(poker?.defaultNodes.count, 5)
    }

    func testSceneTemplatesMaterializeRenderProfiles() throws {
        let travel = try XCTUnwrap(CanvasTemplateRegistry.get("travel-squad"))
        let travelProfile = CanvasTemplateRegistry.materializeRenderProfile(template: travel, canvasId: "travel-canvas")
        XCTAssertEqual(travelProfile.logic.layout, .spatial)
        XCTAssertTrue(travelProfile.values.renderOnlyObjects.contains { object in
            object.id == "scene:travel-squad:background"
        })
        XCTAssertTrue(travelProfile.logic.actions.contains { $0.id == "scene-action:replan-route" })
        XCTAssertNotNil(travelProfile.values.objects["node:travel-canvas-travel-squad-0"])

        let poker = try XCTUnwrap(CanvasTemplateRegistry.get("poker-table"))
        let pokerProfile = CanvasTemplateRegistry.materializeRenderProfile(template: poker, canvasId: "poker-canvas")
        XCTAssertEqual(pokerProfile.logic.layout, .spatial)
        XCTAssertTrue(pokerProfile.values.renderOnlyObjects.contains { object in
            object.metadata != nil && object.id == "scene:poker-table:background"
        })
        XCTAssertTrue(pokerProfile.logic.actions.contains { $0.id == "scene-action:start-game" })
        XCTAssertEqual(pokerProfile.values.objects["node:poker-canvas-poker-table-0"]?.rendererVariant, nil)
    }

    func testTravelSquadMaterializesSceneAnchorsAndInitialState() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("travel-squad"))
        let canvasId = "canvas-travel-\(UUID().uuidString)"
        let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")
        let scene = try XCTUnwrap(record.canvas.sceneSpec)

        XCTAssertEqual(scene.kind, "travel-squad")
        XCTAssertEqual(record.nodes.count, 5)
        XCTAssertNotNil(scene.initialState)
        XCTAssertTrue(scene.nodeAnchors.allSatisfy { $0.nodeId.hasPrefix("\(canvasId)-travel-squad-") })
        XCTAssertTrue(scene.actions.allSatisfy { $0.nodeId.hasPrefix("\(canvasId)-travel-squad-") })
        XCTAssertTrue(scene.artifactBindings.contains { $0.reference == "itinerary.json" })
        let render = try PlannerBoardBridge.store.renderProfileState(canvasId: canvasId)
        XCTAssertEqual(render.status.state, .valid)
        XCTAssertEqual(render.profile.logic.layout, .spatial)
        let orchestration = try PlannerBoardBridge.store.orchestrationProfileState(canvasId: canvasId)
        XCTAssertEqual(orchestration.profile.kind, .workflowGraphV1)
    }

    func testPokerTableMaterializesSceneAnchorsAndInitialState() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("poker-table"))
        let canvasId = "canvas-poker-\(UUID().uuidString)"
        let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")
        let scene = try XCTUnwrap(record.canvas.sceneSpec)

        XCTAssertEqual(scene.kind, "poker-table")
        XCTAssertEqual(record.nodes.count, 5)
        XCTAssertNotNil(scene.initialState)
        XCTAssertTrue(scene.nodeAnchors.allSatisfy { $0.nodeId.hasPrefix("\(canvasId)-poker-table-") })
        XCTAssertTrue(scene.actions.contains { $0.id == "ask-ada" && $0.nodeId.hasSuffix("-1") })
        XCTAssertTrue(scene.actions.contains { $0.id == "ask-mina" && $0.nodeId.hasSuffix("-3") })
        XCTAssertEqual(scene.orchestration?.kind, "poker-rules-v1")
        XCTAssertEqual(scene.orchestration?.stateNodeId, record.nodes.first?.id)
        XCTAssertTrue(scene.artifactBindings.contains { $0.reference == "game-state.json" })
        let orchestration = try PlannerBoardBridge.store.orchestrationProfileState(canvasId: canvasId)
        XCTAssertEqual(orchestration.profile.kind, .pokerRulesV1)
        XCTAssertEqual(orchestration.profile.bindings.roleSlots["ada"], "\(canvasId)-poker-table-1")
        XCTAssertEqual(orchestration.profile.bindings.stateSlots["tableState"]?.reference, "game-state.json")
        XCTAssertTrue(orchestration.profile.bindings.actions.contains {
            $0.id == "ask-ada" && $0.capability == "request-player-action" && $0.targetRoleSlot == "ada"
        })
        let dealer = try XCTUnwrap(record.nodes.first { $0.title == "Dealer / Table State" })
        XCTAssertEqual(dealer.executionMode, .auto)
        XCTAssertEqual(dealer.executorType, .mock)
        XCTAssertNil(dealer.gate, "Dealer is a system state slot, not a human approval gate")
        XCTAssertEqual(dealer.schema.outputs, ["game-state.json", "action-log.json"])
        if case .object(let initial)? = scene.initialState,
           case .object(let setup)? = initial["setup"],
           case .bool(let started)? = setup["started"] {
            XCTAssertFalse(started)
        } else {
            XCTFail("poker scene initialState must include setup.started=false")
        }
        let gm = try XCTUnwrap(record.nodes.first { $0.title == "GM / 规则裁判" })
        XCTAssertEqual(gm.status, .ready)
        XCTAssertNil(gm.blockedReason, "GM starts as a ready human responsibility, not an initial fake blocker")
    }

    func testPokerStartGamePrimitivesWriteSystemDealerStateAndConfigureHumanPlayer() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("poker-table"))
        let canvasId = "canvas-poker-start-\(UUID().uuidString)"
        let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")
        let dealerId = try XCTUnwrap(record.canvas.sceneSpec?.orchestration?.stateNodeId)
        let adaId = try XCTUnwrap(record.canvas.sceneSpec?.nodeAnchors.first { $0.id == "ada" }?.nodeId)
        let brunoId = try XCTUnwrap(record.canvas.sceneSpec?.nodeAnchors.first { $0.id == "bruno" }?.nodeId)
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: canvasId, nodeId: adaId, executionMode: .human)
        _ = try PlannerBoardBridge.store.updateNodeGate(canvasId: canvasId, nodeId: brunoId, executionMode: .auto)
        let output = PlannerNodeOutput(
            nodeId: dealerId,
            status: .done,
            message: PlannerNodeOutputMessage(summary: "Rules Orchestrator started Poker Table", routeTo: []),
            artifacts: [
                PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "game-state.json",
                    reference: "game-state.json",
                    payload: .object([
                        "type": .string("json"),
                        "sceneState": .object([
                            "setup": .object([
                                "started": .bool(true),
                                "userRole": .string("player"),
                                "controlledPlayerId": .string("ada"),
                                "autoRun": .bool(true)
                            ])
                        ])
                    ]),
                    routeTo: []
                )
            ],
            next: .complete,
            forceNewVersion: true
        )
        _ = try PlannerBoardBridge.store.submitNodeOutput(
            canvasId: canvasId,
            nodeId: dealerId,
            output: output,
            submittedByKind: .system,
            submittedBy: "Rules Orchestrator"
        )

        let updated = try PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvasId)
        let ada = try XCTUnwrap(updated.nodes.first { $0.title == "Ada 玩家 Agent" })
        let bruno = try XCTUnwrap(updated.nodes.first { $0.title == "Bruno 玩家 Agent" })
        let gm = try XCTUnwrap(updated.nodes.first { $0.title == "GM / 规则裁判" })
        let dealer = try XCTUnwrap(updated.nodes.first { $0.title == "Dealer / Table State" })
        XCTAssertEqual(ada.executionMode, .human)
        XCTAssertEqual(bruno.executionMode, .auto)
        XCTAssertEqual(dealer.executionMode, .auto)
        XCTAssertEqual(dealer.status, .done)
        XCTAssertEqual(dealer.workflowRunState, .done)
        XCTAssertNil(dealer.gate)
        XCTAssertEqual(gm.executionMode, .human)
        XCTAssertTrue(updated.artifacts.contains { $0.nodeId == dealerId && $0.reference == "game-state.json" })
        let version = updated.artifactVersions.last { $0.nodeId == dealerId && $0.payloadRef == "game-state.json" }
        XCTAssertEqual(version?.submittedByKind, .system)
        if case .object(let payload)? = version?.payloadInline,
           case .object(let sceneState)? = payload["sceneState"],
           case .object(let setup)? = sceneState["setup"],
           case .bool(let started)? = setup["started"] {
            XCTAssertTrue(started)
        } else {
            XCTFail("system game-state artifact must carry sceneState.setup.started=true")
        }
    }

    func testSceneTemplateCanCarryAdaptationContextWithoutChangingSceneSpec() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("poker-table"))
        let canvasId = "canvas-poker-adapt-\(UUID().uuidString)"
        let record = try seedTemplate(
            template,
            canvasId: canvasId,
            ownerId: "owner-a",
            plannerContext: "template:poker-table\nadaptation:4 人德州扑克，有 Dealer、3 个玩家和 GM 审批。"
        )
        let scene = try XCTUnwrap(record.canvas.sceneSpec)

        XCTAssertEqual(record.canvas.plannerContext, "template:poker-table\nadaptation:4 人德州扑克，有 Dealer、3 个玩家和 GM 审批。")
        XCTAssertEqual(scene.kind, "poker-table")
        XCTAssertEqual(record.nodes.count, 5)
        XCTAssertTrue(scene.nodeAnchors.allSatisfy { $0.nodeId.hasPrefix("\(canvasId)-poker-table-") })
    }

    func testMissingOrchestrationProfileMigratesForWorkflowMonitorAndPoker() throws {
        let workflowCanvas = PlanningCanvas(id: "canvas-workflow-\(UUID().uuidString)", ownerId: "owner-a", title: "Workflow", plannerContext: "")
        _ = try PlannerBoardBridge.store.record(for: workflowCanvas, seedNodes: [])
        let workflow = try PlannerBoardBridge.store.orchestrationProfileState(canvasId: workflowCanvas.id)
        XCTAssertEqual(workflow.status.state, .missingMigrated)
        XCTAssertEqual(workflow.profile.kind, .workflowGraphV1)

        let monitorCanvas = PlanningCanvas(id: "canvas-monitor-\(UUID().uuidString)", ownerId: "owner-a", title: "Monitor", plannerContext: "")
        _ = try PlannerBoardBridge.store.record(for: monitorCanvas, seedNodes: [])
        let monitor = try PlannerBoardBridge.store.orchestrationProfileState(canvasId: monitorCanvas.id, canvasKind: .monitor)
        XCTAssertEqual(monitor.status.state, .missingMigrated)
        XCTAssertEqual(monitor.profile.kind, .monitorObserverV1)
        XCTAssertEqual(monitor.profile.policy["autoRun"], .bool(false))

        let template = try XCTUnwrap(CanvasTemplateRegistry.get("poker-table"))
        let pokerCanvasId = "canvas-poker-migrate-\(UUID().uuidString)"
        let poker = PlanningCanvas(
            id: pokerCanvasId,
            ownerId: "owner-a",
            title: "Poker",
            plannerContext: "",
            sceneSpec: CanvasTemplateRegistry.materializeSceneSpec(template: template, canvasId: pokerCanvasId)
        )
        _ = try PlannerBoardBridge.store.record(for: poker, seedNodes: CanvasTemplateRegistry.materializeNodes(template: template, canvasId: pokerCanvasId, ownerId: "owner-a"))
        let pokerProfile = try PlannerBoardBridge.store.orchestrationProfileState(canvasId: pokerCanvasId)
        XCTAssertEqual(pokerProfile.status.state, .missingMigrated)
        XCTAssertEqual(pokerProfile.profile.kind, .pokerRulesV1)
        XCTAssertEqual(pokerProfile.profile.bindings.roleSlots["gm"], "\(pokerCanvasId)-poker-table-4")
    }

    func testReplaceOrchestrationProfileRequiresApprovedProposal() throws {
        let canvasId = "canvas-orchestration-replace-\(UUID().uuidString)"
        let canvas = PlanningCanvas(id: canvasId, ownerId: "owner-a", title: "Workflow", plannerContext: "")
        let record = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [])
        let original = try PlannerBoardBridge.store.orchestrationProfileState(canvasId: canvasId).profile
        XCTAssertEqual(original.kind, .workflowGraphV1)

        var replacement = CanvasOrchestrationProfile.default(kind: .monitorObserverV1)
        replacement.policy = ["autoRun": .bool(false)]
        let proposal = PlanProposal(
            id: "replace-orchestration-profile",
            canvasId: canvasId,
            summary: "Replace orchestration profile",
            changes: [
                PlanChange(
                    kind: .replaceOrchestrationProfile,
                    node: nil,
                    nodeId: nil,
                    title: nil,
                    status: nil,
                    orchestrationProfile: replacement
                )
            ],
            status: .pending
        )
        _ = try PlannerBoardBridge.store.saveProposal(proposal, canvas: record.canvas, seedNodes: record.nodes)
        XCTAssertThrowsError(try PlannerBoardBridge.store.applyProposal(
            proposalId: proposal.id,
            canvasId: canvasId,
            service: PlannerCoreService()
        ))
        XCTAssertEqual(try PlannerBoardBridge.store.orchestrationProfileState(canvasId: canvasId).profile.kind, .workflowGraphV1)

        _ = try PlannerBoardBridge.store.approveProposal(proposalId: proposal.id, canvasId: canvasId)
        _ = try PlannerBoardBridge.store.applyProposal(
            proposalId: proposal.id,
            canvasId: canvasId,
            service: PlannerCoreService()
        )
        XCTAssertEqual(try PlannerBoardBridge.store.orchestrationProfileState(canvasId: canvasId).profile.kind, .monitorObserverV1)
    }

    func testCodingOrchestrationSeedsFiveAutoClaudeNodes() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("coding-orchestration"))
        let canvasId = "canvas-coding-\(UUID().uuidString)"
        let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")

        // 5 step nodes.
        XCTAssertEqual(record.nodes.count, 5)
        XCTAssertTrue(record.nodes.allSatisfy { ($0.nodeKind ?? .step) == .step })

        // ALL nodes auto + claude.
        XCTAssertTrue(record.nodes.allSatisfy { $0.executionMode == .auto },
                      "every orchestration node must be executionMode=.auto")
        XCTAssertTrue(record.nodes.allSatisfy { $0.executorType == .claude },
                      "every orchestration node must be executorType=.claude (the only wired auto path)")
    }

    func testCodingOrchestrationDependencyTopology() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("coding-orchestration"))
        let canvasId = "canvas-coding-\(UUID().uuidString)"
        let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")

        func node(_ index: Int) -> PlanningNode {
            let id = "\(canvasId)-coding-orchestration-\(index)"
            return record.nodes.first { $0.id == id }!
        }
        let main = node(0)        // 主 Agent · 需求拆分与派发
        let frontend = node(1)    // 前端实现
        let backend = node(2)     // 后端实现
        let refactor = node(3)    // 重构
        let integration = node(4) // 集成与验证

        // Entry node has no dependencies.
        XCTAssertTrue((main.dependsOnNodeIds ?? []).isEmpty, "主 Agent is the entry; no deps")

        // The 3 subs each depend on exactly the main agent.
        XCTAssertEqual(frontend.dependsOnNodeIds, [main.id])
        XCTAssertEqual(backend.dependsOnNodeIds, [main.id])
        XCTAssertEqual(refactor.dependsOnNodeIds, [main.id])

        // 集成 depends on all three subs (order-insensitive).
        XCTAssertEqual(
            Set(integration.dependsOnNodeIds ?? []),
            Set([frontend.id, backend.id, refactor.id]),
            "集成与验证 must depend on 前端/后端/重构"
        )

        // Schema inputs/outputs threaded through.
        XCTAssertEqual(Set(main.schema.outputs), Set(["frontend_spec", "backend_spec", "refactor_spec"]))
        XCTAssertEqual(frontend.schema.inputs, ["frontend_spec"])
        XCTAssertEqual(frontend.schema.outputs, ["frontend_pr"])
        XCTAssertEqual(integration.schema.outputs, ["integration_report"])
    }

    func testCodingOrchestrationDependencyEdgesPresentOnGraph() throws {
        let template = try XCTUnwrap(CanvasTemplateRegistry.get("coding-orchestration"))
        let canvasId = "canvas-coding-\(UUID().uuidString)"
        let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")

        func nid(_ index: Int) -> String { "\(canvasId)-coding-orchestration-\(index)" }
        let edges = record.canvas.edges

        // Exactly the 6 dependency edges: main→{1,2,3}, {1,2,3}→4.
        func hasDependencyEdge(from source: String, to target: String) -> Bool {
            edges.contains {
                $0.sourceRef.nodeId == source
                    && $0.targetRef.nodeId == target
                    && $0.edgeMode.mode == "dependency"
            }
        }
        XCTAssertTrue(hasDependencyEdge(from: nid(0), to: nid(1)), "主→前端 edge missing")
        XCTAssertTrue(hasDependencyEdge(from: nid(0), to: nid(2)), "主→后端 edge missing")
        XCTAssertTrue(hasDependencyEdge(from: nid(0), to: nid(3)), "主→重构 edge missing")
        XCTAssertTrue(hasDependencyEdge(from: nid(1), to: nid(4)), "前端→集成 edge missing")
        XCTAssertTrue(hasDependencyEdge(from: nid(2), to: nid(4)), "后端→集成 edge missing")
        XCTAssertTrue(hasDependencyEdge(from: nid(3), to: nid(4)), "重构→集成 edge missing")

        let dependencyEdges = edges.filter { $0.edgeMode.mode == "dependency" }
        XCTAssertEqual(dependencyEdges.count, 6, "exactly 6 dependency edges expected")
    }

    /// Back-compat: existing widget/standard templates must seed unchanged —
    /// human/human, no dependency edges.
    func testExistingTemplatesRemainHumanWithNoDependencyEdges() throws {
        for id in ["code-review", "release-checklist", "engineering-refactor", "npc-canvas"] {
            let template = try XCTUnwrap(CanvasTemplateRegistry.get(id))
            let canvasId = "canvas-\(id)-\(UUID().uuidString)"
            let record = try seedTemplate(template, canvasId: canvasId, ownerId: "owner-a")

            XCTAssertNil(record.canvas.sceneSpec, "\(id): must not gain a scene")
            XCTAssertTrue(record.nodes.allSatisfy { $0.executionMode == .human },
                          "\(id): nodes must stay executionMode=.human")
            XCTAssertTrue(record.nodes.allSatisfy { $0.executorType == .human },
                          "\(id): nodes must stay executorType=.human")
            XCTAssertTrue(record.nodes.allSatisfy { ($0.dependsOnNodeIds ?? []).isEmpty },
                          "\(id): nodes must have no declared dependencies")
            XCTAssertTrue(record.canvas.edges.filter { $0.edgeMode.mode == "dependency" }.isEmpty,
                          "\(id): must have no dependency edges")
        }
    }
}
