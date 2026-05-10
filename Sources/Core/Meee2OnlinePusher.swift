// Meee2OnlinePusher - 推送 session 状态和 transcript 消息到 meee2 cloud dashboard
//
// 监听 SessionEventBus，当 transcriptAppended / sessionMetadataChanged 时，
// 调用 meee2 REST API 同步数据。默认同步打开，或至少一个 session 被
// 单独 opt-in 时激活。

import Foundation
import Combine
import SwiftUI
import Meee2PluginKit
import Meee2CommKit

/// 推送器单例，生命周期随 AppDelegate
public final class Meee2OnlinePusher: @unchecked Sendable {
    public static let shared = Meee2OnlinePusher()
    private init() {}

    private var subscription: AnyCancellable?
    private var pluginSessionsSubscription: AnyCancellable?
    private var heartbeatTimer: Timer?
    private let syncQueue = DispatchQueue(label: "com.meee2.meee2-pusher", qos: .utility)
    private let heartbeatInterval: TimeInterval = 60.0
    private let metadataDebounceInterval: TimeInterval = 0.5
    private let settingsCacheFreshSeconds: TimeInterval = 1.0

    private struct SettingsSnapshot {
        var isConnected: Bool
        var defaultSyncEnabled: Bool
        var disabledSessionIds: Set<String>
        var enabledSessionIds: Set<String>
        var sessionTeamIds: [String: String]
        var teamId: String
        var userId: String
        var normalizedSupabaseUrl: String
        var supabaseKey: String
        var machineId: String
    }

    private struct DesktopCommand {
        var id: String
        var type: String
        var sessionKey: String
        var payload: [String: Any]

        var content: String? {
            payload["content"] as? String
        }
    }

    private struct TranscriptFingerprint: Equatable {
        let fileSize: UInt64
        let modifiedAt: TimeInterval
    }

    private struct PendingCountCacheEntry {
        let at: Date
        let value: Int
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let settingsLock = NSLock()
    private var cachedSettings: SettingsSnapshot?
    private var cachedSettingsAt: Date?
    private let perfLoggingEnabled = ProcessInfo.processInfo.environment["MEEE2_PERF_LOG"] == "1"

    // Track last pushed message count per session to avoid duplicate pushes
    private var lastPushedCount: [String: Int] = [:]
    private var pushedPluginMessageKeys = Set<String>()
    private var inFlightPluginMessageKeys = Set<String>()
    private var pendingSessionUpdateWorkItems: [String: DispatchWorkItem] = [:]
    private var lastSessionUpsertSignatures: [String: String] = [:]
    private var lastPluginUpsertSignatures: [String: String] = [:]
    private var lastPluginTranscriptFingerprints: [String: TranscriptFingerprint] = [:]
    private var inboxPendingCache: [String: PendingCountCacheEntry] = [:]
    private let inboxPendingCacheFreshSeconds: TimeInterval = 1.0

    // MARK: - Activation

    /// Start listening to SessionEventBus and periodic heartbeat
    public func activate() {
        _ = settingsSnapshot(force: true)
        guard shouldStayActive else {
            MLog("[Meee2OnlinePusher] Not connected or no sync targets, skipping activation")
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

        MLog("[Meee2OnlinePusher] Activated - listening to events, heartbeat every 60s")
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
        MLog("[Meee2OnlinePusher] Deactivated")
    }

    public func refreshActivation() {
        _ = settingsSnapshot(force: true)
        if shouldStayActive {
            activate()
        } else {
            deactivate()
        }
    }

    private var shouldStayActive: Bool {
        let settings = settingsSnapshot()
        return settings.isConnected && (settings.defaultSyncEnabled || !settings.enabledSessionIds.isEmpty)
    }

    private var userId: String { settingsSnapshot().userId }
    private var normalizedSupabaseUrl: String { settingsSnapshot().normalizedSupabaseUrl }
    private var supabaseKey: String { settingsSnapshot().supabaseKey }
    private var machineId: String { settingsSnapshot().machineId }

    private func settingsSnapshot(force: Bool = false) -> SettingsSnapshot {
        let now = Date()
        settingsLock.lock()
        defer { settingsLock.unlock() }

        if !force,
           let cached = cachedSettings,
           let cachedAt = cachedSettingsAt,
           now.timeIntervalSince(cachedAt) < settingsCacheFreshSeconds {
            return cached
        }

        let defaults = UserDefaults.standard
        let rawSupabaseUrl = defaults.string(forKey: "meee2SupabaseUrl") ?? ""
        let decodedSupabaseUrl = rawSupabaseUrl.removingPercentEncoding ?? rawSupabaseUrl
        let snapshot = SettingsSnapshot(
            isConnected: defaults.bool(forKey: "meee2Connected"),
            defaultSyncEnabled: defaults.bool(forKey: "meee2Online"),
            disabledSessionIds: Self.sessionIdSet(forKey: "meee2DisabledSessionIds"),
            enabledSessionIds: Self.sessionIdSet(forKey: "meee2EnabledSessionIds"),
            sessionTeamIds: Self.sessionIdMap(forKey: "meee2SessionTeamIds"),
            teamId: defaults.string(forKey: "meee2TeamId") ?? "",
            userId: defaults.string(forKey: "meee2UserId") ?? "",
            normalizedSupabaseUrl: decodedSupabaseUrl
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            supabaseKey: defaults.string(forKey: "meee2SupabaseKey") ?? "",
            machineId: defaults.string(forKey: "meee2MachineId") ?? "unknown"
        )
        cachedSettings = snapshot
        cachedSettingsAt = now
        return snapshot
    }

    // MARK: - Event handling

    private func handleEvent(_ event: SessionEvent) {
        guard shouldStayActive else { return }

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
                MLog("[Meee2OnlinePusher] append-message failed: \(err)")
            }
        }
    }

    private func pushSessionUpdate(sessionId: String) {
        guard let session = SessionStore.shared.get(sessionId) else { return }
        pushSessionUpsert(
            session: session,
            hydrateTranscriptFields: shouldHydrateTranscriptFields(for: session)
        )
    }

    private func pushSessionCreate(sessionId: String) {
        guard let session = SessionStore.shared.get(sessionId) else { return }
        pushSessionUpsert(session: session, force: true)
    }

    private func sendHeartbeatForActiveSessions() {
        let started = Date()
        let activeSessions = SessionStore.shared.listActive()
        for session in activeSessions where shouldSyncSessionId(session.sessionId) {
            pushSessionUpsert(session: session, force: true, hydrateTranscriptFields: false)
        }

        pushPluginSessions(PluginManager.shared.sessions, force: true)
        pollDesktopCommands()
        perfLog("heartbeat", started: started, extra: "sessions=\(activeSessions.count),plugins=\(PluginManager.shared.sessions.count)")
    }

    private func pushSessionUpsert(
        session: SessionData,
        force: Bool = false,
        hydrateTranscriptFields: Bool = true
    ) {
        let started = Date()
        defer {
            perfLog("session-upsert-build", started: started, extra: "sid=\(session.sessionId.prefix(8)),force=\(force),hydrate=\(hydrateTranscriptFields)")
        }
        // Build payload with full summary data for meee2 dashboard
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
        if hydrateTranscriptFields, let transcriptPath = session.transcriptPath {
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
        if hydrateTranscriptFields, let transcriptPath = session.transcriptPath {
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
        if hydrateTranscriptFields, let transcriptPath = session.transcriptPath {
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
                MLog("[Meee2OnlinePusher] upsert failed for \(session.sessionId.prefix(8)): \(err)")
            }
        }
    }

    private func pushPluginSessions(_ sessions: [PluginSession], force: Bool = false) {
        guard shouldStayActive else { return }

        let started = Date()
        for session in sessions where shouldSyncPluginSession(session) {
            pushPluginSessionUpsert(session: session, force: force, hydrateSummary: !force) { [weak self] in
                self?.pushLatestPluginMessageIfNeeded(session: session)
            }
        }
        perfLog("plugin-sessions", started: started, extra: "sessions=\(sessions.count),force=\(force)")
    }

    private func shouldSyncPluginSession(_ session: PluginSession) -> Bool {
        if session.pluginId == "com.meee2.plugin.claude" {
            return false
        }
        return shouldSyncSessionId(session.id)
    }

    private func shouldSyncSessionId(_ sessionId: String) -> Bool {
        let settings = settingsSnapshot()
        let aliases = Self.sessionIdAliases(sessionId)
        if !aliases.isDisjoint(with: settings.disabledSessionIds) {
            return false
        }

        if settings.defaultSyncEnabled {
            return true
        }

        return !aliases.isDisjoint(with: settings.enabledSessionIds)
    }

    private func teamIdForSession(_ sessionId: String) -> String {
        let settings = settingsSnapshot()
        let map = settings.sessionTeamIds
        for alias in Self.sessionIdAliases(sessionId) {
            if let mapped = map[alias], !mapped.isEmpty {
                return mapped
            }
        }
        // `meee2TeamId` is the explicit default sync team selected in
        // Settings. New sessions use it unless a per-session override exists.
        return settings.teamId
    }

    private func pushLatestPluginMessageIfNeeded(session: PluginSession) {
        guard let transcriptPath = session.transcriptPath else { return }
        let targetTeamId = teamIdForSession(session.id)
        guard !targetTeamId.isEmpty else { return }
        guard let fingerprint = transcriptFingerprint(path: transcriptPath) else { return }

        let started = Date()
        let fingerprintKey = "\(targetTeamId):\(session.id):\(transcriptPath)"
        if lastPluginTranscriptFingerprints[fingerprintKey] == fingerprint {
            return
        }

        let entries = FullTranscriptReader.read(transcriptPath: transcriptPath, limit: 20)
        var exportedCount = 0
        var queuedCount = 0
        for entry in entries {
            for exported in pluginTranscriptExports(from: entry) {
                exportedCount += 1
                let key = "\(targetTeamId):\(session.id):\(exported.sourceId)"
                if pushedPluginMessageKeys.contains(key) || inFlightPluginMessageKeys.contains(key) {
                    continue
                }

                inFlightPluginMessageKeys.insert(key)
                queuedCount += 1
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
                            MLog("[Meee2OnlinePusher] plugin append-message failed for \(session.id.prefix(8)): \(err)")
                        }
                    }
                }
            }
        }
        if queuedCount == 0 {
            lastPluginTranscriptFingerprints[fingerprintKey] = fingerprint
        }
        perfLog("plugin-transcript-export", started: started, extra: "sid=\(session.id.prefix(8)),entries=\(entries.count),exports=\(exportedCount),queued=\(queuedCount)")
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

    private func pushPluginSessionUpsert(
        session: PluginSession,
        force: Bool = false,
        hydrateSummary: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        let started = Date()
        let summaryAndStatus = pluginSummaryAndStatus(session: session, hydrateSummary: hydrateSummary)
        var summary = summaryAndStatus.summary

        if let startedAt = summaryAndStatus.startedAt {
            summary["startedAt"] = startedAt
        }
        if let lastActivity = summaryAndStatus.lastActivity {
            summary["lastActivity"] = lastActivity
        }
        if let currentTool = summaryAndStatus.currentTool {
            summary["currentTool"] = currentTool
        }
        if let usage = summaryAndStatus.usageStats {
            summary["usageStats"] = [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "cacheCreateTokens": usage.cacheCreateTokens,
                "cacheReadTokens": usage.cacheReadTokens,
                "turns": usage.turns,
                "model": usage.model
            ]
        }
        if !summaryAndStatus.tasks.isEmpty {
            summary["tasks"] = summaryAndStatus.tasks
        }
        if let currentTask = summaryAndStatus.currentTask {
            summary["currentTask"] = currentTask
        }
        if let pendingPermissionTool = summaryAndStatus.pendingPermissionTool {
            summary["pendingPermissionTool"] = pendingPermissionTool
        }
        if let pendingPermissionMessage = summaryAndStatus.pendingPermissionMessage {
            summary["pendingPermissionMessage"] = pendingPermissionMessage
        }
        if let tty = summaryAndStatus.tty {
            summary["tty"] = tty
        }
        if let termProgram = summaryAndStatus.termProgram {
            summary["termProgram"] = termProgram
        }
        if !summaryAndStatus.backgroundAgents.isEmpty {
            summary["backgroundAgents"] = summaryAndStatus.backgroundAgents
        }
        if let latestRecap = summaryAndStatus.latestRecap {
            summary["latestRecap"] = latestRecap
        }

        let payload: [String: Any] = [
            "machine_id": machineId,
            "session_key": session.id,
            "session_type": "other",
            "status": summaryAndStatus.status,
            "summary": summary
        ]

        let signature = upsertSignature(status: summaryAndStatus.status, summary: summary)
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
                MLog("[Meee2OnlinePusher] plugin upsert failed for \(session.id.prefix(8)): \(err)")
            }
        }
        perfLog("plugin-upsert-build", started: started, extra: "sid=\(session.id.prefix(8)),force=\(force),hydrate=\(hydrateSummary)")
    }

    // MARK: - Helper methods

    private func pluginSummaryAndStatus(
        session: PluginSession,
        hydrateSummary: Bool
    ) -> (
        status: String,
        summary: [String: Any],
        startedAt: String?,
        lastActivity: String?,
        currentTool: String?,
        usageStats: UsageStatsDTO?,
        tasks: [[String: Any]],
        currentTask: String?,
        pendingPermissionTool: String?,
        pendingPermissionMessage: String?,
        tty: String?,
        termProgram: String?,
        backgroundAgents: [[String: Any]],
        latestRecap: [String: Any]?
    ) {
        if hydrateSummary {
            let dto = BoardDTOBuilder.sessionDTO(session)
            var latestRecap: [String: Any]?
            if let recap = dto.latestRecap {
                var value: [String: Any] = ["content": recap.content]
                if let timestamp = recap.timestamp {
                    value["timestamp"] = timestamp
                }
                latestRecap = value
            }
            return (
                status: dto.status,
                summary: [
                    "title": dto.title,
                    "project": dto.project,
                    "pluginId": dto.pluginId,
                    "pluginDisplayName": dto.pluginDisplayName,
                    "pluginColor": dto.pluginColor,
                    "inboxPending": dto.inboxPending
                ],
                startedAt: dto.startedAt,
                lastActivity: dto.lastActivity,
                currentTool: dto.currentTool,
                usageStats: dto.usageStats,
                tasks: dto.tasks.map { ["id": $0.id, "name": $0.name, "status": $0.status] },
                currentTask: dto.currentTask,
                pendingPermissionTool: dto.pendingPermissionTool,
                pendingPermissionMessage: dto.pendingPermissionMessage,
                tty: dto.tty,
                termProgram: dto.termProgram,
                backgroundAgents: dto.backgroundAgents.map {
                    var agent: [String: Any] = [
                        "id": $0.id,
                        "kind": $0.kind,
                        "description": $0.description ?? ""
                    ]
                    if let startedAt = $0.startedAt {
                        agent["startedAt"] = startedAt
                    }
                    return agent
                },
                latestRecap: latestRecap
            )
        }

        let info = PluginManager.shared.getPluginInfo(for: session.pluginId)
        let displayName = info?.displayName ?? session.pluginId
        let colorHex = info.map { hexColorString($0.themeColor) } ?? "#808080"
        let usageStats = session.usageStats.map {
            UsageStatsDTO(
                inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens,
                cacheCreateTokens: $0.cacheCreateTokens,
                cacheReadTokens: $0.cacheReadTokens,
                turns: $0.turns,
                model: $0.model
            )
        }

        return (
            status: session.status.rawValue,
            summary: [
                "title": session.title,
                "project": session.cwd ?? session.title,
                "pluginId": session.pluginId,
                "pluginDisplayName": displayName,
                "pluginColor": colorHex
            ],
            startedAt: BoardDTOBuilder.iso(Optional(session.startedAt)),
            lastActivity: BoardDTOBuilder.iso(session.lastUpdated),
            currentTool: session.toolName,
            usageStats: usageStats,
            tasks: (session.tasks ?? []).map { ["id": $0.id, "name": $0.name, "status": $0.status.rawValue] },
            currentTask: session.subtitle,
            pendingPermissionTool: nil,
            pendingPermissionMessage: nil,
            tty: session.terminalInfo?.tty,
            termProgram: session.terminalInfo?.termProgram,
            backgroundAgents: [],
            latestRecap: nil
        )
    }

    /// Compute pending inbox count for a session (mirrors BoardDTO.pendingInboxCount)
    private func computeInboxPending(sessionId: String) -> Int {
        let now = Date()
        if let cached = inboxPendingCache[sessionId],
           now.timeIntervalSince(cached.at) < inboxPendingCacheFreshSeconds {
            return cached.value
        }

        let channels = ChannelRegistry.shared.list()
        // Build channel -> alias mapping for this session
        var matches: [(channel: String, alias: String)] = []
        for ch in channels {
            for m in ch.members where m.sessionId == sessionId {
                matches.append((ch.name, m.alias))
            }
        }
        let result: Int
        guard !matches.isEmpty else {
            result = MessageRouter.shared.peekInbox(sessionId: sessionId).count
            inboxPendingCache[sessionId] = PendingCountCacheEntry(at: now, value: result)
            return result
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
        result = count
        inboxPendingCache[sessionId] = PendingCountCacheEntry(at: now, value: result)
        if inboxPendingCache.count > 512 {
            inboxPendingCache.removeAll(keepingCapacity: true)
        }
        return result
    }

    private func iso8601String(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private func shouldHydrateTranscriptFields(for session: SessionData) -> Bool {
        guard session.transcriptPath != nil else { return false }
        return session.status.isWorking || session.status.needsUserAction
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

    private func transcriptFingerprint(path: String) -> TranscriptFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }
        return TranscriptFingerprint(fileSize: fileSize, modifiedAt: modifiedAt)
    }

    private func perfLog(_ name: String, started: Date, extra: String = "") {
        guard perfLoggingEnabled else { return }
        let ms = Date().timeIntervalSince(started) * 1_000
        let suffix = extra.isEmpty ? "" : " \(extra)"
        MLog(String(format: "[Perf][Meee2OnlinePusher] %@ %.1fms%@", name, ms, suffix))
    }

    // MARK: - HTTP helper

    private func pollDesktopCommands() {
        let currentUserId = userId
        let currentMachineId = machineId
        guard !normalizedSupabaseUrl.isEmpty,
              !supabaseKey.isEmpty,
              !currentUserId.isEmpty,
              !currentMachineId.isEmpty else {
            return
        }

        rpcDataRequest(
            name: "meee2_poll_desktop_commands",
            payload: [
                "p_user_id": currentUserId,
                "p_machine_id": currentMachineId,
                "p_limit": 10
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                for command in Self.parseDesktopCommands(data) {
                    self.executeDesktopCommand(command, userId: currentUserId, machineId: currentMachineId)
                }
            case .failure(let error):
                MLog("[Meee2OnlinePusher] desktop command poll failed: \(error)")
            }
        }
    }

    private static func parseDesktopCommands(_ data: Data) -> [DesktopCommand] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let type = row["command_type"] as? String,
                  let sessionKey = row["session_key"] as? String,
                  let payload = row["payload"] as? [String: Any] else {
                return nil
            }
            return DesktopCommand(id: id, type: type, sessionKey: sessionKey, payload: payload)
        }
    }

    private func executeDesktopCommand(_ command: DesktopCommand, userId: String, machineId: String) {
        guard command.type == "message_session",
              let content = command.content,
              !content.isEmpty else {
            completeDesktopCommand(
                commandId: command.id,
                userId: userId,
                machineId: machineId,
                status: "failed",
                result: [:],
                error: "Unsupported or invalid desktop command"
            )
            return
        }

        injectLocalMessage(sessionKey: command.sessionKey, content: content) { [weak self] result in
            switch result {
            case .success:
                self?.completeDesktopCommand(
                    commandId: command.id,
                    userId: userId,
                    machineId: machineId,
                    status: "succeeded",
                    result: ["delivery": "queued_to_local_session"],
                    error: nil
                )
            case .failure(let error):
                self?.completeDesktopCommand(
                    commandId: command.id,
                    userId: userId,
                    machineId: machineId,
                    status: "failed",
                    result: [:],
                    error: error.localizedDescription
                )
            }
        }
    }

    private func injectLocalMessage(sessionKey: String, content: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let encodedSessionKey = sessionKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionKey
        guard let url = URL(string: "\(BoardServer.shared.url)/api/sessions/\(encodedSessionKey)/inject") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
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

    private func completeDesktopCommand(
        commandId: String,
        userId: String,
        machineId: String,
        status: String,
        result: [String: Any],
        error: String?
    ) {
        var payload: [String: Any] = [
            "p_command_id": commandId,
            "p_user_id": userId,
            "p_machine_id": machineId,
            "p_status": status,
            "p_result": result
        ]
        if let error {
            payload["p_error"] = error
        }
        rpcDataRequest(name: "meee2_complete_desktop_command", payload: payload) { completeResult in
            if case .failure(let err) = completeResult {
                MLog("[Meee2OnlinePusher] desktop command complete failed: \(err)")
            }
        }
    }

    private func rpcDataRequest(
        name: String,
        payload: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let baseUrl = normalizedSupabaseUrl
        guard !baseUrl.isEmpty,
              !supabaseKey.isEmpty,
              let url = URL(string: "\(baseUrl)/rest/v1/rpc/\(name)") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }

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
                "meee2_upsert_session",
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
                    "meee2_append_recent_message_v2",
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
                "meee2_append_recent_message",
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
