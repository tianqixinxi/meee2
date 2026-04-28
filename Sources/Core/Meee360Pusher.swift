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
    private var pluginSessionsSubscription: AnyCancellable?
    private var heartbeatTimer: Timer?
    private let syncQueue = DispatchQueue(label: "com.meee2.meee360-pusher", qos: .utility)
    private let heartbeatInterval: TimeInterval = 60.0
    private let metadataDebounceInterval: TimeInterval = 0.5

    // Settings from AppStorage (read on activation)
    private var isConnected: Bool { UserDefaults.standard.bool(forKey: "meee360Connected") }
    private var isOnline: Bool { UserDefaults.standard.bool(forKey: "meee360Online") }
    private var disabledSessionIds: Set<String> { Self.sessionIdSet(forKey: "meee360DisabledSessionIds") }
    private var sessionTeamIds: [String: String] { Self.sessionIdMap(forKey: "meee360SessionTeamIds") }
    private var teamId: String { UserDefaults.standard.string(forKey: "meee360TeamId") ?? "" }
    private var userId: String { UserDefaults.standard.string(forKey: "meee360UserId") ?? "" }
    private var supabaseUrl: String { UserDefaults.standard.string(forKey: "meee360SupabaseUrl") ?? "" }
    private var normalizedSupabaseUrl: String {
        let raw = supabaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private var supabaseKey: String { UserDefaults.standard.string(forKey: "meee360SupabaseKey") ?? "" }
    private var machineId: String { UserDefaults.standard.string(forKey: "meee360MachineId") ?? "unknown" }

    // Track last pushed message count per session to avoid duplicate pushes
    private var lastPushedCount: [String: Int] = [:]
    private var pushedPluginMessageKeys = Set<String>()
    private var inFlightPluginMessageKeys = Set<String>()
    private var pendingSessionUpdateWorkItems: [String: DispatchWorkItem] = [:]
    private var lastSessionUpsertSignatures: [String: String] = [:]
    private var lastPluginUpsertSignatures: [String: String] = [:]

    // MARK: - Activation

    /// Start listening to SessionEventBus and periodic heartbeat
    public func activate() {
        guard isConnected && isOnline else {
            MLog("[Meee360Pusher] Not connected or offline, skipping activation")
            return
        }
        guard subscription == nil,
              pluginSessionsSubscription == nil,
              heartbeatTimer == nil else {
            syncQueue.async { [weak self] in
                self?.sendHeartbeatForActiveSessions()
            }
            return
        }

        // Subscribe to events
        subscription = SessionEventBus.shared.publisher
            .sink { [weak self] event in
                self?.handleEvent(event)
            }

        pluginSessionsSubscription = PluginManager.shared.$sessions
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] sessions in
                self?.syncQueue.async {
                    self?.pushPluginSessions(sessions)
                }
            }

        // Start heartbeat timer (60s interval)
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.syncQueue.async {
                self?.sendHeartbeatForActiveSessions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        MLog("[Meee360Pusher] Activated - listening to events, heartbeat every 60s")
        syncQueue.async { [weak self] in
            self?.sendHeartbeatForActiveSessions()
        }
    }

    public func deactivate() {
        subscription?.cancel()
        subscription = nil
        pluginSessionsSubscription?.cancel()
        pluginSessionsSubscription = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        syncQueue.async { [weak self] in
            self?.pendingSessionUpdateWorkItems.values.forEach { $0.cancel() }
            self?.pendingSessionUpdateWorkItems.removeAll()
        }
        MLog("[Meee360Pusher] Deactivated")
    }

    public func refreshActivation() {
        if isConnected && isOnline {
            activate()
        } else {
            deactivate()
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ event: SessionEvent) {
        guard isConnected && isOnline else { return }

        switch event {
        case .transcriptAppended(sessionId: let sid):
            guard shouldSyncSessionId(sid) else { return }
            syncQueue.async { [weak self] in
                self?.pushNewMessage(sessionId: sid)
            }
        case .sessionMetadataChanged(sessionId: let sid):
            guard shouldSyncSessionId(sid) else { return }
            scheduleSessionUpdate(sessionId: sid)
        case .sessionAdded(sessionId: let sid):
            guard shouldSyncSessionId(sid) else { return }
            syncQueue.async { [weak self] in
                self?.pushSessionCreate(sessionId: sid)
            }
        default:
            break
        }
    }

    private func scheduleSessionUpdate(sessionId: String) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingSessionUpdateWorkItems[sessionId]?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.pendingSessionUpdateWorkItems.removeValue(forKey: sessionId)
                self?.pushSessionUpdate(sessionId: sessionId)
            }
            self.pendingSessionUpdateWorkItems[sessionId] = workItem
            self.syncQueue.asyncAfter(deadline: .now() + self.metadataDebounceInterval, execute: workItem)
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
        pushSessionUpsert(session: session, force: true)
    }

    private func sendHeartbeatForActiveSessions() {
        let activeSessions = SessionStore.shared.listActive()
        for session in activeSessions where shouldSyncSessionId(session.sessionId) {
            pushSessionUpsert(session: session, force: true)
        }

        pushPluginSessions(PluginManager.shared.sessions, force: true)
    }

    private func pushSessionUpsert(session: SessionData, force: Bool = false) {
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
                    var agent: [String: Any] = [
                        "id": a.id,
                        "kind": a.kind,
                        "description": a.description ?? ""
                    ]
                    if let startedAt = a.startedAt {
                        agent["startedAt"] = iso8601String(startedAt)
                    }
                    return agent
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

        let signature = upsertSignature(status: status, summary: summary)
        if !force, lastSessionUpsertSignatures[session.sessionId] == signature {
            return
        }

        post(endpoint: "/api/v1/sessions/upsert", payload: payload) { result in
            switch result {
            case .success:
                self.syncQueue.async {
                    self.lastSessionUpsertSignatures[session.sessionId] = signature
                }
            case .failure(let err):
                MLog("[Meee360Pusher] upsert failed for \(session.sessionId.prefix(8)): \(err)")
            }
        }
    }

    private func pushPluginSessions(_ sessions: [PluginSession], force: Bool = false) {
        guard isConnected && isOnline else { return }

        for session in sessions where shouldSyncPluginSession(session) {
            pushPluginSessionUpsert(session: session, force: force) { [weak self] in
                self?.pushLatestPluginMessageIfNeeded(session: session)
            }
        }
    }

    private func shouldSyncPluginSession(_ session: PluginSession) -> Bool {
        if session.pluginId == "com.meee2.plugin.claude" {
            return false
        }
        return shouldSyncSessionId(session.id)
    }

    private func shouldSyncSessionId(_ sessionId: String) -> Bool {
        let disabled = disabledSessionIds
        if disabled.contains(sessionId) {
            return false
        }

        let aliases = Self.sessionIdAliases(sessionId)
        return aliases.isDisjoint(with: disabled)
    }

    private func teamIdForSession(_ sessionId: String) -> String {
        let map = sessionTeamIds
        for alias in Self.sessionIdAliases(sessionId) {
            if let mapped = map[alias], !mapped.isEmpty {
                return mapped
            }
        }
        return teamId
    }

    private func pushLatestPluginMessageIfNeeded(session: PluginSession) {
        guard let transcriptPath = session.transcriptPath else { return }
        let targetTeamId = teamIdForSession(session.id)
        guard !targetTeamId.isEmpty else { return }

        let entries = FullTranscriptReader.read(transcriptPath: transcriptPath, limit: 20)
        for entry in entries {
            for exported in pluginTranscriptExports(from: entry) {
                let key = "\(targetTeamId):\(session.id):\(exported.sourceId)"
                if pushedPluginMessageKeys.contains(key) || inFlightPluginMessageKeys.contains(key) {
                    continue
                }

                inFlightPluginMessageKeys.insert(key)
                let payload: [String: Any] = [
                    "machine_id": machineId,
                    "session_key": session.id,
                    "message": [
                        "role": exported.role,
                        "text": exported.text,
                        "source_id": exported.sourceId,
                        "content": ["text": exported.text, "sourceId": exported.sourceId]
                    ]
                ]

                post(endpoint: "/api/v1/sessions/append-message", payload: payload) { result in
                    self.syncQueue.async {
                        self.inFlightPluginMessageKeys.remove(key)
                        switch result {
                        case .success:
                            self.pushedPluginMessageKeys.insert(key)
                        case .failure(let err):
                            MLog("[Meee360Pusher] plugin append-message failed for \(session.id.prefix(8)): \(err)")
                        }
                    }
                }
            }
        }
    }

    private func pluginTranscriptExports(from entry: FullTranscriptEntry) -> [(sourceId: String, role: String, text: String)] {
        guard entry.type == "user" || entry.type == "assistant" || entry.type == "injected" else {
            return []
        }

        return entry.blocks.enumerated().compactMap { index, block in
            guard block.type == "text",
                  let text = readableTranscriptText(block.text, limit: 4_000) else {
                return nil
            }
            return (
                sourceId: "\(entry.id)#text-\(index)",
                role: entry.type == "injected" ? "user" : entry.type,
                text: text
            )
        }
    }

    private func readableTranscriptText(_ text: String?, limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return String(text.prefix(limit))
    }

    public static func sessionIdSet(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    public static func storeSessionIdSet(_ ids: Set<String>, forKey key: String) {
        let sorted = ids.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func sessionIdMap(forKey key: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    public static func sessionIdAliases(_ sessionId: String) -> Set<String> {
        var aliases: Set<String> = [sessionId]
        let knownPrefixes = [
            "com.meee2.plugin.claude-",
            "com.meee2.plugin.codex-"
        ]
        for prefix in knownPrefixes where sessionId.hasPrefix(prefix) {
            aliases.insert(String(sessionId.dropFirst(prefix.count)))
        }
        return aliases
    }

    private func pushPluginSessionUpsert(session: PluginSession, force: Bool = false, completion: (() -> Void)? = nil) {
        let dto = BoardDTOBuilder.sessionDTO(session)

        var summary: [String: Any] = [
            "title": dto.title,
            "project": dto.project,
            "pluginId": dto.pluginId,
            "pluginDisplayName": dto.pluginDisplayName,
            "pluginColor": dto.pluginColor,
            "inboxPending": dto.inboxPending
        ]

        if let startedAt = dto.startedAt {
            summary["startedAt"] = startedAt
        }
        if let lastActivity = dto.lastActivity {
            summary["lastActivity"] = lastActivity
        }
        if let currentTool = dto.currentTool {
            summary["currentTool"] = currentTool
        }
        if let usage = dto.usageStats {
            summary["usageStats"] = [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "cacheCreateTokens": usage.cacheCreateTokens,
                "cacheReadTokens": usage.cacheReadTokens,
                "turns": usage.turns,
                "model": usage.model
            ]
        }
        if !dto.tasks.isEmpty {
            summary["tasks"] = dto.tasks.map {
                ["id": $0.id, "name": $0.name, "status": $0.status]
            }
        }
        if let currentTask = dto.currentTask {
            summary["currentTask"] = currentTask
        }
        if let pendingPermissionTool = dto.pendingPermissionTool {
            summary["pendingPermissionTool"] = pendingPermissionTool
        }
        if let pendingPermissionMessage = dto.pendingPermissionMessage {
            summary["pendingPermissionMessage"] = pendingPermissionMessage
        }
        if let tty = dto.tty {
            summary["tty"] = tty
        }
        if let termProgram = dto.termProgram {
            summary["termProgram"] = termProgram
        }
        if !dto.backgroundAgents.isEmpty {
            summary["backgroundAgents"] = dto.backgroundAgents.map {
                var agent: [String: Any] = [
                    "id": $0.id,
                    "kind": $0.kind,
                    "description": $0.description ?? ""
                ]
                if let startedAt = $0.startedAt {
                    agent["startedAt"] = startedAt
                }
                return agent
            }
        }
        if let recap = dto.latestRecap {
            var latestRecap: [String: Any] = ["content": recap.content]
            if let timestamp = recap.timestamp {
                latestRecap["timestamp"] = timestamp
            }
            summary["latestRecap"] = latestRecap
        }

        let payload: [String: Any] = [
            "machine_id": machineId,
            "session_key": session.id,
            "session_type": "other",
            "status": dto.status,
            "summary": summary
        ]

        let signature = upsertSignature(status: dto.status, summary: summary)
        if !force, lastPluginUpsertSignatures[session.id] == signature {
            completion?()
            return
        }

        post(endpoint: "/api/v1/sessions/upsert", payload: payload) { result in
            switch result {
            case .success:
                self.syncQueue.async {
                    self.lastPluginUpsertSignatures[session.id] = signature
                    completion?()
                }
            case .failure(let err):
                MLog("[Meee360Pusher] plugin upsert failed for \(session.id.prefix(8)): \(err)")
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

    private func upsertSignature(status: String, summary: [String: Any]) -> String {
        let normalizedSummary = normalizedForSignature(summary, droppingKeys: ["lastActivity"])
        let object: [String: Any] = [
            "status": status,
            "summary": normalizedSummary
        ]
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(status)|\(normalizedSummary)"
    }

    private func normalizedForSignature(_ value: Any, droppingKeys: Set<String>) -> Any {
        if let dict = value as? [String: Any] {
            var normalized: [String: Any] = [:]
            for key in dict.keys.sorted() where !droppingKeys.contains(key) {
                guard let item = dict[key] else { continue }
                normalized[key] = normalizedForSignature(item, droppingKeys: droppingKeys)
            }
            return normalized
        }
        if let array = value as? [Any] {
            return array.map { normalizedForSignature($0, droppingKeys: droppingKeys) }
        }
        return value
    }

    // MARK: - HTTP helper

    private func post(endpoint: String, payload: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let baseUrl = normalizedSupabaseUrl
        guard let rpc = supabaseRPCRequest(endpoint: endpoint, payload: payload),
              !baseUrl.isEmpty,
              let url = URL(string: "\(baseUrl)/rest/v1/rpc/\(rpc.name)") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: rpc.payload)
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

    private func supabaseRPCRequest(endpoint: String, payload: [String: Any]) -> (name: String, payload: [String: Any])? {
        guard !normalizedSupabaseUrl.isEmpty,
              !supabaseKey.isEmpty,
              !userId.isEmpty,
              let machineId = payload["machine_id"] as? String,
              let sessionKey = payload["session_key"] as? String else {
            return nil
        }
        let targetTeamId = teamIdForSession(sessionKey)
        guard !targetTeamId.isEmpty else { return nil }

        switch endpoint {
        case "/api/v1/sessions/upsert":
            return (
                "meee360_upsert_session",
                [
                    "p_team_id": targetTeamId,
                    "p_user_id": userId,
                    "p_machine_id": machineId,
                    "p_session_key": sessionKey,
                    "p_session_type": payload["session_type"] as? String ?? "claude",
                    "p_status": payload["status"] as? String ?? "active",
                    "p_summary": payload["summary"] as? [String: Any] ?? [:]
                ]
            )
        case "/api/v1/sessions/append-message":
            guard let message = payload["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  let text = message["text"] as? String else {
                return nil
            }
            if let sourceId = message["source_id"] as? String, !sourceId.isEmpty {
                return (
                    "meee360_append_recent_message_v2",
                    [
                        "p_team_id": targetTeamId,
                        "p_user_id": userId,
                        "p_machine_id": machineId,
                        "p_session_key": sessionKey,
                        "p_role": role,
                        "p_text": text,
                        "p_source_id": sourceId
                    ]
                )
            }
            return (
                "meee360_append_recent_message",
                [
                    "p_team_id": targetTeamId,
                    "p_user_id": userId,
                    "p_machine_id": machineId,
                    "p_session_key": sessionKey,
                    "p_role": role,
                    "p_text": text
                ]
            )
        default:
            return nil
        }
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
