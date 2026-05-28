import Foundation

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
    struct StorageStats: Encodable {
        let root: String
        let canvases: Int64
        let sessions: Int64
        let runbooks: Int64
        let total: Int64
    }

    struct DeleteConfirmToken: Encodable {
        let token: String
        let issuedAt: String
        let expiresAt: String
    }

    struct DeleteResult: Encodable {
        let ok: Bool
        let removedBytes: Int64
        let removedPaths: [String]
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
    private static var issuedTokens: [(token: String, expiresAt: Date)] = []
    private static let tokenTTL: TimeInterval = 120 // 2 分钟

    // MARK: - 路径解析

    /// 返回所有需要统计 / 删除的 meee2 本地数据路径。
    /// 不包含 hooks / settings.json,只包含 meee2 自己产出的画布、会话、runbook。
    static func meee2DataRoots() -> (canvases: [URL], sessions: [URL], runbooks: [URL]) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let meee2 = home.appendingPathComponent(".meee2", isDirectory: true)

        let canvases: [URL] = [
            meee2.appendingPathComponent("board-canvases.json", isDirectory: false),
            meee2.appendingPathComponent("planner", isDirectory: true)
        ]
        let sessions: [URL] = [
            meee2.appendingPathComponent("sessions", isDirectory: true),
            meee2.appendingPathComponent("inbox", isDirectory: true),
            meee2.appendingPathComponent("attachments", isDirectory: true)
        ]
        let runbooks: [URL] = [
            meee2.appendingPathComponent("runbooks", isDirectory: true)
        ]
        return (canvases, sessions, runbooks)
    }

    static func meee2Root() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
    }

    // MARK: - 统计

    static func gatherStats() -> StorageStats {
        let roots = meee2DataRoots()
        let canvases = totalSize(of: roots.canvases)
        let sessions = totalSize(of: roots.sessions)
        let runbooks = totalSize(of: roots.runbooks)
        return StorageStats(
            root: meee2Root().path,
            canvases: canvases,
            sessions: sessions,
            runbooks: runbooks,
            total: canvases + sessions + runbooks
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
    static func issueDeleteToken() -> DeleteConfirmToken {
        let token = UUID().uuidString
        let now = Date()
        let expiresAt = now.addingTimeInterval(tokenTTL)

        tokenLock.lock()
        // 清掉过期的 + 超过 16 个时丢最老的
        issuedTokens.removeAll { $0.expiresAt < now }
        if issuedTokens.count >= 16 {
            issuedTokens.removeFirst(issuedTokens.count - 15)
        }
        issuedTokens.append((token: token, expiresAt: expiresAt))
        tokenLock.unlock()

        let formatter = ISO8601DateFormatter()
        return DeleteConfirmToken(
            token: token,
            issuedAt: formatter.string(from: now),
            expiresAt: formatter.string(from: expiresAt)
        )
    }

    /// 消费 token —— 一次性,验证通过后会从列表里弹出。
    private static func consumeToken(_ token: String) throws {
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
    }

    // MARK: - 删除

    /// 执行删除。只删 canvases/sessions/runbooks 三类,
    /// 不动 ~/.meee2/plugins、settings.json、hooks 之类的配置。
    static func deleteLocalData(token: String) throws -> DeleteResult {
        try consumeToken(token)

        let roots = meee2DataRoots()
        let all = roots.canvases + roots.sessions + roots.runbooks

        var removed: [String] = []
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
            }
        }
        return DeleteResult(ok: true, removedBytes: removedBytes, removedPaths: removed)
    }
}
