import Foundation

enum AgentLaunchCommand {
    static func fullAccessCommand(forProvider provider: String) -> String {
        normalizedProvider(provider) == "codex"
            ? "codex --dangerously-bypass-approvals-and-sandbox"
            : "claude --dangerously-skip-permissions && printf '\\033[2J\\033[H'"
    }

    static func normalizedProvider(_ raw: String) -> String {
        raw.lowercased().contains("codex") ? "codex" : "claude"
    }

    static func provider(forCommand command: String) -> String {
        normalizedProvider(command)
    }

    static func isMeee2InternalSessionId(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("claude-internal-") || lower.hasPrefix("codex-internal-")
    }

    static func isLikelyProviderResumeSessionId(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMeee2InternalSessionId(trimmed) else { return false }
        return UUID(uuidString: trimmed) != nil
    }

    static func commandRequestsResume(_ rawCommand: String) -> Bool {
        let lower = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return lower.range(
            of: #"(^|[\s"'=])(--resume|resume)([\s"'=]|$)"#,
            options: .regularExpression
        ) != nil
    }

    static func commandUsesInternalResumeId(_ rawCommand: String) -> Bool {
        let lower = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard commandRequestsResume(lower) else { return false }
        return lower.contains("claude-internal-") || lower.contains("codex-internal-")
    }

    static func normalize(command rawCommand: String, fallbackProvider: String = "claude") -> (provider: String, command: String) {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let provider = normalizedProvider(fallbackProvider)
            return (provider, fullAccessCommand(forProvider: provider))
        }

        let lower = trimmed.lowercased()
        let inferredProvider: String
        if lower.hasPrefix("codex") {
            inferredProvider = "codex"
        } else if lower.hasPrefix("claude") {
            inferredProvider = "claude"
        } else {
            inferredProvider = normalizedProvider(fallbackProvider)
        }
        if commandUsesInternalResumeId(trimmed) {
            return (inferredProvider, fullAccessCommand(forProvider: inferredProvider))
        }
        if lower.hasPrefix("codex") {
            if lower.contains("--dangerously-bypass-approvals-and-sandbox") {
                return ("codex", trimmed)
            }
            return ("codex", "\(trimmed) --dangerously-bypass-approvals-and-sandbox")
        }
        if lower.hasPrefix("claude") {
            if lower.contains("--dangerously-skip-permissions") || lower.contains("--permission-mode bypasspermissions") {
                return ("claude", trimmed)
            }
            return ("claude", "\(trimmed) --dangerously-skip-permissions && printf '\\033[2J\\033[H'")
        }
        return (normalizedProvider(fallbackProvider), trimmed)
    }
}
