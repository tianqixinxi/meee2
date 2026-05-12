import Foundation
import Swifter
import Meee2PluginKit

/// Global "ask & spawn" assistant — chat endpoint that supports three LLM
/// providers (OpenAI-compatible, Anthropic native, local `claude -p`) behind
/// the same SSE response shape.
///
/// Frontend POSTs `{ messages, settings }` and reads a server-sent-events
/// stream. Each event the orchestrator emits is one of:
///   • `delta`        — incremental text chunk for the current turn
///   • `tool_call`    — LLM is calling a tool, payload `{id, name, args}`
///   • `tool_result`  — tool finished, payload `{id, result}`
///   • `error`        — terminal failure, stream ends after
///   • `done`         — final event, always last; client closes EventSource
///
/// Settings shape:
///   {
///     provider: "openai" | "anthropic" | "local",
///     apiKey?: string,        // required for openai/anthropic, ignored for local
///     baseUrl?: string,       // optional override for hosted endpoints
///     model?: string,         // optional, sane defaults per provider
///     enabledTools?: string[],// omit = all tools enabled
///     canvasId?: string,      // current canvas id for canvas tools
///     workspacePath?: string, // current canvas workspace for local assistant
///     canvasName?: string
///   }
///
/// Tool catalogue lives in `AssistantTools` and is enforced server-side —
/// the frontend can't ask for tools it hasn't been granted.
enum AssistantAPI {

    private static let maxToolIterations = 8
    /// Total wall-clock cap for the whole orchestration. Hosted providers
    /// usually finish in <30s but local `claude -p` can take longer with
    /// big prompts; 180s is a comfortable upper bound.
    private static let totalTimeoutSeconds: TimeInterval = 180

    // MARK: - Route

    /// POST /api/assistant/chat
    /// Body: `{ messages: [{role, content}], settings: {...} }`
    /// Response: `text/event-stream` (see file header for event types).
    static func chat(_ req: HttpRequest) -> HttpResponse {
        let data = Data(req.body)
        guard let bodyObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BoardAPI.errorResponse("invalid_json", "expected {messages, settings}", status: 400)
        }
        guard let rawMessages = bodyObj["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "messages must be a non-empty array", status: 400)
        }

        let settings = parseSettings(bodyObj["settings"] as? [String: Any])
        let messages = rawMessages.compactMap { dict -> ChatMessage? in
            guard let role = dict["role"] as? String,
                  let content = dict["content"] as? String else { return nil }
            switch role {
            case "user": return ChatMessage(role: .user, content: content)
            case "assistant": return ChatMessage(role: .assistant, content: content)
            default: return nil
            }
        }
        guard !messages.isEmpty, messages.last?.role == .user else {
            return BoardAPI.errorResponse("bad_request", "last message must be role=user", status: 400)
        }

        let systemPrompt = buildSystemPrompt(settings: settings)

        // SSE response. The writer block runs synchronously in Swifter; we
        // launch the async orchestrator inside, signal completion via a
        // DispatchGroup, and serialize all writes through one queue so the
        // socket isn't written from two threads at once.
        return .raw(200, "OK", [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no"
        ]) { writer in
            let writeQueue = DispatchQueue(label: "assistant.sse.write")
            let send: (String, String) -> Void = { eventType, json in
                let line = "event: \(eventType)\ndata: \(json)\n\n"
                let bytes = Array(line.utf8)
                writeQueue.sync {
                    try? writer.write(bytes)
                }
            }

            let group = DispatchGroup()
            group.enter()
            Task.detached {
                await orchestrate(
                    systemPrompt: systemPrompt,
                    initialMessages: messages,
                    settings: settings,
                    send: send
                )
                group.leave()
            }
            _ = group.wait(timeout: .now() + totalTimeoutSeconds)
        }
    }

    // MARK: - Orchestration loop

    /// Drives the conversation: call provider → relay events → if tool
    /// calls came back, dispatch them and re-prompt the LLM with results.
    /// Loops up to `maxToolIterations` times before giving up.
    private static func orchestrate(
        systemPrompt: String,
        initialMessages: [ChatMessage],
        settings: AssistantSettings,
        send: @escaping (String, String) -> Void
    ) async {
        var transcript = initialMessages
        let tools = AssistantTools.filter(settings.enabledTools)

        for iter in 0..<maxToolIterations {
            let provider = AssistantProviderFactory.make(settings.provider)
            var pendingCalls: [ToolCallRef] = []
            var assistantText = ""
            var streamFailed = false

            do {
                for try await ev in provider.runTurn(
                    systemPrompt: systemPrompt,
                    messages: transcript,
                    tools: tools,
                    settings: settings
                ) {
                    switch ev {
                    case .textDelta(let txt):
                        assistantText += txt
                        send("delta", encodeJSON(["text": txt]))
                    case .toolCall(let id, let name, let argsJSON):
                        pendingCalls.append(ToolCallRef(id: id, name: name, argsJSON: argsJSON))
                        // Splice the raw args JSON in unquoted so the client
                        // receives a real object, not a string.
                        let argsBlob = argsJSON.isEmpty ? "{}" : argsJSON
                        send("tool_call",
                             "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"args\":\(argsBlob)}")
                    case .turnDone:
                        break
                    case .error(let msg):
                        send("error", encodeJSON(["message": msg]))
                        send("done", "{}")
                        return
                    }
                }
            } catch {
                send("error", encodeJSON(["message": error.localizedDescription]))
                send("done", "{}")
                streamFailed = true
            }
            if streamFailed { return }

            // No tool calls → conversation done.
            if pendingCalls.isEmpty {
                send("done", "{}")
                return
            }

            // Tool calls present → execute each, append assistant + tool
            // messages to the transcript, loop back to the provider.
            transcript.append(ChatMessage(
                role: .assistant,
                content: assistantText,
                toolCalls: pendingCalls
            ))
            for call in pendingCalls {
                let argsObj = (try? JSONSerialization.jsonObject(with: Data(call.argsJSON.utf8))) as? [String: Any] ?? [:]
                let result = AssistantTools.dispatch(name: call.name, args: argsObj, enabled: settings.enabledTools, settings: settings)
                let resultJSON: String
                switch result {
                case .success(let payload):
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let s = String(data: data, encoding: .utf8) {
                        resultJSON = s
                    } else {
                        resultJSON = "{}"
                    }
                case .failure(let msg):
                    resultJSON = encodeJSON(["error": msg])
                }
                send("tool_result",
                     "{\"id\":\(jsonString(call.id)),\"result\":\(resultJSON)}")
                transcript.append(ChatMessage(
                    role: .tool,
                    content: resultJSON,
                    toolCallId: call.id
                ))
            }

            _ = iter  // suppress unused
        }

        // Hit the iteration cap.
        send("error", encodeJSON(["message": "max tool iterations reached (\(maxToolIterations))"]))
        send("done", "{}")
    }

    // MARK: - Settings parsing

    /// Internal (not `private`) so unit tests can hit it directly without
    /// having to spin up the whole HTTP path.
    static func parseSettings(_ raw: [String: Any]?) -> AssistantSettings {
        let dict = raw ?? [:]
        let providerStr = (dict["provider"] as? String) ?? "local"
        let provider = AssistantSettings.Provider(rawValue: providerStr) ?? .local
        let apiKey = (dict["apiKey"] as? String) ?? ""
        let baseUrl = (dict["baseUrl"] as? String) ?? ""
        let model = (dict["model"] as? String) ?? ""
        let enabledList = dict["enabledTools"] as? [String]
        let enabled: Set<String>? = enabledList.map { Set($0) }
        let scope = (dict["scope"] as? String) ?? "this-mac"
        let canvasId = ((dict["canvasId"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let workspacePath = ((dict["workspacePath"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let canvasName = ((dict["canvasName"] as? String) ?? "Canvas").trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedElements = parseSelectedElements(dict["selectedElements"] as? [[String: Any]])
        return AssistantSettings(
            provider: provider,
            apiKey: apiKey,
            baseUrl: baseUrl,
            model: model,
            enabledTools: enabled,
            scope: scope,
            canvasId: canvasId,
            workspacePath: workspacePath,
            canvasName: canvasName.isEmpty ? "Canvas" : canvasName,
            selectedElements: selectedElements
        )
    }

    private static func parseSelectedElements(_ raw: [[String: Any]]?) -> [AssistantSelectedElement] {
        (raw ?? []).prefix(12).compactMap { item in
            guard let id = item["id"] as? String,
                  let type = item["type"] as? String,
                  let label = item["label"] as? String else {
                return nil
            }
            return AssistantSelectedElement(
                id: id,
                type: type,
                label: label,
                textPreview: item["textPreview"] as? String,
                sessionId: item["sessionId"] as? String,
                channelName: item["channelName"] as? String,
                x: numberValue(item["x"]),
                y: numberValue(item["y"]),
                width: numberValue(item["width"]),
                height: numberValue(item["height"])
            )
        }
    }

    private static func numberValue(_ raw: Any?) -> Double {
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let string = raw as? String, let double = Double(string) { return double }
        return 0
    }

    // MARK: - System prompt

    static func buildSystemPrompt(settings: AssistantSettings) -> String {
        AssistantContextBuilder.buildSystemPrompt(settings: settings)
    }

    static func runAutomation(title: String, prompt: String, settings: AssistantSettings) async -> (output: String, error: String?) {
        let systemPrompt = """
        You are the meee2 automation runner. Execute the user's saved automation
        against the current local board state. Use tools when they are useful,
        especially for session inventory and session details. Be factual: only
        claim evidence you observed through tools or current context. If a
        requested action is unsafe or ambiguous, explain the missing input
        instead of pretending it was completed.

        Return a concise markdown result with:
        - result
        - evidence
        - recommended next actions

        \(buildSystemPrompt(settings: settings))
        """
        var transcript = [
            ChatMessage(role: .user, content: "Automation: \(title)\n\n\(prompt)")
        ]
        let tools = AssistantTools.filter(settings.enabledTools)
        var finalText = ""

        for _ in 0..<maxToolIterations {
            let provider = AssistantProviderFactory.make(settings.provider)
            var pendingCalls: [ToolCallRef] = []
            var assistantText = ""

            do {
                for try await ev in provider.runTurn(
                    systemPrompt: systemPrompt,
                    messages: transcript,
                    tools: tools,
                    settings: settings
                ) {
                    switch ev {
                    case .textDelta(let text):
                        assistantText += text
                    case .toolCall(let id, let name, let argsJSON):
                        pendingCalls.append(ToolCallRef(id: id, name: name, argsJSON: argsJSON))
                    case .turnDone:
                        break
                    case .error(let message):
                        return (finalText.isEmpty ? assistantText : finalText, message)
                    }
                }
            } catch {
                return (finalText.isEmpty ? assistantText : finalText, error.localizedDescription)
            }

            finalText = assistantText
            if pendingCalls.isEmpty {
                return (assistantText.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            }

            transcript.append(ChatMessage(role: .assistant, content: assistantText, toolCalls: pendingCalls))
            for call in pendingCalls {
                let argsObj = (try? JSONSerialization.jsonObject(with: Data(call.argsJSON.utf8))) as? [String: Any] ?? [:]
                let result = AssistantTools.dispatch(name: call.name, args: argsObj, enabled: settings.enabledTools, settings: settings)
                let resultJSON: String
                switch result {
                case .success(let payload):
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let string = String(data: data, encoding: .utf8) {
                        resultJSON = string
                    } else {
                        resultJSON = "{}"
                    }
                case .failure(let message):
                    resultJSON = encodeJSON(["error": message])
                }
                transcript.append(ChatMessage(role: .tool, content: resultJSON, toolCallId: call.id))
            }
        }

        return (finalText, "max tool iterations reached (\(maxToolIterations))")
    }

    // MARK: - JSON helpers

    /// Build a single JSON object from a `[String: Any]` payload (string /
    /// number / bool / nested dict / array). Used for `delta` and `error`
    /// events whose payloads are pure data; events that need to splice raw
    /// JSON (tool_call args, tool_result result) build the line manually.
    private static func encodeJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Quote + escape a string into a JSON string literal (including the
    /// surrounding double quotes). Use for splicing into hand-built JSON.
    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        guard let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        // ["foo"] → "foo"
        return String(str.dropFirst().dropLast())
    }
}
