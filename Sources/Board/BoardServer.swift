import Foundation
import Combine
import Swifter

/// BoardServer —— 本地 HTTP + WebSocket 服务器
///
/// - 静态资源：从 `Sources/Board/WebDist/` (via `Bundle.module`) 提供 React SPA
/// - REST API：`/api/*` 路径由 `BoardAPI` 处理
/// - WebSocket：`/api/events` 推送 `{"type":"state.changed","timestamp":"..."}`
///
/// 绑定：仅 127.0.0.1 （通过 Swifter 的 `listenAddressIPv4` + `forceIPv4: true`）
public final class BoardServer {
    public static let shared = BoardServer()

    private var server: HttpServer?
    private let stateLock = NSLock()

    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = 9876

    public var url: String { "http://localhost:\(port)" }

    /// 当前活跃的 WebSocket sessions（broadcast 用）
    private var wsSessions: [WebSocketSession] = []
    private let wsLock = NSLock()

    /// SessionEventBus 订阅，持有期同 server 生命周期
    private var busSubscription: AnyCancellable?

    private init() {
        if let raw = ProcessInfo.processInfo.environment["MEEE2_BOARD_PORT"],
           let p = UInt16(raw) {
            self.port = p
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

        let server = HttpServer()
        // 仅监听环回地址，防止对外暴露
        server.listenAddressIPv4 = "127.0.0.1"

        registerRoutes(on: server)

        do {
            try server.start(port, forceIPv4: true)
        } catch {
            MError("[BoardServer] failed to bind port \(port): \(error)")
            throw error
        }

        self.server = server
        self.isRunning = true
        MInfo("[BoardServer] listening on \(url) (bound to 127.0.0.1)")

        subscribeToEventBus()
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
        MInfo("[BoardServer] stopped")
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

    private func registerRoutes(on server: HttpServer) {
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
        server.GET["/api/state"]   = BoardAPI.getState
        server.POST["/api/sessions/:id/activate"] = BoardAPI.activateSession
        server.POST["/api/sessions/:id/inject"] = BoardAPI.injectToSession
        server.GET["/api/sessions/:id/transcript"] = BoardAPI.getTranscript
        server.POST["/api/sessions/spawn"] = BoardAPI.spawnSession
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

        // --- Card Templates ---
        server.GET["/api/card-templates"]         = BoardAPI.listCardTemplates
        server.GET["/api/card-templates/:id"]     = BoardAPI.getCardTemplate
        server.PUT["/api/card-templates/:id"]     = BoardAPI.putCardTemplate
        server.DELETE["/api/card-templates/:id"]  = BoardAPI.deleteCardTemplate

        // --- 静态文件（SPA） ---
        // `GET /` -> index.html；其他路径尝试 WebDist 内的文件；未匹配时回 404
        server.notFoundHandler = { [weak self] request in
            guard let self = self else { return .notFound }
            return self.serveStaticFile(for: request.path)
        }
    }

    // MARK: - 静态文件

    private func serveStaticFile(for requestedPath: String) -> HttpResponse {
        guard let webRoot = Bundle.module.url(forResource: "WebDist", withExtension: nil) else {
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
        if !target.path.hasPrefix(webRootStd) {
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
