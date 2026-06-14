import Foundation

enum SessionSurfaceLaunchAction: String, Encodable {
    case create
    case reuse
    case resume
    case recreate
}

struct SessionSurfaceRestoreResult {
    let surface: TerminalSessionSnapshot
    let action: SessionSurfaceLaunchAction
    let providerResumeSessionId: String?
}

enum SessionSurfaceLauncher {
    static func explicitCwd(_ raw: String?) throws -> String? {
        var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("~") {
            value = NSHomeDirectory() + String(value.dropFirst(1))
        }
        let normalized = (value as NSString).standardizingPath
        guard normalized.hasPrefix("/") else {
            throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd must be an absolute path"])
        }
        guard normalized != "/" && normalized != NSHomeDirectory() else {
            throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd is too broad"])
        }
        return normalized
    }

    static func createInternalSessionSurface(
        provider: String,
        cwd: String,
        command: String,
        createIfMissing: Bool,
        canvasId: String?,
        nodeId: String?,
        initialPrompt: String?,
        preferredSessionId: String? = nil,
        recordLauncherInitialPrompt: Bool = false
    ) throws -> TerminalSessionSnapshot {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            if createIfMissing {
                try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            } else {
                throw NSError(domain: "BoardAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "cwd does not exist: \(cwd)"])
            }
        }
        let trimmedPreferredSessionId = preferredSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reusablePreferredSessionId = trimmedPreferredSessionId?.isEmpty == false ? trimmedPreferredSessionId : nil
        let resumeSessionId = reusablePreferredSessionId.flatMap(providerResumeSessionId(forSessionId:))
        let launchCommand = resumeSessionId.map {
            AgentLaunchCommand.resumeCommand(forProvider: provider, sessionId: $0)
        } ?? command
        let handle = try TerminalSessionBackendRegistry.shared.createSession(
            request: TerminalSessionRequest(
                provider: AgentLaunchCommand.normalizedProvider(provider),
                cwd: cwd,
                command: launchCommand,
                canvasId: canvasId,
                nodeId: nodeId,
                initialPrompt: resumeSessionId == nil ? initialPrompt : nil,
                preferredSessionId: reusablePreferredSessionId
            )
        )
        if recordLauncherInitialPrompt {
            recordInitialPrompt(handle.snapshot.sessionId, initialPrompt: resumeSessionId == nil ? initialPrompt : nil)
        }
        BoardServer.shared.broadcastStateChanged()
        return handle.snapshot
    }

    static func restoreSessionSurface(
        sessionId: String,
        cwd: String,
        freshCommand: String,
        resumeCommand: (String) -> String,
        createIfMissing: Bool,
        canvasId: String?,
        nodeId: String?,
        freshInitialPrompt: String?,
        recordLauncherInitialPrompt: Bool = false
    ) throws -> SessionSurfaceRestoreResult {
        if let existingSurface = TerminalSessionBackendRegistry.shared.snapshot(id: sessionId),
           isReusableInternalSurface(existingSurface) {
            return SessionSurfaceRestoreResult(surface: existingSurface, action: .reuse, providerResumeSessionId: nil)
        }

        let resumeSessionId = providerResumeSessionId(forSessionId: sessionId)
        let command = resumeSessionId.map(resumeCommand) ?? freshCommand
        let provider = AgentLaunchCommand.provider(forCommand: command)
        let preferredSessionId = isProviderResumeSessionId(sessionId) || resumeSessionId != nil ? sessionId : nil
        let surface = try createInternalSessionSurface(
            provider: provider,
            cwd: cwd,
            command: command,
            createIfMissing: createIfMissing,
            canvasId: canvasId,
            nodeId: nodeId,
            initialPrompt: resumeSessionId == nil ? freshInitialPrompt : nil,
            preferredSessionId: preferredSessionId,
            recordLauncherInitialPrompt: recordLauncherInitialPrompt
        )
        return SessionSurfaceRestoreResult(
            surface: surface,
            action: resumeSessionId == nil ? .recreate : .resume,
            providerResumeSessionId: resumeSessionId
        )
    }

    static func restoreLauncherSession(
        sessionId: String,
        provider providerOverride: String? = nil,
        cwd cwdOverride: String? = nil
    ) throws -> SessionSurfaceRestoreResult {
        let sessionData = SessionStore.shared.get(sessionId)
        let terminalInfo = SessionTerminalStore.shared.get(sessionId: sessionId)
        let cwd = try explicitCwd(cwdOverride)
            ?? sessionData?.cwd
            ?? terminalInfo?.cwd
            ?? sessionData?.project
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "BoardAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: "session cwd not found: \(sessionId)"])
        }
        let provider = inferProvider(
            override: providerOverride,
            terminalInfo: terminalInfo,
            sessionData: sessionData,
            fallbackSessionId: sessionId
        )
        return try restoreSessionSurface(
            sessionId: sessionId,
            cwd: cwd,
            freshCommand: AgentLaunchCommand.fullAccessCommand(forProvider: provider),
            resumeCommand: { AgentLaunchCommand.resumeCommand(forProvider: provider, sessionId: $0) },
            createIfMissing: true,
            canvasId: terminalInfo?.canvasId,
            nodeId: terminalInfo?.nodeId,
            freshInitialPrompt: nil,
            recordLauncherInitialPrompt: false
        )
    }

    static func isReusableInternalSurface(_ surface: TerminalSessionSnapshot) -> Bool {
        surface.status == InternalTerminalLifecycle.starting.rawValue
            || surface.status == InternalTerminalLifecycle.running.rawValue
    }

    static func providerResumeSessionId(forSessionId sessionId: String) -> String? {
        providerResumeSessionIdForManagedSurface(sessionId)
            ?? (isProviderResumeSessionId(sessionId) ? sessionId : nil)
    }

    static func isProviderResumeSessionId(_ sessionId: String) -> Bool {
        AgentLaunchCommand.isLikelyProviderResumeSessionId(sessionId)
    }

    private static func providerResumeSessionIdForManagedSurface(_ sessionId: String) -> String? {
        if let mapped = SessionTerminalStore.shared.get(sessionId: sessionId)?.providerResumeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty,
           !AgentLaunchCommand.isMeee2InternalSessionId(mapped) {
            return mapped
        }
        return nil
    }

    private static func inferProvider(
        override: String?,
        terminalInfo: SessionTerminalInfo?,
        sessionData: SessionData?,
        fallbackSessionId: String
    ) -> String {
        let haystack = [
            override,
            terminalInfo?.provider,
            terminalInfo?.command,
            sessionData?.sessionId,
            fallbackSessionId,
            sessionData?.terminalInfo?.termProgram
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        return AgentLaunchCommand.normalizedProvider(haystack)
    }

    private static func recordInitialPrompt(_ sessionId: String, initialPrompt: String?) {
        let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return }
        SessionStore.shared.update(sessionId) { session in
            session.currentTask = prompt
            session.lastMessage = prompt
        }
    }
}
