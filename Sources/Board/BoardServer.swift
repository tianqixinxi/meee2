import Foundation
import Combine
import Swifter
import Meee2CommKit

/// BoardServer —— 本地 HTTP + WebSocket 服务器
///
/// - 静态资源：从 `Sources/Board/WebDist/` (via `Bundle.module`) 提供 React SPA
/// - REST API：`/api/*` 路径由 `BoardAPI` 处理
/// - WebSocket：`/api/events` 推送 `{"type":"state.changed","timestamp":"..."}`
///
/// 绑定：仅 127.0.0.1 （通过 Swifter 的 `listenAddressIPv4` + `forceIPv4: true`）
public final class BoardServer {
    public static let shared = BoardServer()
    public static let defaultPort: UInt16 = 9876
    public static let maxAutoPortOffset: UInt16 = 100
    public static let portEnvVar = "MEEE2_BOARD_PORT"

    private var server: HttpServer?
    private let stateLock = NSLock()
    private let preferredPort: UInt16

    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = BoardServer.defaultPort

    public var url: String { "http://127.0.0.1:\(port)" }

    /// 当前活跃的 WebSocket sessions（broadcast 用）
    private var wsSessions: [WebSocketSession] = []
    private let wsLock = NSLock()

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
    }

    // MARK: - 生命周期

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isRunning {
            MInfo("[BoardServer] already running on \(url)")
            return
        }

        var lastError: Error?
        for candidate in candidatePorts() {
            let server = HttpServer()
            // 仅监听环回地址，防止对外暴露
            server.listenAddressIPv4 = "127.0.0.1"

            registerRoutes(on: server)

            do {
                try server.start(candidate, forceIPv4: true)
                self.server = server
                self.port = candidate
                self.isRunning = true
                MInfo("[BoardServer] listening on \(url) (bound to 127.0.0.1)")
                writeRuntimeInfo()
                subscribeToEventBus()
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

        wsLock.lock()
        for ws in wsSessions {
            ws.writeCloseFrame()
        }
        wsSessions.removeAll()
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
                "host": "127.0.0.1",
                "port": Int(port),
                "url": url,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "updatedAt": BoardDTOBuilder.iso(Date())
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
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

    // MARK: - 广播

    /// 广播 state.changed 事件到所有 WS 客户端
    public func broadcastStateChanged() {
        let payload: [String: Any] = [
            "type": "state.changed",
            "timestamp": BoardDTOBuilder.iso(Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
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

    // MARK: - 路由注册

    /// CORS 头：允许 meee360 (localhost:3000 / Vercel deploy) 跨域 fetch
    /// `/api/*`。无 wildcard scope 限制——所有 origin 都允许，因为这个
    /// server 已经只 bind 到 127.0.0.1，只能从同机访问。
    private static let corsHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Max-Age": "600"
    ]

    /// Re-emit a HttpResponse with the CORS headers merged in. Wraps any
    /// existing status code / phrase / body — doesn't change semantics, just
    /// adds headers the browser needs to allow the response back to JS.
    ///
    /// `HttpResponse.content()` is internal in swifter, so we route by case
    /// instead of generic re-wrap. All paths produce `.raw` responses with
    /// CORS headers attached.
    private static func withCORS(_ response: HttpResponse) -> HttpResponse {
        var headers = response.headers()
        for (k, v) in corsHeaders { headers[k] = v }
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
        return { request in withCORS(handler(request)) }
    }

    private func registerRoutes(on server: HttpServer) {
        // CORS preflight (OPTIONS) — meee360 browser sends a preflight before
        // POSTs with custom Content-Type / Authorization. Middleware short-
        // circuits with 204 + the CORS headers so the actual request goes
        // through. Any non-OPTIONS falls through to the route handlers below.
        server.middleware.append { request in
            guard request.method.uppercased() == "OPTIONS" else { return nil }
            return .raw(204, "No Content", BoardServer.corsHeaders) { _ in }
        }

        // --- WebSocket ---
        server["/api/events"] = websocket(
            text: { [weak self] ws, _ in
                // 收到客户端文本：MVP 不处理任何入站指令，只是保持连接
                _ = ws
                _ = self
            },
            connected: { [weak self] ws in
                self?.wsAttach(ws)
            },
            disconnected: { [weak self] ws in
                self?.wsDetach(ws)
            }
        )

        // --- REST API ---
        // CORS-wrapped: meee360 in the browser hits these cross-origin.
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
        server.GET["/api/state"]   = BoardServer.cors(BoardAPI.getState)
        server.POST["/api/sessions/:id/activate"] = BoardServer.cors(BoardAPI.activateSession)
        server.POST["/api/sessions/:id/inject"] = BoardAPI.injectToSession
        server.POST["/api/sessions/:id/push-now"] = BoardServer.cors(BoardAPI.pushToDesktopNow)
        server.POST["/api/sessions/:id/attachments"] = AttachmentsAPI.upload
        server.GET["/api/sessions/:id/inbox"] = BoardServer.cors(BoardAPI.getSessionInbox)
        server.GET["/api/sessions/:id/transcript"] = BoardServer.cors(BoardAPI.getTranscript)
        server.POST["/api/sessions/spawn"] = BoardServer.cors(BoardAPI.spawnSession)

        // External chat session push (browser extension content scripts at
        // chatgpt.com / claude.ai). All CORS-wrapped — they hit localhost
        // from a different origin.
        server.POST["/api/external-sessions/upsert"] = BoardServer.cors(BoardAPI.upsertExternalSession)
        server.POST["/api/external-sessions/:sid/append-message"] = BoardServer.cors(BoardAPI.appendExternalMessage)
        server.DELETE["/api/external-sessions/:sid"] = BoardServer.cors(BoardAPI.deleteExternalSession)
        server.POST["/api/channels"] = BoardAPI.createChannel
        server.DELETE["/api/channels/:name"] = BoardAPI.deleteChannel
        server.POST["/api/channels/:name/members"] = BoardAPI.addMember
        server.DELETE["/api/channels/:name/members/:alias"] = BoardAPI.removeMember
        server.POST["/api/channels/:name/mode"] = BoardAPI.setChannelMode
        server.GET["/api/channels/:name/messages"] = BoardAPI.listMessages
        server.POST["/api/messages/send"] = BoardAPI.sendMessage
        server.POST["/api/messages/:id/hold"] = BoardAPI.holdMessage
        server.POST["/api/messages/:id/deliver"] = BoardAPI.deliverMessage
        server.POST["/api/messages/:id/drop"] = BoardAPI.dropMessage

        // --- Global assistant (claude -p driven "ask & spawn") ---
        server.POST["/api/assistant/chat"] = AssistantAPI.chat

        // --- Card Templates ---
        server.GET["/api/card-templates"]         = BoardAPI.listCardTemplates
        server.GET["/api/card-templates/:id"]     = BoardAPI.getCardTemplate
        server.PUT["/api/card-templates/:id"]     = BoardAPI.putCardTemplate
        server.DELETE["/api/card-templates/:id"]  = BoardAPI.deleteCardTemplate

        // --- Board Layout (session 卡片 + channel hub 坐标) ---
        server.GET["/api/board/layout"] = BoardAPI.getBoardLayout
        server.PUT["/api/board/layout"] = BoardAPI.putBoardLayout

        // --- meee360 callback (OAuth-style auto-connect) ---
        server.GET["/meee360/callback"] = Meee360CallbackAPI.handleCallback

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

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: finalPath)) else {
            return errorPage404()
        }

        let contentType = mimeType(for: finalPath)
        let bytes = Array(data)
        return .raw(200, "OK", ["Content-Type": contentType]) { writer in
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

    private func wsAttach(_ ws: WebSocketSession) {
        wsLock.lock()
        wsSessions.append(ws)
        wsLock.unlock()
        MInfo("[BoardServer] ws connected (total=\(wsSessions.count))")

        // 连上立即发一条初始 state.changed，让客户端主动拉 /api/state
        let payload: [String: Any] = [
            "type": "state.changed",
            "timestamp": BoardDTOBuilder.iso(Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            ws.writeText(text)
        }
    }

    private func wsDetach(_ ws: WebSocketSession) {
        wsLock.lock()
        wsSessions.removeAll { $0 === ws }
        let remaining = wsSessions.count
        wsLock.unlock()
        MInfo("[BoardServer] ws disconnected (total=\(remaining))")
    }

    // MARK: - Event bus subscription

    /// 订阅统一事件总线：收到任何 session/channel/message 变动时，
    /// debounce 200ms 再 broadcastStateChanged() —— 避免突发事件（如 PostToolUse 连发）
    /// 打爆 WS 客户端。与 BoardAPI.* 里直接触发的 broadcastStateChanged() 天然合并。
    private func subscribeToEventBus() {
        busSubscription = SessionEventBus.shared.publisher
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.broadcastStateChanged()
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
