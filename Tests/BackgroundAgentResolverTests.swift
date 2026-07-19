import XCTest
@testable import meee2Kit

/// BackgroundAgentResolver 的 workflow kind 解析（PR: workflow-bridge canvas 化的止血层）。
///
/// 用真实形状的 transcript jsonl 字符串构造现场：
///   - Workflow tool_use → tool_result 启动确认 → 应识别为 running
///   - + <task-notification> completed → 应消失
///   - 无通知但最新 turn_duration.pendingWorkflowCount==0 → 次级信号判完成
///   - run 目录 mtime 判活（journal 长期静默、agent 文件才是心跳）
final class BackgroundAgentResolverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-agent-resolver-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - jsonl 行构造 helpers

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func workflowToolUseLine(toolId: String, ts: Date, name: String? = nil) -> String {
        var input: [String: Any] = ["scriptPath": "/tmp/some/workflow.mjs"]
        if let name { input["name"] = name }
        let obj: [String: Any] = [
            "type": "assistant",
            "timestamp": iso(ts),
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use", "id": toolId, "name": "Workflow", "input": input,
                ]],
            ],
        ]
        return jsonLine(obj)
    }

    private func workflowToolResultLine(
        toolId: String, taskId: String, ts: Date,
        summary: String = "Build the prototype",
        transcriptDir: String = "/tmp/nonexistent-wf-dir"
    ) -> String {
        let text = """
        Workflow launched in background. Task ID: \(taskId)
        Summary: \(summary)
        Transcript dir: \(transcriptDir)
        Script file: /tmp/some/workflow.mjs
        """
        let obj: [String: Any] = [
            "type": "user",
            "timestamp": iso(ts),
            "message": [
                "role": "user",
                "content": [[
                    "type": "tool_result", "tool_use_id": toolId,
                    "content": [["type": "text", "text": text]],
                ]],
            ],
        ]
        return jsonLine(obj)
    }

    private func taskNotificationLine(taskId: String, ts: Date, status: String = "completed") -> String {
        let text = "<task-notification><task-id>\(taskId)</task-id><status>\(status)</status></task-notification>"
        let obj: [String: Any] = [
            "type": "user",
            "timestamp": iso(ts),
            "message": ["role": "user", "content": text],
        ]
        return jsonLine(obj)
    }

    private func turnDurationLine(ts: Date, pendingWorkflowCount: Int?) -> String {
        var obj: [String: Any] = [
            "type": "system",
            "subtype": "turn_duration",
            "timestamp": iso(ts),
            "durationMs": 12345,
        ]
        if let pendingWorkflowCount { obj["pendingWorkflowCount"] = pendingWorkflowCount }
        return jsonLine(obj)
    }

    private func jsonLine(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func writeTranscript(_ lines: [String]) throws -> String {
        let path = tempDir.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    // MARK: - Tests

    func testWorkflowLaunchIsDetectedAsRunning() throws {
        let t0 = Date().addingTimeInterval(-60)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2)),
        ])
        let agents = BackgroundAgentResolver.resolve(transcriptPath: path)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].id, "wcob123")
        XCTAssertEqual(agents[0].kind, "workflow")
        XCTAssertEqual(agents[0].description, "Build the prototype")
        XCTAssertEqual(agents[0].outputPath, "/tmp/nonexistent-wf-dir")
    }

    func testWorkflowCompletionNotificationClearsIt() throws {
        let t0 = Date().addingTimeInterval(-120)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2)),
            taskNotificationLine(taskId: "wcob123", ts: t0.addingTimeInterval(90)),
        ])
        XCTAssertEqual(BackgroundAgentResolver.resolve(transcriptPath: path).count, 0)
    }

    func testTurnDurationZeroPendingActsAsCompletionFallback() throws {
        let t0 = Date().addingTimeInterval(-300)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2)),
            // 没有 task-notification（被 tail 窗口冲掉的场景），
            // 但之后一条 turn_duration 报 pendingWorkflowCount==0
            turnDurationLine(ts: t0.addingTimeInterval(200), pendingWorkflowCount: 0),
        ])
        XCTAssertEqual(BackgroundAgentResolver.resolve(transcriptPath: path).count, 0)
    }

    func testTurnDurationNonZeroPendingKeepsItRunning() throws {
        let t0 = Date().addingTimeInterval(-300)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2)),
            turnDurationLine(ts: t0.addingTimeInterval(200), pendingWorkflowCount: 1),
        ])
        let agents = BackgroundAgentResolver.resolve(transcriptPath: path)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].id, "wcob123")
    }

    func testTurnDurationBeforeLaunchDoesNotClear() throws {
        let t0 = Date().addingTimeInterval(-300)
        let path = try writeTranscript([
            // 上一轮 turn 的 pendingWorkflowCount==0 出现在 workflow 启动之前，不应误杀
            turnDurationLine(ts: t0.addingTimeInterval(-10), pendingWorkflowCount: 0),
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2)),
        ])
        XCTAssertEqual(BackgroundAgentResolver.resolve(transcriptPath: path).count, 1)
    }

    func testQuiescentRunDirPrunesWorkflow() throws {
        // 构造真实 run 目录：agent jsonl 的 mtime 拨旧到超过 idle 门限
        let runDir = tempDir.appendingPathComponent("wf_stale")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let agentFile = runDir.appendingPathComponent("agent-abc.jsonl")
        try "{}".write(to: agentFile, atomically: true, encoding: .utf8)
        let stale = Date().addingTimeInterval(-30 * 60)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: agentFile.path)

        let t0 = Date().addingTimeInterval(-40 * 60)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(
                toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2),
                transcriptDir: runDir.path
            ),
        ])
        XCTAssertEqual(BackgroundAgentResolver.resolve(transcriptPath: path).count, 0)
    }

    func testFreshRunDirKeepsWorkflowAlive() throws {
        let runDir = tempDir.appendingPathComponent("wf_fresh")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try "{}".write(to: runDir.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)

        let t0 = Date().addingTimeInterval(-40 * 60)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0),
            workflowToolResultLine(
                toolId: "toolu_1", taskId: "wcob123", ts: t0.addingTimeInterval(2),
                transcriptDir: runDir.path
            ),
        ])
        let agents = BackgroundAgentResolver.resolve(transcriptPath: path)
        XCTAssertEqual(agents.count, 1)
    }

    func testNamedWorkflowUsesNameAsFallbackDescriptionSource() throws {
        // named workflow：input.name 作 desc 初值，但 tool_result 的 Summary 行优先
        let t0 = Date().addingTimeInterval(-60)
        let path = try writeTranscript([
            workflowToolUseLine(toolId: "toolu_1", ts: t0, name: "review-changes"),
            workflowToolResultLine(
                toolId: "toolu_1", taskId: "wf9", ts: t0.addingTimeInterval(2),
                summary: "Review changed files across dimensions"
            ),
        ])
        let agents = BackgroundAgentResolver.resolve(transcriptPath: path)
        XCTAssertEqual(agents.first?.description, "Review changed files across dimensions")
    }
}
