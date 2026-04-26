// Meee360Pusher - 推送 session 状态和 transcript 消息到 meee360 cloud dashboard
//
// 监听 SessionEventBus，当 transcriptAppended / sessionMetadataChanged 时，
// 调用 meee360 REST API 同步数据。只在 meee360Online=true 时激活。

import Foundation
import Combine
import SwiftUI
import Meee2PluginKit

/// 推送器单例，生命周期随 AppDelegate
public final class Meee360Pusher: @unchecked Sendable {
    public static let shared = Meee360Pusher()
    private init() {}

    private var subscription: AnyCancellable?
    private var heartbeatTimer: Timer?

    // Settings from AppStorage (read on activation)
    private var isConnected: Bool { UserDefaults.standard.bool(forKey: "meee360Connected") }
    private var isOnline: Bool { UserDefaults.standard.bool(forKey: "meee360Online") }
    private var teamId: String { UserDefaults.standard.string(forKey: "meee360TeamId") ?? "" }
    private var userId: String { UserDefaults.standard.string(forKey: "meee360UserId") ?? "" }
    private var supabaseUrl: String { UserDefaults.standard.string(forKey: "meee360SupabaseUrl") ?? "" }
    private var supabaseKey: String { UserDefaults.standard.string(forKey: "meee360SupabaseKey") ?? "" }
    private var machineId: String { UserDefaults.standard.string(forKey: "meee360MachineId") ?? "unknown" }

    // Track last pushed message count per session to avoid duplicate pushes
    private var lastPushedCount: [String: Int] = [:]

    // MARK: - Activation

    /// Start listening to SessionEventBus and periodic heartbeat
    public func activate() {
        guard isConnected && isOnline else {
            MLog("[Meee360Pusher] Not connected or offline, skipping activation")
            return
        }

        // Subscribe to events
        subscription = SessionEventBus.shared.publisher
            .sink { [weak self] event in
                self?.handleEvent(event)
            }

        // Start heartbeat timer (30s interval)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.sendHeartbeatForActiveSessions()
        }

        MLog("[Meee360Pusher] Activated - listening to events, heartbeat every 30s")
    }

    public func deactivate() {
        subscription?.cancel()
        subscription = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        MLog("[Meee360Pusher] Deactivated")
    }

    // MARK: - Event handling

    private func handleEvent(_ event: SessionEvent) {
        guard isConnected && isOnline else { return }

        switch event {
        case .transcriptAppended(sessionId: let sid):
            pushNewMessage(sessionId: sid)
        case .sessionMetadataChanged(sessionId: let sid):
            pushSessionUpdate(sessionId: sid)
        case .sessionAdded(sessionId: let sid):
            pushSessionCreate(sessionId: sid)
        default:
            break
        }
    }

    // MARK: - Push methods

    private func pushNewMessage(sessionId: String) {
        guard let session = SessionStore.shared.get(sessionId) else { return }
        guard let transcriptPath = session.transcriptPath else { return }

        // Load recent messages
        let messages = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 5)
        let currentCount = messages.count

        // Skip if we already pushed this count (duplicate event)
        if lastPushedCount[sessionId] == currentCount {
            return
        }
        lastPushedCount[sessionId] = currentCount

        // Push the latest message only
        guard let latest = messages.last else { return }

        let payload: [String: Any] = [
            "machine_id": machineId,
            "session_key": sessionId,
            "message": [
                "role": latest.role,
                "text": String(latest.text.prefix(200))
            ]
        ]

        post(endpoint: "/api/v1/sessions/append-message", payload: payload) { result in
            if case .failure(let err) = result {
                MLog("[Meee360Pusher] append-message failed: \(err)")
            }
        }
    }

    private func pushSessionUpdate(sessionId: String) {
        guard let session = SessionStore.shared.get(sessionId) else { return }
        pushSessionUpsert(session: session)
    }

    private func pushSessionCreate(sessionId: String) {
        guard let session = SessionStore.shared.get(sessionId) else { return }
        pushSessionUpsert(session: session)
    }

    private func sendHeartbeatForActiveSessions() {
        let activeSessions = SessionStore.shared.listActive()
        for session in activeSessions {
            pushSessionUpsert(session: session)
        }
    }

    private func pushSessionUpsert(session: SessionData) {
        // Build payload with full summary data for meee360 dashboard
        let status = mapStatus(session.status)

        var payload: [String: Any] = [
            "machine_id": machineId,
            "session_key": session.sessionId,
            "session_type": "claude",
            "status": status
        ]

        // Build rich summary JSONB (mirrors BoardDTO.sessionDTO for meee2 web board)
        var summary: [String: Any] = [:]

        // Basic fields
        if !session.project.isEmpty {
            summary["title"] = String(session.project.prefix(100))
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            summary["project"] = cwd
        }

        // Current tool from transcript
        if let transcriptPath = session.transcriptPath {
            let currentTool = TranscriptStatusResolver.resolveCurrentTool(
                transcriptPath: transcriptPath,
                currentTool: session.currentTool
            )
            if let tool = currentTool {
                summary["currentTool"] = tool
            }
        }

        // Usage stats
        if let usage = session.usageStats {
            summary["usageStats"] = [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "cacheCreateTokens": usage.cacheCreateTokens,
                "cacheReadTokens": usage.cacheReadTokens,
                "turns": usage.turns,
                "model": usage.model
            ]
        }

        // Tasks
        let tasks = session.tasks
        if !tasks.isEmpty {
            summary["tasks"] = tasks.map { t in
                [
                    "id": t.id,
                    "name": t.name,
                    "status": t.status.rawValue
                ]
            }
            // Current task (inProgress or first pending)
            if let current = tasks.first(where: { $0.status == .inProgress }) {
                summary["currentTask"] = current.name
            } else if let firstPending = tasks.first(where: { $0.status == .pending }) {
                summary["currentTask"] = firstPending.name
            }
        }

        // Current task from SessionData
        if let currentTask = session.currentTask {
            summary["currentTask"] = currentTask
        }

        // Pending permission info
        if let tool = session.pendingPermissionTool {
            summary["pendingPermissionTool"] = tool
        }
        if let message = session.pendingPermissionMessage {
            summary["pendingPermissionMessage"] = String(message.prefix(500))
        }

        // Background agents from transcript
        if let transcriptPath = session.transcriptPath {
            let bgAgents = BackgroundAgentResolver.resolve(transcriptPath: transcriptPath)
            if !bgAgents.isEmpty {
                summary["backgroundAgents"] = bgAgents.map { a in
                    [
                        "id": a.id,
                        "kind": a.kind,
                        "description": a.description ?? "",
                        "startedAt": a.startedAt != nil ? iso8601String(a.startedAt!) : nil
                    ] as [String: Any?]
                }
            }
        }

        // Latest recap (away summary)
        if let transcriptPath = session.transcriptPath {
            if let recap = RecapResolver.resolve(transcriptPath: transcriptPath) {
                summary["latestRecap"] = [
                    "content": String(recap.content.prefix(500)),
                    "timestamp": recap.timestamp != nil ? iso8601String(recap.timestamp!) : nil
                ]
            }
        }

        // Timestamps
        summary["startedAt"] = iso8601String(session.startedAt)
        summary["lastActivity"] = iso8601String(session.lastActivity)

        // Recent messages (last 5)
        if let transcriptPath = session.transcriptPath {
            let messages = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 5)
            if !messages.isEmpty {
                summary["recentMessages"] = messages.map { m in
                    [
                        "role": m.role,
                        "text": String(m.text.prefix(1000))
                    ]
                }
            }
        }

        // Plugin info (from Claude plugin)
        let pluginInfo = PluginManager.shared.getPluginInfo(for: "com.meee2.plugin.claude")
        summary["pluginDisplayName"] = pluginInfo?.displayName ?? "Claude Code"
        summary["pluginColor"] = hexColorString(pluginInfo?.themeColor)

        // Inbox pending count (from MessageRouter + ChannelRegistry)
        let inboxPending = computeInboxPending(sessionId: session.sessionId)
        if inboxPending > 0 {
            summary["inboxPending"] = inboxPending
        }

        // Terminal info
        if let termInfo = session.terminalInfo {
            summary["termProgram"] = termInfo.termProgram ?? ""
            summary["tty"] = termInfo.tty ?? ""
        }

        // Add summary to payload
        payload["summary"] = summary

        post(endpoint: "/api/v1/sessions/upsert", payload: payload) { result in
            if case .failure(let err) = result {
                MLog("[Meee360Pusher] upsert failed for \(session.sessionId.prefix(8)): \(err)")
            }
        }
    }

    // MARK: - Helper methods

    /// Compute pending inbox count for a session (mirrors BoardDTO.pendingInboxCount)
    private func computeInboxPending(sessionId: String) -> Int {
        let channels = ChannelRegistry.shared.list()
        // Build channel -> alias mapping for this session
        var matches: [(channel: String, alias: String)] = []
        for ch in channels {
            for m in ch.members where m.sessionId == sessionId {
                matches.append((ch.name, m.alias))
            }
        }
        guard !matches.isEmpty else {
            // Fall back to direct inbox
            return MessageRouter.shared.peekInbox(sessionId: sessionId).count
        }

        var count = 0
        for (channelName, alias) in matches {
            let msgs = MessageRouter.shared.listMessages(
                channel: channelName,
                statuses: [.pending, .held]
            )
            for m in msgs {
                if m.fromAlias == alias { continue }
                if m.toAlias == alias || m.toAlias == "*" {
                    count += 1
                }
            }
        }
        // Add direct inbox messages
        count += MessageRouter.shared.peekInbox(sessionId: sessionId).count
        return count
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func hexColorString(_ color: Color?) -> String {
        guard let color = color else { return "#FF9500" }
        let nsColor = NSColor(color).usingColorSpace(.sRGB)
        guard let c = nsColor else { return "#FF9500" }
        let r = Int((c.redComponent * 255.0).rounded())
        let g = Int((c.greenComponent * 255.0).rounded())
        let b = Int((c.blueComponent * 255.0).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - HTTP helper

    private func post(endpoint: String, payload: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        // Determine base URL from Supabase URL or default localhost
        let baseUrl: String
        if !supabaseUrl.isEmpty {
            // Extract project ref from Supabase URL for dashboard
            // e.g. https://xxx.supabase.co -> use localhost:3000 for API
            baseUrl = "http://localhost:3000"
        } else {
            baseUrl = "http://localhost:3000"
        }

        guard let url = URL(string: baseUrl + endpoint) else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth: Bearer token from Supabase anon key (for now, use service role for agent access)
        if !supabaseKey.isEmpty {
            request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    // MARK: - Status mapping

    private func mapStatus(_ status: SessionStatus) -> String {
        switch status {
        case .active: return "active"
        case .idle: return "idle"
        case .waitingForUser: return "waitingForUser"
        case .permissionRequired: return "permissionRequired"
        case .thinking: return "thinking"
        case .tooling: return "tooling"
        case .compacting: return "compacting"
        case .completed: return "completed"
        case .dead: return "dead"
        }
    }
}
