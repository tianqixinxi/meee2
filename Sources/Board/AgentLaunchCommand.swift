import Foundation

enum AgentLaunchCommand {
    static func fullAccessCommand(forProvider provider: String) -> String {
        normalizedProvider(provider) == "codex"
            ? "codex --dangerously-bypass-approvals-and-sandbox"
            : "claude --dangerously-skip-permissions"
    }

    static func normalizedProvider(_ raw: String) -> String {
        raw.lowercased().contains("codex") ? "codex" : "claude"
    }

    static func provider(forCommand command: String) -> String {
        normalizedProvider(command)
    }

    static func normalize(command rawCommand: String, fallbackProvider: String = "claude") -> (provider: String, command: String) {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let provider = normalizedProvider(fallbackProvider)
            return (provider, fullAccessCommand(forProvider: provider))
        }

        let lower = trimmed.lowercased()
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
            return ("claude", "\(trimmed) --dangerously-skip-permissions")
        }
        return (normalizedProvider(fallbackProvider), trimmed)
    }
}
