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
        return internalSessions + staleInternalSessions
    }

    private static func boardSession(_ session: SessionDTO, matches sessionId: String) -> Bool {
        session.id == sessionId
            || session.id.hasSuffix("-\(sessionId)")
            || session.surfaceId == sessionId
    }
}
