import XCTest
@testable import meee2Kit

final class AssistantLocalSessionStoreTests: XCTestCase {
    func testStableSessionIdPersistsPerCanvasKey() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meee2-session-\(UUID().uuidString).json")
        let store = AssistantLocalSessionStore(fileURL: url)

        let first = store.sessionId(forCanvasId: "canvas-a")
        let second = store.sessionId(forCanvasId: "canvas-a")
        let other = store.sessionId(forCanvasId: "canvas-b")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertFalse(first.isEmpty)
    }

    func testProjectionKeepsOnlyVisibleTextBlocks() {
        let sessionId = "11111111-1111-1111-1111-111111111111"
        let entries = [
            FullTranscriptEntry(
                id: "u1",
                type: "user",
                timestamp: "2026-05-20T10:00:00Z",
                blocks: [textBlock("User: hello\n\nAssistant:")]
            ),
            FullTranscriptEntry(
                id: "a1",
                type: "assistant",
                timestamp: "2026-05-20T10:00:01Z",
                blocks: [
                    FullTranscriptBlock(
                        type: "thinking",
                        text: "private chain",
                        toolId: nil,
                        toolName: nil,
                        toolInputJSON: nil,
                        toolUseId: nil,
                        toolResultText: nil,
                        toolResultTruncated: nil
                    ),
                    textBlock("final answer"),
                ]
            ),
            FullTranscriptEntry(
                id: "a2",
                type: "assistant",
                timestamp: "2026-05-20T10:00:02Z",
                blocks: [
                    FullTranscriptBlock(
                        type: "tool_use",
                        text: nil,
                        toolId: "tool-1",
                        toolName: "Read",
                        toolInputJSON: "{\"file\":\"secret\"}",
                        toolUseId: nil,
                        toolResultText: nil,
                        toolResultTruncated: nil
                    ),
                ]
            ),
        ]

        let messages = AssistantLocalSessionProjection.messages(sessionId: sessionId, entries: entries)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.map(\.content), ["hello", "final answer"])
    }

    func testProjectionStripsFakeToolFenceFromAssistantText() {
        let sessionId = "11111111-1111-1111-1111-111111111111"
        let entry = FullTranscriptEntry(
            id: "a1",
            type: "assistant",
            timestamp: nil,
            blocks: [textBlock("""
            I will check that.

            ```tool
            {"name":"get_session_list","args":{"status":"busy"}}
            ```
            """)]
        )

        let messages = AssistantLocalSessionProjection.messages(sessionId: sessionId, entries: [entry])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "I will check that.")
        XCTAssertFalse(messages.first?.content.contains("get_session_list") ?? true)
    }

    func testProjectionDropsFenceOnlyAssistantText() {
        let sessionId = "11111111-1111-1111-1111-111111111111"
        let entry = FullTranscriptEntry(
            id: "a1",
            type: "assistant",
            timestamp: nil,
            blocks: [textBlock("""
            ```tool
            {"name":"get_session_list","args":{}}
            ```
            """)]
        )

        let messages = AssistantLocalSessionProjection.messages(sessionId: sessionId, entries: [entry])
        XCTAssertTrue(messages.isEmpty)
    }

    private func textBlock(_ text: String) -> FullTranscriptBlock {
        FullTranscriptBlock(
            type: "text",
            text: text,
            toolId: nil,
            toolName: nil,
            toolInputJSON: nil,
            toolUseId: nil,
            toolResultText: nil,
            toolResultTruncated: nil
        )
    }
}
