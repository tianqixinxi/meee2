import Foundation
import Meee2PluginKit

// MARK: - Quick Open Entry

enum QuickOpenEntryKind: String, CaseIterable {
    case session
    case canvas
    case artifact
}

/// 扁平化的 Quick Open 条目，供浮窗搜索和跳转。
struct SessionPaletteEntry: Identifiable, Equatable {
    let id: String
    let kind: QuickOpenEntryKind
    let title: String
    let subtitle: String
    let detail: String?
    let searchableText: String
    let status: String
    let statusRaw: SessionStatus?
    let lastActivity: Date
    let sessionId: String
    let surfaceId: String?
    let canvasId: String?
    let nodeId: String?
    let artifactId: String?
    let terminalKind: String

    static func == (lhs: SessionPaletteEntry, rhs: SessionPaletteEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search Engine

/// Quick Open 搜索引擎 —— 对内存中 session / canvas / artifact 做全文匹配 + 过滤。
/// 设计目标：冷启动 < 200ms（纯内存操作，无网络 I/O）。
final class SessionPaletteSearchEngine {

    enum DomainFilter: String, CaseIterable {
        case all
        case sessions
        case canvases
        case artifacts
    }

    enum SortBy: String {
        case relevance
        case lastActivity
        case kind
    }

    var query: String = ""
    var domainFilter: DomainFilter = .all
    var sortBy: SortBy = .relevance

    init() {}

    func search(
        sessions: [PluginSession],
        storeSessions: [SessionData],
        internalSurfaces: [TerminalSessionSnapshot] = [],
        canvases: [BoardLayoutStore.Canvas] = [],
        artifacts: [PlannerArtifact] = []
    ) -> [SessionPaletteEntry] {
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let storeBySessionId = Dictionary(uniqueKeysWithValues: storeSessions.map { ($0.sessionId, $0) })
        let canvasNames = Dictionary(uniqueKeysWithValues: canvases.map { ($0.id, $0.name) })
        var entries: [SessionPaletteEntry] = []
        var seenSessionIds = Set<String>()

        if domainFilter == .all || domainFilter == .sessions {
            entries += internalSessionEntries(
                surfaces: internalSurfaces,
                storeBySessionId: storeBySessionId,
                seenSessionIds: &seenSessionIds
            )
            entries += externalSessionEntries(
                sessions: sessions,
                seenSessionIds: seenSessionIds
            )
        }

        if domainFilter == .all || domainFilter == .canvases {
            entries += canvases.map(canvasEntry)
        }

        if domainFilter == .all || domainFilter == .artifacts {
            entries += artifacts.map { artifactEntry($0, canvasNames: canvasNames) }
        }

        let filtered = entries
            .map { entry -> (entry: SessionPaletteEntry, score: Int) in
                (entry, score(query: queryLower, haystack: entry.searchableText))
            }
            .filter { queryLower.isEmpty || $0.score > 0 }

        switch sortBy {
        case .relevance:
            return filtered
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.entry.lastActivity > $1.entry.lastActivity
                }
                .map(\.entry)
        case .lastActivity:
            return filtered
                .sorted { $0.entry.lastActivity > $1.entry.lastActivity }
                .map(\.entry)
        case .kind:
            return filtered
                .sorted {
                    if $0.entry.kind.rawValue != $1.entry.kind.rawValue {
                        return $0.entry.kind.rawValue < $1.entry.kind.rawValue
                    }
                    return $0.entry.title < $1.entry.title
                }
                .map(\.entry)
        }
    }

    func counts(
        sessions: [PluginSession],
        storeSessions: [SessionData],
        internalSurfaces: [TerminalSessionSnapshot] = [],
        canvases: [BoardLayoutStore.Canvas] = [],
        artifacts: [PlannerArtifact] = []
    ) -> [DomainFilter: Int] {
        var seenSessionIds = Set<String>()
        let storeBySessionId = Dictionary(uniqueKeysWithValues: storeSessions.map { ($0.sessionId, $0) })
        let internalCount = internalSessionEntries(
            surfaces: internalSurfaces,
            storeBySessionId: storeBySessionId,
            seenSessionIds: &seenSessionIds
        ).count
        let externalCount = externalSessionEntries(sessions: sessions, seenSessionIds: seenSessionIds).count
        let sessionCount = internalCount + externalCount
        return [
            .all: sessionCount + canvases.count + artifacts.count,
            .sessions: sessionCount,
            .canvases: canvases.count,
            .artifacts: artifacts.count
        ]
    }

    private func internalSessionEntries(
        surfaces: [TerminalSessionSnapshot],
        storeBySessionId: [String: SessionData],
        seenSessionIds: inout Set<String>
    ) -> [SessionPaletteEntry] {
        surfaces
            .filter { $0.status != "exited" && $0.status != "failed" }
            .compactMap { surface -> SessionPaletteEntry? in
                guard seenSessionIds.insert(surface.sessionId).inserted else { return nil }
                let storeSession = storeBySessionId[surface.sessionId]
                let status = storeSession?.status ?? .active
                let statusText = surface.status == "running" ? statusName(for: status) : surface.status
                let title = internalSurfaceTitle(surface)
                let project = URL(fileURLWithPath: storeSession?.cwd ?? surface.cwd).lastPathComponent
                return SessionPaletteEntry(
                    id: "session:\(surface.sessionId)",
                    kind: .session,
                    title: title,
                    subtitle: project,
                    detail: "Internal · \(statusText)",
                    searchableText: [
                        title, surface.sessionId, surface.surfaceId,
                        surface.canvasId ?? "", surface.nodeId ?? "",
                        project, surface.cwd, statusText,
                        storeSession?.currentTask ?? "",
                        storeSession?.currentTool ?? "",
                        storeSession?.lastMessage ?? ""
                    ].joined(separator: " ").lowercased(),
                    status: statusText,
                    statusRaw: status,
                    lastActivity: surface.updatedAt,
                    sessionId: surface.sessionId,
                    surfaceId: surface.surfaceId,
                    canvasId: surface.canvasId,
                    nodeId: surface.nodeId,
                    artifactId: nil,
                    terminalKind: "internal"
                )
            }
    }

    private func externalSessionEntries(
        sessions: [PluginSession],
        seenSessionIds: Set<String>
    ) -> [SessionPaletteEntry] {
        sessions
            .filter { !seenSessionIds.contains($0.id) }
            .filter { !$0.status.isHistorical || $0.urgentEvent != nil }
            .map { session in
                let pluginDisplayName = PluginManager.shared.getPluginInfo(for: session.pluginId)?.displayName
                    ?? session.pluginId
                let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? session.projectName
                let statusText = statusName(for: session.status)
                return SessionPaletteEntry(
                    id: "session:\(session.id)",
                    kind: .session,
                    title: session.title,
                    subtitle: project,
                    detail: "\(pluginDisplayName) · \(statusText)",
                    searchableText: [
                        session.title,
                        session.id,
                        session.pluginId,
                        pluginDisplayName,
                        project,
                        session.cwd ?? "",
                        session.subtitle ?? "",
                        session.toolName ?? "",
                        session.lastMessage ?? "",
                        statusText
                    ].joined(separator: " ").lowercased(),
                    status: statusText,
                    statusRaw: session.status,
                    lastActivity: session.lastUpdated ?? session.startedAt,
                    sessionId: session.id,
                    surfaceId: nil,
                    canvasId: nil,
                    nodeId: nil,
                    artifactId: nil,
                    terminalKind: "external"
                )
            }
    }

    private func canvasEntry(_ canvas: BoardLayoutStore.Canvas) -> SessionPaletteEntry {
        let kind = canvas.kind?.rawValue ?? "board"
        let workspaceFolder = canvas.workspaceFolderName ?? ""
        let updated = canvas.lastRemoteUpdatedAt ?? canvas.lastSyncedAt ?? canvas.dirtySince ?? Date.distantPast
        return SessionPaletteEntry(
            id: "canvas:\(canvas.id)",
            kind: .canvas,
            title: canvas.name,
            subtitle: workspaceFolder,
            detail: "\(kind) canvas",
            searchableText: [
                canvas.name,
                canvas.id,
                workspaceFolder,
                canvas.teamId ?? "",
                canvas.ownerUserId ?? "",
                kind
            ].joined(separator: " ").lowercased(),
            status: kind,
            statusRaw: nil,
            lastActivity: updated,
            sessionId: "",
            surfaceId: nil,
            canvasId: canvas.id,
            nodeId: nil,
            artifactId: nil,
            terminalKind: ""
        )
    }

    private func artifactEntry(_ artifact: PlannerArtifact, canvasNames: [String: String]) -> SessionPaletteEntry {
        let canvasName = canvasNames[artifact.canvasId] ?? artifact.canvasId
        let version = artifact.versionIndex.map { "v\($0)" } ?? artifact.status
        return SessionPaletteEntry(
            id: "artifact:\(artifact.canvasId):\(artifact.id)",
            kind: .artifact,
            title: artifact.title,
            subtitle: canvasName,
            detail: "\(artifact.kind.rawValue) · \(version)",
            searchableText: [
                artifact.title,
                artifact.id,
                artifact.canvasId,
                artifact.nodeId,
                artifact.kind.rawValue,
                artifact.reference,
                artifact.status,
                canvasName
            ].joined(separator: " ").lowercased(),
            status: artifact.status,
            statusRaw: nil,
            lastActivity: artifact.createdAt,
            sessionId: "",
            surfaceId: nil,
            canvasId: artifact.canvasId,
            nodeId: artifact.nodeId,
            artifactId: artifact.id,
            terminalKind: ""
        )
    }

    private func internalSurfaceTitle(_ surface: TerminalSessionSnapshot) -> String {
        let displayName = surface.provider.lowercased() == "codex" ? "Codex" : "Claude"
        let project = URL(fileURLWithPath: surface.cwd).lastPathComponent
        return "\(displayName) - \(project)"
    }

    private func statusName(for status: SessionStatus) -> String {
        switch status {
        case .active: return "active"
        case .thinking: return "thinking"
        case .tooling: return "tooling"
        case .idle: return "idle"
        case .waitingForUser: return "waitingForUser"
        case .permissionRequired: return "permissionRequired"
        case .awaitingChoice: return "awaitingChoice"
        case .completed: return "completed"
        case .compacting: return "compacting"
        case .dead: return "dead"
        }
    }

    private func score(query: String, haystack: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count > 1 {
            var total = 0
            for token in tokens {
                let tokenScore = scoreSingleToken(query: token, haystack: haystack)
                guard tokenScore > 0 else { return 0 }
                total += tokenScore
            }
            return total + tokens.count * 40
        }
        return scoreSingleToken(query: query, haystack: haystack)
    }

    private func scoreSingleToken(query: String, haystack: String) -> Int {
        if let range = haystack.range(of: query) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let boundaryBonus = offset == 0 ? 50 : 0
            return 1_000 - offset + boundaryBonus + query.count
        }

        var queryIndex = query.startIndex
        var spread = 0
        var lastMatch: String.Index?
        var haystackIndex = haystack.startIndex
        while haystackIndex < haystack.endIndex && queryIndex < query.endIndex {
            if haystack[haystackIndex] == query[queryIndex] {
                if let lastMatch {
                    spread += haystack.distance(from: lastMatch, to: haystackIndex) - 1
                }
                lastMatch = haystackIndex
                queryIndex = query.index(after: queryIndex)
            }
            haystackIndex = haystack.index(after: haystackIndex)
        }
        guard queryIndex == query.endIndex else { return 0 }
        return max(1, 200 - spread)
    }
}
