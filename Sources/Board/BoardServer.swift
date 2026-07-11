import Foundation
import Combine
import Swifter
import Meee2CommKit
import Security

/// BoardServer —— 本地 HTTP + WebSocket 服务器
///
/// - 静态资源：从 `Sources/Board/WebDist/` (via `Bundle.module`) 提供 React SPA
/// - REST API：`/api/*` 路径由 `BoardAPI` 处理
/// - WebSocket：`/api/events` 推送 `state.changed` + 单调递增 `revision`
///
/// 绑定：始终仅 127.0.0.1（通过 Swifter 的 `listenAddressIPv4` + `forceIPv4: true`）。
/// Board API 可以启动/终止进程并读取本地会话，因此不支持 LAN bind。
public final class BoardServer {
    public static let shared = BoardServer()
    public static let defaultPort: UInt16 = 9876
    public static let defaultBindAddress: String = "127.0.0.1"
    public static let maxAutoPortOffset: UInt16 = 100
    public static let portEnvVar = "MEEE2_BOARD_PORT"
    public static let legacyBindEnvVar = "MEEE2_BOARD_BIND"
    public static let devOriginsEnvVar = "MEEE2_BOARD_DEV_ORIGINS"
    public static let controlTokenHeader = "X-Meee2-Control-Token"
    static let viteDevOrigins: Set<String> = [
        "http://127.0.0.1:5002",
        "http://localhost:5002"
    ]

    private var server: HttpServer?
    private let stateLock = NSLock()
    private let preferredPort: UInt16
    private let bindAddress = BoardServer.defaultBindAddress
    private let configuredDevOrigins: Set<String>
    private var controlToken = BoardServer.generateControlToken()

    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = BoardServer.defaultPort

    /// Loopback URL —— 内部回调（meee2 OAuth callback / CLI 提示）始终用这个，
    /// 即使 server 暴露到 0.0.0.0，浏览器在本机访问 `127.0.0.1` 一样能命中。
    public var url: String { "http://127.0.0.1:\(port)" }

    /// 当前活跃的 WebSocket sessions（broadcast 用）
    private var wsSessions: [WebSocketSession] = []
    private var wsPendingAuthentication: [WebSocketSession: DispatchWorkItem] = [:]
    private let wsLock = NSLock()
    private let revisionLock = NSLock()
    private var stateRevision: UInt64 = 0
    private var stateGeneratedAt = Date()
    private var pendingChangedSessionIds = Set<String>()
    private var pendingRemovedSessionIds = Set<String>()
    private var pendingSnapshotRequired = false

    /// SessionEventBus 订阅，持有期同 server 生命周期
    private var busSubscription: AnyCancellable?

    private init() {
        if let raw = ProcessInfo.processInfo.environment[Self.portEnvVar],
           let p = UInt16(raw),
           p > 0 {
            self.preferredPort = p
            self.port = p
        } else {
            self.preferredPort = Self.defaultPort
        }
        let explicitDevOrigins = Self.parseDevOrigins(
            ProcessInfo.processInfo.environment[Self.devOriginsEnvVar]
        )
        #if DEBUG
        self.configuredDevOrigins = explicitDevOrigins.union(Self.viteDevOrigins)
        #else
        self.configuredDevOrigins = explicitDevOrigins
        #endif
    }

    // MARK: - 生命周期

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isRunning {
            MInfo("[BoardServer] already running on \(url)")
            return
        }

        // A token belongs to one listening lifetime. Restarting the same
        // singleton invalidates every browser/MCP client from the old launch.
        controlToken = Self.generateControlToken()
        revisionLock.lock()
        stateRevision = 0
        stateGeneratedAt = Date()
        pendingChangedSessionIds.removeAll()
        pendingRemovedSessionIds.removeAll()
        pendingSnapshotRequired = false
        revisionLock.unlock()

        if let legacyBind = ProcessInfo.processInfo.environment[Self.legacyBindEnvVar],
           !legacyBind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           legacyBind != Self.defaultBindAddress {
            MWarn("[BoardServer] ignoring MEEE2_BOARD_BIND=\(legacyBind); the local control plane is loopback-only")
        }

        // Opt-in: route planner agent events through the meee2-online TS
        // runtime when both env vars are set. Otherwise the in-process
        // DefaultPlannerAgentRuntime keeps serving requests.
        HTTPPlannerAgentRuntime.installFromEnvironment()

        var lastError: Error?
        for candidate in candidatePorts() {
            let server = HttpServer()
            // Never expose the process/session control plane to a network interface.
            server.listenAddressIPv4 = bindAddress

            registerRoutes(on: server)

            do {
                try server.start(candidate, forceIPv4: true)
                self.server = server
                self.port = candidate
                self.isRunning = true
                MInfo("[BoardServer] listening on \(url) (loopback-only, control auth enabled)")
                writeRuntimeInfo()
                subscribeToEventBus()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    BoardAPI.reconcileStateBeforeBroadcast()
                    self?.broadcastStateChanged()
                }
                PlannerScheduleRunner.shared.start()
                return
            } catch {
                lastError = error
                MWarn("[BoardServer] port \(candidate) unavailable: \(error)")
            }
        }

        MError("[BoardServer] failed to bind any candidate port from \(preferredPort)")
        throw lastError ?? BoardServerError.noAvailablePort(start: preferredPort)
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        busSubscription?.cancel()
        busSubscription = nil
        PlannerScheduleRunner.shared.stop()

        wsLock.lock()
        let sockets = wsSessions + Array(wsPendingAuthentication.keys)
        for timeout in wsPendingAuthentication.values { timeout.cancel() }
        for ws in sockets {
            ws.writeCloseFrame()
        }
        wsSessions.removeAll()
        wsPendingAuthentication.removeAll()
        wsLock.unlock()

        server?.stop()
        server = nil
        isRunning = false
        removeRuntimeInfo()
        MInfo("[BoardServer] stopped")
    }

    private func candidatePorts() -> [UInt16] {
        var seen = Set<UInt16>()
        var ports: [UInt16] = []

        func appendRange(start: UInt16) {
            let upper = min(Int(UInt16.max), Int(start) + Int(Self.maxAutoPortOffset))
            for raw in Int(start)...upper {
                let port = UInt16(raw)
                if seen.insert(port).inserted {
                    ports.append(port)
                }
            }
        }

        appendRange(start: preferredPort)
        if preferredPort != Self.defaultPort {
            appendRange(start: Self.defaultPort)
        }
        return ports
    }

    private func writeRuntimeInfo() {
        do {
            let fileURL = try Self.runtimeInfoFileURL()
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "name": "meee2-board-server",
                "host": bindAddress,
                "port": Int(port),
                "url": url,
                // Same-user local clients (the MCP shim and diagnostic scripts)
                // read this 0600 file. Never expose the token through /api/health
                // or logs.
                "controlToken": controlToken,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "updatedAt": BoardDTOBuilder.iso(Date())
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
            guard chmod(fileURL.path, S_IRUSR | S_IWUSR) == 0 else {
                try? FileManager.default.removeItem(at: fileURL)
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            MWarn("[BoardServer] failed to write runtime info: \(error)")
        }
    }

    private func removeRuntimeInfo() {
        do {
            let fileURL = try Self.runtimeInfoFileURL()
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let data = try Data(contentsOf: fileURL)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let filePID = obj?["pid"] as? Int
            let filePort = obj?["port"] as? Int
            let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
            if filePID == currentPID && filePort == Int(port) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            MWarn("[BoardServer] failed to remove runtime info: \(error)")
        }
    }

    public static func runtimeInfoFileURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BoardServerError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent("meee2", isDirectory: true)
            .appendingPathComponent("board-server.json", isDirectory: false)
    }

    /// Authorize an in-process URLSession call back into BoardServer. This is
    /// intentionally narrower than exposing the token as a public property.
    public func authorizeControlRequest(_ request: inout URLRequest) {
        request.setValue(controlToken, forHTTPHeaderField: Self.controlTokenHeader)
    }

    // MARK: - 广播

    /// 广播 state.changed 事件到所有 WS 客户端
    public func broadcastStateChanged() {
        let version = advanceStateRevision()
        let changedIds = Set(version.changedSessionIds)
        let changedSessions = changedIds.isEmpty ? [] : BoardSessionSnapshotProvider
            .currentBoardSessions(reconcileTerminalStatuses: false)
            .filter { session in
                changedIds.contains(session.id)
                    || session.surfaceId.map(changedIds.contains) == true
                    || session.providerResumeSessionId.map(changedIds.contains) == true
            }
        let payload = StateChangedFrame(
            type: "state.changed",
            timestamp: BoardDTOBuilder.iso(version.generatedAt),
            revision: version.revision,
            changedSessionIds: version.changedSessionIds,
            removedSessionIds: version.removedSessionIds,
            changedSessions: changedSessions,
            snapshotRequired: version.snapshotRequired
                || (!version.changedSessionIds.isEmpty && changedSessions.isEmpty)
        )
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        wsLock.lock()
        let sessions = wsSessions
        wsLock.unlock()

        for ws in sessions {
            ws.writeText(text)
        }
    }

    func currentStateVersion() -> (revision: UInt64, generatedAt: Date) {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return (stateRevision, stateGeneratedAt)
    }

    private func advanceStateRevision() -> (
        revision: UInt64,
        generatedAt: Date,
        changedSessionIds: [String],
        removedSessionIds: [String],
        snapshotRequired: Bool
    ) {
        revisionLock.lock()
        stateRevision &+= 1
        stateGeneratedAt = Date()
        let version = (
            stateRevision,
            stateGeneratedAt,
            pendingChangedSessionIds.sorted(),
            pendingRemovedSessionIds.sorted(),
            pendingSnapshotRequired || (pendingChangedSessionIds.isEmpty && pendingRemovedSessionIds.isEmpty)
        )
        pendingChangedSessionIds.removeAll()
        pendingRemovedSessionIds.removeAll()
        pendingSnapshotRequired = false
        revisionLock.unlock()
        return version
    }

    private func recordStateDelta(_ event: SessionEvent) {
        revisionLock.lock()
        switch event {
        case .sessionAdded(let sessionId),
             .sessionMetadataChanged(let sessionId),
             .transcriptAppended(let sessionId):
            pendingRemovedSessionIds.remove(sessionId)
            pendingChangedSessionIds.insert(sessionId)
        case .sessionRemoved(let sessionId):
            pendingChangedSessionIds.remove(sessionId)
            pendingRemovedSessionIds.insert(sessionId)
        default:
            pendingSnapshotRequired = true
        }
        revisionLock.unlock()
    }

    private struct StateChangedFrame: Encodable {
        let type: String
        let timestamp: String
        let revision: UInt64
        let changedSessionIds: [String]
        let removedSessionIds: [String]
        let changedSessions: [SessionDTO]
        let snapshotRequired: Bool
    }

    // MARK: - 路由注册

    enum ControlPlaneDecision: Equatable {
        case allow
        case forbiddenOrigin
        case unauthorized
    }

    /// Only an explicitly configured loopback dev server may call across
    /// origins. Production always uses the BoardServer's actual bound origin.
    static func parseDevOrigins(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").compactMap { item -> String? in
            let candidate = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "http",
                  let host = components.host?.lowercased(),
                  host == "127.0.0.1" || host == "localhost",
                  let port = components.port,
                  components.path.isEmpty || components.path == "/",
                  components.query == nil,
                  components.fragment == nil,
                  components.user == nil,
                  components.password == nil else {
                return nil
            }
            return "http://\(host):\(port)"
        })
    }

    static func allowedOrigins(port: UInt16, devOrigins: Set<String>) -> Set<String> {
        var origins: Set<String> = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)"
        ]
        origins.formUnion(devOrigins)
        return origins
    }

    private var allowedOrigins: Set<String> {
        Self.allowedOrigins(port: port, devOrigins: configuredDevOrigins)
    }

    static func isMutatingMethod(_ method: String) -> Bool {
        switch method.uppercased() {
        case "POST", "PUT", "PATCH", "DELETE": return true
        default: return false
        }
    }

    static func requestRequiresControlToken(_ request: HttpRequest) -> Bool {
        if isMutatingMethod(request.method) { return true }
        guard request.method.uppercased() == "GET",
              request.path.hasPrefix("/api/sessions/"),
              request.path.hasSuffix("/inbox") else { return false }
        let drain = request.queryParams.first { $0.0 == "drain" }?.1.lowercased()
        return drain == "true" || drain == "1"
    }

    private static func header(_ name: String, in request: HttpRequest) -> String? {
        request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func requestOriginIsAllowed(_ request: HttpRequest, allowedOrigins: Set<String>) -> Bool {
        if let origin = header("Origin", in: request), !origin.isEmpty {
            return allowedOrigins.contains(origin)
        }

        // Modern browsers send this even on requests that omit Origin. Treat
        // an explicitly cross-site request as hostile rather than falling back
        // to the command-line/local-process path.
        if header("Sec-Fetch-Site", in: request)?.lowercased() == "cross-site" {
            return false
        }

        if let referer = header("Referer", in: request), !referer.isEmpty,
           let url = URL(string: referer),
           let origin = normalizedOrigin(of: url) {
            return allowedOrigins.contains(origin)
        }
        return true
    }

    static func requestHasControlToken(_ request: HttpRequest, expectedToken: String) -> Bool {
        guard let supplied = header(controlTokenHeader, in: request) else { return false }
        return constantTimeEqual(supplied, expectedToken)
    }

    static func controlPlaneDecision(
        for request: HttpRequest,
        allowedOrigins: Set<String>,
        expectedToken: String
    ) -> ControlPlaneDecision {
        guard requestOriginIsAllowed(request, allowedOrigins: allowedOrigins) else {
            return .forbiddenOrigin
        }
        guard !requestRequiresControlToken(request)
                || requestHasControlToken(request, expectedToken: expectedToken) else {
            return .unauthorized
        }
        return .allow
    }

    private static func normalizedOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let port = url.port else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func generateControlToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // UUIDs are still unpredictable enough for the same-user fallback,
            // while avoiding a process crash if the system RNG is unavailable.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func corsHeaders(for request: HttpRequest) -> [String: String] {
        var headers: [String: String] = [
            "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization, \(controlTokenHeader)",
            "Access-Control-Max-Age": "600",
            "Vary": "Origin"
        ]
        if let origin = header("Origin", in: request), !origin.isEmpty {
            headers["Access-Control-Allow-Origin"] = origin
        }
        return headers
    }

    /// Re-emit a HttpResponse with the CORS headers merged in. Wraps any
    /// existing status code / phrase / body — doesn't change semantics, just
    /// adds headers the browser needs to allow the response back to JS.
    ///
    /// `HttpResponse.content()` is internal in swifter, so we route by case
    /// instead of generic re-wrap. All paths produce `.raw` responses with
    /// CORS headers attached.
    private static func withCORS(_ response: HttpResponse, request: HttpRequest) -> HttpResponse {
        var headers = response.headers()
        for (k, v) in corsHeaders(for: request) { headers[k] = v }
        if request.path == "/api/control/bootstrap" {
            headers["Cache-Control"] = "no-store"
            headers["Pragma"] = "no-cache"
            headers["X-Content-Type-Options"] = "nosniff"
        }
        let status = response.statusCode
        let phrase = response.reasonPhrase

        switch response {
        case .ok(let body):
            let bodyData = serializeBody(body)
            return .raw(status, phrase, headers) { writer in
                try writer.write(bodyData)
            }
        case .badRequest(let body):
            let bodyData = body.map { serializeBody($0) } ?? Data()
            return .raw(status, phrase, headers) { writer in
                try writer.write(bodyData)
            }
        case .raw(_, _, let originalHeaders, let originalWriter):
            if let extras = originalHeaders {
                for (k, v) in extras where headers[k] == nil { headers[k] = v }
            }
            return .raw(status, phrase, headers) { writer in
                if let originalWriter = originalWriter { try originalWriter(writer) }
            }
        default:
            // .created/.accepted/.unauthorized/.forbidden/.notFound/etc — no
            // body. Just pass status + headers through.
            return .raw(status, phrase, headers) { _ in }
        }
    }

    /// Serialize an HttpResponseBody to Data (only the cases swifter actually
    /// emits from our handlers — json / html / text / data / custom).
    private static func serializeBody(_ body: HttpResponseBody) -> Data {
        switch body {
        case .json(let obj):
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        case .html(let s), .htmlBody(let s), .text(let s):
            return Data(s.utf8)
        case .data(let d, _):
            return d
        case .custom(let obj, let serializer):
            if let s = try? serializer(obj) {
                return Data(s.utf8)
            }
            return Data()
        }
    }

    /// Wrap a route handler so its response carries CORS headers.
    private static func cors(_ handler: @escaping (HttpRequest) -> HttpResponse) -> (HttpRequest) -> HttpResponse {
        return { request in withCORS(handler(request), request: request) }
    }

    private static func securityError(
        status: Int,
        reason: String,
        code: String,
        message: String,
        request: HttpRequest
    ) -> HttpResponse {
        let payload: [String: Any] = [
            "error": ["code": code, "message": message]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var headers = corsHeaders(for: request)
        headers["Content-Type"] = "application/json; charset=utf-8"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        return .raw(status, reason, headers) { writer in
            try writer.write(data)
        }
    }

    static func websocketAuthToken(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "auth",
              let token = object["controlToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func registerRoutes(on server: HttpServer) {
        // One gate covers every current and future /api route. Origin validation
        // protects both reads and writes from browser-based localhost attacks;
        // every mutation additionally requires this launch's control token.
        server.middleware.append { [weak self] request in
            guard let self, request.path.hasPrefix("/api/") else { return nil }

            guard Self.requestOriginIsAllowed(request, allowedOrigins: self.allowedOrigins) else {
                let origin = Self.header("Origin", in: request) ?? "<none>"
                MWarn("[BoardServer] rejected origin for \(request.method) \(request.path): \(origin)")
                return Self.securityError(
                    status: 403,
                    reason: "Forbidden",
                    code: "forbidden_origin",
                    message: "This local control plane does not allow the request origin.",
                    request: request
                )
            }

            if request.method.uppercased() == "OPTIONS" {
                return .raw(204, "No Content", Self.corsHeaders(for: request)) { _ in }
            }

            guard !Self.requestRequiresControlToken(request)
                    || Self.requestHasControlToken(request, expectedToken: self.controlToken) else {
                MWarn("[BoardServer] rejected unauthenticated mutation \(request.method) \(request.path)")
                return Self.securityError(
                    status: 401,
                    reason: "Unauthorized",
                    code: "control_token_required",
                    message: "A current meee2 control token is required.",
                    request: request
                )
            }
            return nil
        }

        // --- WebSocket ---
        let eventSocket = websocket(
            text: { [weak self] ws, text in
                self?.wsHandleClientText(ws, text: text)
            },
            connected: { [weak self] ws in
                self?.wsBeginAuthentication(ws)
            },
            disconnected: { [weak self] ws in
                self?.wsDetach(ws)
            }
        )
        // The browser WebSocket API cannot set custom headers. Authentication
        // therefore happens in the first application frame, keeping the token
        // out of URLs, access logs and browser history.
        server["/api/events"] = eventSocket

        // --- REST API ---
        // CORS-wrapped: meee2 in the browser hits these cross-origin.
        server.GET["/api/health"] = BoardServer.cors { [weak self] _ in
            guard let self = self else { return .raw(503, "Service Unavailable", [:]) { _ in } }
            return .ok(.json([
                "ok": true,
                "name": "meee2",
                "url": self.url,
                "port": Int(self.port),
                "pid": Int(ProcessInfo.processInfo.processIdentifier)
            ]))
        }
        server.GET["/api/control/bootstrap"] = BoardServer.cors { [weak self] _ in
            guard let self else {
                return .raw(503, "Service Unavailable", [:]) { _ in }
            }
            return .ok(.json(["controlToken": self.controlToken]))
        }
        server.GET["/api/state"]   = BoardServer.cors(BoardAPI.getState)
        server.GET["/api/system/meee2-mcp-status"] = BoardServer.cors(BoardAPI.getMeee2MCPStatus)
        server.GET["/api/system/meee2-agent-runtime-status"] = BoardServer.cors(BoardAPI.getMeee2AgentRuntimeStatus)
        server.POST["/api/system/meee2-agent-runtime-install"] = BoardServer.cors(BoardAPI.installMeee2AgentRuntime)
        server.GET["/api/system/readiness"] = BoardServer.cors(BoardAPI.getReadiness)
        server.POST["/api/system/readiness/repair"] = BoardServer.cors(BoardAPI.repairReadiness)
        server.POST["/api/system/debug-export"] = BoardServer.cors(BoardAPI.exportDebug)
        server.GET["/api/system/storage-stats"] = BoardServer.cors(BoardAPI.getStorageStats)
        // Destructive: must be same-origin from the local meee2 UI. Any
        // foreign Origin (e.g. a website the user visits while board is
        // running) is rejected with 403 before BoardAPI sees the request.
        // See SECURITY.md → "Local data wipe endpoints" for rationale.
        server.POST["/api/system/delete-local-data/token"] = BoardServer.cors(BoardAPI.issueDeleteLocalDataToken)
        server.POST["/api/system/delete-local-data"] = BoardServer.cors(BoardAPI.deleteLocalData)
        server.POST["/api/system/legacy-message-cleanup/token"] = BoardServer.cors(BoardAPI.issueLegacyMessageCleanupToken)
        server.POST["/api/system/legacy-message-cleanup"] = BoardServer.cors(BoardAPI.cleanUpLegacyMessages)
        server.GET["/api/sessions/intake-diagnostics"] = BoardServer.cors(BoardAPI.getSessionIntakeDiagnostics)
        server.GET["/api/session-projects"] = BoardServer.cors(BoardAPI.listSessionProjects)
        server.POST["/api/session-projects"] = BoardServer.cors(BoardAPI.createSessionProject)
        server.POST["/api/session-projects/pick-directory"] = BoardServer.cors(BoardAPI.pickSessionProjectDirectory)
        server.POST["/api/session-launcher/pick-attachments"] = BoardServer.cors(BoardAPI.pickSessionLaunchAttachments)
        server.POST["/api/session-launcher/attachments"] = BoardServer.cors(BoardAPI.uploadSessionLaunchAttachment)
        server.PATCH["/api/session-projects/:id"] = BoardServer.cors(BoardAPI.updateSessionProject)
        server.POST["/api/session-projects/:id/reveal"] = BoardServer.cors(BoardAPI.revealSessionProject)
        server.DELETE["/api/session-projects/:id"] = BoardServer.cors(BoardAPI.forgetSessionProject)
        server.POST["/api/session-projects/:id/sessions"] = BoardServer.cors(BoardAPI.createSessionProjectSession)
        server.POST["/api/session-launcher/temporary-sessions"] = BoardServer.cors(BoardAPI.createTemporarySession)
        server.POST["/api/session-launcher/sessions/:id/reopen"] = BoardServer.cors(BoardAPI.reopenLauncherSession)
        server.GET["/api/app-settings"] = BoardServer.cors(BoardAPI.getAppSettings)
        server.PATCH["/api/app-settings"] = BoardServer.cors(BoardAPI.updateAppSettings)
        server.GET["/api/user-profile"] = BoardServer.cors(BoardAPI.getUserProfile)
        server.POST["/api/user-profile/connect"] = BoardServer.cors(BoardAPI.openMeee2OnlineConnect)
        server.POST["/api/user-profile/dashboard"] = BoardServer.cors(BoardAPI.openMeee2OnlineDashboard)
        server.POST["/api/user-profile/settings"] = BoardServer.cors(BoardAPI.openMeee2Settings)
        server.PATCH["/api/user-profile"] = BoardServer.cors(BoardAPI.updateUserProfile)
        server.DELETE["/api/user-profile"] = BoardServer.cors(BoardAPI.disconnectMeee2Online)
        server.GET["/api/team/members"] = BoardServer.cors(BoardAPI.getTeamMembers)
        server.GET["/api/automations"] = BoardServer.cors(BoardAPI.listAutomations)
        server.POST["/api/automations"] = BoardServer.cors(BoardAPI.createAutomation)
        server.POST["/api/automations/:id/run"] = BoardServer.cors(BoardAPI.runAutomation)
        server.DELETE["/api/automations/:id"] = BoardServer.cors(BoardAPI.deleteAutomation)
        server.POST["/api/sessions/:id/activate"] = BoardServer.cors(BoardAPI.activateSession)
        server.POST["/api/sessions/:id/open-workspace"] = BoardServer.cors(BoardAPI.openSessionWorkspace)
        server.POST["/api/sessions/:id/inject"] = BoardServer.cors(BoardAPI.injectToSession)
        server.POST["/api/sessions/:id/push-now"] = BoardServer.cors(BoardAPI.pushToDesktopNow)
        server.POST["/api/sessions/:id/control"] = BoardServer.cors(BoardAPI.updateSessionControl)
        server.POST["/api/sessions/:id/permission"] = BoardServer.cors(BoardAPI.respondToSessionPermission)
        server.GET["/api/sessions/:id/environment"] = BoardServer.cors(BoardAPI.getSessionEnvironment)
        server.POST["/api/sessions/:id/environment/open"] = BoardServer.cors(BoardAPI.openSessionEnvironmentOutput)
        server.GET["/api/sessions/:id/artifacts"] = BoardServer.cors(BoardAPI.getSessionArtifacts)
        server.DELETE["/api/sessions/:id"] = BoardServer.cors(BoardAPI.closeSession)
        server.GET["/api/artifacts"] = BoardServer.cors(BoardAPI.listArtifacts)
        server.GET["/api/artifact-candidates"] = BoardServer.cors(BoardAPI.listArtifactCandidates)
        server.POST["/api/artifact-candidates/hook"] = BoardServer.cors(BoardAPI.ingestArtifactCandidateHook)
        server.POST["/api/artifact-candidates/:id/promote"] = BoardServer.cors(BoardAPI.promoteArtifactCandidate)
        server.POST["/api/artifact-candidates/:id/discard"] = BoardServer.cors(BoardAPI.discardArtifactCandidate)
        server.GET["/api/memory"] = BoardServer.cors(BoardAPI.listMemoryRecords)
        server.POST["/api/memory"] = BoardServer.cors(BoardAPI.createMemoryRecord)
        server.PATCH["/api/memory/:id"] = BoardServer.cors(BoardAPI.updateMemoryRecord)
        server.DELETE["/api/memory/:id"] = BoardServer.cors(BoardAPI.deleteMemoryRecord)
        server.GET["/api/session-surfaces"] = BoardServer.cors(BoardAPI.listSessionSurfaces)
        server.POST["/api/session-surfaces"] = BoardServer.cors(BoardAPI.createSessionSurface)
        server.GET["/api/session-surfaces/:id"] = BoardServer.cors(BoardAPI.getSessionSurface)
        server.POST["/api/session-surfaces/:id/close"] = BoardServer.cors(BoardAPI.closeSessionSurface)
        server.POST["/api/system/open-accessibility-settings"] = BoardServer.cors(BoardAPI.openAccessibilitySettings)
        server.GET["/api/whoami"] = BoardServer.cors(BoardAPI.getWhoami)
        server.GET["/api/version"] = BoardServer.cors(BoardAPI.getVersion)
        server.POST["/api/version/check"] = BoardServer.cors(BoardAPI.checkVersion)
        server.POST["/api/update/install"] = BoardServer.cors(BoardAPI.installUpdate)
        server.POST["/api/update/check-in-background"] = BoardServer.cors(BoardAPI.checkUpdateInBackground)
        server.GET["/api/_dev/perf"] = BoardServer.cors(BoardAPI.getDevPerf)
        server.POST["/api/_dev/perf/reset"] = BoardServer.cors(BoardAPI.resetDevPerf)
        server.POST["/api/_dev/override-latest"] = BoardServer.cors(BoardAPI.devOverrideLatest)
        server.GET["/api/_dev/pill-click-plan"] = BoardServer.cors(BoardAPI.devPillClickPlan)
        server.POST["/api/_e2e/team-sync"] = BoardServer.cors(BoardAPI.e2eSyncTeamCanvases)
        server.POST["/api/_e2e/sessions/:id"] = BoardServer.cors(BoardAPI.e2eUpsertSession)
        server.POST["/api/_e2e/sessions/:id/messages"] = BoardServer.cors(BoardAPI.e2eAppendSessionMessage)
        server.POST["/api/sessions/:id/attachments"] = BoardServer.cors(AttachmentsAPI.upload)
        server.GET["/api/sessions/:id/inbox"] = BoardServer.cors(BoardAPI.getSessionInbox)
        server.GET["/api/sessions/:id/transcript"] = BoardServer.cors(BoardAPI.getTranscript)
        server.POST["/api/sessions/spawn"] = BoardServer.cors(BoardAPI.spawnSession)
        server.GET["/api/canvases"] = BoardServer.cors(BoardAPI.listCanvases)
        server.POST["/api/canvases"] = BoardServer.cors(BoardAPI.createCanvas)
        server.PATCH["/api/canvases/:id"] = BoardServer.cors(BoardAPI.updateCanvas)
        server.DELETE["/api/canvases/:id"] = BoardServer.cors(BoardAPI.deleteCanvas)
        server.POST["/api/canvases/:id/sessions"] = BoardServer.cors(BoardAPI.addSessionToCanvas)
        server.POST["/api/canvases/:id/sessions/spawn-global"] = BoardServer.cors(BoardAPI.spawnGlobalSession)
        server.DELETE["/api/canvases/:id/sessions/:sessionId"] = BoardServer.cors(BoardAPI.removeSessionFromCanvas)
        server.POST["/api/canvases/:id/conflict"] = BoardServer.cors(BoardAPI.resolveCanvasConflict)
        server.GET["/api/templates"] = BoardServer.cors(BoardAPI.listCanvasTemplates)
        server.POST["/api/templates/:id/apply"] = BoardServer.cors(BoardAPI.applyCanvasTemplate)
        server.POST["/api/templates/from-canvas"] = BoardServer.cors(BoardAPI.createTemplateFromCanvas)
        server.POST["/api/templates/:id/edit-draft"] = BoardServer.cors(BoardAPI.createTemplateEditDraft)
        server.POST["/api/templates/:id/replace-from-canvas"] = BoardServer.cors(BoardAPI.replaceTemplateFromCanvas)
        server.PATCH["/api/templates/:id/metadata"] = BoardServer.cors(BoardAPI.updateTemplateMetadata)
        server.GET["/api/claude/workflows"] = BoardServer.cors(BoardAPI.listClaudeWorkflows)
        server.POST["/api/claude/workflows/import-upload"] = BoardServer.cors(BoardAPI.importUploadedClaudeWorkflow)
        server.POST["/api/claude/workflows/:id/import"] = BoardServer.cors(BoardAPI.importClaudeWorkflow)
        server.GET["/api/planner/monitor"] = BoardServer.cors(BoardAPI.getPlannerWorkspaceMonitor)
        server.POST["/api/planner/activity"] = BoardServer.cors(BoardAPI.updatePlannerActivity)
        server.GET["/api/planner/canvases/:id/state"] = BoardServer.cors(BoardAPI.getPlannerCanvasState)
        server.GET["/api/planner/canvases/:id/graph"] = BoardServer.cors(BoardAPI.getPlannerGraphState)
        server.PATCH["/api/planner/canvases/:id/render-profile/values"] = BoardServer.cors(BoardAPI.patchCanvasRenderValues)
        server.POST["/api/planner/canvases/:id/render-profile/reveal"] = BoardServer.cors(BoardAPI.revealCanvasRenderProfile)
        server.POST["/api/planner/canvases/:id/clear"] = BoardServer.cors(BoardAPI.clearPlannerCanvasContent)
        server.PATCH["/api/planner/canvases/:id/visibility"] = BoardServer.cors(BoardAPI.setPlannerCanvasVisibility)
        server.PATCH["/api/planner/canvases/:id/description"] = BoardServer.cors(BoardAPI.setPlannerCanvasDescription)
        server.POST["/api/planner/canvases/:id/proposals/generate"] = BoardServer.cors(BoardAPI.generatePlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/refine"] = BoardServer.cors(BoardAPI.refinePlannerProposal)
        // ENG-2 bonus: clean engine path for "refine session prompt" — replaces
        // the ENG-5 injectToSession workaround so the directive is auditable
        // (shows up as a proposal + canvas event) instead of going dark.
        server.POST["/api/planner/canvases/:id/proposals/refine-session-prompt"] = BoardServer.cors(BoardAPI.refineSessionPromptProposal)
        server.POST["/api/planner/canvases/:id/proposals/inspect-drift"] = BoardServer.cors(BoardAPI.inspectPlannerDrift)
        server.POST["/api/planner/canvases/:id/proposals/apply-preview"] = BoardServer.cors(BoardAPI.applyPlannerProposalPreview)
        server.POST["/api/planner/canvases/:id/proposals/graph-change"] = BoardServer.cors(BoardAPI.proposePlannerGraphChange)
        server.POST["/api/planner/canvases/:id/templates/delivery-pipeline"] = BoardServer.cors(BoardAPI.createPlannerDeliveryPipeline)
        server.POST["/api/planner/canvases/:id/proposals/:proposalId/approve"] = BoardServer.cors(BoardAPI.approvePlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/:proposalId/apply"] = BoardServer.cors(BoardAPI.applyPlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/:proposalId/reject"] = BoardServer.cors(BoardAPI.rejectPlannerProposal)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/bind-session"] = BoardServer.cors(BoardAPI.bindPlannerSessionToNode)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/dispatch"] = BoardServer.cors(BoardAPI.dispatchPlannerNodeSession)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/internal-session"] = BoardServer.cors(BoardAPI.ensurePlannerNodeInternalSession)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/abandon-session"] = BoardServer.cors(BoardAPI.abandonPlannerNodeSession)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/detach-session"] = BoardServer.cors(BoardAPI.detachPlannerNodeSession)
        server.POST["/api/planner/canvases/:id/sessions/resume-closed"] = BoardServer.cors(BoardAPI.resumeClosedPlannerSessions)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/artifacts"] = BoardServer.cors(BoardAPI.attachPlannerArtifactToNode)
        server.PATCH["/api/planner/canvases/:id/nodes/:nodeId/inputs"] = BoardServer.cors(BoardAPI.bindPlannerNodeInput)
        server.PATCH["/api/planner/canvases/:id/nodes/:nodeId/status"] = BoardServer.cors(BoardAPI.updatePlannerNodeStatus)
        server.PATCH["/api/planner/canvases/:id/nodes/:nodeId/gate"] = BoardServer.cors(BoardAPI.updatePlannerNodeGate)
        server.PATCH["/api/planner/canvases/:id/nodes/:nodeId/schedule"] = BoardServer.cors(BoardAPI.updatePlannerNodeSchedule)
        server.DELETE["/api/planner/canvases/:id/nodes/:nodeId"] = BoardServer.cors(BoardAPI.deletePlannerNode)
        server.GET["/api/planner/canvases/:id/nodes/:nodeId/contract"] = BoardServer.cors(BoardAPI.getPlannerNodeContract)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/output"] = BoardServer.cors(BoardAPI.submitPlannerNodeOutput)
        // proposal 子功能 · propose_add_node:节点会话提议新增 step(产物 pending,
        // 走既有 approve/apply/reject 管线;MCP propose_add_node 调这里)。
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/propose-add-node"] = BoardServer.cors(BoardAPI.proposePlannerAddNode)
        server.POST["/api/planner/canvases/:id/scene/actions"] = BoardServer.cors(BoardAPI.runCanvasSceneAction)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/sub-canvas"] = BoardServer.cors(BoardAPI.createPlannerSubCanvasFromNode)
        server.GET["/api/planner/canvases/:id/artifacts/:artifactId/content"] = BoardServer.cors(BoardAPI.getPlannerArtifactContent)
        // Direct artifact-layer read/write — 账本直改,不经节点状态机。
        // session(MCP get_artifact/update_artifact)与人工同走这两个端点。
        server.GET["/api/planner/canvases/:id/artifacts/latest"] = BoardServer.cors(BoardAPI.getLatestPlannerArtifacts)
        server.POST["/api/planner/canvases/:id/artifacts/update"] = BoardServer.cors(BoardAPI.updatePlannerArtifact)
        // 手动同步:给 artifact 所在节点的绑定会话投递「写穿」指令(operator
        // → session inbox),由会话用 MCP get_artifact/update_artifact 刷新快照。
        server.POST["/api/planner/canvases/:id/artifacts/sync"] = BoardServer.cors(BoardAPI.syncPlannerArtifact)
        server.POST["/api/planner/canvases/:id/artifacts/views"] = BoardServer.cors(BoardAPI.updatePlannerArtifactViews)
        // UI-1 (ENG-3) — artifact version chain read API.
        server.GET["/api/planner/canvases/:id/nodes/:nodeId/artifact-versions"] = BoardServer.cors(BoardAPI.listPlannerArtifactVersions)
        server.GET["/api/planner/canvases/:id/artifact-versions/:versionId"] = BoardServer.cors(BoardAPI.getPlannerArtifactVersion)
        // UI-1 (ENG-3) — re-run a gate node by re-submitting its latest version
        // with force_new_version: true. Body: { reference?: string } (optional;
        // defaults to the node's latest version slot).
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/rerun"] = BoardServer.cors(BoardAPI.rerunPlannerNode)
        // Teams · 多人增量贡献 — collect-list step 的共享账本。policy 是本地
        // 节点字段(随 team canvas state 同步给成员);贡献读写代理到云端
        // meee2_artifact_versions 的 contrib slot,每条带 submitted_by 归属。
        server.PATCH["/api/planner/canvases/:id/nodes/:nodeId/contribution"] = BoardServer.cors(BoardAPI.updatePlannerNodeContribution)
        server.GET["/api/planner/canvases/:id/nodes/:nodeId/contributions"] = BoardServer.cors(BoardAPI.listPlannerNodeContributions)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/contributions"] = BoardServer.cors(BoardAPI.submitPlannerNodeContribution)
        // 共建主路径:成员启动自己的 AI 收集会话(专属轻量会话,产出经 MCP
        // add_node_contribution 逐条进账本)。
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/contribution-session"] = BoardServer.cors(BoardAPI.startPlannerContributionSession)
        // 收集会话自评达标 → 建议收口信号;收口人物化账本 → 节点完成触发下游。
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/contribution-completion-suggestion"] = BoardServer.cors(BoardAPI.submitPlannerContributionCompletionSuggestion)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/contribution-complete"] = BoardServer.cors(BoardAPI.completePlannerNodeContribution)
        // Wave 1-3 integration — OnlineProxy routes.
        // UI-2: assign a node to a teammate through meee2-online.
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/assign"] = BoardServer.cors(BoardAPI.proxyAssignPlannerNode)
        // UI-2: list sub-canvases the current user owns.
        server.GET["/api/planner/owned-canvases"] = BoardServer.cors(BoardAPI.proxyListOwnedCanvases)
        // UI-6: recent artifact versions across the canvas (drives the AI Recap drawer).
        server.GET["/api/cloud/artifact-versions/recent"] = BoardServer.cors(BoardAPI.proxyRecentArtifactVersions)
        server.POST["/api/planner/canvases/:id/artifacts/:artifactId/kanban-items/:itemId/sub-canvas"] = BoardServer.cors(BoardAPI.openKanbanItemSubCanvas)
        server.PATCH["/api/planner/canvases/:id/nodes/:nodeId/layout"] = BoardServer.cors(BoardAPI.updatePlannerNodeLayout)
        // P1 Run layer — start / list / inspect / abort workflow runs.
        server.POST["/api/planner/canvases/:id/runs"] = BoardServer.cors(BoardAPI.startPlannerRun)
        server.GET["/api/planner/canvases/:id/runs"] = BoardServer.cors(BoardAPI.listPlannerRuns)
        server.POST["/api/planner/canvases/:id/deliveries"] = BoardServer.cors(BoardAPI.startPlannerRun)
        server.GET["/api/planner/canvases/:id/deliveries"] = BoardServer.cors(BoardAPI.listPlannerRuns)
        server.PATCH["/api/planner/canvases/:id/deliveries/:deliveryId/nodes/:nodeId/assignee"] = BoardServer.cors(BoardAPI.updatePlannerDeliveryNodeAssignee)
        server.GET["/api/planner/runs/:runId"] = BoardServer.cors(BoardAPI.getPlannerRun)
        server.POST["/api/planner/runs/:runId/abort"] = BoardServer.cors(BoardAPI.abortPlannerRun)
        server.GET["/api/coordination-groups"] = BoardServer.cors(BoardAPI.listCoordinationGroups)
        server.POST["/api/coordination-groups/:id/sync"] = BoardServer.cors(BoardAPI.syncCoordinationGroup)
        server.POST["/api/coordination-groups/:id/ask"] = BoardServer.cors(BoardAPI.askCoordinationGroup)
        server.POST["/api/coordination-groups/:id/pause"] = BoardServer.cors(BoardAPI.pauseCoordinationGroup)
        server.POST["/api/coordination-groups/:id/resume"] = BoardServer.cors(BoardAPI.resumeCoordinationGroup)
        server.DELETE["/api/coordination-groups/:id/members/:sessionId"] = BoardServer.cors(BoardAPI.removeCoordinationMember)

        // Phase 5 — Integrations (真接入). Read-only browsing of external
        // items. The actual artifact attach still goes through the existing
        // /api/planner/canvases/:id/nodes/:nodeId/artifacts endpoint.
        server.GET["/api/integrations/agent-scan"] = BoardServer.cors(IntegrationsAPI.getAgentScan)
        server.GET["/api/integrations/side-effects"] = BoardServer.cors(IntegrationsAPI.getCanvasSideEffects)
        server.POST["/api/integrations/:id/install"] = BoardServer.cors(IntegrationsAPI.installIntegration)
        server.POST["/api/integrations/:id/credentials"] = BoardServer.cors(IntegrationsAPI.uploadIntegrationCredentials)
        server.POST["/api/integrations/:id/preauth"] = BoardServer.cors(IntegrationsAPI.preauthIntegration)
        server.POST["/api/integrations/:id/complete-auth"] = BoardServer.cors(IntegrationsAPI.completeAuth)
        server.POST["/api/integrations/:id/recommend-workflow"] = BoardServer.cors(IntegrationsAPI.recommendWorkflow)
        server.POST["/api/integrations/:id/runbook"] = BoardServer.cors(IntegrationsAPI.generateRunbook)
        server.GET["/api/integrations/github/repos"] = BoardServer.cors(IntegrationsAPI.getGithubRepos)
        server.GET["/api/integrations/github/repos/:owner/:repo/pulls"] = BoardServer.cors(IntegrationsAPI.getGithubPulls)
        server.GET["/api/integrations/github/repos/:owner/:repo/issues"] = BoardServer.cors(IntegrationsAPI.getGithubIssues)
        server.GET["/api/integrations/lark/docs"] = BoardServer.cors(IntegrationsAPI.getLarkDocs)

        // Retired external chat session push endpoints. Keep CORS-wrapped
        // handlers so older browser extensions receive a clear 410 response.
        server.POST["/api/external-sessions/upsert"] = BoardServer.cors(BoardAPI.upsertExternalSession)
        server.POST["/api/external-sessions/:sid/append-message"] = BoardServer.cors(BoardAPI.appendExternalMessage)
        server.DELETE["/api/external-sessions/:sid"] = BoardServer.cors(BoardAPI.deleteExternalSession)
        server.POST["/api/channels"] = BoardServer.cors(BoardAPI.createChannel)
        server.DELETE["/api/channels/:name"] = BoardServer.cors(BoardAPI.deleteChannel)
        server.POST["/api/channels/:name/members"] = BoardServer.cors(BoardAPI.addMember)
        server.DELETE["/api/channels/:name/members/:alias"] = BoardServer.cors(BoardAPI.removeMember)
        server.POST["/api/channels/:name/mode"] = BoardServer.cors(BoardAPI.setChannelMode)
        server.POST["/api/channels/:name/rename"] = BoardServer.cors(BoardAPI.renameChannel)
        server.GET["/api/channels/:name/messages"] = BoardServer.cors(BoardAPI.listMessages)
        server.POST["/api/messages/send"] = BoardServer.cors(BoardAPI.sendMessage)
        server.POST["/api/messages/:id/hold"] = BoardServer.cors(BoardAPI.holdMessage)
        server.POST["/api/messages/:id/deliver"] = BoardServer.cors(BoardAPI.deliverMessage)
        server.POST["/api/messages/:id/drop"] = BoardServer.cors(BoardAPI.dropMessage)

        // --- Global assistant (claude -p driven "ask & spawn") ---
        server.POST["/api/assistant/chat"] = BoardServer.cors(AssistantAPI.chat)
        server.GET["/api/assistant/local-session/messages"] = BoardServer.cors(AssistantAPI.localSessionMessages)
        server.GET["/api/assistant/secret"] = BoardServer.cors(AssistantAPI.secretStatus)
        server.PUT["/api/assistant/secret"] = BoardServer.cors(AssistantAPI.updateSecret)
        server.DELETE["/api/assistant/secret"] = BoardServer.cors(AssistantAPI.deleteSecret)

        // --- Card Templates ---
        server.GET["/api/card-templates"]         = BoardServer.cors(BoardAPI.listCardTemplates)
        server.GET["/api/card-templates/:id"]     = BoardServer.cors(BoardAPI.getCardTemplate)
        server.PUT["/api/card-templates/:id"]     = BoardServer.cors(BoardAPI.putCardTemplate)
        server.DELETE["/api/card-templates/:id"]  = BoardServer.cors(BoardAPI.deleteCardTemplate)

        // --- Board Layout (session 卡片 + channel hub 坐标) ---
        server.GET["/api/board/layout"] = BoardServer.cors(BoardAPI.getBoardLayout)
        server.PUT["/api/board/layout"] = BoardServer.cors(BoardAPI.putBoardLayout)

        // --- meee2 callback (OAuth-style auto-connect) ---
        server.GET["/meee2/callback"] = Meee2OnlineCallbackAPI.handleCallback

        // --- 静态文件（SPA） ---
        // `GET /` -> index.html；其他路径尝试 WebDist 内的文件；未匹配时回 404
        server.notFoundHandler = { [weak self] request in
            guard let self = self else { return .notFound }
            return self.serveStaticFile(for: request.path)
        }
    }

    // MARK: - 静态文件

    private func serveStaticFile(for requestedPath: String) -> HttpResponse {
        guard let webRoot = BoardWebDistLocator.webRootURL() else {
            MWarn("[BoardServer] WebDist not found in bundle")
            return errorPage404()
        }

        // 规整路径 —— "/" -> "index.html"，否则去掉前导 "/"
        var relative = requestedPath
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        // 防御：拒绝 "../" 逃逸
        if relative.contains("..") {
            return errorPage404()
        }

        let target = webRoot.appendingPathComponent(relative).standardizedFileURL
        // 确保解析后仍在 webRoot 之内
        let webRootStd = webRoot.standardizedFileURL.path
        if target.path != webRootStd && !target.path.hasPrefix(webRootStd + "/") {
            return errorPage404()
        }

        // 不存在 -> SPA fallback: fallback 到 index.html（方便 client-side routing）
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var finalPath = target.path
        if !fm.fileExists(atPath: finalPath, isDirectory: &isDir) || isDir.boolValue {
            let indexPath = webRoot.appendingPathComponent("index.html").path
            if fm.fileExists(atPath: indexPath) {
                finalPath = indexPath
            } else {
                return errorPage404()
            }
        }

        guard var data = try? Data(contentsOf: URL(fileURLWithPath: finalPath)) else {
            return errorPage404()
        }

        // The bundled app receives the launch-scoped token without putting it
        // in a URL, history entry, referrer, or log. Vite development pages use
        // /api/control/bootstrap instead.
        if finalPath.hasSuffix("index.html"),
           var html = String(data: data, encoding: .utf8) {
            let meta = "<meta name=\"meee2-control-token\" content=\"\(controlToken)\">"
            if html.contains("</head>") {
                html = html.replacingOccurrences(of: "</head>", with: "  \(meta)\n  </head>")
                data = Data(html.utf8)
            }
        }

        let contentType = mimeType(for: finalPath)
        var headers = [
            "Content-Type": contentType,
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            "Expires": "0",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
            "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": "default-src 'self'; connect-src 'self' ws: wss:; " +
                "img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; " +
                "script-src 'self'; font-src 'self' data:; frame-ancestors 'none'; " +
                "base-uri 'self'; object-src 'none'"
        ]
        if finalPath.hasSuffix(".woff") || finalPath.hasSuffix(".woff2") || finalPath.hasSuffix(".ttf") {
            headers["Cache-Control"] = "public, max-age=3600"
            headers.removeValue(forKey: "Pragma")
            headers.removeValue(forKey: "Expires")
        }
        let bytes = Array(data)
        return .raw(200, "OK", headers) { writer in
            try writer.write(bytes)
        }
    }

    private func errorPage404() -> HttpResponse {
        let msg = "<!doctype html><html><body><h1>404 Not Found</h1></body></html>"
        let bytes = Array(msg.utf8)
        return .raw(404, "Not Found", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(bytes)
        }
    }

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "application/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "map":         return "application/json; charset=utf-8"
        case "txt":         return "text/plain; charset=utf-8"
        default:            return "application/octet-stream"
        }
    }

    // MARK: - WebSocket session 管理

    private func wsBeginAuthentication(_ ws: WebSocketSession) {
        let timeout = DispatchWorkItem { [weak self, weak ws] in
            guard let self, let ws else { return }
            self.wsLock.lock()
            let wasPending = self.wsPendingAuthentication.removeValue(forKey: ws) != nil
            self.wsLock.unlock()
            if wasPending {
                MWarn("[BoardServer] ws authentication timed out")
                ws.writeCloseFrame()
            }
        }
        wsLock.lock()
        wsPendingAuthentication[ws] = timeout
        wsLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func wsHandleClientText(_ ws: WebSocketSession, text: String) {
        let supplied = Self.websocketAuthToken(in: text)
        wsLock.lock()
        guard let timeout = wsPendingAuthentication.removeValue(forKey: ws) else {
            let authenticated = wsSessions.contains { $0 === ws }
            wsLock.unlock()
            if !authenticated { ws.writeCloseFrame() }
            return
        }
        timeout.cancel()
        guard let supplied, Self.constantTimeEqual(supplied, controlToken) else {
            wsLock.unlock()
            MWarn("[BoardServer] rejected websocket first-frame authentication")
            ws.writeCloseFrame()
            return
        }
        wsSessions.append(ws)
        let total = wsSessions.count
        wsLock.unlock()

        if let data = try? JSONSerialization.data(withJSONObject: ["type": "auth.ok"]),
           let text = String(data: data, encoding: .utf8) {
            ws.writeText(text)
        }
        wsAttachAuthenticated(ws, total: total)
    }

    private func wsAttachAuthenticated(_ ws: WebSocketSession, total: Int) {
        MInfo("[BoardServer] ws connected (total=\(total))")
        // issue #25 诊断：与 client 端的 [StateTrace][board-ws] reconnected 配对，
        // 用来确认 board flash 之前是否伴随一次 WS reconnect。
        MInfo("[StateTrace][ws-connect] /api/events client connected (total clients=\(total))")

        // 连上立即发一条初始 state.changed，让客户端主动拉 /api/state
        let version = currentStateVersion()
        let payload: [String: Any] = [
            "type": "state.changed",
            "timestamp": BoardDTOBuilder.iso(version.generatedAt),
            "revision": version.revision,
            "changedSessionIds": [],
            "removedSessionIds": [],
            "changedSessions": [],
            "snapshotRequired": true
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            ws.writeText(text)
        }
    }

    private func wsDetach(_ ws: WebSocketSession) {
        wsLock.lock()
        wsPendingAuthentication.removeValue(forKey: ws)?.cancel()
        wsSessions.removeAll { $0 === ws }
        let remaining = wsSessions.count
        wsLock.unlock()
        MInfo("[BoardServer] ws disconnected (total=\(remaining))")
        // issue #25 诊断：与 client 端 [StateTrace][board-ws] disconnected 配对。
        MInfo("[StateTrace][ws-disconnect] /api/events client disconnected (total clients=\(remaining))")
    }

    // MARK: - Event bus subscription

    /// 订阅统一事件总线：收到任何 session/channel/message 变动时，
    /// debounce 200ms 再 broadcastStateChanged() —— 避免突发事件（如 PostToolUse 连发）
    /// 打爆 WS 客户端。与 BoardAPI.* 里直接触发的 broadcastStateChanged() 天然合并。
    private func subscribeToEventBus() {
        busSubscription = SessionEventBus.shared.publisher
            .handleEvents(receiveOutput: { [weak self] event in
                self?.recordStateDelta(event)
                BoardPerfProbe.shared.recordEvent(
                    "eventbus.\(event.perfProbeName)",
                    title: event.perfProbeName,
                    category: "eventbus",
                    detail: event.perfProbeDetail
                )
            })
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                BoardAPI.reconcileStateBeforeBroadcast()
                self?.broadcastStateChanged()
            }
    }
}

private extension SessionEvent {
    var perfProbeName: String {
        switch self {
        case .sessionAdded: return "sessionAdded"
        case .sessionRemoved: return "sessionRemoved"
        case .sessionMetadataChanged: return "sessionMetadataChanged"
        case .transcriptAppended: return "transcriptAppended"
        case .channelMutated: return "channelMutated"
        case .messageMutated: return "messageMutated"
        case .cardTemplateChanged: return "cardTemplateChanged"
        case .boardLayoutChanged: return "boardLayoutChanged"
        case .plannerCanvasChanged: return "plannerCanvasChanged"
        }
    }

    var perfProbeDetail: String? {
        switch self {
        case .sessionAdded(let sessionId),
             .sessionRemoved(let sessionId),
             .sessionMetadataChanged(let sessionId),
             .transcriptAppended(let sessionId):
            return "session=\(String(sessionId.prefix(8)))"
        case .channelMutated(let name):
            return "channel=\(name)"
        case .messageMutated(let id, let channel):
            return "message=\(String(id.prefix(8))) channel=\(channel)"
        case .cardTemplateChanged(let id):
            return "template=\(id)"
        case .plannerCanvasChanged(let canvasId):
            return "canvas=\(String(canvasId.prefix(24)))"
        case .boardLayoutChanged:
            return nil
        }
    }
}

private enum BoardServerError: LocalizedError {
    case applicationSupportUnavailable
    case noAvailablePort(start: UInt16)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Could not locate the Application Support directory."
        case .noAvailablePort(let start):
            return "No available BoardServer port found starting at \(start)."
        }
    }
}
