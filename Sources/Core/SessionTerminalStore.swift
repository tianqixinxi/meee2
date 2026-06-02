import Foundation

/// Session 与终端的映射信息
struct SessionTerminalInfo: Codable {
    let sessionId: String
    var tty: String?
    var termProgram: String?
    var termBundleId: String?
    var cwd: String
    var lastActivityAt: Date
    var status: String
    var command: String?
    var provider: String?
    var providerResumeSessionId: String?
    var canvasId: String?
    var nodeId: String?
    var backend: String?
    var fallbackReason: String?

    // cmux 专用
    var cmuxSocketPath: String?
    var cmuxSurfaceId: String?
}

/// 持久化 Session-Terminal 映射
/// 存储位置: ~/.meee2/session-terminals.json
class SessionTerminalStore {
    static let shared = SessionTerminalStore()

    private let fileManager = FileManager.default
    private let storeURL: URL
    private var store: [String: SessionTerminalInfo] = [:]
    private let queue = DispatchQueue(label: "com.meee2.terminalstore", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()

    private init() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        storeURL = dir.appendingPathComponent("session-terminals.json")
        queue.setSpecific(key: queueKey, value: ())

        // 确保目录存在
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        load()

        // 启动时清理过期 session
        cleanupExpired()
    }

    // MARK: - Public Methods

    /// 更新 session 的终端信息
    func update(
        sessionId: String,
        tty: String?,
        termProgram: String?,
        termBundleId: String?,
        cmuxSocketPath: String?,
        cmuxSurfaceId: String?,
        cwd: String,
        status: String,
        command: String? = nil,
        provider: String? = nil,
        providerResumeSessionId: String? = nil,
        canvasId: String? = nil,
        nodeId: String? = nil,
        backend: String? = nil,
        fallbackReason: String? = nil
    ) {
        performSync {
            var info = store[sessionId] ?? SessionTerminalInfo(
                sessionId: sessionId,
                tty: tty,
                termProgram: termProgram,
                termBundleId: termBundleId,
                cwd: cwd,
                lastActivityAt: Date(),
                status: status,
                command: command,
                provider: provider,
                providerResumeSessionId: providerResumeSessionId,
                canvasId: canvasId,
                nodeId: nodeId,
                backend: backend,
                fallbackReason: fallbackReason,
                cmuxSocketPath: cmuxSocketPath,
                cmuxSurfaceId: cmuxSurfaceId
            )

            info.tty = tty ?? info.tty
            info.termProgram = termProgram ?? info.termProgram
            info.termBundleId = termBundleId ?? info.termBundleId
            info.cmuxSocketPath = cmuxSocketPath ?? info.cmuxSocketPath
            info.cmuxSurfaceId = cmuxSurfaceId ?? info.cmuxSurfaceId
            if let command {
                info.command = Self.commandForStorage(provider: provider ?? info.provider, command: command)
            }
            info.provider = provider ?? info.provider
            if let providerResumeSessionId {
                info.providerResumeSessionId = Self.validProviderResumeSessionId(providerResumeSessionId)
            }
            info.canvasId = canvasId ?? info.canvasId
            info.nodeId = nodeId ?? info.nodeId
            info.backend = backend ?? info.backend ?? Self.inferBackend(termProgram: info.termProgram)
            info.fallbackReason = fallbackReason ?? info.fallbackReason
            info.cwd = cwd
            info.lastActivityAt = Date()
            info.status = status

            store[sessionId] = info
            save()

            NSLog("[SessionTerminalStore] Updated session \(sessionId.prefix(8)): tty=\(tty ?? "nil"), term=\(termProgram ?? "nil"), cmuxSocket=\(cmuxSocketPath ?? "nil")")
        }
    }

    func updateBackend(sessionId: String, backend: String?, fallbackReason: String? = nil) {
        performSync {
            guard var info = store[sessionId] else { return }
            info.backend = backend ?? info.backend
            info.fallbackReason = fallbackReason
            info.lastActivityAt = Date()
            store[sessionId] = info
            save()
        }
    }

    /// 获取 session 的终端信息
    func get(sessionId: String) -> SessionTerminalInfo? {
        return queue.sync {
            store[sessionId]
        }
    }

    /// 获取所有存储的 session
    func getAll() -> [String: SessionTerminalInfo] {
        return queue.sync {
            store
        }
    }

    /// 删除已结束的 session
    func remove(sessionId: String) {
        performSync {
            store.removeValue(forKey: sessionId)
            save()
        }
    }

    func setProviderResumeSessionId(sessionId: String, providerResumeSessionId: String) {
        let trimmed = providerResumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSync {
            guard var info = store[sessionId] else { return }
            guard let validResumeId = Self.validProviderResumeSessionId(trimmed) else {
                info.providerResumeSessionId = nil
                info.lastActivityAt = Date()
                store[sessionId] = info
                save()
                NSLog("[SessionTerminalStore] Ignored invalid provider resume id for internal session \(sessionId.prefix(8))")
                return
            }
            info.providerResumeSessionId = validResumeId
            info.lastActivityAt = Date()
            store[sessionId] = info
            save()
            NSLog("[SessionTerminalStore] Linked internal session \(sessionId.prefix(8)) to provider resume id \(validResumeId.prefix(8))")
        }
    }

    @discardableResult
    func setProviderResumeSessionIdForSurface(
        cmuxSurfaceId: String?,
        providerResumeSessionId: String
    ) -> String? {
        let surfaceId = cmuxSurfaceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resumeId = providerResumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surfaceId.isEmpty,
              let validResumeId = Self.validProviderResumeSessionId(resumeId) else {
            return nil
        }
        return performSyncReturning {
            guard let sessionId = store.first(where: { _, info in
                info.cmuxSurfaceId == surfaceId
                    && InternalSessionIdentity.isSurfaceTerminal(
                        termProgram: info.termProgram,
                        termBundleId: info.termBundleId
                    )
            })?.key else {
                return nil
            }
            var info = store[sessionId]!
            guard info.providerResumeSessionId != validResumeId else { return sessionId }
            info.providerResumeSessionId = validResumeId
            info.lastActivityAt = Date()
            store[sessionId] = info
            save()
            NSLog("[SessionTerminalStore] Linked surface \(surfaceId.prefix(12)) session \(sessionId.prefix(8)) to provider resume id \(validResumeId.prefix(8))")
            return sessionId
        }
    }

    /// 清理过期 session (超过 24 小时无活动)
    func cleanupExpired() {
        performSync {
            let threshold = Date().addingTimeInterval(-24 * 60 * 60)
            let before = store.count
            var changed = false

            store = store.filter { $0.value.lastActivityAt > threshold }
            changed = migrateInvalidInternalResumeCommandsLocked() || changed

            let removed = before - store.count
            if removed > 0 {
                NSLog("[SessionTerminalStore] Cleaned up \(removed) expired sessions")
            }
            if removed > 0 || changed {
                save()
            }
        }
    }

    // MARK: - Private Methods

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: SessionTerminalInfo].self, from: data) else {
            NSLog("[SessionTerminalStore] No existing store found, starting fresh")
            return
        }

        store = decoded
        if migrateInvalidInternalResumeCommandsLocked() {
            save()
        }
        NSLog("[SessionTerminalStore] Loaded \(store.count) session-terminal mappings")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL)
    }

    private func performSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func performSyncReturning<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    private func migrateInvalidInternalResumeCommandsLocked() -> Bool {
        var changed = false
        for (sessionId, var info) in store {
            var entryChanged = false
            let providerResume = info.providerResumeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasValidProviderResume = Self.validProviderResumeSessionId(providerResume) != nil
            if !providerResume.isEmpty && !hasValidProviderResume {
                info.providerResumeSessionId = nil
                entryChanged = true
            }
            if AgentLaunchCommand.isMeee2InternalSessionId(sessionId),
               !hasValidProviderResume,
               let command = info.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               AgentLaunchCommand.commandRequestsResume(command) {
                info.command = Self.freshCommand(provider: info.provider, command: command)
                entryChanged = true
            }
            if entryChanged {
                store[sessionId] = info
                changed = true
            }
        }
        if changed {
            NSLog("[SessionTerminalStore] Migrated invalid internal resume commands")
        }
        return changed
    }

    private static func validProviderResumeSessionId(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard AgentLaunchCommand.isLikelyProviderResumeSessionId(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func commandForStorage(provider: String?, command: String) -> String {
        if AgentLaunchCommand.commandUsesInternalResumeId(command) {
            return freshCommand(provider: provider, command: command)
        }
        return command
    }

    private static func inferBackend(termProgram: String?) -> String? {
        switch termProgram?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "meee2-ghostty-surface":
            return TerminalSessionBackendKind.ghosttySurface.rawValue
        case .some:
            return TerminalSessionBackendKind.external.rawValue
        case .none:
            return nil
        }
    }

    private static func freshCommand(provider: String?, command: String?) -> String {
        let haystack = "\(provider ?? "") \(command ?? "")".lowercased()
        return AgentLaunchCommand.fullAccessCommand(forProvider: haystack.contains("codex") ? "codex" : "claude")
    }
}
