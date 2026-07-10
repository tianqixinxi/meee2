import Foundation

struct AgentLaunchAttachment: Codable, Equatable {
    let path: String
    let filename: String?
    let contentType: String?
}

enum AgentLaunchCommand {
    static let codexFullAccessFlags = "--dangerously-bypass-approvals-and-sandbox"

    static func defaultCommand(forProvider provider: String) -> String {
        launchCommand(forProvider: provider, permissionMode: "onRequest")
    }

    static func fullAccessCommand(forProvider provider: String) -> String {
        launchCommand(forProvider: provider, permissionMode: "fullAccess")
    }

    static func launchCommand(forProvider provider: String, permissionMode rawMode: String?, planMode: Bool = false) -> String {
        let provider = normalizedProvider(provider)
        let mode = normalizedPermissionMode(rawMode)
        let planRequested = planMode || mode == "plan"
        if provider == "codex" {
            let command: String
            switch mode == "plan" ? "onRequest" : mode {
            case "readOnly":
                command = "codex --sandbox read-only --ask-for-approval on-request"
            case "onRequest", "default":
                command = "codex --sandbox workspace-write --ask-for-approval on-request"
            case "acceptEdits":
                command = "codex --sandbox workspace-write --ask-for-approval never"
            default:
                command = "codex \(codexFullAccessFlags)"
            }
            return command
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

    static func resumeCommand(
        forProvider provider: String,
        sessionId: String,
        permissionMode: String? = "onRequest"
    ) -> String {
        let quotedSessionId = "'\(sessionId.replacingOccurrences(of: "'", with: "'\\''"))'"
        let provider = normalizedProvider(provider)
        let base = launchCommand(forProvider: provider, permissionMode: permissionMode)
        return provider == "codex"
            ? "\(base) resume \(quotedSessionId)"
            : "\(base) --resume \(quotedSessionId)"
    }

    static func launcherInitialPrompt(
        forProvider provider: String,
        planMode: Bool,
        initialPrompt rawPrompt: String?,
        attachments: [AgentLaunchAttachment] = []
    ) -> String? {
        let prompt = rawPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attachmentLines = attachments
            .map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "@\($0)" }
        let content = (attachmentLines + (prompt.isEmpty ? [] : [prompt])).joined(separator: "\n")
        if planMode && normalizedProvider(provider) == "codex" {
            return content.isEmpty ? "/plan" : "/plan \(content)"
        }
        return content.isEmpty ? nil : content
    }

    static func launcherDisplayPrompt(forDeliveredInitialPrompt rawPrompt: String?) -> String? {
        let prompt = rawPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return nil }
        let lower = prompt.lowercased()
        guard lower == "/plan" || lower.hasPrefix("/plan ") else {
            return displayPromptWithoutLeadingAttachments(prompt)
        }
        let withoutPlan = prompt.dropFirst("/plan".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayPromptWithoutLeadingAttachments(withoutPlan)
    }

    static func normalizedProvider(_ raw: String) -> String {
        raw.lowercased().contains("codex") ? "codex" : "claude"
    }

    private static func displayPromptWithoutLeadingAttachments(_ raw: String) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let firstPromptIndex = lines.firstIndex { line in
            !isAttachmentReferenceLine(String(line))
        }
        guard let firstPromptIndex else { return nil }
        let prompt = lines[firstPromptIndex...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private static func isAttachmentReferenceLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("@/") || line.hasPrefix("@~")
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
            return "onRequest"
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
            return (provider, defaultCommand(forProvider: provider))
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
            return (inferredProvider, defaultCommand(forProvider: inferredProvider))
        }
        if lower.hasPrefix("codex") {
            return ("codex", commandWithCodexSafetyDefaults(trimmed))
        }
        if lower.hasPrefix("claude") {
            if lower.contains("--dangerously-skip-permissions") || lower.contains("--permission-mode") {
                return ("claude", trimmed)
            }
            return ("claude", "\(trimmed) --permission-mode default")
        }
        return (normalizedProvider(fallbackProvider), trimmed)
    }

    private static func commandWithCodexSafetyDefaults(_ command: String) -> String {
        var parts = [command]
        let lower = command.lowercased()
        let explicitlyBypassesApprovals = lower.contains("--dangerously-bypass-approvals-and-sandbox")
        if !explicitlyBypassesApprovals && !lower.contains("--sandbox") {
            parts.append("--sandbox workspace-write")
        }
        if !explicitlyBypassesApprovals && !lower.contains("--ask-for-approval") {
            parts.append("--ask-for-approval on-request")
        }
        return parts.joined(separator: " ")
    }

}
