import Foundation

enum BoardSessionSnapshotProvider {
    static func currentBoardSessions() -> [SessionDTO] {
        _ = InternalTerminalRuntime.shared.restorePersistedSurfaces()
        let terminalInfos = SessionTerminalStore.shared.getAll()
        let internalSessions = TerminalSessionBackendRegistry.shared
            .listSnapshots()
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
        let enrichedInternalSessions = (internalSessions + staleInternalSessions).map { dto -> SessionDTO in
            guard BoardDTOBuilder.isInternalTerminalProgram(dto.termProgram),
                  dto.recentMessages.isEmpty,
                  let cli = InternalSessionIdentity.correlatedCliSession(
                    forWorkspaceCwd: dto.project,
                    among: cliCorrelationCandidates,
                    // BUG B: gate out a stale prior-run CLI in a reused workspace.
                    // A freshly-dispatched surface must not adopt a dead/completed
                    // CLI that predates it — that would flip the live node
                    // running→failed. dto.startedAt is ISO8601 (iso8601.string).
                    surfaceStartedAt: dto.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                  ),
                  cli.sessionId != dto.id else {
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
