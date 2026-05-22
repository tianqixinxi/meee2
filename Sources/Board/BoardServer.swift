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
/// 绑定：默认仅 127.0.0.1 （通过 Swifter 的 `listenAddressIPv4` + `forceIPv4: true`）。
/// 设 env `MEEE2_BOARD_BIND=0.0.0.0` 可暴露到局域网（无 auth，自担风险）。
public final class BoardServer {
    public static let shared = BoardServer()
    public static let defaultPort: UInt16 = 9876
    public static let defaultBindAddress: String = "127.0.0.1"
    public static let maxAutoPortOffset: UInt16 = 100
    public static let portEnvVar = "MEEE2_BOARD_PORT"
    public static let bindEnvVar = "MEEE2_BOARD_BIND"

    private var server: HttpServer?
    private let stateLock = NSLock()
    private let preferredPort: UInt16
    /// 实际 bind 的 IPv4 地址。`127.0.0.1` = 仅本机；`0.0.0.0` = 全部接口（LAN 可达）；
    /// 也可指定具体网卡 IP（比如只暴露给 `192.168.1.0/24`）。
    private let bindAddress: String

    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = BoardServer.defaultPort

    /// Loopback URL —— 内部回调（meee2 OAuth callback / CLI 提示）始终用这个，
    /// 即使 server 暴露到 0.0.0.0，浏览器在本机访问 `127.0.0.1` 一样能命中。
    public var url: String { "http://127.0.0.1:\(port)" }

    /// LAN 可达 URLs —— 当 bindAddress 非 loopback 时，遍历本机所有 IPv4 网卡。
    /// 用于启动时打印让用户知道局域网里别的设备该填什么地址。
    public var lanURLs: [String] {
        guard bindAddress != Self.defaultBindAddress else { return [] }
        return Self.enumerateLanIPv4Addresses().map { "http://\($0):\(port)" }
    }

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
        // bind 地址也可通过环境变量覆盖。空串 / 非法值 → 回落 loopback。
        let envBind = ProcessInfo.processInfo.environment[Self.bindEnvVar]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        self.bindAddress = envBind.isEmpty ? Self.defaultBindAddress : envBind
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
            // 默认只监听环回地址；用户设置 MEEE2_BOARD_BIND=0.0.0.0 可暴露到 LAN
            // （API 没 auth，等于完全开放，仅家里 / 私有 WiFi 用）。
            server.listenAddressIPv4 = bindAddress

            registerRoutes(on: server)

            do {
                try server.start(candidate, forceIPv4: true)
                self.server = server
                self.port = candidate
                self.isRunning = true
                if bindAddress == Self.defaultBindAddress {
                    MInfo("[BoardServer] listening on \(url) (bound to 127.0.0.1)")
                } else {
                    MWarn("[BoardServer] LAN-exposed: bound to \(bindAddress):\(candidate). " +
                          "BoardAPI has no auth — anyone on the network can spawn / inject / kill sessions.")
                    MInfo("[BoardServer] loopback: \(url)")
                    for lurl in lanURLs {
                        MInfo("[BoardServer] LAN reachable: \(lurl)")
                    }
                }
                writeRuntimeInfo()
                subscribeToEventBus()
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
                "host": bindAddress,
                "port": Int(port),
                "url": url,
                "lanUrls": lanURLs,
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

    /// 列出本机所有非 loopback IPv4 地址（en0/en1/Wi-Fi/以太网/USB-C 网卡等）。
    /// 用 `getifaddrs()` —— BSD 标准 API，不需要额外依赖。过滤掉 link-local
    /// （169.254.x）和 utun / awdl0 / llw0 这些不是真 LAN 的虚拟接口。
    static func enumerateLanIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return results }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            // 必须 UP + RUNNING + 非 loopback
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            // 接口名过滤：utun*（VPN）、awdl0 / llw0（Apple Wireless Direct Link）跳过
            let ifname = String(cString: ptr.pointee.ifa_name)
            if ifname.hasPrefix("utun") || ifname == "awdl0" || ifname == "llw0" { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let rc = getnameinfo(addr, saLen, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let host = String(cString: hostBuf)
            // 169.254.x 是 link-local 自分配地址，没用
            if host.hasPrefix("169.254.") { continue }
            results.append(host)
        }
        return results
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

    /// CORS 头：允许 meee2 (localhost:3000 / Vercel deploy) 跨域 fetch
    /// `/api/*`。无 wildcard scope 限制——所有 origin 都允许，因为这个
    /// server 已经只 bind 到 127.0.0.1，只能从同机访问。
    private static let corsHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS",
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
        // CORS preflight (OPTIONS) — meee2 browser sends a preflight before
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
        server.GET["/api/state"]   = BoardServer.cors(BoardAPI.getState)
        server.GET["/api/system/meee2-mcp-status"] = BoardServer.cors(BoardAPI.getMeee2MCPStatus)
        server.GET["/api/system/meee2-agent-runtime-status"] = BoardServer.cors(BoardAPI.getMeee2AgentRuntimeStatus)
        server.POST["/api/system/meee2-agent-runtime-install"] = BoardServer.cors(BoardAPI.installMeee2AgentRuntime)
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
        server.POST["/api/sessions/:id/inject"] = BoardAPI.injectToSession
        server.POST["/api/sessions/:id/push-now"] = BoardServer.cors(BoardAPI.pushToDesktopNow)
        server.DELETE["/api/sessions/:id"] = BoardServer.cors(BoardAPI.closeSession)
        server.POST["/api/system/open-accessibility-settings"] = BoardServer.cors(BoardAPI.openAccessibilitySettings)
        server.GET["/api/whoami"] = BoardServer.cors(BoardAPI.getWhoami)
        server.GET["/api/version"] = BoardServer.cors(BoardAPI.getVersion)
        server.POST["/api/version/check"] = BoardServer.cors(BoardAPI.checkVersion)
        server.POST["/api/update/install"] = BoardServer.cors(BoardAPI.installUpdate)
        server.POST["/api/update/check-in-background"] = BoardServer.cors(BoardAPI.checkUpdateInBackground)
        server.POST["/api/_dev/override-latest"] = BoardServer.cors(BoardAPI.devOverrideLatest)
        server.GET["/api/_dev/pill-click-plan"] = BoardServer.cors(BoardAPI.devPillClickPlan)
        server.POST["/api/sessions/:id/attachments"] = AttachmentsAPI.upload
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
        server.GET["/api/planner/monitor"] = BoardServer.cors(BoardAPI.getPlannerWorkspaceMonitor)
        server.POST["/api/planner/activity"] = BoardServer.cors(BoardAPI.updatePlannerActivity)
        server.GET["/api/planner/canvases/:id/state"] = BoardServer.cors(BoardAPI.getPlannerCanvasState)
        server.GET["/api/planner/canvases/:id/graph"] = BoardServer.cors(BoardAPI.getPlannerGraphState)
        server.POST["/api/planner/canvases/:id/clear"] = BoardServer.cors(BoardAPI.clearPlannerCanvasContent)
        server.PATCH["/api/planner/canvases/:id/visibility"] = BoardServer.cors(BoardAPI.setPlannerCanvasVisibility)
        server.PATCH["/api/planner/canvases/:id/description"] = BoardServer.cors(BoardAPI.setPlannerCanvasDescription)
        server.POST["/api/planner/canvases/:id/proposals/generate"] = BoardServer.cors(BoardAPI.generatePlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/refine"] = BoardServer.cors(BoardAPI.refinePlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/inspect-drift"] = BoardServer.cors(BoardAPI.inspectPlannerDrift)
        server.POST["/api/planner/canvases/:id/proposals/apply-preview"] = BoardServer.cors(BoardAPI.applyPlannerProposalPreview)
        server.POST["/api/planner/canvases/:id/proposals/graph-change"] = BoardServer.cors(BoardAPI.proposePlannerGraphChange)
        server.POST["/api/planner/canvases/:id/templates/delivery-pipeline"] = BoardServer.cors(BoardAPI.createPlannerDeliveryPipeline)
        server.POST["/api/planner/canvases/:id/proposals/:proposalId/approve"] = BoardServer.cors(BoardAPI.approvePlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/:proposalId/apply"] = BoardServer.cors(BoardAPI.applyPlannerProposal)
        server.POST["/api/planner/canvases/:id/proposals/:proposalId/reject"] = BoardServer.cors(BoardAPI.rejectPlannerProposal)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/bind-session"] = BoardServer.cors(BoardAPI.bindPlannerSessionToNode)
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/dispatch"] = BoardServer.cors(BoardAPI.dispatchPlannerNodeSession)
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
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/sub-canvas"] = BoardServer.cors(BoardAPI.createPlannerSubCanvasFromNode)
        server.GET["/api/planner/canvases/:id/artifacts/:artifactId/content"] = BoardServer.cors(BoardAPI.getPlannerArtifactContent)
        // UI-1 (ENG-3) — artifact version chain read API.
        server.GET["/api/planner/canvases/:id/nodes/:nodeId/artifact-versions"] = BoardServer.cors(BoardAPI.listPlannerArtifactVersions)
        server.GET["/api/planner/canvases/:id/artifact-versions/:versionId"] = BoardServer.cors(BoardAPI.getPlannerArtifactVersion)
        // UI-1 (ENG-3) — re-run a gate node by re-submitting its latest version
        // with force_new_version: true. Body: { reference?: string } (optional;
        // defaults to the node's latest version slot).
        server.POST["/api/planner/canvases/:id/nodes/:nodeId/rerun"] = BoardServer.cors(BoardAPI.rerunPlannerNode)
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
        server.POST["/api/integrations/:id/complete-auth"] = BoardServer.cors(IntegrationsAPI.completeAuth)
        server.POST["/api/integrations/:id/recommend-workflow"] = BoardServer.cors(IntegrationsAPI.recommendWorkflow)
        server.POST["/api/integrations/:id/runbook"] = BoardServer.cors(IntegrationsAPI.generateRunbook)
        server.GET["/api/integrations/github/repos"] = BoardServer.cors(IntegrationsAPI.getGithubRepos)
        server.GET["/api/integrations/github/repos/:owner/:repo/pulls"] = BoardServer.cors(IntegrationsAPI.getGithubPulls)
        server.GET["/api/integrations/github/repos/:owner/:repo/issues"] = BoardServer.cors(IntegrationsAPI.getGithubIssues)
        server.GET["/api/integrations/lark/docs"] = BoardServer.cors(IntegrationsAPI.getLarkDocs)

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
        server.POST["/api/channels/:name/rename"] = BoardAPI.renameChannel
        server.GET["/api/channels/:name/messages"] = BoardAPI.listMessages
        server.POST["/api/messages/send"] = BoardAPI.sendMessage
        server.POST["/api/messages/:id/hold"] = BoardAPI.holdMessage
        server.POST["/api/messages/:id/deliver"] = BoardAPI.deliverMessage
        server.POST["/api/messages/:id/drop"] = BoardAPI.dropMessage

        // --- Global assistant (claude -p driven "ask & spawn") ---
        server.POST["/api/assistant/chat"] = AssistantAPI.chat
        server.GET["/api/assistant/local-session/messages"] = BoardServer.cors(AssistantAPI.localSessionMessages)

        // --- Card Templates ---
        server.GET["/api/card-templates"]         = BoardAPI.listCardTemplates
        server.GET["/api/card-templates/:id"]     = BoardAPI.getCardTemplate
        server.PUT["/api/card-templates/:id"]     = BoardAPI.putCardTemplate
        server.DELETE["/api/card-templates/:id"]  = BoardAPI.deleteCardTemplate

        // --- Board Layout (session 卡片 + channel hub 坐标) ---
        server.GET["/api/board/layout"] = BoardAPI.getBoardLayout
        server.PUT["/api/board/layout"] = BoardAPI.putBoardLayout

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

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: finalPath)) else {
            return errorPage404()
        }

        let contentType = mimeType(for: finalPath)
        var headers = [
            "Content-Type": contentType,
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            "Expires": "0"
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

    private func wsAttach(_ ws: WebSocketSession) {
        wsLock.lock()
        wsSessions.append(ws)
        let total = wsSessions.count
        wsLock.unlock()
        MInfo("[BoardServer] ws connected (total=\(total))")
        // issue #25 诊断：与 client 端的 [StateTrace][board-ws] reconnected 配对，
        // 用来确认 board flash 之前是否伴随一次 WS reconnect。
        MInfo("[StateTrace][ws-connect] /api/events client connected (total clients=\(total))")

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
        // issue #25 诊断：与 client 端 [StateTrace][board-ws] disconnected 配对。
        MInfo("[StateTrace][ws-disconnect] /api/events client disconnected (total clients=\(remaining))")
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
