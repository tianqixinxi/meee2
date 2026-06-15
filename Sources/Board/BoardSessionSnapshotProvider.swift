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
        return enrichedInternalSessions
    }

    private static func boardSession(_ session: SessionDTO, matches sessionId: String) -> Bool {
        session.id == sessionId
            || session.id.hasSuffix("-\(sessionId)")
            || session.surfaceId == sessionId
    }
}
