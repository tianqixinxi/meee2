import Foundation
import Meee2CommKit

/// SystemStorageAPI — 给 Settings → Privacy section 用的本地存储统计 + 删除入口。
///
/// 路径约定:
/// - canvases:  `~/.meee2/board-canvases.json` + `~/.meee2/planner/`
/// - sessions:  `~/.meee2/sessions/`
/// - runbooks:  `~/.meee2/runbooks/`
///
/// 删除入口走「双确认 + token」流程:UI 先 GET 一个一次性 token,
/// 然后 POST 同样的 token 才真正删除,避免误点。
enum SystemStorageAPI {
    enum DeleteMode: String, Codable {
        /// Delete generated work data while preserving settings and Keychain.
        case workData
        /// Delete work data and all credentials owned by the meee2 Keychain service.
        case factoryReset
    }

    struct StorageStats: Encodable {
        let root: String
        let canvases: Int64
        let sessions: Int64
        let runbooks: Int64
        /// Pre-retention-policy terminal history; preview only until confirmed.
        let reclaimableMessageCount: Int
        let reclaimableMessageBytes: Int64
        let total: Int64
        let factoryResetExtra: Int64
        let factoryResetTotal: Int64
    }

    struct DeleteConfirmToken: Encodable {
        let token: String
        let mode: DeleteMode
        let issuedAt: String
        let expiresAt: String
    }

    struct DeleteResult: Encodable {
        let ok: Bool
        let removedBytes: Int64
        let removedPaths: [String]
        let failedPaths: [String]
        let hooksUnregistered: Bool
        let mcpUnregistered: Bool
        let credentialsCleared: Bool
    }

    enum APIError: LocalizedError {
        case tokenInvalid
        case tokenExpired

        var errorDescription: String? {
            switch self {
            case .tokenInvalid: return "delete confirm token is invalid or unknown"
            case .tokenExpired: return "delete confirm token expired; request a new one"
            }
        }
    }

    // 已签发的一次性 token —— 简化起见用 in-process 缓存即可,
    // 上限 16 个,超过则丢掉最老的。
    private static let tokenLock = NSLock()
    private static var issuedTokens: [(token: String, mode: DeleteMode, expiresAt: Date)] = []
    private static let tokenTTL: TimeInterval = 120 // 2 分钟

    // MARK: - 路径解析

    /// 返回所有需要统计 / 删除的 meee2 本地数据路径。
    /// 不包含 hooks / settings.json,只包含 meee2 自己产出的画布、会话、runbook。
    static func meee2DataRoots() -> (canvases: [URL], sessions: [URL], runbooks: [URL]) {
        let meee2 = StorageRoots.processDefault.baseDirectory

        let canvases: [URL] = [
            meee2.appendingPathComponent("board-canvases.json", isDirectory: false),
            meee2.appendingPathComponent("planner-canvases.json", isDirectory: false),
            meee2.appendingPathComponent("planner", isDirectory: true),
            meee2.appendingPathComponent("artifacts", isDirectory: true),
            meee2.appendingPathComponent("workspaces", isDirectory: true)
        ]
        let sessions: [URL] = [
            meee2.appendingPathComponent("sessions", isDirectory: true),
            meee2.appendingPathComponent("inbox", isDirectory: true),
            meee2.appendingPathComponent("messages", isDirectory: true),
            meee2.appendingPathComponent("channels", isDirectory: true),
            meee2.appendingPathComponent("queues", isDirectory: true),
            meee2.appendingPathComponent("unread", isDirectory: true),
            meee2.appendingPathComponent("attachments", isDirectory: true),
            meee2.appendingPathComponent("artifact-candidates", isDirectory: true),
            meee2.appendingPathComponent("assistant", isDirectory: true),
            meee2.appendingPathComponent("memory", isDirectory: true),
            meee2.appendingPathComponent("session-controls.json", isDirectory: false),
            meee2.appendingPathComponent("session-terminals.json", isDirectory: false),
            meee2.appendingPathComponent("session-projects.json", isDirectory: false),
            meee2.appendingPathComponent("coordination-groups.json", isDirectory: false),
            meee2.appendingPathComponent("automations.json", isDirectory: false),
            meee2.appendingPathComponent("token-rate-history.json", isDirectory: false),
            CommKitStoragePaths.processDefault.inboxDirectory
        ]
        let runbooks: [URL] = [
            meee2.appendingPathComponent("runbooks", isDirectory: true)
        ]
        return (canvases, sessions, runbooks)
    }

    static func factoryResetAdditionalRoots() -> [URL] {
        let meee2 = meee2Root()
        let logs = StorageRoots.processDefault.logsDirectory
        return [
            meee2.appendingPathComponent("settings.json", isDirectory: false),
            meee2.appendingPathComponent("message-retention-policy.json", isDirectory: false),
            meee2.appendingPathComponent("mcp-registry-cache.json", isDirectory: false),
            meee2.appendingPathComponent("board-server.json", isDirectory: false),
            meee2.appendingPathComponent("debug-exports", isDirectory: true),
            meee2.appendingPathComponent("connectors", isDirectory: true),
            meee2.appendingPathComponent("mcp-meee2", isDirectory: true),
            meee2.appendingPathComponent("audit.log", isDirectory: false),
            logs.appendingPathComponent("meee2.log", isDirectory: false),
            logs.appendingPathComponent("meee2.log.1", isDirectory: false),
            logs.appendingPathComponent("meee2.log.2", isDirectory: false),
            logs.appendingPathComponent("meee2.log.3", isDirectory: false),
            logs.appendingPathComponent("meee2.log.4", isDirectory: false),
            logs.appendingPathComponent("meee2.log.5", isDirectory: false),
            URL(fileURLWithPath: "/tmp/meee2.log", isDirectory: false)
        ]
    }

    static func meee2Root() -> URL {
        StorageRoots.processDefault.baseDirectory
    }

    // MARK: - 统计

    static func gatherStats() -> StorageStats {
        let roots = meee2DataRoots()
        let canvases = totalSize(of: roots.canvases)
        let sessions = totalSize(of: roots.sessions)
        let runbooks = totalSize(of: roots.runbooks)
        let factoryResetExtra = totalSize(of: factoryResetAdditionalRoots())
        let retention = MessageRouter.shared.retentionPreview()
        return StorageStats(
            root: meee2Root().path,
            canvases: canvases,
            sessions: sessions,
            runbooks: runbooks,
            reclaimableMessageCount: retention.protectedHistoryCount,
            reclaimableMessageBytes: retention.protectedHistoryBytes,
            total: canvases + sessions + runbooks,
            factoryResetExtra: factoryResetExtra,
            factoryResetTotal: canvases + sessions + runbooks + factoryResetExtra
        )
    }

    private static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { acc, url in
            acc + recursiveSize(of: url)
        }
    }

    private static func recursiveSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.totalFileAllocatedSize {
                total += Int64(size)
            } else if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - 删除 token

    /// 签发一次性删除 token,UI 拿到后必须在二次 confirm modal 里回传同样的 token。
    static func issueDeleteToken(mode: DeleteMode = .workData) -> DeleteConfirmToken {
        let token = UUID().uuidString
        let now = Date()
        let expiresAt = now.addingTimeInterval(tokenTTL)

        tokenLock.lock()
        // 清掉过期的 + 超过 16 个时丢最老的
        issuedTokens.removeAll { $0.expiresAt < now }
        if issuedTokens.count >= 16 {
            issuedTokens.removeFirst(issuedTokens.count - 15)
        }
        issuedTokens.append((token: token, mode: mode, expiresAt: expiresAt))
        tokenLock.unlock()

        let formatter = ISO8601DateFormatter()
        return DeleteConfirmToken(
            token: token,
            mode: mode,
            issuedAt: formatter.string(from: now),
            expiresAt: formatter.string(from: expiresAt)
        )
    }

    /// 消费 token —— 一次性,验证通过后会从列表里弹出。
    private static func consumeToken(_ token: String, mode: DeleteMode) throws {
        let now = Date()
        tokenLock.lock()
        defer { tokenLock.unlock() }

        guard let idx = issuedTokens.firstIndex(where: { $0.token == token }) else {
            // 区分一下 expired 和 unknown,但 unknown 也可能是过期之后被清掉了,
            // 所以这里就笼统报 invalid。
            throw APIError.tokenInvalid
        }
        let entry = issuedTokens[idx]
        issuedTokens.remove(at: idx)
        if entry.expiresAt < now {
            throw APIError.tokenExpired
        }
        guard entry.mode == mode else {
            // A work-data token must never be escalated into a factory reset.
            throw APIError.tokenInvalid
        }
    }

    // MARK: - 删除

    /// 执行删除。只删 canvases/sessions/runbooks 三类,
    /// 不动 ~/.meee2/plugins、settings.json、hooks 之类的配置。
    ///
    /// 顺序：**先删磁盘 → 后清内存 store → 广播 state.changed**。
    /// 理由：万一磁盘删除部分失败，至少 in-memory store 还反映"真实
    /// 残留在 disk 上的数据"，不会出现 UI 显示为空但 ~/.meee2 还
    /// 留着孤儿文件的不一致；下一次启动 reloadFromDisk 也能恢复。
    /// 我们对单个 url 删除失败不抛错（保持原行为，部分成功也算成功），
    /// 但只要至少删了一项就清内存 + 广播；如果一项都没删（不太可能），
    /// 则保持内存原状。
    static func deleteLocalData(
        token: String,
        mode: DeleteMode = .workData
    ) throws -> DeleteResult {
        try consumeToken(token, mode: mode)

        let roots = meee2DataRoots()
        var all = roots.canvases + roots.sessions + roots.runbooks
        if mode == .factoryReset {
            // LogManager and AuditLogger own open handles for these two files;
            // their reset hooks remove/reopen them safely below.
            let managedLogs = Set([
                LogManager.shared.logFileURL.standardizedFileURL.path,
                AuditLogger.shared.logFileURL.standardizedFileURL.path
            ])
            all += factoryResetAdditionalRoots().filter {
                !managedLogs.contains($0.standardizedFileURL.path)
            }
        }
        all = uniqueRoots(all)

        var removed: [String] = []
        var failed: [String] = []
        var removedBytes: Int64 = 0
        let fm = FileManager.default
        for url in all {
            guard fm.fileExists(atPath: url.path) else { continue }
            let size = recursiveSize(of: url)
            do {
                try fm.removeItem(at: url)
                removed.append(url.path)
                removedBytes += size
                NSLog("[SystemStorageAPI] removed \(url.path) (\(size) bytes)")
            } catch {
                NSLog("[SystemStorageAPI] failed to remove \(url.path): \(error)")
                failed.append(url.path)
            }
        }

        // 删盘后同步内存 store —— 否则 SessionStore.shared.sessions 和
        // BoardLayoutStore 的 cached snapshot 还会持有已删的 session/canvas，
        // UI 继续展示并可能在下次 update 时把它们再写回 ~/.meee2。
        // 用 DispatchQueue.main.sync 保证 SwiftUI `@Published` 在主线程 mutate。
        if !removed.isEmpty {
            let clearMemory: () -> Void = {
                SessionStore.shared.clearAllInMemory()
                BoardLayoutStore.shared.clearInMemoryCache()
                MessageRouter.shared.clearAllInMemory()
                ChannelRegistry.shared.clearAllInMemory()
            }
            if Thread.isMainThread {
                clearMemory()
            } else {
                DispatchQueue.main.sync(execute: clearMemory)
            }

            // 立刻广播 state.changed，让 React UI / TUI / Island 翻成空态，
            // 不用等下一个 hook 触发去抖刷新。
            BoardServer.shared.broadcastStateChanged()
        }

        var hooksUnregistered = true
        var mcpUnregistered = true
        let credentialsCleared: Bool
        if mode == .factoryReset {
            credentialsCleared = OnlineProxy.clearAllSecureCredentialsForFactoryReset()
            hooksUnregistered = SettingsConfigManager.shared.unregisterMeee2Hooks()
            mcpUnregistered = MCPConfigManager.shared.unregisterMeee2()
            removedBytes += LogManager.shared.resetForFactoryReset()
            removedBytes += AuditLogger.shared.resetForFactoryReset()
            resetUserDefaults()
            if !credentialsCleared {
                NSLog("[SystemStorageAPI] factory reset could not clear every Keychain credential")
            }
        } else {
            credentialsCleared = true
        }

        return DeleteResult(
            ok: failed.isEmpty && credentialsCleared && hooksUnregistered && mcpUnregistered,
            removedBytes: removedBytes,
            removedPaths: removed,
            failedPaths: failed,
            hooksUnregistered: hooksUnregistered,
            mcpUnregistered: mcpUnregistered,
            credentialsCleared: credentialsCleared
        )
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func resetUserDefaults() {
        let defaults = UserDefaults.standard
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        } else {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.synchronize()
    }
}
