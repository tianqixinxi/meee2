import Foundation
import Meee2CommKit

// MARK: - Shared types

/// LLM-facing message format used across all three providers. Each provider
/// converts to its native shape before sending.
struct ChatMessage {
    let role: Role
    let content: String
    /// Tool-call references, only populated on assistant messages that requested tools.
    let toolCalls: [ToolCallRef]
    /// Tool-result message — `toolCallId` references the matching call on a previous assistant message.
    let toolCallId: String?

    enum Role: String {
        case system, user, assistant, tool
    }

    init(role: Role, content: String, toolCalls: [ToolCallRef] = [], toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

struct ToolCallRef {
    let id: String
    let name: String
    /// Arguments as a JSON string (providers serialize back to object shape on send).
    let argsJSON: String
}

/// Event a provider yields as it streams a response. The AssistantAPI
/// orchestrator forwards these to the SSE client + reacts to `.toolCall`
/// by running the tool and looping back to the provider with the result.
enum ProviderEvent {
    case textDelta(String)
    /// Tool call request from the LLM. Yielded once the args are fully
    /// accumulated (we don't stream partial JSON args).
    case toolCall(id: String, name: String, argsJSON: String)
    /// End of one provider turn. If the response contained tool calls the
    /// orchestrator will resume by calling the provider again with results
    /// appended.
    case turnDone(stopReason: String?)
    case error(String)
}

struct AssistantSettings {
    enum Provider: String {
        case openai      // OpenAI-compatible /v1/chat/completions
        case anthropic   // Anthropic /v1/messages
        case local       // claude -p
        case localCodex  // codex exec --json
    }

    let provider: Provider
    let apiKey: String        // empty for local
    let baseUrl: String       // empty for local
    let model: String         // empty for local providers → CLI default
    let enabledTools: Set<String>?  // nil = all
    let scope: String         // "this-mac" or a meee2 team id
    let canvasId: String      // current canvas id for canvas-aware tools
    let workspacePath: String // current canvas workspace for local temporary assistant
    let canvasName: String
    let localRunPurpose: LocalRunPurpose
    let selectedElements: [AssistantSelectedElement]

    enum LocalRunPurpose: String {
        case interactive
        case recap
        case title

        var appliesCompletionCooldown: Bool {
            self == .recap
        }
    }
}

extension AssistantSettings {
    func withCanvasDefaults(canvasId nextCanvasId: String, canvasName nextCanvasName: String? = nil) -> AssistantSettings {
        let trimmedCanvasId = nextCanvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCanvasName = (nextCanvasName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantSettings(
            provider: provider,
            apiKey: apiKey,
            baseUrl: baseUrl,
            model: model,
            enabledTools: enabledTools,
            scope: scope,
            canvasId: canvasId.isEmpty ? trimmedCanvasId : canvasId,
            workspacePath: workspacePath,
            canvasName: canvasName == "Canvas" && !trimmedCanvasName.isEmpty ? trimmedCanvasName : canvasName,
            localRunPurpose: localRunPurpose,
            selectedElements: selectedElements
        )
    }
}

struct AssistantSelectedElement {
    let id: String
    let type: String
    let label: String
    let textPreview: String?
    let sessionId: String?
    let channelName: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Common interface across hosted (OpenAI / Anthropic) and local CLI
/// providers. Each implementation streams `ProviderEvent` values as the LLM
/// produces output; the orchestrator on top of this protocol handles the
/// tool-use loop + SSE relay.
protocol AssistantProvider {
    /// Run one turn against the LLM. Returns an async sequence of events.
    /// The provider is responsible for streaming text deltas and emitting
    /// fully-assembled tool calls (no partial JSON).
    func runTurn(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

// MARK: - Provider factory

enum AssistantProviderFactory {
    static func make(_ kind: AssistantSettings.Provider) -> AssistantProvider {
        switch kind {
        case .openai: return OpenAIProvider()
        case .anthropic: return AnthropicProvider()
        case .local: return LocalClaudeProvider()
        case .localCodex: return LocalCodexProvider()
        }
    }
}

// MARK: - OpenAI-compatible provider

/// POSTs `{baseUrl}/chat/completions` with `stream: true` and parses SSE
/// chunks. Supports any OpenAI-compatible endpoint (Anthropic via OpenRouter,
/// LiteLLM, Ollama, vLLM, …) so users get a single configuration knob for
/// "any hosted LLM that speaks the OpenAI shape".
struct OpenAIProvider: AssistantProvider {
    func runTurn(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await stream(
                        systemPrompt: systemPrompt,
                        messages: messages,
                        tools: tools,
                        settings: settings,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    private func stream(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        let baseUrl = (settings.baseUrl.isEmpty ? "https://api.openai.com/v1" : settings.baseUrl)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(baseUrl)/chat/completions") else {
            throw NSError(domain: "AssistantProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid baseUrl: \(baseUrl)"])
        }

        // Build messages
        var oaiMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages {
            switch m.role {
            case .system:
                oaiMessages.append(["role": "system", "content": m.content])
            case .user:
                oaiMessages.append(["role": "user", "content": m.content])
            case .assistant:
                if m.toolCalls.isEmpty {
                    oaiMessages.append(["role": "assistant", "content": m.content])
                } else {
                    oaiMessages.append([
                        "role": "assistant",
                        "content": m.content,
                        "tool_calls": m.toolCalls.map { tc in
                            [
                                "id": tc.id,
                                "type": "function",
                                "function": [
                                    "name": tc.name,
                                    "arguments": tc.argsJSON
                                ]
                            ] as [String: Any]
                        }
                    ])
                }
            case .tool:
                oaiMessages.append([
                    "role": "tool",
                    "tool_call_id": m.toolCallId ?? "",
                    "content": m.content
                ])
            }
        }

        var body: [String: Any] = [
            "model": settings.model.isEmpty ? "gpt-4o-mini" : settings.model,
            "messages": oaiMessages,
            "temperature": 0.2,
            "stream": true
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.inputSchema
                    ]
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Read error body for diagnostics
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw NSError(domain: "AssistantProvider", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "openai HTTP \(http.statusCode): \(errBody.prefix(500))"])
        }

        // Parse SSE: each event is `data: {...}\n\n`. We track tool_call deltas
        // by index since OpenAI sends fragmented `function.arguments` chunks.
        struct ToolCallAcc { var id = ""; var name = ""; var args = "" }
        var toolAccs: [Int: ToolCallAcc] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                // Flush any complete tool calls
                for (_, acc) in toolAccs.sorted(by: { $0.key < $1.key }) {
                    if !acc.id.isEmpty {
                        continuation.yield(.toolCall(id: acc.id, name: acc.name, argsJSON: acc.args))
                    }
                }
                continuation.yield(.turnDone(stopReason: nil))
                continuation.finish()
                return
            }
            guard let data = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }

            let delta = first["delta"] as? [String: Any] ?? [:]
            if let txt = delta["content"] as? String, !txt.isEmpty {
                continuation.yield(.textDelta(txt))
            }
            if let tcalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcalls {
                    let idx = (tc["index"] as? Int) ?? 0
                    var acc = toolAccs[idx] ?? ToolCallAcc()
                    if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                        if let args = fn["arguments"] as? String { acc.args += args }
                    }
                    toolAccs[idx] = acc
                }
            }
            if let stop = first["finish_reason"] as? String, !stop.isEmpty {
                // Some implementations emit finish_reason on the last delta
                // before [DONE]; flush tool calls and end the turn early.
                for (_, acc) in toolAccs.sorted(by: { $0.key < $1.key }) {
                    if !acc.id.isEmpty {
                        continuation.yield(.toolCall(id: acc.id, name: acc.name, argsJSON: acc.args))
                    }
                }
                continuation.yield(.turnDone(stopReason: stop))
                continuation.finish()
                return
            }
        }
        // Stream ended without [DONE] — close out anyway.
        continuation.yield(.turnDone(stopReason: nil))
        continuation.finish()
    }
}

// MARK: - Anthropic-native provider

/// POSTs `{baseUrl}/v1/messages` with `stream: true`. Handles Anthropic's
/// distinct event types (`content_block_delta`, `tool_use`, etc.) and
/// converts them into the same `ProviderEvent` shape.
struct AnthropicProvider: AssistantProvider {
    func runTurn(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await stream(
                        systemPrompt: systemPrompt,
                        messages: messages,
                        tools: tools,
                        settings: settings,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    private func stream(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        let baseUrl = (settings.baseUrl.isEmpty ? "https://api.anthropic.com" : settings.baseUrl)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(baseUrl)/v1/messages") else {
            throw NSError(domain: "AssistantProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid baseUrl: \(baseUrl)"])
        }

        // Anthropic separates `system` (top-level) from `messages` (only user/assistant).
        // Tool results live in user messages as content blocks of type "tool_result".
        var anMessages: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system:
                continue  // already in top-level system
            case .user:
                if !pendingToolResults.isEmpty {
                    anMessages.append(["role": "user", "content": pendingToolResults])
                    pendingToolResults.removeAll()
                }
                anMessages.append(["role": "user", "content": m.content])
            case .assistant:
                if !pendingToolResults.isEmpty {
                    anMessages.append(["role": "user", "content": pendingToolResults])
                    pendingToolResults.removeAll()
                }
                if m.toolCalls.isEmpty {
                    anMessages.append(["role": "assistant", "content": m.content])
                } else {
                    var blocks: [[String: Any]] = []
                    if !m.content.isEmpty {
                        blocks.append(["type": "text", "text": m.content])
                    }
                    for tc in m.toolCalls {
                        let parsed = (try? JSONSerialization.jsonObject(with: Data(tc.argsJSON.utf8))) ?? [:]
                        blocks.append([
                            "type": "tool_use",
                            "id": tc.id,
                            "name": tc.name,
                            "input": parsed
                        ])
                    }
                    anMessages.append(["role": "assistant", "content": blocks])
                }
            case .tool:
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId ?? "",
                    "content": m.content
                ])
            }
        }
        if !pendingToolResults.isEmpty {
            anMessages.append(["role": "user", "content": pendingToolResults])
        }

        var body: [String: Any] = [
            "model": settings.model.isEmpty ? "claude-haiku-4-5-20251001" : settings.model,
            "system": systemPrompt,
            "messages": anMessages,
            "max_tokens": 4096,
            "stream": true
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                [
                    "name": t.name,
                    "description": t.description,
                    "input_schema": t.inputSchema
                ] as [String: Any]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errBody = ""
            for try await line in bytes.lines { errBody += line + "\n" }
            throw NSError(domain: "AssistantProvider", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "anthropic HTTP \(http.statusCode): \(errBody.prefix(500))"])
        }

        // Anthropic SSE: events with `event:` then `data: {...}`. We track
        // each content_block by index; tool_use blocks accumulate
        // `partial_json` deltas before being emitted as one tool call.
        struct ToolUseAcc { var id = ""; var name = ""; var args = "" }
        var toolBlocks: [Int: ToolUseAcc] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                let idx = (obj["index"] as? Int) ?? 0
                if let block = obj["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use" {
                    var acc = ToolUseAcc()
                    acc.id = block["id"] as? String ?? ""
                    acc.name = block["name"] as? String ?? ""
                    toolBlocks[idx] = acc
                }
            case "content_block_delta":
                let idx = (obj["index"] as? Int) ?? 0
                guard let delta = obj["delta"] as? [String: Any] else { continue }
                if delta["type"] as? String == "text_delta",
                   let txt = delta["text"] as? String, !txt.isEmpty {
                    continuation.yield(.textDelta(txt))
                } else if delta["type"] as? String == "input_json_delta",
                          let partial = delta["partial_json"] as? String {
                    var acc = toolBlocks[idx] ?? ToolUseAcc()
                    acc.args += partial
                    toolBlocks[idx] = acc
                }
            case "content_block_stop":
                let idx = (obj["index"] as? Int) ?? 0
                if let acc = toolBlocks[idx], !acc.id.isEmpty {
                    continuation.yield(.toolCall(id: acc.id, name: acc.name, argsJSON: acc.args))
                    toolBlocks.removeValue(forKey: idx)
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let stop = delta["stop_reason"] as? String {
                    // Wait for message_stop to actually finish so we don't
                    // close the stream before any tail content_block_stop.
                    _ = stop
                }
            case "message_stop":
                continuation.yield(.turnDone(stopReason: nil))
                continuation.finish()
                return
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "anthropic stream error"
                continuation.yield(.error(msg))
                continuation.finish()
                return
            default:
                break
            }
        }
        continuation.yield(.turnDone(stopReason: nil))
        continuation.finish()
    }
}

// MARK: - Local CLI provider helpers

struct LocalToolFence: Equatable {
    let id: String
    let name: String
    let args: String
}

enum LocalAssistantToolProtocol {
    static func augmentedSystemPrompt(_ base: String, tools: [ToolDef]) -> String {
        guard !tools.isEmpty else { return base }
        var s = base
        s += "\n\nYou have these tools available. To call one, output exactly one fenced block like:\n\n"
        s += "```tool\n{\"name\": \"<tool_name>\", \"args\": { ... }}\n```\n\n"
        s += "After you emit the fence, stop. The runtime will execute the tool "
        s += "and reply with the result, then you continue. "
        s += "If you don't need a tool, just answer normally.\n\n"
        s += "Tools:\n"
        for t in tools {
            let schemaJSON = (try? JSONSerialization.data(withJSONObject: t.inputSchema, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            s += "- `\(t.name)` — \(t.description) (schema: \(schemaJSON))\n"
        }
        return s
    }

    static func parseToolFence(_ text: String, idPrefix: String) -> LocalToolFence? {
        let pattern = #"```tool\s*\n([\s\S]*?)\n```"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        let json = String(text[r])
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty,
              let argsObj = obj["args"] as? [String: Any] else { return nil }
        let argsData = (try? JSONSerialization.data(withJSONObject: argsObj)) ?? Data("{}".utf8)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        let id = "\(idPrefix)-\(UUID().uuidString.prefix(8))"
        return LocalToolFence(id: String(id), name: name, args: argsJSON)
    }
}

// MARK: - Local claude -p provider

/// Spawns a local `claude -p --output-format stream-json --print` and parses
/// the JSONL events. This lets the user run the assistant entirely on their
/// machine (no API key, reuses ~/.claude OAuth) while still going through
/// the same `runTurn` / `ProviderEvent` shape as hosted providers.
///
/// Tools: claude CLI has no native function-calling for the `-p` mode, so
/// instead we instruct the model via the system prompt to emit a fenced
/// JSON block when it wants to call a tool, and parse that out of the final
/// text. The orchestrator then runs the tool and re-invokes claude with the
/// result appended to the conversation. This gives us the same end-to-end
/// behaviour without a local MCP roundtrip.
struct LocalClaudeProvider: AssistantProvider {
    func runTurn(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                // Defensive backstop (recap-respawn hang): the local `claude -p`
                // run is rate-gated per canvas — max-in-flight=1 + a cooldown —
                // so a failing recap can never spawn unbounded and starve the
                // board HTTP server / main thread. A rejected run yields a plain
                // error event (caller keeps its local baseRecap), never a spin.
                let gateResult = AssistantLocalRunGate.shared.acquireDetailed(
                    key: settings.canvasId,
                    completionCooldown: settings.localRunPurpose.appliesCompletionCooldown
                )
                let lease: AssistantLocalRunGate.Lease
                switch gateResult {
                case .acquired(let acquiredLease):
                    lease = acquiredLease
                case .rejected(let reason):
                    let canvas = settings.canvasId.isEmpty ? "global" : settings.canvasId
                    MLog(
                        "[AssistantLocalRunGate] rejected canvas=\(canvas) "
                            + "purpose=\(settings.localRunPurpose.rawValue) reason=\(reason.description)"
                    )
                    continuation.yield(.error("local assistant busy for this canvas (\(reason.description))"))
                    continuation.finish()
                    return
                }
                var mutableLease = lease
                defer { mutableLease.release() }
                do {
                    let store = AssistantLocalSessionStore.shared
                    let persistSession = settings.localRunPurpose != .title
                    let sessionId = persistSession
                        ? store.sessionId(forCanvasId: settings.canvasId)
                        : UUID().uuidString
                    try runProcess(
                        systemPrompt: augmentedSystemPrompt(systemPrompt, tools: tools),
                        messages: messages,
                        workspacePath: settings.workspacePath,
                        model: settings.localRunPurpose == .title ? settings.model : "",
                        sessionId: sessionId,
                        sessionName: AssistantLocalSessionStore.sessionName(
                            canvasId: settings.canvasId,
                            canvasName: settings.canvasName
                        ),
                        persistSession: persistSession,
                        continuation: continuation
                    )
                } catch let error as LocalClaudeExitError where error.isSessionIdError {
                    do {
                        let store = AssistantLocalSessionStore.shared
                        let sessionId = store.resetSessionId(forCanvasId: settings.canvasId)
                        try runProcess(
                            systemPrompt: augmentedSystemPrompt(systemPrompt, tools: tools),
                            messages: messages,
                            workspacePath: settings.workspacePath,
                            model: "",
                            sessionId: sessionId,
                            sessionName: AssistantLocalSessionStore.sessionName(
                                canvasId: settings.canvasId,
                                canvasName: settings.canvasName
                            ),
                            persistSession: true,
                            continuation: continuation
                        )
                    } catch {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    func augmentedSystemPrompt(_ base: String, tools: [ToolDef]) -> String {
        LocalAssistantToolProtocol.augmentedSystemPrompt(base, tools: tools)
    }

    private func runProcess(
        systemPrompt: String,
        messages: [ChatMessage],
        workspacePath rawWorkspacePath: String,
        model: String,
        sessionId: String,
        sessionName: String,
        persistSession: Bool,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) throws {
        let claudePath = resolveClaudeBinary()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let shouldResume = persistSession
            && AssistantLocalSessionStore.shared.transcriptPath(forSessionId: sessionId) != nil
        let args = claudeArguments(
            systemPrompt: systemPrompt,
            model: model,
            sessionId: sessionId,
            sessionName: sessionName,
            resumeExistingSession: shouldResume,
            persistSession: persistSession
        )
        if let p = claudePath {
            process.executableURL = URL(fileURLWithPath: p)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude"] + args
        }
        var environment = ProcessInfo.processInfo.environment
        environment["MEEE2_ASSISTANT_SESSION"] = "1"
        process.environment = environment
        let workspacePath = (rawWorkspacePath as NSString).standardizingPath
        if !workspacePath.isEmpty {
            try FileManager.default.createDirectory(
                atPath: workspacePath,
                withIntermediateDirectories: true
            )
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Render conversation as a plain prompt — same shape the previous
        // implementation used. claude -p treats stdin as the user input.
        var rendered: [String] = []
        for m in messages {
            let role: String
            switch m.role {
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .tool: role = "ToolResult(\(m.toolCallId ?? ""))"
            case .system: continue
            }
            rendered.append("\(role): \(m.content)")
        }
        rendered.append("Assistant:")
        let prompt = rendered.joined(separator: "\n\n")
        if let data = prompt.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        // Buffer stream-json line-by-line and emit text deltas. claude's
        // stream-json events look like:
        //   {"type":"assistant","message":{"content":[{"type":"text","text":"…"}]}}
        // and partial messages with "delta" subevents.
        var buf = Data()
        var fullText = ""
        let handle = stdout.fileHandleForReading
        // synchronous read loop because we're inside a detached Task; using
        // readabilityHandler complicates teardown.
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: 0..<nl)
                buf.removeSubrange(0...nl)
                guard let s = String(data: line, encoding: .utf8), !s.isEmpty else { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { continue }
                let kind = obj["type"] as? String ?? ""
                if kind == "stream_event",
                   let evt = obj["event"] as? [String: Any] {
                    let etype = evt["type"] as? String ?? ""
                    if etype == "content_block_delta",
                       let delta = evt["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let txt = delta["text"] as? String {
                        fullText += txt
                        continuation.yield(.textDelta(txt))
                    }
                } else if kind == "assistant",
                          let msg = obj["message"] as? [String: Any],
                          let content = msg["content"] as? [[String: Any]] {
                    // Final assistant message — fullText may already be
                    // populated from deltas; emit any tail text we missed.
                    var tail = ""
                    for blk in content where blk["type"] as? String == "text" {
                        tail += (blk["text"] as? String ?? "")
                    }
                    if tail.count > fullText.count {
                        let missing = String(tail.suffix(tail.count - fullText.count))
                        if !missing.isEmpty {
                            continuation.yield(.textDelta(missing))
                            fullText = tail
                        }
                    }
                }
            }
        }

        // Wait for exit
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw LocalClaudeExitError(status: process.terminationStatus, stderr: String(err.prefix(400)))
        }

        // Look for tool-call fence in the final text and emit as a tool call.
        if let call = parseToolFence(fullText) {
            continuation.yield(.toolCall(id: call.id, name: call.name, argsJSON: call.args))
        }
        continuation.yield(.turnDone(stopReason: nil))
        continuation.finish()
    }

    func claudeArguments(
        systemPrompt: String,
        model: String = "",
        sessionId: String,
        sessionName: String,
        resumeExistingSession: Bool = false,
        persistSession: Bool = true
    ) -> [String] {
        var args = [
            "-p",
            "--append-system-prompt", systemPrompt,
            "--name", sessionName,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]
        if resumeExistingSession {
            args.insert(contentsOf: ["--resume", sessionId], at: 3)
        } else {
            args.insert(contentsOf: ["--session-id", sessionId], at: 3)
        }
        if !persistSession {
            args.append("--no-session-persistence")
        }
        if !model.isEmpty {
            args += ["--model", model]
        }
        return args
    }

    struct LocalClaudeExitError: LocalizedError, Equatable {
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            "claude exited \(status): \(stderr)"
        }

        var isSessionIdError: Bool {
            let lower = stderr.lowercased()
            return lower.contains("session id") || lower.contains("session-id")
        }
    }

    typealias ParsedToolFence = LocalToolFence

    /// Exposed for tests — pure parser, no side effects.
    func parseToolFence(_ text: String) -> ParsedToolFence? {
        LocalAssistantToolProtocol.parseToolFence(text, idPrefix: "local")
    }

    private func resolveClaudeBinary() -> String? {
        let candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }
}

// MARK: - Local codex exec provider

/// Spawns local `codex exec --json` and adapts Codex JSONL events to the same
/// assistant provider contract. Codex emits complete `agent_message` items
/// rather than token deltas, so the provider yields each completed message as a
/// single text delta.
struct LocalCodexProvider: AssistantProvider {
    func runTurn(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ToolDef],
        settings: AssistantSettings
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                let gateResult = AssistantLocalRunGate.shared.acquireDetailed(
                    key: "codex:\(settings.canvasId)",
                    completionCooldown: settings.localRunPurpose.appliesCompletionCooldown
                )
                let lease: AssistantLocalRunGate.Lease
                switch gateResult {
                case .acquired(let acquiredLease):
                    lease = acquiredLease
                case .rejected(let reason):
                    let canvas = settings.canvasId.isEmpty ? "global" : settings.canvasId
                    MLog(
                        "[AssistantLocalRunGate] rejected localCodex canvas=\(canvas) "
                            + "purpose=\(settings.localRunPurpose.rawValue) reason=\(reason.description)"
                    )
                    continuation.yield(.error("local Codex assistant busy for this canvas (\(reason.description))"))
                    continuation.finish()
                    return
                }
                var mutableLease = lease
                defer { mutableLease.release() }

                let store = AssistantLocalCodexSessionStore.shared
                let persistSession = settings.localRunPurpose != .title
                let existingThreadId = persistSession ? store.sessionId(forCanvasId: settings.canvasId) : nil
                do {
                    try runProcess(
                        systemPrompt: LocalAssistantToolProtocol.augmentedSystemPrompt(systemPrompt, tools: tools),
                        messages: messages,
                        workspacePath: settings.workspacePath,
                        model: settings.model,
                        existingThreadId: existingThreadId,
                        canvasId: settings.canvasId,
                        persistSession: persistSession,
                        continuation: continuation
                    )
                } catch let error as LocalCodexExitError where error.isSessionIdError && existingThreadId != nil {
                    store.resetSessionId(forCanvasId: settings.canvasId)
                    do {
                        try runProcess(
                            systemPrompt: LocalAssistantToolProtocol.augmentedSystemPrompt(systemPrompt, tools: tools),
                            messages: messages,
                            workspacePath: settings.workspacePath,
                            model: settings.model,
                            existingThreadId: nil,
                            canvasId: settings.canvasId,
                            persistSession: persistSession,
                            continuation: continuation
                        )
                    } catch {
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    private func runProcess(
        systemPrompt: String,
        messages: [ChatMessage],
        workspacePath rawWorkspacePath: String,
        model: String,
        existingThreadId: String?,
        canvasId: String,
        persistSession: Bool,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) throws {
        let codexPath = resolveCodexBinary()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let workspacePath = (rawWorkspacePath as NSString).standardizingPath
        let args = codexArguments(
            model: model,
            workspacePath: workspacePath,
            existingThreadId: existingThreadId,
            ephemeral: !persistSession
        )

        if let p = codexPath {
            process.executableURL = URL(fileURLWithPath: p)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + args
        }
        var environment = ProcessInfo.processInfo.environment
        environment["MEEE2_ASSISTANT_SESSION"] = "1"
        process.environment = environment
        if !workspacePath.isEmpty {
            try FileManager.default.createDirectory(
                atPath: workspacePath,
                withIntermediateDirectories: true
            )
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        if let data = codexPrompt(systemPrompt: systemPrompt, messages: messages).data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        var buf = Data()
        var fullText = ""
        let handle = stdout.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: 0..<nl)
                buf.removeSubrange(0...nl)
                guard let s = String(data: line, encoding: .utf8), !s.isEmpty else { continue }
                try handleCodexJSONLine(
                    s,
                    canvasId: canvasId,
                    persistSession: persistSession,
                    fullText: &fullText,
                    continuation: continuation
                )
            }
        }

        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw LocalCodexExitError(status: process.terminationStatus, stderr: String(err.prefix(800)))
        }

        if let call = LocalAssistantToolProtocol.parseToolFence(fullText, idPrefix: "codex-local") {
            continuation.yield(.toolCall(id: call.id, name: call.name, argsJSON: call.args))
        }
        continuation.yield(.turnDone(stopReason: nil))
        continuation.finish()
    }

    func codexArguments(
        model: String = "",
        workspacePath rawWorkspacePath: String = "",
        existingThreadId: String? = nil,
        ephemeral: Bool = false
    ) -> [String] {
        let workspacePath = rawWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String]
        if let existingThreadId, !existingThreadId.isEmpty {
            args = ["exec", "resume", "--json", "--skip-git-repo-check"]
            if !model.isEmpty {
                args += ["--model", model]
            }
            args += [existingThreadId, "-"]
        } else {
            args = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check"]
            if ephemeral { args.append("--ephemeral") }
            if !model.isEmpty {
                args += ["--model", model]
            }
            if !workspacePath.isEmpty {
                args += ["--cd", workspacePath]
            }
            args.append("-")
        }
        return args
    }

    func codexPrompt(systemPrompt: String, messages: [ChatMessage]) -> String {
        var rendered = ["System:\n\(systemPrompt)"]
        for m in messages {
            let role: String
            switch m.role {
            case .system: role = "System"
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .tool: role = "ToolResult(\(m.toolCallId ?? ""))"
            }
            rendered.append("\(role): \(m.content)")
        }
        rendered.append("Assistant:")
        return rendered.joined(separator: "\n\n")
    }

    private func handleCodexJSONLine(
        _ line: String,
        canvasId: String,
        persistSession: Bool,
        fullText: inout String,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) throws {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "thread.started":
            if persistSession,
               let threadId = obj["thread_id"] as? String, !threadId.isEmpty {
                AssistantLocalCodexSessionStore.shared.setSessionId(threadId, forCanvasId: canvasId)
            }
        case "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String,
                  !text.isEmpty else { return }
            if !fullText.isEmpty { fullText += "\n\n" }
            fullText += text
            continuation.yield(.textDelta(text))
        case "turn.failed", "error":
            throw LocalCodexExitError(status: 1, stderr: codexErrorMessage(from: obj))
        default:
            break
        }
    }

    private func codexErrorMessage(from obj: [String: Any]) -> String {
        if let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = obj["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
        }
        return "codex JSON event reported failure"
    }

    struct LocalCodexExitError: LocalizedError, Equatable {
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            "codex exited \(status): \(stderr)"
        }

        var isSessionIdError: Bool {
            let lower = stderr.lowercased()
            return lower.contains("session") || lower.contains("thread")
        }
    }

    private func resolveCodexBinary() -> String? {
        let candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/codex"),
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }
}

private struct AssistantLocalCodexSessionRecord: Codable {
    var sessionId: String
    var createdAt: Date
    var updatedAt: Date
}

final class AssistantLocalCodexSessionStore {
    static let shared = AssistantLocalCodexSessionStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: AssistantLocalCodexSessionRecord]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = StorageRoots.processDefault.baseDirectory
                .appendingPathComponent("assistant/codex-sessions.json")
        }
    }

    func sessionId(forCanvasId canvasId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let key = AssistantLocalSessionStore.key(canvasId: canvasId)
        let current = loadRecords()
        guard var record = current[key], !record.sessionId.isEmpty else { return nil }
        var next = current
        record.updatedAt = Date()
        next[key] = record
        records = next
        saveRecords(next)
        return record.sessionId
    }

    func setSessionId(_ sessionId: String, forCanvasId canvasId: String) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = AssistantLocalSessionStore.key(canvasId: canvasId)
        var current = loadRecords()
        let createdAt = current[key]?.createdAt ?? Date()
        current[key] = AssistantLocalCodexSessionRecord(
            sessionId: trimmed,
            createdAt: createdAt,
            updatedAt: Date()
        )
        records = current
        saveRecords(current)
    }

    func resetSessionId(forCanvasId canvasId: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = AssistantLocalSessionStore.key(canvasId: canvasId)
        var current = loadRecords()
        current.removeValue(forKey: key)
        records = current
        saveRecords(current)
    }

    private func loadRecords() -> [String: AssistantLocalCodexSessionRecord] {
        if let records { return records }
        guard let data = try? Data(contentsOf: fileURL) else {
            records = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([String: AssistantLocalCodexSessionRecord].self, from: data)) ?? [:]
        records = decoded
        return decoded
    }

    private func saveRecords(_ records: [String: AssistantLocalCodexSessionRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            MLog("[AssistantLocalCodexSessionStore] failed to save session map: \(error.localizedDescription)")
        }
    }
}
