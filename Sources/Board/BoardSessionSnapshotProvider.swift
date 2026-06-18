import Foundation
import Meee2PluginKit

enum BoardSessionSnapshotProvider {
    static func currentBoardSessions() -> [SessionDTO] {
        let snapshots = TerminalSessionBackendRegistry.shared.listSnapshots()
        SessionTerminalStore.shared.reconcileManagedSurfaceStatuses(liveSnapshots: snapshots)
        let terminalInfos = SessionTerminalStore.shared.getAll()
        let internalSessions = snapshots
            .filter { $0.status != "exited" && $0.status != "failed" }
            .map(BoardDTOBuilder.internalSessionDTO)
        let staleInternalSessions = SessionStore.shared.listAll()
            .filter { !$0.status.isHistorical }
            .filter { BoardDTOBuilder.isInternalTerminalProgram($0.terminalInfo?.termProgram) }
            .filter { session in
                !internalSessions.contains { internalSession in
                    boardSession(internalSession, matches: session.sessionId)
                }
            }
            // req3: a LOCAL (non-managed-workspace) record that is no longer in the
            // live surface registry only belongs in the list if its process is still
            // alive. Otherwise it is a dead surface leftover (its CLI half, if still
            // running, surfaces under its own UUID record and is kept below).
            .filter { isLiveLocalSession($0) }
            .map { session in
                BoardDTOBuilder.staleInternalSessionDTO(session, terminalInfo: terminalInfos[session.sessionId])
            }
        let cliCorrelationCandidates = SessionStore.shared.listAll()
        let cliCorrelationIndex = InternalSessionIdentity.makeCliCorrelationIndex(candidates: cliCorrelationCandidates)
        let iso8601 = ISO8601DateFormatter()
        let enrichedInternalSessions = (internalSessions + staleInternalSessions).map { dto -> SessionDTO in
            guard BoardDTOBuilder.isInternalTerminalProgram(dto.termProgram),
                  dto.recentMessages.isEmpty else {
                return dto
            }
            // Bind this surface to the CLI session it ACTUALLY launched, keyed by
            // the surface's own providerResumeSessionId (recorded by ClaudePlugin
            // on the first hook). The per-canvas workspace dir is shared by every
            // node + every re-dispatch, so the cwd heuristic below can adopt a
            // *sibling node's* CLI session and bleed its `.dead` status onto this
            // live surface — resetting the node to 未启动. The authoritative id
            // match eliminates that; cwd correlation is only the fallback for the
            // brief pre-first-hook window where no providerResumeSessionId exists.
            let resumeId = SessionTerminalStore.shared.get(sessionId: dto.id)?
                .providerResumeSessionId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? dto.providerResumeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cli = InternalSessionIdentity.authoritativeCliSession(
                forProviderResumeSessionId: resumeId,
                in: cliCorrelationIndex
            ) ?? InternalSessionIdentity.correlatedCliSession(
                forWorkspaceCwd: dto.project,
                in: cliCorrelationIndex,
                // BUG B: gate out a stale prior-run CLI in a reused workspace.
                // A freshly-dispatched surface must not adopt a dead/completed
                // CLI that predates it — that would flip the live node
                // running→failed. dto.startedAt is ISO8601 (iso8601.string).
                surfaceStartedAt: dto.startedAt.flatMap { iso8601.date(from: $0) }
            )
            guard let cli, cli.sessionId != dto.id else { return dto }
            let usedAuthoritative = resumeId.map { !$0.isEmpty && cli.sessionId == $0 } ?? false
            // Defense-in-depth for the cwd-fallback path: a live internal surface
            // (exited/failed surfaces are filtered out above) means its own
            // `claude` is still running, so a *historical* adopted status can only
            // come from the WRONG (sibling/prior-run) CLI. Never let it downgrade
            // a live surface to dead/completed — that is the exact reset we are
            // eliminating. The authoritative path is exempt: it is this surface's
            // own CLI, so its historical status is genuine.
            if !usedAuthoritative,
               TranscriptStatusResolver.resolve(for: cli).isHistorical,
               !SessionStatus.from(rawString: dto.status).isHistorical {
                return dto
            }
            return BoardDTOBuilder.surfaceDTOAdoptingCliSession(dto, cli: cli)
        }
        let externalStoredSessions = SessionStore.shared.listAll()
            .filter { !$0.status.isHistorical }
            .filter { !BoardDTOBuilder.isInternalTerminalProgram($0.terminalInfo?.termProgram) }
            .filter { session in
                !enrichedInternalSessions.contains { boardSession($0, matches: session.sessionId) }
            }
            // req3: an external native session is a LOCAL terminal — keep it only
            // while its process lives (a dead native terminal can no longer be
            // jumped to). Managed-workspace (canvas/node) sessions are exempt: their
            // lifecycle is owned by the canvas, not a live local PID.
            .filter { isLiveLocalSession($0) }
            .map { session in
                let terminalInfo = terminalInfos[session.sessionId]
                let pluginId = pluginId(for: session, terminalInfo: terminalInfo)
                return BoardDTOBuilder.sessionDTO(session.toPluginSession(pluginId: pluginId))
            }
        // req1: collapse cards that represent the SAME CLI session. A meee2-launched
        // terminal leaves both a surface record (claude-ghostty-*) and the real
        // `claude` CLI record (UUID), tied only by providerResumeSessionId — the
        // id-based dedup above misses them. Keep the most openable/live card per id.
        return dedupByProviderResumeSessionId(enrichedInternalSessions + externalStoredSessions)
    }

    /// A LOCAL (non-managed-workspace) session is shown only while its process is
    /// alive. Canvas/node sessions live under `~/.meee2/workspaces` and keep their
    /// own lifecycle (no live local PID requirement).
    private static func isLiveLocalSession(_ session: SessionData) -> Bool {
        let path = session.cwd ?? session.project
        if InternalSessionIdentity.isMeee2ManagedWorkspace(path) { return true }
        return SessionStore.processAlive(session.pid)
    }

    /// Collapse SessionDTOs that share a non-empty `providerResumeSessionId` (they
    /// are the surface + CLI halves of one terminal). Keeps the highest-ranked card.
    static func dedupByProviderResumeSessionId(_ sessions: [SessionDTO]) -> [SessionDTO] {
        var indexByResumeId: [String: Int] = [:]
        var result: [SessionDTO] = []
        for session in sessions {
            let resumeId = session.providerResumeSessionId?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !resumeId.isEmpty else {
                result.append(session)
                continue
            }
            if let existing = indexByResumeId[resumeId] {
                if shouldPreferResumeDuplicate(session, over: result[existing]) {
                    result[existing] = session
                }
            } else {
                indexByResumeId[resumeId] = result.count
                result.append(session)
            }
        }
        return result
    }

    /// Within a `providerResumeSessionId` group prefer the card backed by a live
    /// openable surface (native-workspace), then a non-historical status, then the
    /// most recent activity.
    private static func shouldPreferResumeDuplicate(_ candidate: SessionDTO, over current: SessionDTO) -> Bool {
        let candidateRank = resumeDuplicateRank(candidate)
        let currentRank = resumeDuplicateRank(current)
        if candidateRank != currentRank { return candidateRank > currentRank }
        return resumeDuplicateActivity(candidate) > resumeDuplicateActivity(current)
    }

    private static func resumeDuplicateRank(_ session: SessionDTO) -> Int {
        var rank = 0
        if session.openTarget == "native-workspace" { rank += 4 }
        if session.surfaceId != nil { rank += 2 }
        if !SessionStatus.from(rawString: session.status).isHistorical { rank += 1 }
        return rank
    }

    private static func resumeDuplicateActivity(_ session: SessionDTO) -> Date {
        guard let raw = session.lastActivity ?? session.startedAt else { return .distantPast }
        return ISO8601DateFormatter().date(from: raw) ?? .distantPast
    }

    private static func boardSession(_ session: SessionDTO, matches sessionId: String) -> Bool {
        session.id == sessionId
            || session.id.hasSuffix("-\(sessionId)")
            || session.surfaceId == sessionId
    }

    private static func pluginId(for session: SessionData, terminalInfo: SessionTerminalInfo?) -> String {
        let haystack = [
            terminalInfo?.provider,
            terminalInfo?.command,
            session.terminalInfo?.termProgram,
            session.sessionId
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("codex") ? "com.meee2.plugin.codex" : "com.meee2.plugin.claude"
    }
}
