import XCTest
@testable import meee2Kit

final class ClaudeWorkflowInterceptionServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var plannerStoreURL: URL!
    private var createdCanvasIds: [String] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-workflow-interception-tests-\(UUID().uuidString)")
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

    func testKnownWorkflowCommandInAskModeRequiresSecondPromptBeforeCreatingCanvas() throws {
        let service = try makeService(mode: .ask, workflowName: "prd-review")
        let canvasCountBefore = BoardLayoutStore.shared.snapshot().canvases.count

        let outcome = service.intercept(
            sessionId: "claude-session-a",
            cwd: tempRoot.path,
            rawPrompt: " /prd-review --ticket M2-42 "
        )

        guard case let .confirmationRequired(_, commandName, meee2Prompt, claudePrompt) = outcome else {
            return XCTFail("expected confirmationRequired, got \(outcome)")
        }
        XCTAssertEqual(commandName, "/prd-review")
        XCTAssertEqual(meee2Prompt, "/prd-review --ticket M2-42 --meee2")
        XCTAssertEqual(claudePrompt, "/prd-review --ticket M2-42 --claude")
        XCTAssertEqual(BoardLayoutStore.shared.snapshot().canvases.count, canvasCountBefore)
    }

    func testConfirmedMeee2PromptImportsCanvasAndStartsRunInAskMode() throws {
        let service = try makeService(mode: .ask, workflowName: "prd-review")

        let outcome = service.intercept(
            sessionId: "claude-session-a",
            cwd: tempRoot.path,
            rawPrompt: " /prd-review --ticket M2-42 --meee2 "
        )

        guard case let .intercepted(canvasId, _, commandName, canvasName, mode, reused, runId) = outcome else {
            return XCTFail("expected interception, got \(outcome)")
        }
        createdCanvasIds.append(canvasId)
        XCTAssertEqual(commandName, "/prd-review")
        XCTAssertEqual(canvasName, "prd-review")
        XCTAssertEqual(mode, .ask)
        XCTAssertFalse(reused)
        XCTAssertNotNil(runId)

        let snapshot = BoardLayoutStore.shared.snapshot()
        XCTAssertEqual(snapshot.activeCanvasId, canvasId)
        let graph = try PlannerBoardBridge.graphState(for: canvasId, snapshot: snapshot)
        XCTAssertEqual(graph.canvas.plannerContext, "claude-workflow:\(tempRoot.appendingPathComponent("config/workflows/prd-review.js").path)")
        XCTAssertTrue(graph.nodes.contains { $0.dispatch?.command == "/prd-review" })
        let runs = try PlannerBoardBridge.runs(for: canvasId, snapshot: snapshot)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.summary, "Imported from Claude Code workflow command: /prd-review --ticket M2-42")
    }

    func testUnknownSlashCommandAndNaturalLanguageAreIgnored() throws {
        let service = try makeService(mode: .ask, workflowName: "ship-feature")

        XCTAssertEqual(
            service.intercept(sessionId: "sid", cwd: tempRoot.path, rawPrompt: "/foo"),
            .ignored
        )
        XCTAssertEqual(
            service.intercept(sessionId: "sid", cwd: tempRoot.path, rawPrompt: "please ship this feature"),
            .ignored
        )
        XCTAssertEqual(
            service.intercept(sessionId: "sid", cwd: tempRoot.path, rawPrompt: "/ship-feature-extra"),
            .ignored
        )
        XCTAssertEqual(
            service.intercept(sessionId: "sid", cwd: tempRoot.path, rawPrompt: "/ship-feature --claude"),
            .ignored
        )
        XCTAssertEqual(
            service.intercept(sessionId: "sid", cwd: tempRoot.path, rawPrompt: "please ship this feature"),
            .ignored
        )
    }

    func testNativeWorkflowPromptRequiresConfirmationBeforeCreatingCanvas() throws {
        let service = try makeService(mode: .ask, workflowName: "ship-feature")

        let outcome = service.intercept(
            sessionId: "sid-native",
            cwd: tempRoot.path,
            rawPrompt: "workflow explore last five commits"
        )

        guard case let .confirmationRequired(_, commandName, meee2Prompt, claudePrompt) = outcome else {
            return XCTFail("expected native workflow confirmation, got \(outcome)")
        }
        XCTAssertEqual(commandName, "workflow explore last five commits")
        XCTAssertEqual(meee2Prompt, "workflow explore last five commits --meee2")
        XCTAssertEqual(claudePrompt, "workflow explore last five commits --claude")
        XCTAssertFalse(BoardLayoutStore.shared.snapshot().canvases.contains { $0.name == "Workflow: explore last five commits" })
    }

    func testConfirmedNativeWorkflowPromptCreatesCanvasAndStartsRun() throws {
        let service = try makeService(mode: .ask, workflowName: "ship-feature")

        let outcome = service.intercept(
            sessionId: "sid-native",
            cwd: tempRoot.path,
            rawPrompt: "workflow explore last five commits --meee2"
        )

        guard case let .intercepted(canvasId, workflowId, commandName, canvasName, mode, reused, runId) = outcome else {
            return XCTFail("expected native workflow interception, got \(outcome)")
        }
        createdCanvasIds.append(canvasId)
        XCTAssertTrue(workflowId.hasPrefix("native:"))
        XCTAssertEqual(commandName, "workflow explore last five commits")
        XCTAssertEqual(canvasName, "Workflow: explore last five commits")
        XCTAssertEqual(mode, .ask)
        XCTAssertFalse(reused)
        XCTAssertNotNil(runId)

        let snapshot = BoardLayoutStore.shared.snapshot()
        let graph = try PlannerBoardBridge.graphState(for: canvasId, snapshot: snapshot)
        XCTAssertEqual(graph.canvas.plannerContext, "claude-native-workflow:explore last five commits")
        XCTAssertEqual(graph.nodes.map(\.title), ["Run workflow"])
        XCTAssertTrue(graph.nodes.contains { $0.dispatch?.command == "workflow explore last five commits" })
        let runs = try PlannerBoardBridge.runs(for: canvasId, snapshot: snapshot)
        XCTAssertEqual(runs.first?.summary, "Imported from Claude Code workflow command: workflow explore last five commits")
    }

    func testNativeWorkflowClaudeConfirmationIsIgnored() throws {
        let service = try makeService(mode: .ask, workflowName: "ship-feature")

        XCTAssertEqual(
            service.intercept(sessionId: "sid-native", cwd: tempRoot.path, rawPrompt: "workflow explore last five commits --claude"),
            .ignored
        )
    }

    func testDuplicateTriggerReusesCanvas() throws {
        let service = try makeService(mode: .ask, workflowName: "ship-feature")
        let prompt = "  /ship-feature   --dry-run --meee2  "

        let first = service.intercept(sessionId: "sid-dup", cwd: tempRoot.path, rawPrompt: prompt)
        guard case let .intercepted(firstCanvasId, _, _, _, _, firstReused, _) = first else {
            return XCTFail("expected first interception")
        }
        createdCanvasIds.append(firstCanvasId)
        XCTAssertFalse(firstReused)

        let second = service.intercept(sessionId: "sid-dup", cwd: tempRoot.path, rawPrompt: prompt)
        guard case let .intercepted(secondCanvasId, _, _, _, _, secondReused, _) = second else {
            return XCTFail("expected second interception")
        }
        XCTAssertEqual(secondCanvasId, firstCanvasId)
        XCTAssertTrue(secondReused)
    }

    func testAutoModeStartsPlannerRun() throws {
        let service = try makeService(mode: .auto, workflowName: "release-check")

        let outcome = service.intercept(
            sessionId: "sid-auto",
            cwd: tempRoot.path,
            rawPrompt: "/release-check --smoke"
        )

        guard case let .intercepted(canvasId, _, commandName, _, mode, _, runId) = outcome else {
            return XCTFail("expected interception, got \(outcome)")
        }
        createdCanvasIds.append(canvasId)
        XCTAssertEqual(commandName, "/release-check")
        XCTAssertEqual(mode, .auto)
        XCTAssertNotNil(runId)

        let snapshot = BoardLayoutStore.shared.snapshot()
        let runs = try PlannerBoardBridge.runs(for: canvasId, snapshot: snapshot)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.title, "Claude workflow /release-check")
        XCTAssertEqual(runs.first?.summary, "Imported from Claude Code workflow command: /release-check --smoke")
    }

    func testControlResponseBlocksUserPromptSubmitForKnownCommand() throws {
        let service = try makeService(mode: .ask, workflowName: "prd-review")
        let canvasCountBefore = BoardLayoutStore.shared.snapshot().canvases.count
        let raw = #"{"hook_event_name":"UserPromptSubmit","session_id":"sid-response","cwd":"\#(tempRoot.path)","prompt":"/prd-review"}"#
        let event = HookEvent(
            event: .userPromptSubmit,
            sessionId: "sid-response",
            cwd: tempRoot.path,
            rawData: raw
        )

        let response = service.controlResponse(for: event)

        XCTAssertEqual(response?.decision, "block")
        XCTAssertTrue(response?.reason?.contains("prd-review") == true)
        XCTAssertTrue(response?.reason?.contains("--meee2") == true)
        XCTAssertTrue(response?.reason?.contains("--claude") == true)
        XCTAssertEqual(BoardLayoutStore.shared.snapshot().canvases.count, canvasCountBefore)
    }

    private func makeService(mode: ClaudeWorkflowCanvasMode, workflowName: String) throws -> ClaudeWorkflowInterceptionService {
        let configDir = tempRoot.appendingPathComponent("config")
        try writeWorkflow(root: configDir, name: workflowName)
        let library = ClaudeWorkflowLibrary(environment: { ["CLAUDE_CONFIG_DIR": configDir.path] })
        return ClaudeWorkflowInterceptionService(
            library: library,
            importer: ClaudeWorkflowImporter(
                library: library,
                generator: FailingWorkflowGenerator(),
                store: PlannerBoardBridge.store
            ),
            modeProvider: { mode },
            broadcaster: {},
            boardOpener: { _ in }
        )
    }

    private func writeWorkflow(root: URL, name: String) throws {
        let workflows = root.appendingPathComponent("workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try """
        export const meta = {
          name: '\(name)',
          phases: [
            { title: 'Prepare', detail: 'Prepare \(name)' },
            { title: 'Execute', detail: 'Execute \(name)' }
          ]
        }
        export default async () => {}
        """.write(to: workflows.appendingPathComponent("\(name).js"), atomically: true, encoding: .utf8)
    }
}

private struct FailingWorkflowGenerator: ClaudeWorkflowNodeDraftGenerating {
    func generatePlan(workflow: ClaudeWorkflowFile, source: String) throws -> ClaudeWorkflowImportPlan {
        throw ClaudeWorkflowLibraryError.aiParseFailed("should not be called for metadata phases")
    }
}
