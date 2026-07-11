import Foundation

/// Generates one stable conversation title from the launcher's first user
/// prompt. The running agent stays untouched; a non-persistent provider call
/// performs the small summarization and failures keep the prompt fallback.
enum SessionTitleGenerator {
    static let codexPreferredModel = "gpt-5.4-mini"
    static let claudePreferredModel = "haiku"

    private static let lock = NSLock()
    private static var inFlight: Set<String> = []

    static func schedule(
        sessionId: String,
        provider: String,
        prompt: String,
        workspacePath: String
    ) {
        let providerKind: AssistantSettings.Provider = provider.lowercased().contains("codex")
            ? .localCodex
            : .local
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SessionStore.shared.get(sessionId)?.generatedTitle == nil,
              begin(sessionId: sessionId) else {
            return
        }

        let preferredModel = providerKind == .localCodex
            ? codexPreferredModel
            : claudePreferredModel
        let settings = titleSettings(
            provider: providerKind,
            model: preferredModel,
            sessionId: sessionId,
            workspacePath: workspacePath
        )
        let fallbackSettings = titleSettings(
            provider: providerKind,
            model: "",
            sessionId: sessionId,
            workspacePath: workspacePath
        )
        Task.detached {
            defer { finish(sessionId: sessionId) }
            let provider = AssistantProviderFactory.make(providerKind)
            let preferredTitle = await generateTitle(
                prompt: prompt,
                provider: provider,
                settings: settings
            )
            var title = preferredTitle
            if title == nil {
                title = await generateTitle(
                    prompt: prompt,
                    provider: AssistantProviderFactory.make(providerKind),
                    settings: fallbackSettings
                )
            }
            guard let title else { return }
            SessionStore.shared.update(sessionId) { session in
                // Compare-and-set: retries/provider refreshes never replace an
                // already accepted generated title.
                if session.generatedTitle == nil {
                    session.generatedTitle = title
                }
            }
        }
    }

    private static func titleSettings(
        provider: AssistantSettings.Provider,
        model: String,
        sessionId: String,
        workspacePath: String
    ) -> AssistantSettings {
        AssistantSettings(
            provider: provider,
            apiKey: "",
            baseUrl: "",
            model: model,
            enabledTools: [],
            scope: "this-mac",
            canvasId: "session-title-\(sessionId)",
            workspacePath: workspacePath,
            canvasName: "Session title",
            localRunPurpose: .title,
            selectedElements: []
        )
    }

    static func generateTitle(
        prompt: String,
        provider: AssistantProvider,
        settings: AssistantSettings
    ) async -> String? {
        let systemPrompt = """
        Generate a concise title for a software-agent conversation.
        Use the same language as the user. Capture the intent, not the wording.
        Prefer 3 to 8 words. Return only the title: no quotes, prefix, markdown,
        explanation, or trailing punctuation.
        """
        var output = ""
        do {
            for try await event in provider.runTurn(
                systemPrompt: systemPrompt,
                messages: [ChatMessage(role: .user, content: prompt)],
                tools: [],
                settings: settings
            ) {
                switch event {
                case .textDelta(let text): output += text
                case .error(let message):
                    MDebug("[SessionTitle] generation failed: \(message)")
                    return nil
                case .toolCall: return nil
                case .turnDone: break
                }
            }
        } catch {
            MDebug("[SessionTitle] generation failed: \(error.localizedDescription)")
            return nil
        }
        return cleanedTitle(output)
    }

    static func cleanedTitle(_ raw: String) -> String? {
        var title = raw
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(
            of: #"^(?:title|标题|主题)\s*[:：]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let paired: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("《", "》")]
        if paired.contains(where: { title.first == $0.0 && title.last == $0.1 }), title.count >= 2 {
            title.removeFirst()
            title.removeLast()
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r。.!?！？:：;；"))
        guard !title.isEmpty else { return nil }
        return title.count <= 200 ? title : String(title.prefix(200))
    }

    private static func begin(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.insert(sessionId).inserted
    }

    private static func finish(sessionId: String) {
        lock.lock()
        inFlight.remove(sessionId)
        lock.unlock()
    }
}
