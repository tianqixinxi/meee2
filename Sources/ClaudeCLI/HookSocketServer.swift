import Foundation
import os.log
import Meee2PluginKit
import Meee2CommKit

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.meee2", category: "Hooks")

/// Response to send back to the hook
public struct PermissionResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
public typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
public typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
public class HookSocketServer {
    public static let shared = HookSocketServer()
    /// 实际监听路径。委托给 `MEEE2Env.socketPath`，可被 `MEEE2_SOCK` env 覆盖；
    /// 默认值 `/tmp/meee2.sock` 与历史硬编码一致，零回归。
    public static var socketPath: String { MEEE2Env.socketPath }

    // MARK: - Permission-timeout policy

    /// 权限请求等待用户回复的最长时间。超过这个时限还没有响应，
    /// 会用 `permissionTimeoutDecision` 自动回复并释放 socket，避免 Claude CLI 永远挂起。
    /// 设为 0 或负数表示禁用（仅在测试里这么干）。
    public static var permissionTimeoutSeconds: TimeInterval = 300

    /// 超时时自动采用的决策。合法值："deny" / "allow" / "ask"。
    /// 默认 "deny" 最安全：工具调用被拒，用户重试即可重新触发一次请求。
    public static var permissionTimeoutDecision: String = "deny"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.meee2.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    // MARK: - Encoder with sorted keys for deterministic cache keys

    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    // MARK: - Public API

    /// Start the socket server
    public func start(
        onEvent: @escaping HookEventHandler,
        onPermissionFailure: PermissionFailureHandler? = nil
    ) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    /// Stop the socket server
    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId
    public func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason)
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    public func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    public func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    public func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    public func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: String?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.toolName, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    public func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    // MARK: - Private - Server Lifecycle

    private func startServer(
        onEvent: @escaping HookEventHandler,
        onPermissionFailure: PermissionFailureHandler?
    ) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o700)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    // MARK: - Private - Connection Handling

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData
        if Self.isSyntheticProbe(data) {
            writeProbeResponse(to: clientSocket)
            close(clientSocket)
            return
        }

        guard var event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        // Set raw data
        event.rawData = String(data: data, encoding: .utf8)

        logger.debug("Received: \(event.event?.rawValue ?? "unknown", privacy: .public) for \(event.sessionId?.prefix(8) ?? "?", privacy: .public)")

        // Cache tool_use_id from PreToolUse
        if event.event == .preToolUse, let toolUseId = event.toolUseId {
            cacheToolUseId(event: event, toolUseId: toolUseId)
        }

        // Clean up cache on session end
        if event.event == .sessionEnd, let sessionId = event.sessionId {
            cleanupCache(sessionId: sessionId)
        }

        // A2A: Stop 事件不再做 inline drainInbox + block-decision 注入。
        // 之前的设计：把 inbox 拼成一个 reason 字符串 → return decision=block →
        // Claude 把这段当作下一轮 user prompt 内联消化。代价：transcript 里
        // 写成 `type=user, isMeta=true`，Web UI 看不到（被当 !bash 回显丢掉）；
        // 即便保留也是个"📨 Injected"特殊气泡，跟用户手打的真消息割裂。
        //
        // 现在统一走 Ghostty input 路径：让 Stop 自然关闭 → Claude 完整收尾
        // 当前回合 → ClaudePlugin 处理 Stop 把 SessionStore 状态翻到 resting →
        // SessionEventBus.sessionMetadataChanged → MessageRouter 订阅触发
        // flushInboxIfResting → Ghostty `input text` + send key enter → Claude
        // 看到一条**正常的** user prompt → transcript 写普通 `type=user`，Web
        // UI 自然显示为 user 气泡。所有消息只有一条入口、一种渲染。
        // NSLog("[StateTrace][hook-ingress][socket] sid=\(event.sessionId?.prefix(8) ?? "-") evt=\(event.event?.rawValue ?? "nil") tool=\(event.toolName ?? "-") statusField=\(event.status ?? "-") inferred=\(event.inferredStatus.rawValue)")

        // Handle permission requests
        if event.expectsResponse {
            // NSLog("[HookSocketServer] Permission request expects response")
            // NSLog("[HookSocketServer] event.toolUseId: \(event.toolUseId ?? "nil")")
            // NSLog("[HookSocketServer] event.sessionId: \(event.sessionId ?? "nil")")

            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
                // NSLog("[HookSocketServer] Using toolUseId from event: \(toolUseId)")
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
                // NSLog("[HookSocketServer] Using cached toolUseId: \(toolUseId)")
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId?.prefix(8) ?? "?", privacy: .public) - no cache hit")
                NSLog("[HookSocketServer] ERROR: No toolUseId found, closing socket!")
                close(clientSocket)
                eventHandler?(event)
                return
            }

            // NSLog("[HookSocketServer] Permission request - keeping socket open for \(event.sessionId?.prefix(8) ?? "?") tool:\(toolUseId.prefix(12))")

            // Update event with resolved toolUseId
            event.toolUseId = toolUseId

            let pending = PendingPermission(
                sessionId: event.sessionId ?? "",
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: event,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            // NSLog("[HookSocketServer] Stored pending permission: toolUseId=\(toolUseId), sessionId=\(pending.sessionId)")
            // NSLog("[HookSocketServer] Total pending permissions: \(pendingPermissions.count)")
            permissionsLock.unlock()

            scheduleAutoResponse(toolUseId: toolUseId)

            eventHandler?(event)
            return
        } else {
            // Stop hook 上的桌面版兜底：CLI session 走 AgentInboxShell 的
            // Ghostty input 路径（transcript 写普通 user 气泡），但 Claude
            // Desktop 子进程没 tty 推不进去，唯一可靠的注入路径是 hook
            // decision=block + reason，让 Claude 把 reason 当下一轮 prompt
            // 消化。CLI / SDK / 其它 session 都走原 close 路径，不响应。
            if event.event == .stop, let sid = event.sessionId,
               let response = drainResponseForDesktopStop(sessionId: sid) {
                // NSLog("[HookSocketServer] Event Stop with desktop drain, writing decision=block then closing")
                writeRawResponse(response, to: clientSocket)
            } else {
                // NSLog("[HookSocketServer] Event does NOT expect response, closing socket")
            }
            close(clientSocket)
        }

        eventHandler?(event)
    }

    private static func isSyntheticProbe(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["meee2_probe"] as? Bool == true
    }

    private func writeProbeResponse(to socket: Int32) {
        let payload = #"{"ok":true,"kind":"meee2.synthetic-probe"}"#
        guard let data = payload.data(using: .utf8) else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let n = write(socket, base, data.count)
            if n < 0 {
                NSLog("[HookSocketServer] writeProbeResponse failed errno=\(errno)")
            }
        }
    }

    /// 桌面版 Stop hook 的 inline drain。仅在确认是 `entrypoint=claude-desktop`
    /// 的 session 上触发；CLI/SDK/未知 entrypoint 都返回 nil（让流程走默认 close
    /// 路径，inbox 由 AgentInboxShell 走 Ghostty/iTerm/Apple Terminal 推送）。
    /// inbox 为空也返回 nil（不能空 reason 阻塞 Stop）。
    ///
    /// 取出来的消息通过 LabeledSenderPolicy 格式化（`[meee2 a2a] from ...`），
    /// 多条用空行分隔，跟 AgentInboxShell.deliverIfResting 的 payload 形态一致。
    ///
    /// 访问级别 internal（非 private）方便 unit test 直接调用；唯一调用方是
    /// 同文件里的 handleClient。
    func drainResponseForDesktopStop(sessionId: String) -> PermissionResponse? {
        let path = SessionStore.shared.get(sessionId)?.transcriptPath
        guard ClaudeEntrypointReader.read(transcriptPath: path)
                == ClaudeEntrypointReader.knownDesktop else {
            return nil
        }
        let messages = MessageRouter.shared.drainInbox(sessionId: sessionId)
        guard !messages.isEmpty else { return nil }

        let policy = LabeledSenderPolicy()
        let formatted = messages.compactMap { msg -> String? in
            policy.format(A2AInboundView(
                id: msg.id,
                traceId: msg.traceId,
                channel: msg.channel,
                fromAlias: msg.fromAlias,
                toAlias: msg.toAlias,
                hopCount: msg.hopCount,
                content: msg.content,
                createdAt: msg.createdAt,
                injectedByHuman: msg.injectedByHuman
            ))
        }.joined(separator: "\n\n")

        guard !formatted.isEmpty else { return nil }

        for msg in messages {
            ConversationContext.shared.recordInbound(sessionId: sessionId, message: msg)
        }

        // NSLog("[HookSocketServer] Desktop Stop drain: sid=\(sessionId.prefix(8)) drained=\(messages.count) msgs reason=\(formatted.count) chars")
        return PermissionResponse(decision: "block", reason: formatted)
    }

    private func writeRawResponse(_ response: PermissionResponse, to socket: Int32) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let n = write(socket, base, data.count)
            if n < 0 {
                NSLog("[HookSocketServer] writeRawResponse failed errno=\(errno)")
            }
        }
    }

    // MARK: - Private - Permission Response

    /// 为一个刚收下来的 pending permission 安排超时兜底：过了 `permissionTimeoutSeconds`
    /// 还没有被 user / A2A 回复，就用 `permissionTimeoutDecision` 自动回，避免 Claude CLI 挂死。
    /// 真实响应路径下，`sendPermissionResponse` 已经从 dict 里 remove 了 entry，
    /// 这里 fire 的时候找不到就是 no-op。
    private func scheduleAutoResponse(toolUseId: String) {
        let timeout = Self.permissionTimeoutSeconds
        guard timeout > 0 else { return }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }

            self.permissionsLock.lock()
            let stillPending = self.pendingPermissions[toolUseId]
            self.permissionsLock.unlock()

            guard let pending = stillPending else { return }

            let decision = Self.permissionTimeoutDecision
            let reason = "meee2: no response within \(Int(timeout))s, defaulting to \(decision)"
            logger.warning("Permission \(toolUseId.prefix(12), privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) timed out after \(Int(timeout))s — auto \(decision, privacy: .public)")
            self.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason)
        }
    }

    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        let response = PermissionResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()

        // DEBUG: enable temporarily when diagnosing permission routing.
        // NSLog("[HookSocketServer] === PENDING PERMISSIONS DEBUG ===")
        // for (toolUseId, pending) in pendingPermissions {
        //     NSLog("[HookSocketServer]   toolUseId: \(toolUseId.prefix(12)) -> sessionId: \(pending.sessionId.prefix(8))")
        // }
        // NSLog("[HookSocketServer] Looking for sessionId: \(sessionId.prefix(8))")

        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            NSLog("[HookSocketServer] WARNING: No pending permission for session: \(sessionId.prefix(8))")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = PermissionResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }

    // MARK: - Private - Tool Use ID Cache

    private func cacheToolUseId(event: HookEvent, toolUseId: String) {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.toolName, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId?.prefix(8) ?? "?", privacy: .public) tool:\(event.toolName ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.toolName, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId?.prefix(8) ?? "?", privacy: .public) tool:\(event.toolName ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    private func cacheKey(sessionId: String?, toolName: String?, toolInput: String?) -> String {
        return "\(sessionId ?? ""):\(toolName ?? "unknown"):\(toolInput ?? "{}")"
    }

    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private - Cleanup

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }
}
