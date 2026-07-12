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
            plannerContext: plannerContext ?? "template:\(template.id)"
        )
        let seedNodes = CanvasTemplateRegistry.materializeNodes(
            template: template,
            canvasId: canvasId,
            ownerId: ownerId
        )
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [])
        return try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: seedNodes)
    }

    func testCodingOrchestrationIsRegistered() {
        let template = CanvasTemplateRegistry.get("coding-orchestration")
        XCTAssertNotNil(template, "coding-orchestration must be registered in CanvasTemplateRegistry.all")
        XCTAssertEqual(template?.category, "engineering")
        XCTAssertEqual(template?.defaultNodes.count, 5)
        XCTAssertEqual(
            CanvasTemplateRegistry.all.map(\.id),
            ["coding-orchestration"],
            "the official catalog should expose only the production-ready template"
        )
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
    }
}
