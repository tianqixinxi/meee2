import XCTest
@testable import meee2Kit

final class ClaudeWorkflowLibraryTests: XCTestCase {
    private var tempRoot: URL!
    private var plannerStoreURL: URL!
    private var createdCanvasIds: [String] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-workflow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        plannerStoreURL = tempRoot.appendingPathComponent("planner-canvases.json")
        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
    }

    override func tearDownWithError() throws {
        PlannerBoardBridge.store = PlannerStore.shared
        for canvasId in createdCanvasIds {
            _ = try? BoardLayoutStore.shared.deleteCanvas(id: canvasId)
        }
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        plannerStoreURL = nil
        createdCanvasIds = []
    }

    func testConfigDirWorkflowsOverrideHomeClaudeWorkflows() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        let homeDir = tempRoot.appendingPathComponent("home")
        try writeWorkflow(root: configDir, name: "global-demo", source: "export default async () => {}")
        try writeWorkflow(root: homeDir.appendingPathComponent(".claude"), name: "home-demo", source: "export default async () => {}")

        let library = ClaudeWorkflowLibrary(
            environment: { ["CLAUDE_CONFIG_DIR": configDir.path] },
            homeDirectory: { homeDir }
        )

        let scan = library.scan()
        XCTAssertEqual(scan.root.path, configDir.appendingPathComponent("workflows").path)
        XCTAssertEqual(scan.workflows.map(\.name), ["global-demo"])
    }

    func testScanIgnoresNonJSAndNonRecursiveFiles() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(root: configDir, name: "importable", source: "export default async () => {}")
        let workflows = configDir.appendingPathComponent("workflows")
        try "nope".write(to: workflows.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: workflows.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "nested".write(to: workflows.appendingPathComponent("nested/hidden.js"), atomically: true, encoding: .utf8)

        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })

        XCTAssertEqual(library.scan().workflows.map(\.name), ["importable"])
    }

    func testMissingAndEmptyDirectoriesReturnStableEmptyList() throws {
        let configDir = tempRoot.appendingPathComponent("missing")
        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        XCTAssertEqual(library.scan().workflows, [])

        try FileManager.default.createDirectory(at: configDir.appendingPathComponent("workflows"), withIntermediateDirectories: true)
        XCTAssertEqual(library.scan().workflows, [])
    }

    func testTooLargeWorkflowIsListedButNotReadable() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        let source = String(repeating: "x", count: ClaudeWorkflowLibrary.maxSourceBytes + 1)
        try writeWorkflow(root: configDir, name: "too-large", source: source)

        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        let workflow = try XCTUnwrap(library.scan().workflows.first)

        XCTAssertFalse(workflow.readable)
        XCTAssertThrowsError(try library.readSource(workflow)) { error in
            XCTAssertTrue(error.localizedDescription.contains("readable") || error.localizedDescription.contains("exceeds"))
        }
    }

    func testScanExtractsWorkflowMetadata() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(
            root: configDir,
            name: "filename-fallback",
            source: """
            export const meta = {
              name: 'inspect-meee2-modules',
              description: 'Explore the meee2 repo and summarize main modules',
              phases: [
                { title: 'Scan structure', detail: 'identify top-level modules and their roles' },
                { title: 'Deep-dive services', detail: 'analyze core runtime services' },
                { title: 'Summarize', detail: 'synthesize module overview' }
              ]
            }
            phase('Ignored when meta phases exist')
            """
        )

        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        let workflow = try XCTUnwrap(library.scan().workflows.first)

        XCTAssertEqual(workflow.name, "inspect-meee2-modules")
        XCTAssertEqual(workflow.commandName, "/inspect-meee2-modules")
        XCTAssertEqual(workflow.description, "Explore the meee2 repo and summarize main modules")
        XCTAssertEqual(workflow.phases.map(\.title), ["Scan structure", "Deep-dive services", "Summarize"])
        XCTAssertEqual(workflow.phases[0].detail, "identify top-level modules and their roles")
    }

    func testScanFallsBackToPhaseCallsWithoutMetaPhases() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(
            root: configDir,
            name: "phase-calls",
            source: """
            export const meta = { name: 'phase-calls', description: 'Uses phase calls' }
            phase('Collect context')
            phase("Write report")
            """
        )

        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        let workflow = try XCTUnwrap(library.scan().workflows.first)

        XCTAssertEqual(workflow.description, "Uses phase calls")
        XCTAssertEqual(workflow.phases.map(\.title), ["Collect context", "Write report"])
    }

    func testImportFallsBackWithoutExecutingWorkflowSource() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(
            root: configDir,
            name: "dangerous",
            source: """
            import fs from 'node:fs'
            fs.writeFileSync('\(tempRoot.appendingPathComponent("should-not-exist").path)', 'executed')
            export default async () => {}
            """
        )
        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        let workflow = try XCTUnwrap(library.scan().workflows.first)
        let importer = ClaudeWorkflowImporter(
            library: library,
            generator: FailingGenerator(),
            store: PlannerBoardBridge.store
        )

        let snapshot = try importer.importWorkflow(id: workflow.id, name: nil, scope: .personal)
        createdCanvasIds.append(snapshot.activeCanvasId)
        let graph = try PlannerBoardBridge.graphState(for: snapshot.activeCanvasId, snapshot: snapshot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("should-not-exist").path))
        XCTAssertEqual(graph.nodes.map(\.title), ["Workflow source", "Review orchestration", "Run workflow node", "Collect report"])
        XCTAssertTrue(graph.nodes.contains { $0.blockedReason?.contains("AI parse failed") == true })
    }

    func testImportUsesMetadataPhasesWithoutAI() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(
            root: configDir,
            name: "structured",
            source: """
            export const meta = {
              name: 'structured-workflow',
              description: 'Workflow with explicit phases',
              phases: [
                { title: 'Scan structure', detail: 'identify top-level modules' },
                { title: 'Deep-dive services', detail: 'analyze runtime services' },
                { title: 'Summarize', detail: 'write final overview' }
              ]
            }
            export default async () => {}
            """
        )
        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        let workflow = try XCTUnwrap(library.scan().workflows.first)
        let importer = ClaudeWorkflowImporter(
            library: library,
            generator: FailingGenerator(),
            store: PlannerBoardBridge.store
        )

        let snapshot = try importer.importWorkflow(id: workflow.id, name: nil, scope: .personal)
        createdCanvasIds.append(snapshot.activeCanvasId)
        let graph = try PlannerBoardBridge.graphState(for: snapshot.activeCanvasId, snapshot: snapshot)

        XCTAssertEqual(graph.canvas.title, "structured-workflow")
        XCTAssertEqual(graph.nodes.map(\.title), ["Scan structure", "Deep-dive services", "Summarize"])
        XCTAssertEqual(graph.nodes[0].schema.goal, "identify top-level modules")
        XCTAssertEqual(graph.nodes[0].executorType, .claude)
        XCTAssertEqual(graph.nodes[1].dependsOnNodeIds, [graph.nodes[0].id])
        XCTAssertEqual(graph.nodes[2].dependsOnNodeIds, [graph.nodes[1].id])
    }

    func testUploadedWorkflowFallsBackWithoutExecutingSource() throws {
        let marker = tempRoot.appendingPathComponent("uploaded-should-not-exist")
        let source = """
        import fs from 'node:fs'
        fs.writeFileSync('\(marker.path)', 'executed')
        export default async () => {}
        """
        let importer = ClaudeWorkflowImporter(
            library: ClaudeWorkflowLibrary(environment: { [:] }),
            generator: FailingGenerator(),
            store: PlannerBoardBridge.store
        )

        let snapshot = try importer.importUploadedWorkflow(
            filename: "uploaded-research.js",
            source: source,
            name: nil,
            scope: .personal
        )
        createdCanvasIds.append(snapshot.activeCanvasId)
        let graph = try PlannerBoardBridge.graphState(for: snapshot.activeCanvasId, snapshot: snapshot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(graph.canvas.title, "uploaded-research")
        XCTAssertEqual(graph.nodes.map(\.title), ["Workflow source", "Review orchestration", "Run workflow node", "Collect report"])
        XCTAssertTrue(graph.nodes[0].contextSources.contains { $0.reference == "uploaded:uploaded-research.js" })
    }

    func testUploadedWorkflowRejectsNonJSFile() throws {
        let importer = ClaudeWorkflowImporter(
            library: ClaudeWorkflowLibrary(environment: { [:] }),
            generator: FailingGenerator(),
            store: PlannerBoardBridge.store
        )

        XCTAssertThrowsError(try importer.importUploadedWorkflow(
            filename: "notes.md",
            source: "export default async () => {}",
            name: nil,
            scope: .personal
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(".js"))
        }
    }

    func testImportMaterializesAIGeneratedNodes() throws {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(root: configDir, name: "research", source: "export default async () => {}")
        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        let workflow = try XCTUnwrap(library.scan().workflows.first)
        let importer = ClaudeWorkflowImporter(
            library: library,
            generator: StaticGenerator(plan: ClaudeWorkflowImportPlan(
                summary: "Research flow",
                nodes: [
                    ClaudeWorkflowNodeDraft(title: "Plan research", goal: "Define the question", dependsOn: [], needsReview: false),
                    ClaudeWorkflowNodeDraft(title: "Collect sources", goal: "Gather evidence", dependsOn: [0], needsReview: false),
                    ClaudeWorkflowNodeDraft(title: "Review report", goal: "Human approves the report", dependsOn: [1], needsReview: true)
                ]
            )),
            store: PlannerBoardBridge.store
        )

        let snapshot = try importer.importWorkflow(id: workflow.id, name: "Imported research", scope: .personal)
        createdCanvasIds.append(snapshot.activeCanvasId)
        let graph = try PlannerBoardBridge.graphState(for: snapshot.activeCanvasId, snapshot: snapshot)

        XCTAssertEqual(graph.canvas.title, "Imported research")
        XCTAssertEqual(graph.nodes.map(\.title), ["Plan research", "Collect sources", "Review report"])
        XCTAssertEqual(graph.nodes[0].executionMode, .auto)
        XCTAssertEqual(graph.nodes[0].executorType, .claude)
        XCTAssertEqual(graph.nodes[2].executionMode, .human)
        XCTAssertEqual(graph.nodes[1].dependsOnNodeIds, [graph.nodes[0].id])
    }

    private func writeWorkflow(root: URL, name: String, source: String) throws {
        let workflows = root.appendingPathComponent("workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try source.write(to: workflows.appendingPathComponent("\(name).js"), atomically: true, encoding: .utf8)
    }
}

private struct FailingGenerator: ClaudeWorkflowNodeDraftGenerating {
    func generatePlan(workflow: ClaudeWorkflowFile, source: String) throws -> ClaudeWorkflowImportPlan {
        throw ClaudeWorkflowLibraryError.aiParseFailed("test failure")
    }
}

private struct StaticGenerator: ClaudeWorkflowNodeDraftGenerating {
    let plan: ClaudeWorkflowImportPlan

    func generatePlan(workflow: ClaudeWorkflowFile, source: String) throws -> ClaudeWorkflowImportPlan {
        plan
    }
}
