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
        let normalizedProvider = AgentLaunchCommand.normalizedProvider(provider)
        let promptToDeliver = resumeSessionId == nil ? initialPrompt : nil
        let handle = try TerminalSessionBackendRegistry.shared.createSession(
            request: TerminalSessionRequest(
                provider: normalizedProvider,
                cwd: cwd,
                command: launchCommand,
                canvasId: canvasId,
                nodeId: nodeId,
                initialPrompt: promptToDeliver,
                initialPromptSettleCeiling: initialPromptSettleCeiling(
                    provider: normalizedProvider,
                    initialPrompt: promptToDeliver
                ),
                preferredSessionId: reusablePreferredSessionId
            )
        )
        if recordLauncherInitialPrompt {
            recordInitialPrompt(
                handle.snapshot.sessionId,
                provider: normalizedProvider,
                cwd: cwd,
                initialPrompt: resumeSessionId == nil ? initialPrompt : nil
            )
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
        providerResumeSessionId providerResumeSessionIdOverride: String? = nil,
        provider providerOverride: String? = nil,
        permissionMode: String? = nil,
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
        if let existingSurface = TerminalSessionBackendRegistry.shared.snapshot(id: sessionId),
           isReusableInternalSurface(existingSurface) {
            return SessionSurfaceRestoreResult(surface: existingSurface, action: .reuse, providerResumeSessionId: nil)
        }
        let explicitResumeId = providerResumeSessionIdOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resumeSessionId = explicitResumeId
            .flatMap { isProviderResumeSessionId($0) ? $0 : nil }
            ?? providerResumeSessionId(forSessionId: sessionId)
        guard let resumeSessionId else {
            throw NSError(
                domain: "BoardAPI",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "session cannot be resumed because no provider resume id was recorded"]
            )
        }
        return try restoreSessionSurface(
            sessionId: resumeSessionId,
            cwd: cwd,
            freshCommand: AgentLaunchCommand.defaultCommand(forProvider: provider),
            resumeCommand: {
                AgentLaunchCommand.resumeCommand(
                    forProvider: provider,
                    sessionId: $0,
                    permissionMode: permissionMode
                )
            },
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
        let sessionData = SessionStore.shared.get(sessionId)
        if let mapped = sessionData?.providerResumeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty,
           !AgentLaunchCommand.isMeee2InternalSessionId(mapped) {
            return mapped
        }
        if let mapped = SessionTerminalStore.shared.get(sessionId: sessionId)?.providerResumeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !mapped.isEmpty,
           !AgentLaunchCommand.isMeee2InternalSessionId(mapped) {
            SessionStore.shared.setProviderResumeSessionId(sessionId: sessionId, providerResumeSessionId: mapped)
            return mapped
        }
        let terminalInfo = SessionTerminalStore.shared.get(sessionId: sessionId)
        if let backfilled = CodexProviderSessionBackfill.findAndPersistProviderResumeSessionId(
            sessionData: sessionData,
            terminalInfo: terminalInfo
        ) {
            return backfilled
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

    private static func recordInitialPrompt(
        _ sessionId: String,
        provider: String,
        cwd: String,
        initialPrompt: String?
    ) {
        guard let prompt = AgentLaunchCommand.launcherDisplayPrompt(
            forDeliveredInitialPrompt: initialPrompt
        ) else { return }
        SessionStore.shared.update(sessionId) { session in
            session.currentTask = prompt
            session.lastMessage = prompt
        }
        SessionTitleGenerator.schedule(
            sessionId: sessionId,
            provider: provider,
            prompt: prompt,
            workspacePath: cwd
        )
    }

    private static func initialPromptSettleCeiling(provider: String, initialPrompt: String?) -> TimeInterval? {
        let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return nil }
        return provider == "codex" ? 90.0 : nil
    }
}
