import XCTest
@testable import meee2Kit
import Meee2PluginKit

final class SessionStoreContinuityTests: XCTestCase {
    func testRekeySessionPreservesContinuityFieldsAndSidecars() {
        let oldId = "continuity-old-\(UUID().uuidString)"
        let newId = "continuity-new-\(UUID().uuidString)"
        let store = SessionStore.shared

        defer {
            store.delete(oldId)
            store.delete(newId)
        }

        var original = SessionData(
            sessionId: oldId,
            project: "project-a",
            cwd: "/tmp/project-a",
            pid: 12345,
            ghosttyTerminalId: "ghostty-1",
            iTermSessionId: "iterm-1",
            appleTerminalSessionId: "apple-1",
            transcriptPath: "/tmp/transcript.jsonl",
            startedAt: Date(timeIntervalSince1970: 100),
            lastActivity: Date(timeIntervalSince1970: 200),
            status: .tooling,
            currentTool: "Bash",
            description: "user note",
            tasks: [SessionTask(id: "task-1", name: "Task", status: .inProgress)],
            currentTask: "working",
            terminalInfo: PluginTerminalInfo(
                tty: "ttys001",
                termProgram: "ghostty",
                termBundleId: "com.mitchellh.ghostty",
                cmuxSocketPath: nil,
                cmuxSurfaceId: nil
            ),
            usageStats: UsageStats(inputTokens: 1, outputTokens: 2),
            lastMessage: "last"
        )
        original.pendingPermissionTool = "Edit"
        original.pendingPermissionMessage = "Needs approval"
        original.providerResumeSessionId = "8db44e39-685d-47ab-bd0e-5e97386ded80"

        store.create(original)
        _ = store.enqueue(oldId, message: "queued")
        store.setUnread(oldId, type: "message", message: "unread")

        XCTAssertTrue(store.rekeySession(oldId, to: newId))

        XCTAssertNil(store.get(oldId))
        let recovered = store.get(newId)
        XCTAssertEqual(recovered?.sessionId, newId)
        XCTAssertEqual(recovered?.description, "user note")
        XCTAssertEqual(recovered?.ghosttyTerminalId, "ghostty-1")
        XCTAssertEqual(recovered?.terminalInfo?.tty, "ttys001")
        XCTAssertEqual(recovered?.tasks.first?.id, "task-1")
        XCTAssertEqual(recovered?.usageStats?.inputTokens, 1)
        XCTAssertEqual(recovered?.providerResumeSessionId, "8db44e39-685d-47ab-bd0e-5e97386ded80")
        XCTAssertEqual(recovered?.pendingPermissionTool, "Edit")
        XCTAssertEqual(store.queueLength(newId), 1)
        XCTAssertEqual(store.dequeue(newId), "queued")
        XCTAssertEqual(store.getUnread(newId)?.message, "unread")
    }

    func testWithSessionIdPreservesEncodedFields() throws {
        var original = SessionData(
            sessionId: "old",
            project: "project",
            cwd: "/tmp/project",
            status: .permissionRequired,
            currentTool: "Bash",
            description: "note"
        )
        original.pendingPermissionTool = "Bash"
        original.pendingPermissionMessage = "Run command"
        original.providerResumeSessionId = "8db44e39-685d-47ab-bd0e-5e97386ded80"

        let copied = original.withSessionId("new")

        XCTAssertEqual(copied.sessionId, "new")
        XCTAssertEqual(copied.project, original.project)
        XCTAssertEqual(copied.cwd, original.cwd)
        XCTAssertEqual(copied.status, original.status)
        XCTAssertEqual(copied.currentTool, original.currentTool)
        XCTAssertEqual(copied.description, original.description)
        XCTAssertEqual(copied.providerResumeSessionId, original.providerResumeSessionId)
        XCTAssertEqual(copied.pendingPermissionTool, original.pendingPermissionTool)
        XCTAssertEqual(copied.pendingPermissionMessage, original.pendingPermissionMessage)

        let data = try JSONEncoder().encode(copied)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)
        XCTAssertEqual(decoded.sessionId, "new")
        XCTAssertEqual(decoded.pendingPermissionTool, "Bash")
        XCTAssertEqual(decoded.providerResumeSessionId, "8db44e39-685d-47ab-bd0e-5e97386ded80")
    }

    func testSetProviderResumeSessionIdPreservesLastActivity() {
        let sessionId = "resume-anchor-\(UUID().uuidString)"
        let store = SessionStore.shared
        let lastActivity = Date(timeIntervalSince1970: 200)

        defer { store.delete(sessionId) }

        store.create(SessionData(
            sessionId: sessionId,
            project: "project-a",
            cwd: "/tmp/project-a",
            startedAt: Date(timeIntervalSince1970: 100),
            lastActivity: lastActivity,
            status: .dead
        ))

        store.setProviderResumeSessionId(
            sessionId: sessionId,
            providerResumeSessionId: "8db44e39-685d-47ab-bd0e-5e97386ded80"
        )

        let recovered = store.get(sessionId)
        XCTAssertEqual(recovered?.providerResumeSessionId, "8db44e39-685d-47ab-bd0e-5e97386ded80")
        XCTAssertEqual(recovered?.lastActivity, lastActivity)
    }

    func testHistoricalStatusesAreNotLiveSurfaceStatuses() {
        XCTAssertTrue(SessionStatus.completed.isHistorical)
        XCTAssertTrue(SessionStatus.dead.isHistorical)
        XCTAssertFalse(SessionStatus.idle.isHistorical)
        XCTAssertFalse(SessionStatus.thinking.isHistorical)
        XCTAssertFalse(SessionStatus.permissionRequired.isHistorical)
    }
}
