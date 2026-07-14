import XCTest
@testable import meee2Kit

/// WorkflowBridgeRunService 的文件面逻辑：journal 增量 tail 驱动节点、
/// wf 目录发现（script 精确配对）。register/tick 的会话 spawn 侧不在单测
/// 范围（走端到端验收）。
final class WorkflowBridgeRunServiceTests: XCTestCase {

    private var tempDir: URL!
    private var plannerStoreURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfbridge-svc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        plannerStoreURL = tempDir.appendingPathComponent("planner-canvases.json")
        PlannerBoardBridge.store = PlannerStore(fileURL: plannerStoreURL)
    }

    override func tearDownWithError() throws {
        PlannerBoardBridge.store = PlannerStore.shared
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - helpers

    private func seedCanvas(runId: String) throws -> (canvasId: String, execNodeId: String) {
        let canvasId = "wfb-canvas-\(runId)"
        let execNodeId = "wfb-\(runId)-exec"
        let canvas = PlanningCanvas(
            id: canvasId, ownerId: "tester", title: "WF \(runId)",
            plannerContext: "workflow-bridge:\(runId)"
        )
        _ = try PlannerBoardBridge.store.record(for: canvas, seedNodes: [])
        _ = try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: [
            PlanningNode(
                id: execNodeId,
                canvasId: canvasId,
                title: "Relay 执行",
                schema: NodeSchema(inputs: [], outputs: [], goal: "test"),
                contextSources: [],
                executionMode: .auto,
                executorType: .claude,
                doerId: "tester",
                status: .ready,
                nodeKind: .step,
                workflowRunState: .dispatched
            ),
        ])
        return (canvasId, execNodeId)
    }

    private func makeHandle(runId: String, canvasId: String, execNodeId: String, wfDir: String) -> WorkflowBridgeRunService.RunHandle {
        WorkflowBridgeRunService.RunHandle(
            runId: runId,
            runDir: tempDir.appendingPathComponent("runs/\(runId)").path,
            canvasId: canvasId,
            canvasName: "WF \(runId)",
            originSessionId: nil,
            execNodeId: execNodeId,
            phaseNodeIds: [],
            surfaceSessionId: "surface-1",
            workflowName: "test-wf",
            workflowDescription: nil,
            relayCliSessionId: "cli-1",
            transcriptDir: nil,
            wfDir: wfDir,
            state: .running,
            lastEvent: "test",
            lastEventAt: Date(),
            registeredAt: Date()
        )
    }

    @discardableResult
    private func appendJournal(_ dir: URL, _ lines: [String]) throws -> URL {
        let journal = dir.appendingPathComponent("journal.jsonl")
        let payload = lines.map { $0 + "\n" }.joined()
        if FileManager.default.fileExists(atPath: journal.path) {
            let handle = try FileHandle(forWritingTo: journal)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload.data(using: .utf8)!)
        } else {
            try payload.write(to: journal, atomically: true, encoding: .utf8)
        }
        return journal
    }

    // MARK: - journal tail 驱动节点

    func testJournalStartedCreatesAgentNodeAndResultCompletesIt() throws {
        let runId = "run-a"
        let (canvasId, execNodeId) = try seedCanvas(runId: runId)
        let wfDir = tempDir.appendingPathComponent("wf_aaa")
        try FileManager.default.createDirectory(at: wfDir, withIntermediateDirectories: true)

        var handle = makeHandle(runId: runId, canvasId: canvasId, execNodeId: execNodeId, wfDir: wfDir.path)
        try appendJournal(wfDir, [
            #"{"type":"started","key":"v2:k1","agentId":"a111"}"#,
        ])
        WorkflowBridgeRunService.shared.tailJournal(&handle)

        var record = try PlannerBoardBridge.store.appendNodes(canvasId: canvasId, nodes: [])
        let agentNodeId = "wfb-\(runId)-agent-a111"
        var agentNode = record.nodes.first { $0.id == agentNodeId }
        XCTAssertNotNil(agentNode, "started 事件应动态创建 agent 镜像节点")
        XCTAssertEqual(agentNode?.workflowRunState, .running)
        XCTAssertEqual(agentNode?.nodeKind, .external)
        XCTAssertEqual(agentNode?.dependsOnNodeIds, [execNodeId])
        XCTAssertEqual(handle.agents["a111"]?.state, "running")

        // 增量：第二轮只消费新行；result 收官该节点并挂 artifact
        try appendJournal(wfDir, [
            #"{"type":"result","key":"v2:k1","agentId":"a111","result":"all done, wrote 3 files"}"#,
        ])
        WorkflowBridgeRunService.shared.tailJournal(&handle)

        record = try PlannerBoardBridge.store.appendNodes(canvasId: canvasId, nodes: [])
        agentNode = record.nodes.first { $0.id == agentNodeId }
        XCTAssertEqual(agentNode?.workflowRunState, .done)
        XCTAssertEqual(agentNode?.status, .done)
        XCTAssertEqual(handle.agents["a111"]?.state, "done")
        let artifact = record.artifacts.first { $0.nodeId == agentNodeId }
        XCTAssertNotNil(artifact, "result 应挂 checkResult artifact")
        XCTAssertEqual(artifact?.reference, "wfbridge://\(runId)/a111")
    }

    func testJournalResultWithoutStartedStillCreatesNode() throws {
        let runId = "run-b"
        let (canvasId, execNodeId) = try seedCanvas(runId: runId)
        let wfDir = tempDir.appendingPathComponent("wf_bbb")
        try FileManager.default.createDirectory(at: wfDir, withIntermediateDirectories: true)

        var handle = makeHandle(runId: runId, canvasId: canvasId, execNodeId: execNodeId, wfDir: wfDir.path)
        // started 丢失（tail 窗口外）——result 也要能补建节点后收官
        try appendJournal(wfDir, [
            #"{"type":"result","key":"v2:k9","agentId":"a999","result":"late"}"#,
        ])
        WorkflowBridgeRunService.shared.tailJournal(&handle)

        let record = try PlannerBoardBridge.store.appendNodes(canvasId: canvasId, nodes: [])
        let node = record.nodes.first { $0.id == "wfb-\(runId)-agent-a999" }
        XCTAssertEqual(node?.workflowRunState, .done)
    }

    func testJournalPartialLineIsDeferredToNextTick() throws {
        let runId = "run-c"
        let (canvasId, execNodeId) = try seedCanvas(runId: runId)
        let wfDir = tempDir.appendingPathComponent("wf_ccc")
        try FileManager.default.createDirectory(at: wfDir, withIntermediateDirectories: true)

        var handle = makeHandle(runId: runId, canvasId: canvasId, execNodeId: execNodeId, wfDir: wfDir.path)
        // 写入不带换行的半行——不应被消费，offset 停在行首
        let journal = wfDir.appendingPathComponent("journal.jsonl")
        try #"{"type":"started","key":"v2:k1","agent"#.write(to: journal, atomically: true, encoding: .utf8)
        WorkflowBridgeRunService.shared.tailJournal(&handle)
        XCTAssertEqual(handle.agents.count, 0)
        XCTAssertEqual(handle.journalOffset, 0)

        // 补齐该行 + 换行后，下一轮完整消费
        let fh = try FileHandle(forWritingTo: journal)
        try fh.seekToEnd()
        try fh.write(contentsOf: #"Id":"a222"}"#.data(using: .utf8)! + "\n".data(using: .utf8)!)
        try fh.close()
        WorkflowBridgeRunService.shared.tailJournal(&handle)
        XCTAssertEqual(handle.agents["a222"]?.state, "running")
    }

    // MARK: - wf 目录发现

    func testDiscoverWorkflowDirMatchesByScriptContent() throws {
        let transcriptDir = tempDir.appendingPathComponent("session-1")
        let wfRoot = transcriptDir.appendingPathComponent("subagents/workflows")
        let metaRoot = transcriptDir.appendingPathComponent("workflows")
        try FileManager.default.createDirectory(
            at: wfRoot.appendingPathComponent("wf_old"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: wfRoot.appendingPathComponent("wf_mine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaRoot, withIntermediateDirectories: true)

        let runDir = tempDir.appendingPathComponent("runs/run-d")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let script = "export const meta = { name: 'mine' }\nreturn 42\n"
        try script.write(
            to: runDir.appendingPathComponent("workflow.mjs"), atomically: true, encoding: .utf8)

        // 两个 wf 元数据：只有 wf_mine 的 script 与 runDir 的一致
        try JSONSerialization.data(withJSONObject: ["runId": "wf_old", "script": "something else"])
            .write(to: metaRoot.appendingPathComponent("wf_old.json"))
        try JSONSerialization.data(withJSONObject: ["runId": "wf_mine", "script": script])
            .write(to: metaRoot.appendingPathComponent("wf_mine.json"))

        let found = WorkflowBridgeRunService.shared.discoverWorkflowDir(
            transcriptDir: transcriptDir.path, runDir: runDir.path
        )
        XCTAssertEqual(found, wfRoot.appendingPathComponent("wf_mine").path)
    }

    func testDiscoverWorkflowDirSingleCandidateShortCircuits() throws {
        let transcriptDir = tempDir.appendingPathComponent("session-2")
        let wfRoot = transcriptDir.appendingPathComponent("subagents/workflows")
        try FileManager.default.createDirectory(
            at: wfRoot.appendingPathComponent("wf_only"), withIntermediateDirectories: true)
        let found = WorkflowBridgeRunService.shared.discoverWorkflowDir(
            transcriptDir: transcriptDir.path, runDir: "/nonexistent"
        )
        XCTAssertEqual(found, wfRoot.appendingPathComponent("wf_only").path)
    }
}
