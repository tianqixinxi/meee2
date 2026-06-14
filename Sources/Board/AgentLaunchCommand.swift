import Foundation

enum AgentLaunchCommand {
    static let codexAutomationFlags = "--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
    static let codexPlanModeConfig = "-c 'collaboration_mode=\"plan\"'"

    static func fullAccessCommand(forProvider provider: String) -> String {
        launchCommand(forProvider: provider, permissionMode: "fullAccess")
    }

    static func launchCommand(forProvider provider: String, permissionMode rawMode: String?, planMode: Bool = false) -> String {
        let provider = normalizedProvider(provider)
        let mode = normalizedPermissionMode(rawMode)
        let planRequested = planMode || mode == "plan"
        if provider == "codex" {
            let command: String
            switch mode == "plan" ? "fullAccess" : mode {
            case "readOnly":
                command = "codex --sandbox read-only --ask-for-approval on-request --dangerously-bypass-hook-trust"
            case "onRequest", "default":
                command = "codex --sandbox workspace-write --ask-for-approval on-request --dangerously-bypass-hook-trust"
            case "acceptEdits":
                command = "codex --sandbox workspace-write --ask-for-approval never --dangerously-bypass-hook-trust"
            default:
                command = "codex \(codexAutomationFlags)"
            }
            return planRequested ? commandWithCodexPlanMode(command) : command
        }
        if planRequested {
            return "claude --permission-mode plan"
        }
        switch mode {
        case "default", "onRequest", "readOnly":
            return "claude --permission-mode default"
        case "acceptEdits":
            return "claude --permission-mode acceptEdits"
        default:
            return "claude --dangerously-skip-permissions"
        }
    }

    static func resumeCommand(forProvider provider: String, sessionId: String) -> String {
        let quotedSessionId = "'\(sessionId.replacingOccurrences(of: "'", with: "'\\''"))'"
        return normalizedProvider(provider) == "codex"
            ? "codex \(codexAutomationFlags) resume \(quotedSessionId)"
            : "claude --resume \(quotedSessionId) --dangerously-skip-permissions"
    }

    static func normalizedProvider(_ raw: String) -> String {
        raw.lowercased().contains("codex") ? "codex" : "claude"
    }

    static func normalizedPermissionMode(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "readonly", "read_only", "read-only":
            return "readOnly"
        case "onrequest", "on_request", "on-request", "confirm", "ask", "default":
            return "onRequest"
        case "acceptedits", "accept_edits", "accept-edits", "autoedit", "auto":
            return "acceptEdits"
        case "plan", "planning":
            return "plan"
        case "fullaccess", "full_access", "full-access", "bypasspermissions", "bypass", "danger":
            return "fullAccess"
        default:
            return "fullAccess"
        }
    }

    static func provider(forCommand command: String) -> String {
        normalizedProvider(command)
    }

    static func isMeee2InternalSessionId(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("claude-internal-")
            || lower.hasPrefix("codex-internal-")
            || lower.hasPrefix("claude-ghostty-")
            || lower.hasPrefix("codex-ghostty-")
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
        return lower.contains("claude-internal-")
            || lower.contains("codex-internal-")
            || lower.contains("claude-ghostty-")
            || lower.contains("codex-ghostty-")
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
            return ("codex", commandWithCodexAutomationFlags(trimmed))
        }
        if lower.hasPrefix("claude") {
            if lower.contains("--dangerously-skip-permissions") || lower.contains("--permission-mode bypasspermissions") {
                return ("claude", trimmed)
            }
            return ("claude", "\(trimmed) --dangerously-skip-permissions")
        }
        return (normalizedProvider(fallbackProvider), trimmed)
    }

    private static func commandWithCodexAutomationFlags(_ command: String) -> String {
        var parts = [command]
        let lower = command.lowercased()
        if !lower.contains("--dangerously-bypass-approvals-and-sandbox") {
            parts.append("--dangerously-bypass-approvals-and-sandbox")
        }
        if !lower.contains("--dangerously-bypass-hook-trust") {
            parts.append("--dangerously-bypass-hook-trust")
        }
        return parts.joined(separator: " ")
    }

    private static func commandWithCodexPlanMode(_ command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("collaboration_mode") {
            return command
        }
        if lower == "codex" {
            return "codex \(codexPlanModeConfig)"
        }
        if lower.hasPrefix("codex ") {
            return "codex \(codexPlanModeConfig) \(command.dropFirst("codex ".count))"
        }
        return "\(command) \(codexPlanModeConfig)"
    }
}
