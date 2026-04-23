import XCTest
@testable import meee2Kit

final class HookEventTests: XCTestCase {

    // MARK: - JSON Parsing

    func testParsePermissionRequest() throws {
        let json = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "abc-123",
            "tool_name": "Bash",
            "tool_use_id": "use-456",
            "permission": "Run command: ls -la",
            "cwd": "/tmp/test/project",
            "status": "waiting_for_approval"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.event, .permissionRequest)
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolUseId, "use-456")
        XCTAssertEqual(event.permission, "Run command: ls -la")
        XCTAssertEqual(event.status, "waiting_for_approval")
    }

    func testParsePostToolUse() throws {
        let json = """
        {
            "hook_event_name": "PostToolUse",
            "session_id": "abc-123",
            "tool_name": "Edit",
            "cwd": "/tmp/test"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.event, .postToolUse)
        XCTAssertEqual(event.toolName, "Edit")
    }

    func testParseStopEvent() throws {
        let json = """
        {
            "hook_event_name": "Stop",
            "session_id": "abc-123",
            "last_assistant_message": "Task completed successfully"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.event, .stop)
        XCTAssertEqual(event.lastAssistantMessage, "Task completed successfully")
    }

    func testParseSessionStartWithTerminalInfo() throws {
        let json = """
        {
            "hook_event_name": "SessionStart",
            "session_id": "sess-789",
            "cwd": "/tmp/test/project",
            "tty": "ttys001",
            "termProgram": "ghostty",
            "termBundleId": "com.mitchellh.ghostty"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.event, .sessionStart)
        XCTAssertEqual(event.tty, "ttys001")
        XCTAssertEqual(event.termProgram, "ghostty")
        XCTAssertEqual(event.termBundleId, "com.mitchellh.ghostty")
    }

    func testParseMinimalEvent() throws {
        let json = """
        {
            "hook_event_name": "Notification",
            "session_id": "x"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.event, .notification)
        XCTAssertNil(event.toolName)
        XCTAssertNil(event.permission)
        XCTAssertNil(event.tty)
    }

    func testParseMissingOptionalFields() throws {
        let json = """
        {
            "session_id": "abc"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: json.data(using: .utf8)!)
        XCTAssertNil(event.event)
        XCTAssertNil(event.toolName)
        XCTAssertNil(event.cwd)
    }

    // MARK: - Computed Properties

    func testExpectsResponse() {
        let permEvent = HookEvent(event: .permissionRequest, sessionId: "s", status: "waiting_for_approval")
        XCTAssertTrue(permEvent.expectsResponse)

        let toolEvent = HookEvent(event: .postToolUse, sessionId: "s")
        XCTAssertFalse(toolEvent.expectsResponse)

        let stopEvent = HookEvent(event: .stop, sessionId: "s")
        XCTAssertFalse(stopEvent.expectsResponse)
    }

    func testInferredStatus() {
        // preToolUse without status field → inferred from event type
        let preToolEvent = HookEvent(event: .preToolUse, sessionId: "s", toolName: "Bash")
        XCTAssertEqual(preToolEvent.inferredStatus, .thinking) // event-based fallback

        // permissionRequest with waiting_for_approval status → permissionRequired
        let permEvent = HookEvent(event: .permissionRequest, sessionId: "s", status: "waiting_for_approval")
        XCTAssertEqual(permEvent.inferredStatus, .permissionRequired)

        let compactEvent = HookEvent(event: .preCompact, sessionId: "s")
        XCTAssertEqual(compactEvent.inferredStatus, .compacting)

        let stopEvent = HookEvent(event: .stop, sessionId: "s")
        XCTAssertEqual(stopEvent.inferredStatus, .completed)

        let promptEvent = HookEvent(event: .userPromptSubmit, sessionId: "s")
        XCTAssertEqual(promptEvent.inferredStatus, .thinking)
    }

    func testShouldShowUrgentPanel() {
        // PermissionRequest → always urgent (regardless of status field)
        let urgent = HookEvent(event: .permissionRequest, sessionId: "s", status: "waiting_for_approval")
        XCTAssertTrue(urgent.shouldShowUrgentPanel)

        // PermissionRequest without status → still urgent
        let permNoStatus = HookEvent(event: .permissionRequest, sessionId: "s")
        XCTAssertTrue(permNoStatus.shouldShowUrgentPanel)

        // Non-permission event → not urgent
        let tool = HookEvent(event: .postToolUse, sessionId: "s")
        XCTAssertFalse(tool.shouldShowUrgentPanel)
    }
}
