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

    private init() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        storeURL = dir.appendingPathComponent("session-terminals.json")

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
        nodeId: String? = nil
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            var info = self.store[sessionId] ?? SessionTerminalInfo(
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
                cmuxSocketPath: cmuxSocketPath,
                cmuxSurfaceId: cmuxSurfaceId
            )

            info.tty = tty ?? info.tty
            info.termProgram = termProgram ?? info.termProgram
            info.termBundleId = termBundleId ?? info.termBundleId
            info.cmuxSocketPath = cmuxSocketPath ?? info.cmuxSocketPath
            info.cmuxSurfaceId = cmuxSurfaceId ?? info.cmuxSurfaceId
            info.command = command ?? info.command
            info.provider = provider ?? info.provider
            info.providerResumeSessionId = providerResumeSessionId ?? info.providerResumeSessionId
            info.canvasId = canvasId ?? info.canvasId
            info.nodeId = nodeId ?? info.nodeId
            info.cwd = cwd
            info.lastActivityAt = Date()
            info.status = status

            self.store[sessionId] = info
            self.save()

            NSLog("[SessionTerminalStore] Updated session \(sessionId.prefix(8)): tty=\(tty ?? "nil"), term=\(termProgram ?? "nil"), cmuxSocket=\(cmuxSocketPath ?? "nil")")
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
        queue.async { [weak self] in
            self?.store.removeValue(forKey: sessionId)
            self?.save()
        }
    }

    func setProviderResumeSessionId(sessionId: String, providerResumeSessionId: String) {
        let trimmed = providerResumeSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, var info = self.store[sessionId] else { return }
            info.providerResumeSessionId = trimmed
            info.lastActivityAt = Date()
            self.store[sessionId] = info
            self.save()
            NSLog("[SessionTerminalStore] Linked internal session \(sessionId.prefix(8)) to provider resume id \(trimmed.prefix(8))")
        }
    }

    /// 清理过期 session (超过 24 小时无活动)
    func cleanupExpired() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let threshold = Date().addingTimeInterval(-24 * 60 * 60)
            let before = self.store.count
            var changed = false

            self.store = self.store.filter { $0.value.lastActivityAt > threshold }
            changed = self.migrateInvalidInternalResumeCommandsLocked() || changed

            let removed = before - self.store.count
            if removed > 0 {
                NSLog("[SessionTerminalStore] Cleaned up \(removed) expired sessions")
            }
            if removed > 0 || changed {
                self.save()
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

    private func migrateInvalidInternalResumeCommandsLocked() -> Bool {
        var changed = false
        for (sessionId, var info) in store {
            var entryChanged = false
            let providerResume = info.providerResumeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasValidProviderResume = !providerResume.isEmpty && !Self.isMeee2InternalSessionId(providerResume)
            if !providerResume.isEmpty && !hasValidProviderResume {
                info.providerResumeSessionId = nil
                entryChanged = true
            }
            if Self.isMeee2InternalSessionId(sessionId),
               !hasValidProviderResume,
               let command = info.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               Self.commandUsesInternalResumeId(command, sessionId: sessionId) {
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

    private static func isMeee2InternalSessionId(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("claude-internal-") || lower.hasPrefix("codex-internal-")
    }

    private static func commandUsesInternalResumeId(_ command: String, sessionId: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("resume") && lower.contains(sessionId.lowercased())
    }

    private static func freshCommand(provider: String?, command: String?) -> String {
        let haystack = "\(provider ?? "") \(command ?? "")".lowercased()
        if haystack.contains("codex") {
            return "codex --dangerously-bypass-approvals-and-sandbox"
        }
        return "claude --dangerously-skip-permissions"
    }
}
