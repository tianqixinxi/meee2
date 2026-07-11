import XCTest
@testable import meee2Kit

/// Unit tests for the pure helpers inside `LocalClaudeProvider` —
/// `parseToolFence` (regex extraction) and `augmentedSystemPrompt` (string
/// composition). The actual `runTurn` end-to-end paths spawn a `claude`
/// subprocess / hit network and live in integration smoke tests.
final class AssistantProviderTests: XCTestCase {

    // MARK: - parseToolFence

    func testParseToolFenceExtractsNameAndArgs() {
        let provider = LocalClaudeProvider()
        let text = """
        Sure, I'll look that up.

        ```tool
        {"name": "get_session_list", "args": {"status": "tooling"}}
        ```
        """
        let parsed = provider.parseToolFence(text)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "get_session_list")
        // args is the JSON object re-serialised; parse and compare structurally
        let argData = parsed?.args.data(using: .utf8) ?? Data()
        let argObj = (try? JSONSerialization.jsonObject(with: argData)) as? [String: Any]
        XCTAssertEqual(argObj?["status"] as? String, "tooling")
        // id is synthesised by the provider — just make sure something's there
        XCTAssertFalse(parsed?.id.isEmpty ?? true)
    }

    func testParseToolFenceReturnsNilWhenAbsent() {
        let provider = LocalClaudeProvider()
        XCTAssertNil(provider.parseToolFence("plain text answer, no fence"))
        XCTAssertNil(provider.parseToolFence(""))
    }

    func testParseToolFenceIgnoresUnrelatedFences() {
        let provider = LocalClaudeProvider()
        // ```spawn``` is the legacy pattern from the old AssistantChat; the
        // new tool fence is ```tool``` — this must NOT match.
        let text = """
        ```spawn
        {"cwd": "/tmp"}
        ```
        """
        XCTAssertNil(provider.parseToolFence(text))
    }

    func testParseToolFenceMatchesFirstFenceOnly() {
        // If the model emits multiple tool fences (rare but possible during
        // a hallucination), we conservatively pick the first — the orchestrator
        // re-prompts with the result and the model can issue the next call
        // on the next turn, no batching.
        let provider = LocalClaudeProvider()
        let text = """
        ```tool
        {"name": "get_session_list", "args": {}}
        ```

        ```tool
        {"name": "get_session_info", "args": {"sessionId": "abc"}}
        ```
        """
        let parsed = provider.parseToolFence(text)
        XCTAssertEqual(parsed?.name, "get_session_list")
    }

    func testParseToolFenceRejectsMalformedJSON() {
        let provider = LocalClaudeProvider()
        let text = """
        ```tool
        {name: get_session_list, args: oops}
        ```
        """
        XCTAssertNil(provider.parseToolFence(text))
    }

    func testParseToolFenceRejectsMissingName() {
        let provider = LocalClaudeProvider()
        let text = """
        ```tool
        {"args": {"foo": "bar"}}
        ```
        """
        XCTAssertNil(provider.parseToolFence(text))
    }

    func testParseToolFenceHandlesSurroundingProse() {
        // Real local-claude responses often wrap the fence in commentary;
        // the parser must still find it.
        let provider = LocalClaudeProvider()
        let text = """
        Let me check the board state for you. Calling the tool now:

        ```tool
        {"name": "get_session_list", "args": {}}
        ```

        I'll continue once I have the result.
        """
        XCTAssertEqual(provider.parseToolFence(text)?.name, "get_session_list")
    }

    // MARK: - augmentedSystemPrompt

    func testAugmentedSystemPromptPassesThroughWhenNoTools() {
        let provider = LocalClaudeProvider()
        let base = "You are an assistant."
        XCTAssertEqual(provider.augmentedSystemPrompt(base, tools: []), base)
    }

    func testAugmentedSystemPromptIncludesFenceProtocol() {
        let provider = LocalClaudeProvider()
        let tools = [
            ToolDef(
                name: "echo",
                description: "Echo a string back to the caller.",
                inputSchema: ["type": "object", "properties": ["msg": ["type": "string"]]]),
        ]
        let augmented = provider.augmentedSystemPrompt("BASE", tools: tools)
        // The augmentation must (a) keep the base, (b) describe the fence
        // protocol, (c) name the tool, (d) include its description.
        XCTAssertTrue(augmented.contains("BASE"))
        XCTAssertTrue(augmented.contains("```tool"))
        XCTAssertTrue(augmented.contains("`echo`"))
        XCTAssertTrue(augmented.contains("Echo a string back"))
    }

    func testAugmentedSystemPromptListsAllTools() {
        let provider = LocalClaudeProvider()
        let augmented = provider.augmentedSystemPrompt("BASE", tools: AssistantTools.all)
        for tool in AssistantTools.all {
            XCTAssertTrue(
                augmented.contains("`\(tool.name)`"),
                "augmented prompt missing tool '\(tool.name)'")
        }
    }

    // MARK: - claude CLI args

    func testLocalClaudeArgsUseStableSessionPersistence() {
        let provider = LocalClaudeProvider()
        let args = provider.claudeArguments(
            systemPrompt: "BASE",
            sessionId: "11111111-1111-1111-1111-111111111111",
            sessionName: "meee2ai:Canvas"
        )
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertTrue(args.contains("11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(args.contains("--name"))
        XCTAssertTrue(args.contains("meee2ai:Canvas"))
        XCTAssertFalse(args.contains("--no-session-persistence"))
    }

    // MARK: - codex CLI args

    func testLocalCodexArgsStartReadOnlyExecSession() {
        let provider = LocalCodexProvider()
        let args = provider.codexArguments(
            model: "gpt-5-codex",
            workspacePath: "/tmp/meee2-canvas"
        )
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("--json"))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("gpt-5-codex"))
        XCTAssertTrue(args.contains("--cd"))
        XCTAssertTrue(args.contains("/tmp/meee2-canvas"))
        XCTAssertEqual(args.last, "-")
    }

    func testLocalCodexArgsResumeExistingThread() {
        let provider = LocalCodexProvider()
        let args = provider.codexArguments(existingThreadId: "019f2c54-4123-7ac1-81db-3589b0e24726")
        XCTAssertEqual(Array(args.prefix(3)), ["exec", "resume", "--json"])
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertTrue(args.contains("019f2c54-4123-7ac1-81db-3589b0e24726"))
        XCTAssertEqual(args.last, "-")
        XCTAssertFalse(args.contains("--sandbox"))
        XCTAssertFalse(args.contains("--cd"))
    }

    func testLocalCodexTitleRunIsEphemeral() {
        let args = LocalCodexProvider().codexArguments(
            workspacePath: "/tmp/meee2-title",
            ephemeral: true
        )
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("read-only"))
    }

    func testLocalClaudeTitleRunDoesNotPersistSession() {
        let args = LocalClaudeProvider().claudeArguments(
            systemPrompt: "TITLE",
            model: "haiku",
            sessionId: "11111111-1111-1111-1111-111111111111",
            sessionName: "session-title",
            persistSession: false
        )
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("haiku"))
    }

    func testLocalCodexPromptIncludesSystemAndConversation() {
        let provider = LocalCodexProvider()
        let prompt = provider.codexPrompt(
            systemPrompt: "BASE",
            messages: [
                ChatMessage(role: .user, content: "Hello"),
                ChatMessage(role: .assistant, content: "Hi"),
                ChatMessage(role: .tool, content: "{\"ok\":true}", toolCallId: "tool-1"),
            ]
        )
        XCTAssertTrue(prompt.contains("System:\nBASE"))
        XCTAssertTrue(prompt.contains("User: Hello"))
        XCTAssertTrue(prompt.contains("Assistant: Hi"))
        XCTAssertTrue(prompt.contains("ToolResult(tool-1): {\"ok\":true}"))
        XCTAssertTrue(prompt.hasSuffix("Assistant:"))
    }

    // MARK: - Provider factory

    func testFactoryReturnsCorrectProviderForEachKind() {
        XCTAssertTrue(AssistantProviderFactory.make(.openai) is OpenAIProvider)
        XCTAssertTrue(AssistantProviderFactory.make(.anthropic) is AnthropicProvider)
        XCTAssertTrue(AssistantProviderFactory.make(.local) is LocalClaudeProvider)
        XCTAssertTrue(AssistantProviderFactory.make(.localCodex) is LocalCodexProvider)
    }
}
