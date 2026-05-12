import Foundation
import Meee2CommKit
import Meee2PluginKit

struct MemberDigest: Codable, Equatable {
    var sessionId: String
    var summary: String
    var currentTask: String
    var status: String
    var blockers: [String]
    var lastDecision: String
    var lastTranscriptCursor: String
    var lastActivity: Date?
}

struct CoordinationEvent: Codable, Equatable {
    var id: String
    var groupId: String
    var kind: String
    var reason: String
    var sessionIds: [String]
    var contextPreview: String
    var createdAt: Date
}

struct CoordinationGroup: Codable, Equatable {
    var id: String
    var canvasId: String
    var coordinatorSessionId: String?
    var pendingSpawnIntentId: String?
    var memberSessionIds: [String]
    var mode: String
    var goal: String
    var paused: Bool
    var memberDigests: [String: MemberDigest]
    var events: [CoordinationEvent]
    var lastWakeAt: Date?
    var lastRoutedAction: String?
    var createdAt: Date
    var updatedAt: Date
}

enum CoordinationStoreError: LocalizedError {
    case notFound(String)
    case coordinatorNotReady(String)
    case noRecipients
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "coordination group not found: \(id)"
        case .coordinatorNotReady(let id): return "coordinator session is not ready for group: \(id)"
        case .noRecipients: return "no recipient sessions"
        case .invalidInput(let message): return message
        }
    }
}

final class CoordinationStore {
    static let shared = CoordinationStore()

    static let memberDigestLimit = 1_200
    static let transcriptDeltaLimit = 600
    static let compactContextLimit = 8_000

    private struct DiskState: Codable {
        var groups: [CoordinationGroup]
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.meee2.coordination-store", qos: .utility)
    private var loaded = false
    private var groups: [CoordinationGroup] = []

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".meee2", isDirectory: true)
                .appendingPathComponent("coordination-groups.json", isDirectory: false)
        }
    }

    func snapshot() -> [CoordinationGroup] {
        queue.sync {
            loadLocked()
            return groups
        }
    }

    func groupsForCanvas(_ canvasId: String) -> [CoordinationGroup] {
        snapshot().filter { $0.canvasId == canvasId }
    }

    @discardableResult
    func createGroup(
        canvasId: String,
        coordinatorSessionId: String?,
        pendingSpawnIntentId: String?,
        memberSessionIds: [String],
        goal: String
    ) throws -> CoordinationGroup {
        let ids = uniqueNonEmpty(memberSessionIds)
        guard !ids.isEmpty else { throw CoordinationStoreError.invalidInput("memberSessionIds is empty") }
        return try queue.sync {
            loadLocked()
            let now = Date()
            let group = CoordinationGroup(
                id: "coord-\(UUID().uuidString.lowercased())",
                canvasId: canvasId,
                coordinatorSessionId: coordinatorSessionId,
                pendingSpawnIntentId: pendingSpawnIntentId,
                memberSessionIds: ids,
                mode: "hybrid",
                goal: String(goal.prefix(Self.memberDigestLimit)),
                paused: false,
                memberDigests: Dictionary(uniqueKeysWithValues: ids.map {
                    ($0, emptyDigest(sessionId: $0, now: now))
                }),
                events: [],
                lastWakeAt: nil,
                lastRoutedAction: nil,
                createdAt: now,
                updatedAt: now
            )
            groups.append(group)
            try saveLocked()
            return group
        }
    }

    func bindCoordinator(spawnIntentId: String, sessionId: String) {
        guard !spawnIntentId.isEmpty, !sessionId.isEmpty else { return }
        queue.sync {
            loadLocked()
            var changed = false
            for index in groups.indices where groups[index].pendingSpawnIntentId == spawnIntentId {
                groups[index].coordinatorSessionId = sessionId
                groups[index].pendingSpawnIntentId = nil
                groups[index].updatedAt = Date()
                changed = true
            }
            if changed { try? saveLocked() }
        }
    }

    @discardableResult
    func refreshMemberDigest(groupId: String, sessionId: String) throws -> (changed: Bool, wakeReason: String?) {
        let update = digestUpdate(for: sessionId)
        return try queue.sync {
            loadLocked()
            guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
                throw CoordinationStoreError.notFound(groupId)
            }
            guard groups[groupIndex].memberSessionIds.contains(sessionId) else {
                return (false, nil)
            }
            let previous = groups[groupIndex].memberDigests[sessionId]
            var merged = update
            merged.lastDecision = previous?.lastDecision ?? ""
            if previous?.lastTranscriptCursor == merged.lastTranscriptCursor,
               previous?.status == merged.status,
               previous?.currentTask == merged.currentTask,
               previous?.blockers == merged.blockers {
                return (false, nil)
            }
            groups[groupIndex].memberDigests[sessionId] = merged
            groups[groupIndex].updatedAt = Date()
            try saveLocked()
            return (true, wakeReason(previous: previous, current: merged))
        }
    }

    @discardableResult
    func updateDigest(
        groupId: String,
        sessionId: String,
        summary: String?,
        blockers: [String]?,
        lastDecision: String?,
        currentTask: String?
    ) throws -> CoordinationGroup {
        try queue.sync {
            loadLocked()
            guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
                throw CoordinationStoreError.notFound(groupId)
            }
            guard groups[groupIndex].memberSessionIds.contains(sessionId) else {
                throw CoordinationStoreError.invalidInput("session is not a member of this group: \(sessionId)")
            }
            var digest = groups[groupIndex].memberDigests[sessionId] ?? emptyDigest(sessionId: sessionId, now: Date())
            if let summary { digest.summary = Self.truncate(summary, to: Self.memberDigestLimit) }
            if let blockers { digest.blockers = blockers.map { Self.truncate($0, to: 240) } }
            if let lastDecision { digest.lastDecision = Self.truncate(lastDecision, to: 400) }
            if let currentTask { digest.currentTask = Self.truncate(currentTask, to: 400) }
            digest.lastActivity = Date()
            groups[groupIndex].memberDigests[sessionId] = digest
            groups[groupIndex].updatedAt = Date()
            try saveLocked()
            return groups[groupIndex]
        }
    }

    @discardableResult
    func appendEvent(
        groupId: String,
        kind: String,
        reason: String,
        sessionIds: [String],
        contextPreview: String
    ) throws -> CoordinationEvent {
        try queue.sync {
            loadLocked()
            guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else {
                throw CoordinationStoreError.notFound(groupId)
            }
            let event = CoordinationEvent(
                id: "evt-\(UUID().uuidString.lowercased())",
                groupId: groupId,
                kind: kind,
                reason: Self.truncate(reason, to: 300),
                sessionIds: uniqueNonEmpty(sessionIds),
                contextPreview: Self.truncate(contextPreview, to: 1_200),
                createdAt: Date()
            )
            groups[groupIndex].events.append(event)
            if groups[groupIndex].events.count > 100 {
                groups[groupIndex].events = Array(groups[groupIndex].events.suffix(100))
            }
            groups[groupIndex].updatedAt = Date()
            try saveLocked()
            return event
        }
    }

    @discardableResult
    func setPaused(groupId: String, paused: Bool) throws -> CoordinationGroup {
        try queue.sync {
            loadLocked()
            guard let index = groups.firstIndex(where: { $0.id == groupId }) else {
                throw CoordinationStoreError.notFound(groupId)
            }
            groups[index].paused = paused
            groups[index].updatedAt = Date()
            try saveLocked()
            return groups[index]
        }
    }

    @discardableResult
    func removeMember(groupId: String, sessionId: String) throws -> CoordinationGroup {
        try queue.sync {
            loadLocked()
            guard let index = groups.firstIndex(where: { $0.id == groupId }) else {
                throw CoordinationStoreError.notFound(groupId)
            }
            groups[index].memberSessionIds.removeAll { $0 == sessionId }
            groups[index].memberDigests[sessionId] = nil
            groups[index].updatedAt = Date()
            try saveLocked()
            return groups[index]
        }
    }

    @discardableResult
    func markWoken(groupId: String, lastRoutedAction: String?) throws -> CoordinationGroup {
        try queue.sync {
            loadLocked()
            guard let index = groups.firstIndex(where: { $0.id == groupId }) else {
                throw CoordinationStoreError.notFound(groupId)
            }
            groups[index].lastWakeAt = Date()
            if let lastRoutedAction {
                groups[index].lastRoutedAction = Self.truncate(lastRoutedAction, to: 500)
            }
            groups[index].updatedAt = Date()
            try saveLocked()
            return groups[index]
        }
    }

    func compactContext(groupId: String, reason: String, changedSessionIds: [String]) throws -> String {
        let group = try group(id: groupId)
        let changed = Set(changedSessionIds)
        var lines: [String] = [
            "Coordination update",
            "Group: \(group.id)",
            "Goal: \(group.goal)",
            "Wake reason: \(reason)",
            "",
            "Members digest:"
        ]
        for sid in group.memberSessionIds {
            guard let digest = group.memberDigests[sid] else { continue }
            let marker = changed.contains(sid) ? "changed" : "known"
            lines.append("- [\(marker)] \(sid)")
            lines.append("  status: \(digest.status)")
            if !digest.currentTask.isEmpty { lines.append("  task: \(digest.currentTask)") }
            if !digest.summary.isEmpty { lines.append("  summary: \(digest.summary)") }
            if !digest.blockers.isEmpty { lines.append("  blockers: \(digest.blockers.joined(separator: "; "))") }
            if !digest.lastDecision.isEmpty { lines.append("  lastDecision: \(digest.lastDecision)") }
        }
        lines.append("")
        lines.append("Requested action: summarize risks and next steps. Channel/inbox routing is disabled.")
        return Self.truncate(lines.joined(separator: "\n"), to: Self.compactContextLimit)
    }

    func sendToSession(sessionId: String, content: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoordinationStoreError.invalidInput("content is empty") }
        throw CoordinationStoreError.invalidInput(
            "channel/inbox session routing is disabled; use Workroom/Handoff once available"
        )
    }

    func broadcast(groupId: String, content: String?, contentBySessionId: [String: String]) throws -> Int {
        let group = try group(id: groupId)
        var delivered = 0
        for sid in group.memberSessionIds {
            let message = contentBySessionId[sid] ?? content ?? ""
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try sendToSession(sessionId: sid, content: message)
            delivered += 1
        }
        if delivered == 0 { throw CoordinationStoreError.noRecipients }
        return delivered
    }

    func manualAsk(groupId: String, reason: String) throws {
        let group = try group(id: groupId)
        guard let coordinator = group.coordinatorSessionId, !coordinator.isEmpty else {
            throw CoordinationStoreError.coordinatorNotReady(groupId)
        }
        let context = try compactContext(
            groupId: groupId,
            reason: reason.isEmpty ? "manual Ask coordinator" : reason,
            changedSessionIds: group.memberSessionIds
        )
        try sendToSession(sessionId: coordinator, content: context)
        _ = try appendEvent(
            groupId: groupId,
            kind: "wake",
            reason: reason.isEmpty ? "manual Ask coordinator" : reason,
            sessionIds: group.memberSessionIds,
            contextPreview: context
        )
        _ = try markWoken(groupId: groupId, lastRoutedAction: "Manual ask coordinator")
    }

    func group(id: String) throws -> CoordinationGroup {
        try queue.sync {
            loadLocked()
            if let group = groups.first(where: { $0.id == id }) {
                return group
            }
            throw CoordinationStoreError.notFound(id)
        }
    }

    private func digestUpdate(for sessionId: String) -> MemberDigest {
        let now = Date()
        let pluginSession = pluginSession(for: sessionId)
        let realSid = resolveStoreSessionId(sessionId)
        let stored = SessionStore.shared.get(realSid)
        let transcriptPath = pluginSession?.transcriptPath ?? stored?.transcriptPath
        let messages = TranscriptParser.loadMessages(transcriptPath: transcriptPath, count: 8)
        let delta = messages
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n")
        let status = pluginSession?.status.rawValue ?? stored?.status.rawValue ?? "unknown"
        let task = pluginSession?.subtitle ?? pluginSession?.toolName ?? stored?.currentTask ?? stored?.currentTool ?? ""
        let blockerText = [
            pluginSession?.errorMessage,
            stored?.pendingPermissionMessage,
            status == "permissionRequired" ? stored?.pendingPermissionTool ?? "permission required" : nil
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cursor = transcriptCursor(path: transcriptPath)
        return MemberDigest(
            sessionId: sessionId,
            summary: Self.truncate(delta, to: Self.memberDigestLimit),
            currentTask: Self.truncate(task, to: 400),
            status: status,
            blockers: blockerText.map { Self.truncate($0, to: 240) },
            lastDecision: "",
            lastTranscriptCursor: cursor,
            lastActivity: pluginSession?.lastUpdated ?? stored?.lastActivity ?? now
        )
    }

    private func wakeReason(previous: MemberDigest?, current: MemberDigest) -> String? {
        if current.status == "permissionRequired" { return "permissionRequired: \(current.sessionId)" }
        if !current.blockers.isEmpty { return "blocked: \(current.sessionId)" }
        let text = "\(current.currentTask)\n\(current.summary)".lowercased()
        let keywords = ["blocked", "permission", "handoff", "conflict", "failed", "error", "卡住", "失败", "权限", "冲突", "交接"]
        if keywords.contains(where: { text.contains($0) }) {
            return "semantic change: \(current.sessionId)"
        }
        if previous == nil { return nil }
        return nil
    }

    private func pluginSession(for sessionId: String) -> PluginSession? {
        PluginManager.shared.sessions.first { $0.id == sessionId }
    }

    private func resolveStoreSessionId(_ sessionId: String) -> String {
        if SessionStore.shared.get(sessionId) != nil { return sessionId }
        if let pluginSession = pluginSession(for: sessionId) {
            let prefix = "\(pluginSession.pluginId)-"
            if pluginSession.id.hasPrefix(prefix) {
                let raw = String(pluginSession.id.dropFirst(prefix.count))
                if SessionStore.shared.get(raw) != nil { return raw }
                return raw
            }
        }
        return sessionId
    }

    private func resolveInboxSessionId(_ sessionId: String) -> String {
        resolveStoreSessionId(sessionId)
    }

    private func transcriptCursor(path: String?) -> String {
        guard let path else { return "" }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(String(format: "%.3f", modified))"
    }

    private func emptyDigest(sessionId: String, now: Date) -> MemberDigest {
        MemberDigest(
            sessionId: sessionId,
            summary: "",
            currentTask: "",
            status: "unknown",
            blockers: [],
            lastDecision: "",
            lastTranscriptCursor: "",
            lastActivity: now
        )
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            groups = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(DiskState.self, from: data) {
            groups = decoded.groups
        } else {
            groups = []
        }
    }

    private func saveLocked() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(DiskState(groups: groups))
        try data.write(to: fileURL, options: .atomic)
        SessionEventBus.shared.publish(.boardLayoutChanged)
    }

    private func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }
}
