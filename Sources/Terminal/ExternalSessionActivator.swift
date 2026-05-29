import Foundation

public enum ExternalSessionActivator {
    public static func activate(_ session: SessionData) {
        if ClaudeDesktopActivator.isDesktopBacked(
            sid: session.sessionId,
            transcriptPath: session.transcriptPath
        ) {
            ClaudeDesktopActivator.activate(sid: session.sessionId)
            return
        }

        let terminalInfo = session.terminalInfo
        var aiSession = AISession(
            id: session.sessionId,
            pid: session.pid ?? 0,
            cwd: session.cwd ?? session.project,
            startedAt: session.startedAt,
            status: session.status,
            currentTask: session.currentTask,
            toolName: session.currentTool
        )
        aiSession.lastUpdated = session.lastActivity
        aiSession.tty = terminalInfo?.tty
        aiSession.termProgram = terminalInfo?.termProgram
        aiSession.termBundleId = terminalInfo?.termBundleId
        aiSession.cmuxSocketPath = terminalInfo?.cmuxSocketPath
        aiSession.cmuxSurfaceId = terminalInfo?.cmuxSurfaceId
        aiSession.ghosttyTerminalId = session.ghosttyTerminalId
        TerminalManager.smartActivateTerminal(forSession: aiSession)
    }
}
