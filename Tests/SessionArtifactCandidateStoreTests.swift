import XCTest
@testable import meee2Kit

final class SessionArtifactCandidateStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-candidate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testClaudePostToolUseCapturesMaterialBashResult() throws {
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let event = try hookEvent("""
        {
          "hook_event_name": "PostToolUse",
          "session_id": "sid-1",
          "cwd": "/tmp/work",
          "tool_name": "Bash",
          "tool_use_id": "tool-1",
          "tool_input": { "command": "swift test" },
          "tool_response": { "exit_code": 0, "stdout": "Test Suite passed" }
        }
        """)

        let inserted = store.ingestClaudeHook(event)

        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted[0].kind, "check-result")
        XCTAssertEqual(inserted[0].sessionId, "sid-1")
        XCTAssertTrue(inserted[0].summary.contains("swift test"))
    }

    func testReadOnlyBashCommandIsIgnored() throws {
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let event = try hookEvent("""
        {
          "hook_event_name": "PostToolUse",
          "session_id": "sid-1",
          "cwd": "/tmp/work",
          "tool_name": "Bash",
          "tool_use_id": "tool-1",
          "tool_input": { "command": "rg artifactIndex" },
          "tool_response": { "exit_code": 0, "stdout": "packages/board-app/src/lib/artifactIndex.ts" }
        }
        """)

        XCTAssertTrue(store.ingestClaudeHook(event).isEmpty)
        XCTAssertTrue(store.list(sessionId: "sid-1").isEmpty)
    }

    func testCodexApplyPatchPayloadCapturesChangedFiles() throws {
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "session_id": "codex-sid",
            "cwd": "/Users/example/project",
            "tool_name": "apply_patch",
            "tool_use_id": "patch-1",
            "tool_input": [
                "command": """
                *** Begin Patch
                *** Update File: packages/board-app/src/App.tsx
                @@
                -old
                +new
                *** End Patch
                """
            ],
            "tool_response": [:]
        ]

        let inserted = store.ingestCodexHookPayload(payload)

        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted[0].kind, "file-diff")
        XCTAssertEqual(inserted[0].provider, "codex")
        XCTAssertEqual(inserted[0].references.first?.value, "/Users/example/project/packages/board-app/src/App.tsx")
    }

    func testCandidatesPersistAndDedupeByToolUseAndReference() throws {
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let event = try hookEvent("""
        {
          "hook_event_name": "PostToolUse",
          "session_id": "sid-2",
          "cwd": "/tmp/work",
          "tool_name": "Bash",
          "tool_use_id": "tool-2",
          "tool_input": { "command": "gh pr create --fill" },
          "tool_response": { "stdout": "https://github.com/acme/repo/pull/42" }
        }
        """)

        XCTAssertEqual(store.ingestClaudeHook(event).count, 1)
        XCTAssertEqual(store.ingestClaudeHook(event).count, 0)

        let reloaded = SessionArtifactCandidateStore(rootURL: tempRoot)
        let items = reloaded.list(sessionId: "sid-2")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, "impl-pr")
        XCTAssertEqual(items[0].references.first?.value, "https://github.com/acme/repo/pull/42")
    }

    func testStopFinalSummaryBecomesCandidate() throws {
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let event = try hookEvent("""
        {
          "hook_event_name": "Stop",
          "session_id": "sid-final",
          "cwd": "/tmp/work",
          "last_assistant_message": "Implemented the session artifacts modal fix and verified it with typecheck and targeted frontend tests."
        }
        """)

        let inserted = store.ingestClaudeHook(event)

        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted[0].kind, "final-text")
        XCTAssertEqual(inserted[0].references.first?.kind, "session-final")
        XCTAssertTrue(inserted[0].summary.contains("Implemented the session artifacts modal fix"))
    }

    func testStopInteractiveQuestionDoesNotBecomeFinalTextCandidate() throws {
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let event = try hookEvent("""
        {
          "hook_event_name": "Stop",
          "session_id": "sid-question",
          "cwd": "/tmp/work",
          "last_assistant_message": "我可以把 final 文本也纳入候选。你希望默认归档，还是只在包含验证结果时归档？"
        }
        """)

        XCTAssertTrue(store.ingestClaudeHook(event).isEmpty)
        XCTAssertTrue(store.list(sessionId: "sid-question").isEmpty)
    }

    func testCombinedArtifactsIncludesProviderResumeAliasCandidates() throws {
        let boardSessionId = "board-\(UUID().uuidString)"
        let providerSessionId = "provider-\(UUID().uuidString)"
        SessionStore.shared.create(SessionData(
            sessionId: boardSessionId,
            project: "AliasProject",
            providerResumeSessionId: providerSessionId
        ))
        defer { SessionStore.shared.delete(boardSessionId) }
        let store = SessionArtifactCandidateStore(rootURL: tempRoot)
        let event = try hookEvent("""
        {
          "hook_event_name": "Stop",
          "session_id": "\(providerSessionId)",
          "cwd": "/tmp/work",
          "last_assistant_message": "Generated a Lark document: https://example.larksuite.com/docx/abc123 and summarized the result."
        }
        """)

        XCTAssertEqual(store.ingestClaudeHook(event).count, 2)

        let envelope = store.combinedArtifacts(sessionId: boardSessionId)
        XCTAssertEqual(envelope.candidates.count, 2)
        XCTAssertEqual(envelope.totalCount, 2)
        XCTAssertTrue(envelope.candidates.allSatisfy { $0.sessionId == providerSessionId })
    }

    func testCodexTranscriptBackfillCapturesToolResultURL() throws {
        let transcript = tempRoot.appendingPathComponent("codex.jsonl")
        try """
        {"timestamp":"2026-06-16T04:36:10.899Z","type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"call-1","invocation":{"server":"lark","tool":"docx_builtin_import","arguments":{"markdown":"https://github.com/acme/repo/pull/1"}},"result":{"Ok":{"content":[{"type":"text","text":"{\\"result\\":{\\"type\\":\\"docx\\",\\"url\\":\\"https://example.larksuite.com/docx/doc123\\"}}"}]}}}}
        {"timestamp":"2026-06-16T04:36:14.752Z","type":"event_msg","payload":{"type":"agent_message","message":"已生成 Lark 文档：\\n\\nhttps://example.larksuite.com/docx/doc123","phase":"final_answer"}}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let candidates = SessionArtifactCandidateExtractor.extractCodexTranscript(
            sessionId: "sid-transcript",
            cwd: "/tmp/work",
            transcriptURL: transcript
        )

        XCTAssertTrue(candidates.contains { candidate in
            candidate.references.contains { $0.value == "https://example.larksuite.com/docx/doc123" }
        })
        XCTAssertFalse(candidates.contains { candidate in
            candidate.references.contains { $0.value == "https://github.com/acme/repo/pull/1" }
        })
    }

    private func hookEvent(_ json: String) throws -> HookEvent {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var event = try decoder.decode(HookEvent.self, from: data)
        event.rawData = json
        return event
    }
}
