import Foundation
import Meee2PluginKit

/// Builds the default context for the board assistant.
///
/// This intentionally stays separate from AssistantAPI: the API owns HTTP and
/// SSE orchestration, while this builder owns prompt/context policy.
enum AssistantContextBuilder {
    private static let sessionSummaryBudgetBytes = 8 * 1024
    private static let cwdSummaryBudgetBytes = 3 * 1024
    private static let maxDefaultOtherSessions = 8

    static func buildSystemPrompt(settings: AssistantSettings) -> String {
        let canvasContext = loadCanvasContext(settings: settings)
        let workspacePath = canvasContext.workspacePath.isEmpty
            ? settings.workspacePath
            : canvasContext.workspacePath
        let sessionSummary = currentSessionSummary(context: canvasContext)
        let cwdList = candidateCwds(currentWorkspace: workspacePath)
        let cwdSummary = cwdList.isEmpty
            ? "(no recent projects found)"
            : budgetedLines(cwdList.map { "- \($0)" }, maxBytes: cwdSummaryBudgetBytes)
        let selectedSummary = selectedElementsSummary(settings.selectedElements)
        let scopeSummary = assistantScopeSummary(settings.scope)

        return """
        You are the meee2 board assistant. The user can see a canvas of
        live Claude / Codex / etc. sessions and is asking you to query,
        summarise, or spawn new ones.

        Be concise. Respond in the user's language (often Chinese).

        Current assistant scope:
        \(scopeSummary)

        Current canvas:
        - ID: \(canvasContext.canvasId.isEmpty ? "(not set)" : canvasContext.canvasId)
        - Name: \(canvasContext.canvasName)
        - Workspace: \(workspacePath.isEmpty ? "(not set)" : workspacePath)

        Treat this chat as a temporary assistant bound to the current canvas.
        It does not create a board session card by itself. For local file/path
        work, use the current canvas workspace as the working directory.

        Default context policy:
        - The session list below is lightweight metadata, not full transcripts.
        - Current-canvas visible sessions are the primary context.
        - If selected canvas elements are present, treat them as the user's
          current focus for this turn.
        - Hidden or other-canvas sessions are only included as a short index.
        - For content-level questions, call transcript/channel tools instead
          of guessing from previews.

        Current sessions on the board:
        \(sessionSummary.isEmpty ? "(none)" : sessionSummary)

        Selected canvas elements at chat start:
        \(selectedSummary.isEmpty ? "(none)" : selectedSummary)

        Recent project directories on this machine:
        \(cwdSummary)

        User's home is \(NSHomeDirectory()). Always use absolute paths
        (expand `~` to the home).

        You have these tools available (call them when the user's intent
        clearly maps to one):
          - get_session_list        -- narrow by status / plugin / project
          - get_session_info        -- fetch full state + a short transcript preview
          - get_session_transcript  -- recent transcript entries for content questions
          - list_channels           -- A2A channels (name / mode / member count)
          - get_channel_messages    -- recent messages on a channel for content questions
          - get_canvas_context      -- read the current canvas layout and visible items
          - propose_canvas_patch    -- propose a low-risk canvas layout/note change; user applies it
          - create_session          -- spawn a new local session at a cwd
          - create_coordinator_session -- spawn a global coordinator session for selected sessions
          - get_coordination_state  -- read hybrid coordinator groups and compact member digests
          - send_to_session         -- route a message through a session's operator inbox
          - broadcast_to_members    -- route messages to a coordinator group's members
          - update_group_digest     -- maintain compact coordinator/member state
          - ask_coordinator         -- manually wake a global coordinator with compact context
          - pause_coordination / resume_coordination -- control automatic coordinator wake-ups

        Guidelines:
          - If the user asks "what sessions do I have", call get_session_list
            instead of guessing.
          - If they ask about a specific session, call get_session_info.
          - If they ask to summarise / explain what a session is doing or
            what it asked, call get_session_transcript (it returns more
            entries than get_session_info's preview).
          - If they ask about an A2A channel ("ops channel", "today's coordination
            channel"), call list_channels first if the id is fuzzy, then
            get_channel_messages with the channel name.
          - If they ask what is on this canvas, how things are laid out, or
            whether you can rearrange the canvas, call get_canvas_context.
          - If they explicitly ask to tidy, move, hide, show, or add/update a
            note/label/frame/connector/shape on the canvas, call
            propose_canvas_patch. This only produces an Apply card in the UI;
            do not claim the canvas changed until the user clicks Apply.
          - Use add_frame for groups, add_connector for relationships, and
            add_shape/add_label for role or status nodes. Prefer stylePreset:
            coordination, review, dependency, handoff, or group.
          - If the user says to create a lead/coordinator/组长/reviewer for
            selected sessions, call create_coordinator_session.
          - Coordinators do not depend on channels. For routing work, use
            send_to_session or broadcast_to_members. For state, use
            get_coordination_state and update_group_digest.
          - Do not generate arbitrary Excalidraw JSON. Use only the supported
            proposal operations.
          - Do not create a new session unless the user explicitly asks to
            create or open one. For normal questions, answer in this temporary
            canvas assistant.
          - If they explicitly ask to create / open a new session, call
            create_session. Use mode=global for canvas-wide/coordinator work
            and mode=project only when a project cwd is clear.
          - For mutating tools (create_session) prefer to confirm the cwd
            briefly with the user first if there's any ambiguity.
        """
    }

    private struct CanvasContext {
        let canvasId: String
        let canvasName: String
        let workspacePath: String
        let visibleSessionIds: Set<String>
        let hiddenSessionIds: Set<String>
        let layout: BoardLayoutStore.Layout
    }

    private static func loadCanvasContext(settings: AssistantSettings) -> CanvasContext {
        let snapshot = BoardLayoutStore.shared.snapshot()
        let requestedId = settings.canvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        let canvasId = requestedId.isEmpty ? snapshot.activeCanvasId : requestedId
        let canvas = snapshot.canvases.first(where: { $0.id == canvasId })
        let layout = canvas.map { BoardLayoutStore.shared.load(canvasId: $0.id) } ?? .empty
        let memberships = snapshot.memberships.filter { $0.canvasId == canvasId }
        let visibleIds = Set(memberships.filter { $0.visible }.map { $0.sessionId })
        let hiddenIds = Set(memberships.filter { !$0.visible }.map { $0.sessionId })
        let workspacePath = (try? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)) ?? settings.workspacePath
        return CanvasContext(
            canvasId: canvas?.id ?? canvasId,
            canvasName: canvas?.name ?? settings.canvasName,
            workspacePath: workspacePath,
            visibleSessionIds: visibleIds,
            hiddenSessionIds: hiddenIds,
            layout: layout
        )
    }

    private enum CanvasPresence: Int {
        case visible = 0
        case hidden = 1
        case other = 2

        var label: String {
            switch self {
            case .visible: return "visible"
            case .hidden: return "hidden"
            case .other: return "other-canvas"
            }
        }
    }

    private static func currentSessionSummary(context: CanvasContext) -> String {
        let live = PluginManager.shared.sessions.filter { !$0.status.isHistorical }
        guard !live.isEmpty else { return "" }

        let rows = live.map { session in
            (presence: presence(for: session, context: context), session: session)
        }.sorted { lhs, rhs in
            if lhs.presence.rawValue != rhs.presence.rawValue {
                return lhs.presence.rawValue < rhs.presence.rawValue
            }
            if lhs.presence == .visible,
               let lp = context.layout.sessions[lhs.session.id],
               let rp = context.layout.sessions[rhs.session.id] {
                if lp.y != rp.y { return lp.y < rp.y }
                return lp.x < rp.x
            }
            return lastActivity(lhs.session) > lastActivity(rhs.session)
        }

        let visibleRows = rows.filter { $0.presence == .visible }
        let hiddenRows = rows.filter { $0.presence == .hidden }
        let otherRows = rows.filter { $0.presence == .other }.prefix(maxDefaultOtherSessions)

        var lines: [String] = []
        appendSection(
            title: "Current canvas visible sessions",
            rows: visibleRows,
            context: context,
            into: &lines
        )
        appendSection(
            title: "Hidden on this canvas",
            rows: hiddenRows,
            context: context,
            into: &lines
        )
        appendSection(
            title: "Other live sessions (short index only)",
            rows: Array(otherRows),
            context: context,
            into: &lines
        )

        return budgetedLines(lines, maxBytes: sessionSummaryBudgetBytes)
    }

    private static func selectedElementsSummary(_ elements: [AssistantSelectedElement]) -> String {
        guard !elements.isEmpty else { return "" }
        let lines = elements.prefix(12).map { el in
            var parts = [
                "- \(shortId(el.id))",
                "type=\(el.type)",
                "label=\(el.label)",
                "pos=(\(Int(el.x)),\(Int(el.y)))",
                "size=\(Int(el.width))x\(Int(el.height))"
            ]
            if let sessionId = normalizeEmpty(el.sessionId) {
                parts.append("sessionId=\(sessionId)")
            }
            if let channelName = normalizeEmpty(el.channelName) {
                parts.append("channelName=\(channelName)")
            }
            if let text = normalizeEmpty(el.textPreview) {
                parts.append("text=\"\(truncate(text, to: 220))\"")
            }
            return parts.joined(separator: " | ")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        title: String,
        rows: [(presence: CanvasPresence, session: PluginSession)],
        context: CanvasContext,
        into lines: inout [String]
    ) {
        guard !rows.isEmpty else { return }
        lines.append("\(title):")
        for row in rows {
            lines.append(sessionLine(row.session, presence: row.presence, context: context))
        }
    }

    private static func sessionLine(
        _ session: PluginSession,
        presence: CanvasPresence,
        context: CanvasContext
    ) -> String {
        let realId = realSessionId(session)
        let stored = SessionStore.shared.get(realId)
        let pluginName = PluginManager.shared.getPluginInfo(for: session.pluginId)?.displayName ?? session.pluginId
        let title = session.title.isEmpty ? "(untitled)" : session.title
        let cwd = normalizeEmpty(session.cwd ?? stored?.cwd)
        let tool = normalizeEmpty(stored?.currentTool ?? session.toolName)
        let task = normalizeEmpty(stored?.currentTask ?? session.subtitle)
        let model = normalizeEmpty((stored?.usageStats ?? session.usageStats)?.model)
        let latest = normalizeEmpty(session.lastMessage ?? stored?.lastMessage)
        let pendingPermission = normalizeEmpty(stored?.pendingPermissionTool)
        let point = context.layout.sessions[session.id]

        var parts: [String] = []
        parts.append("- \(shortId(session.id))")
        parts.append("[\(presence.label)]")
        parts.append("[\(statusName(session.status))]")
        parts.append(title)
        parts.append("plugin=\(pluginName)")
        if let cwd { parts.append("cwd=\(cwd)") }
        parts.append("last=\(iso(lastActivity(session)))")
        if let point { parts.append("pos=(\(Int(point.x)),\(Int(point.y)))") }
        if let model { parts.append("model=\(model)") }
        if let tool { parts.append("tool=\(tool)") }
        if let task { parts.append("task=\(truncate(task, to: 160))") }
        if let pendingPermission { parts.append("pendingPermission=\(pendingPermission)") }
        if let latest { parts.append("latest=\"\(truncate(latest, to: 220))\"") }
        return parts.joined(separator: " | ")
    }

    private static func presence(for session: PluginSession, context: CanvasContext) -> CanvasPresence {
        if context.visibleSessionIds.contains(session.id) { return .visible }
        if context.hiddenSessionIds.contains(session.id) { return .hidden }
        return .other
    }

    private static func realSessionId(_ session: PluginSession) -> String {
        let prefix = "\(session.pluginId)-"
        if session.id.hasPrefix(prefix) {
            return String(session.id.dropFirst(prefix.count))
        }
        return session.id
    }

    private static func lastActivity(_ session: PluginSession) -> Date {
        session.lastUpdated ?? session.startedAt
    }

    private static func statusName(_ status: SessionStatus) -> String {
        status.rawValue
    }

    private static func shortId(_ id: String) -> String {
        id.count <= 8 ? id : String(id.prefix(8))
    }

    private static func normalizeEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func truncate(_ s: String, to maxChars: Int) -> String {
        if s.count <= maxChars { return s }
        return String(s.prefix(maxChars)) + "..."
    }

    private static func budgetedLines(_ lines: [String], maxBytes: Int) -> String {
        var used = 0
        var out: [String] = []
        for line in lines {
            let bytes = line.utf8.count + 1
            if used + bytes > maxBytes {
                out.append("- ... truncated to keep default context small; call tools for more.")
                break
            }
            out.append(line)
            used += bytes
        }
        return out.joined(separator: "\n")
    }

    /// Recent project directories from SessionTerminalStore + ~/projects/*.
    private static func candidateCwds(currentWorkspace: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []

        func append(_ raw: String?) {
            guard let raw else { return }
            let cwd = (raw as NSString).standardizingPath
            guard cwd.hasPrefix("/"), !seen.contains(cwd) else { return }
            seen.insert(cwd)
            out.append(cwd)
        }

        append(currentWorkspace)

        let infos = SessionTerminalStore.shared.getAll().values
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        for info in infos {
            append(info.cwd)
            if out.count >= 20 { break }
        }

        let projectsRoot = (NSHomeDirectory() as NSString).appendingPathComponent("projects")
        if let children = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) {
            for child in children.sorted() {
                let path = (projectsRoot as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                append(path)
                if out.count >= 30 { break }
            }
        }
        return out
    }

    private static func assistantScopeSummary(_ scope: String) -> String {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "this-mac" {
            return "This Mac. Use local meee2 tools and local session context."
        }
        let teamName = BoardDTOBuilder.meee2OnlineTeams().first(where: { $0.id == trimmed })?.name ?? trimmed
        return "Team: \(teamName). Prefer team-scoped wording, but any action that changes this Mac must still use local meee2 tools."
    }
}
