import Foundation
import Meee2CommKit

enum SessionArtifactCandidateStatus: String, Codable, Equatable {
    case candidate
    case promoted
    case discarded
}

struct SessionArtifactReference: Codable, Equatable {
    var kind: String
    var value: String
    var label: String?
}

struct SessionArtifactCandidate: Codable, Equatable, Identifiable {
    var id: String
    var sessionId: String
    var provider: String
    var cwd: String?
    var title: String
    var kind: String
    var status: SessionArtifactCandidateStatus
    var createdAt: Date
    var updatedAt: Date
    var sourceEvent: String
    var toolName: String?
    var toolUseId: String?
    var references: [SessionArtifactReference]
    var summary: String
    var promotedCanvasId: String?
    var promotedNodeId: String?
    var promotedArtifactId: String?
}

struct SessionArtifactAttachTarget: Codable, Equatable {
    var canvasId: String
    var canvasName: String
    var nodeId: String
    var nodeTitle: String
}

struct SessionArtifactsEnvelope: Encodable {
    var sessionId: String
    var candidates: [SessionArtifactCandidate]
    var artifacts: [PlannerArtifact]
    var totalCount: Int
    var attachTargets: [SessionArtifactAttachTarget]
}

struct ArtifactCandidateListEnvelope: Encodable {
    var candidates: [SessionArtifactCandidate]
}

struct ArtifactCandidateMutationEnvelope: Encodable {
    var candidate: SessionArtifactCandidate
    var artifact: PlannerArtifact?
    var attachTargets: [SessionArtifactAttachTarget]
}

enum SessionArtifactCandidateStoreError: LocalizedError {
    case missingSession
    case candidateNotFound(String)
    case attachTargetNotFound
    case artifactAttachFailed

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "missing session id"
        case .candidateNotFound(let id):
            return "artifact candidate not found: \(id)"
        case .attachTargetNotFound:
            return "attach target not found for this session"
        case .artifactAttachFailed:
            return "candidate was promoted but the attached artifact could not be resolved"
        }
    }
}

final class SessionArtifactCandidateStore {
    static let shared = SessionArtifactCandidateStore()

    private let queue = DispatchQueue(label: "com.meee2.session-artifact-candidates")
    private let fileManager: FileManager
    private let rootURL: URL
    private var cache: [String: [SessionArtifactCandidate]] = [:]
    private var loadedSessionIds = Set<String>()
    private var backfilledCodexTranscriptSessionIds = Set<String>()

    init(
        rootURL: URL = StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("artifact-candidates", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    @discardableResult
    func ingestClaudeHook(_ event: HookEvent) -> [SessionArtifactCandidate] {
        ingestHook(provider: "claude", event: event)
    }

    @discardableResult
    func ingestCodexHookPayload(_ raw: [String: Any]) -> [SessionArtifactCandidate] {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              var event = try? JSONDecoder.codexHookDecoder.decode(HookEvent.self, from: data) else {
            return []
        }
        if event.rawData == nil,
           let text = String(data: data, encoding: .utf8) {
            event.rawData = text
        }
        return ingestHook(provider: "codex", event: event)
    }

    func list(sessionId: String? = nil, includeDiscarded: Bool = false) -> [SessionArtifactCandidate] {
        queue.sync {
            if let sessionId = normalized(sessionId), !sessionId.isEmpty {
                let items = loadLocked(sessionId: sessionId)
                return filtered(items, includeDiscarded: includeDiscarded)
            }
            var all: [SessionArtifactCandidate] = []
            for sessionId in allPersistedSessionIdsLocked() {
                all.append(contentsOf: loadLocked(sessionId: sessionId))
            }
            for (sessionId, items) in cache where !loadedSessionIds.contains(sessionId) {
                all.append(contentsOf: items)
            }
            return filtered(all, includeDiscarded: includeDiscarded)
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func list(sessionIds: [String], includeDiscarded: Bool = false) -> [SessionArtifactCandidate] {
        let ids = uniqueNormalizedSessionIds(sessionIds)
        guard !ids.isEmpty else { return [] }
        return queue.sync {
            var all: [SessionArtifactCandidate] = []
            for sid in ids {
                all.append(contentsOf: loadLocked(sessionId: sid))
            }
            return uniqueCandidates(filtered(all, includeDiscarded: includeDiscarded))
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func get(candidateId: String, includeDiscarded: Bool = true) -> SessionArtifactCandidate? {
        queue.sync {
            for sessionId in allKnownSessionIdsLocked() {
                let items = loadLocked(sessionId: sessionId)
                if let match = items.first(where: { $0.id == candidateId }) {
                    if includeDiscarded || match.status != .discarded {
                        return match
                    }
                    return nil
                }
            }
            return nil
        }
    }

    func discard(candidateId: String) throws -> SessionArtifactCandidate {
        try update(candidateId: candidateId) { candidate in
            candidate.status = .discarded
            candidate.updatedAt = Date()
        }
    }

    func markPromoted(
        candidateId: String,
        canvasId: String?,
        nodeId: String?,
        artifactId: String
    ) throws -> SessionArtifactCandidate {
        try update(candidateId: candidateId) { candidate in
            candidate.status = .promoted
            candidate.promotedCanvasId = canvasId
            candidate.promotedNodeId = nodeId
            candidate.promotedArtifactId = artifactId
            candidate.updatedAt = Date()
        }
    }

    func removeSession(_ sessionId: String) {
        let sid = normalized(sessionId)
        queue.sync {
            cache.removeValue(forKey: sid)
            loadedSessionIds.remove(sid)
            try? fileManager.removeItem(at: fileURLLocked(sessionId: sid))
        }
    }

    func combinedArtifacts(sessionId: String) -> SessionArtifactsEnvelope {
        let sid = normalized(sessionId)
        let aliases = sessionAliases(for: sid)
        backfillCodexTranscripts(sessionIds: aliases)
        let snapshot = BoardLayoutStore.shared.snapshot()
        let formal = formalArtifactsAndTargets(sessionIds: aliases, snapshot: snapshot)
        let allCandidates = list(sessionIds: aliases, includeDiscarded: true)
        let candidates = allCandidates.filter { $0.status == .candidate }
        let sessionScopedArtifacts = allCandidates
            .filter { $0.status == .promoted && $0.promotedCanvasId == nil }
            .map { sessionScopedArtifact(for: $0) }
            .sorted { $0.createdAt > $1.createdAt }
        let artifacts = (sessionScopedArtifacts + formal.artifacts).sorted { $0.createdAt > $1.createdAt }
        return SessionArtifactsEnvelope(
            sessionId: sid,
            candidates: candidates,
            artifacts: artifacts,
            totalCount: candidates.count + artifacts.count,
            attachTargets: formal.targets
        )
    }

    func sessionScopedArtifact(
        for candidate: SessionArtifactCandidate,
        kind: PlannerArtifactKind? = nil,
        title: String? = nil,
        reference: String? = nil,
        status: String? = nil
    ) -> PlannerArtifact {
        let artifactId = candidate.promotedArtifactId ?? "session-artifact-\(candidate.id)"
        return PlannerArtifact(
            id: artifactId,
            canvasId: "session:\(candidate.sessionId)",
            nodeId: candidate.sessionId,
            kind: kind ?? Self.plannerArtifactKind(forCandidateKind: candidate.kind),
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? candidate.title,
            reference: reference?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? candidate.references.first?.value ?? candidate.id,
            status: status?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "promoted",
            createdAt: candidate.updatedAt,
            payload: Self.artifactPayload(for: candidate),
            producedBy: .agent,
            reviewStatus: "approved"
        )
    }

    func attachTargets(sessionId: String) -> [SessionArtifactAttachTarget] {
        formalArtifactsAndTargets(
            sessionIds: sessionAliases(for: normalized(sessionId)),
            snapshot: BoardLayoutStore.shared.snapshot()
        ).targets
    }

    private func ingestHook(provider: String, event: HookEvent) -> [SessionArtifactCandidate] {
        guard let sessionId = normalized(event.sessionId), !sessionId.isEmpty else { return [] }
        let candidates = SessionArtifactCandidateExtractor.extract(provider: provider, event: event, sessionId: sessionId)
        guard !candidates.isEmpty else { return [] }
        return insertCandidates(candidates, sessionId: sessionId)
    }

    private func insertCandidates(_ candidates: [SessionArtifactCandidate], sessionId: String) -> [SessionArtifactCandidate] {
        return queue.sync {
            var existing = loadLocked(sessionId: sessionId)
            var inserted: [SessionArtifactCandidate] = []
            for candidate in candidates {
                let key = dedupeKey(candidate)
                if let index = existing.firstIndex(where: { dedupeKey($0) == key }) {
                    var current = existing[index]
                    current.updatedAt = max(current.updatedAt, candidate.updatedAt)
                    if current.summary.isEmpty { current.summary = candidate.summary }
                    existing[index] = current
                    continue
                }
                existing.append(candidate)
                inserted.append(candidate)
            }
            if !inserted.isEmpty {
                cache[sessionId] = existing.sorted { $0.createdAt > $1.createdAt }
                saveLocked(sessionId: sessionId)
            }
            return inserted
        }
    }

    private func backfillCodexTranscripts(sessionIds: [String]) {
        for sessionId in uniqueNormalizedSessionIds(sessionIds) {
            guard shouldBackfillCodexTranscript(sessionId: sessionId),
                  let transcriptURL = codexTranscriptURL(sessionId: sessionId) else {
                continue
            }
            let cwd = SessionStore.shared.listAll().first {
                sessionIdsMatch($0.sessionId, sessionId) || sessionIdsMatch($0.providerResumeSessionId ?? "", sessionId)
            }?.cwd
            let candidates = SessionArtifactCandidateExtractor.extractCodexTranscript(
                sessionId: sessionId,
                cwd: cwd,
                transcriptURL: transcriptURL
            )
            if !candidates.isEmpty {
                _ = insertCandidates(candidates, sessionId: sessionId)
            }
        }
    }

    private func shouldBackfillCodexTranscript(sessionId: String) -> Bool {
        queue.sync {
            guard !backfilledCodexTranscriptSessionIds.contains(sessionId) else { return false }
            backfilledCodexTranscriptSessionIds.insert(sessionId)
            return true
        }
    }

    private func codexTranscriptURL(sessionId: String) -> URL? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var matches: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.contains(sessionId) else {
                continue
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            matches.append((url, modified))
        }
        return matches.sorted { $0.modified > $1.modified }.first?.url
    }

    private func update(
        candidateId: String,
        mutate: (inout SessionArtifactCandidate) -> Void
    ) throws -> SessionArtifactCandidate {
        try queue.sync {
            for sessionId in allKnownSessionIdsLocked() {
                var items = loadLocked(sessionId: sessionId)
                guard let index = items.firstIndex(where: { $0.id == candidateId }) else { continue }
                mutate(&items[index])
                cache[sessionId] = items
                saveLocked(sessionId: sessionId)
                return items[index]
            }
            throw SessionArtifactCandidateStoreError.candidateNotFound(candidateId)
        }
    }

    private func filtered(
        _ items: [SessionArtifactCandidate],
        includeDiscarded: Bool
    ) -> [SessionArtifactCandidate] {
        items.filter { includeDiscarded || $0.status == .candidate }
    }

    private static func artifactPayload(for candidate: SessionArtifactCandidate) -> BoardJSONValue {
        let refs = candidate.references.map { reference in
            BoardJSONValue.object([
                "kind": .string(reference.kind),
                "value": .string(reference.value),
                "label": reference.label.map(BoardJSONValue.string) ?? .null
            ])
        }
        return .object([
            "type": .string(PlannerArtifactPayloadType.text.rawValue),
            "text": .string(candidate.summary),
            "source": .string("artifact-candidate"),
            "candidateId": .string(candidate.id),
            "candidateKind": .string(candidate.kind),
            "references": .array(refs)
        ])
    }

    private static func plannerArtifactKind(forCandidateKind kind: String) -> PlannerArtifactKind {
        switch kind {
        case "impl-pr":
            return .implPR
        case "check-result":
            return .checkResult
        case "prd":
            return .prd
        case "kanban":
            return .kanban
        default:
            return .generic
        }
    }

    private func uniqueCandidates(_ items: [SessionArtifactCandidate]) -> [SessionArtifactCandidate] {
        var seen = Set<String>()
        var unique: [SessionArtifactCandidate] = []
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = displayDedupeKey(item)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(item)
        }
        return unique
    }

    private func displayDedupeKey(_ candidate: SessionArtifactCandidate) -> String {
        let refs = candidate.references
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
        if !refs.isEmpty {
            return "\(candidate.sessionId)::\(candidate.kind)::\(refs)"
        }
        return candidate.id
    }

    private func loadLocked(sessionId: String) -> [SessionArtifactCandidate] {
        if loadedSessionIds.contains(sessionId) {
            return cache[sessionId] ?? []
        }
        loadedSessionIds.insert(sessionId)
        let url = fileURLLocked(sessionId: sessionId)
        guard let data = try? Data(contentsOf: url) else {
            cache[sessionId] = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = (try? decoder.decode([SessionArtifactCandidate].self, from: data)) ?? []
        cache[sessionId] = items
        return items
    }

    private func saveLocked(sessionId: String) {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache[sessionId] ?? [])
            try data.write(to: fileURLLocked(sessionId: sessionId), options: [.atomic])
        } catch {
            MWarn("[ArtifactCandidate] failed to persist session=\(sessionId.prefix(8)): \(error.localizedDescription)")
        }
    }

    private func allKnownSessionIdsLocked() -> [String] {
        Array(Set(allPersistedSessionIdsLocked()).union(cache.keys)).sorted()
    }

    private func allPersistedSessionIdsLocked() -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    private func fileURLLocked(sessionId: String) -> URL {
        rootURL.appendingPathComponent(safePathComponent(sessionId)).appendingPathExtension("json")
    }

    private func dedupeKey(_ candidate: SessionArtifactCandidate) -> String {
        let refs = candidate.references.map { "\($0.kind)=\($0.value)" }.joined(separator: "|")
        return [
            candidate.sessionId,
            candidate.toolUseId ?? "",
            candidate.toolName ?? "",
            candidate.kind,
            refs.isEmpty ? candidate.title : refs
        ].joined(separator: "::")
    }

    private func formalArtifactsAndTargets(
        sessionIds: [String],
        snapshot: BoardLayoutStore.Snapshot
    ) -> (artifacts: [PlannerArtifact], targets: [SessionArtifactAttachTarget]) {
        let aliases = uniqueNormalizedSessionIds(sessionIds)
        guard !aliases.isEmpty else { return ([], []) }
        var artifacts: [PlannerArtifact] = []
        var targets: [SessionArtifactAttachTarget] = []
        for canvas in snapshot.canvases {
            guard let state = try? PlannerBoardBridge.canvasState(
                for: canvas.id,
                snapshot: snapshot,
                actorUserId: PlannerPermission.currentActorId()
            ) else { continue }
            let matchingNodes = state.nodes.filter { node in
                guard let bound = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty else {
                    return false
                }
                return aliases.contains { sessionIdsMatch(bound, $0) }
            }
            guard !matchingNodes.isEmpty else { continue }
            let matchingNodeIds = Set(matchingNodes.map(\.id))
            artifacts.append(contentsOf: state.artifacts.filter { matchingNodeIds.contains($0.nodeId) })
            for node in matchingNodes {
                targets.append(SessionArtifactAttachTarget(
                    canvasId: canvas.id,
                    canvasName: canvas.name,
                    nodeId: node.id,
                    nodeTitle: node.title
                ))
            }
        }
        let uniqueTargets = Dictionary(grouping: targets, by: { "\($0.canvasId):\($0.nodeId)" })
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in
                if lhs.canvasName != rhs.canvasName { return lhs.canvasName < rhs.canvasName }
                return lhs.nodeTitle < rhs.nodeTitle
            }
        let uniqueArtifacts = Dictionary(grouping: artifacts, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.createdAt > $1.createdAt }
        return (
            artifacts: uniqueArtifacts,
            targets: uniqueTargets
        )
    }

    private func sessionAliases(for sessionId: String) -> [String] {
        var aliases = [sessionId]

        if let session = SessionStore.shared.get(sessionId) {
            aliases.append(session.providerResumeSessionId ?? "")
            aliases.append(session.terminalInfo?.cmuxSurfaceId ?? "")
        }
        if let terminal = SessionTerminalStore.shared.get(sessionId: sessionId) {
            aliases.append(terminal.providerResumeSessionId ?? "")
            aliases.append(terminal.cmuxSurfaceId ?? "")
        }

        for session in SessionStore.shared.listAll() {
            let providerResume = normalized(session.providerResumeSessionId) ?? ""
            let terminalSurfaceId = normalized(session.terminalInfo?.cmuxSurfaceId) ?? ""
            if sessionIdsMatch(session.sessionId, sessionId)
                || sessionIdsMatch(providerResume, sessionId)
                || sessionIdsMatch(terminalSurfaceId, sessionId) {
                aliases.append(session.sessionId)
                aliases.append(providerResume)
                aliases.append(terminalSurfaceId)
            }
        }

        for (_, terminal) in SessionTerminalStore.shared.getAll() {
            let providerResume = normalized(terminal.providerResumeSessionId) ?? ""
            let surfaceId = normalized(terminal.cmuxSurfaceId) ?? ""
            if sessionIdsMatch(terminal.sessionId, sessionId)
                || sessionIdsMatch(providerResume, sessionId)
                || sessionIdsMatch(surfaceId, sessionId) {
                aliases.append(terminal.sessionId)
                aliases.append(providerResume)
                aliases.append(surfaceId)
            }
        }

        return uniqueNormalizedSessionIds(aliases)
    }

    private func uniqueNormalizedSessionIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for raw in rawIds {
            let id = normalized(raw)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)
        }
        return ids
    }

    private func sessionIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return a.hasSuffix("-\(b)") || b.hasSuffix("-\(a)")
    }

    private func normalized(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SessionArtifactCandidateExtractor {
    static func extract(provider: String, event: HookEvent, sessionId: String) -> [SessionArtifactCandidate] {
        switch event.event {
        case .postToolUse, .postToolUseFailure:
            return extractToolUse(provider: provider, event: event, sessionId: sessionId)
        case .stop:
            return extractStop(provider: provider, event: event, sessionId: sessionId)
        default:
            return []
        }
    }

    static func extractCodexTranscript(sessionId: String, cwd: String?, transcriptURL: URL) -> [SessionArtifactCandidate] {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8), !text.isEmpty else {
            return []
        }
        var candidates: [SessionArtifactCandidate] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }
            let timestamp = timestampValue(object["timestamp"]) ?? Date()
            let envelopeType = stringValue(object["type"]) ?? ""
            let payloadType = stringValue(payload["type"]) ?? ""

            if envelopeType == "event_msg", payloadType == "mcp_tool_call_end" {
                let resultText = collectStringValues(payload["result"]).joined(separator: "\n")
                candidates.append(contentsOf: urlCandidatesFromText(
                    provider: "codex",
                    sessionId: sessionId,
                    cwd: cwd,
                    sourceEvent: "TranscriptToolResult",
                    toolName: transcriptToolName(payload["invocation"]),
                    toolUseId: stringValue(payload["call_id"]),
                    text: resultText,
                    summaryPrefix: "Codex transcript tool result referenced",
                    urlFilter: isMaterialTranscriptURL,
                    timestamp: timestamp
                ))
            } else if envelopeType == "response_item", payloadType == "function_call_output" {
                candidates.append(contentsOf: urlCandidatesFromText(
                    provider: "codex",
                    sessionId: sessionId,
                    cwd: cwd,
                    sourceEvent: "TranscriptToolOutput",
                    toolName: nil,
                    toolUseId: stringValue(payload["call_id"]),
                    text: stringValue(payload["output"]) ?? "",
                    summaryPrefix: "Codex transcript tool output referenced",
                    urlFilter: isMaterialTranscriptURL,
                    timestamp: timestamp
                ))
            } else if envelopeType == "event_msg", payloadType == "agent_message",
                      stringValue(payload["phase"]) == "final_answer" {
                let message = stringValue(payload["message"]) ?? ""
                candidates.append(contentsOf: finalMessageCandidates(
                    provider: "codex",
                    sessionId: sessionId,
                    cwd: cwd,
                    message: message,
                    sourceEvent: "TranscriptFinalAnswer",
                    includeFinalText: false,
                    timestamp: timestamp
                ))
            } else if envelopeType == "response_item", payloadType == "message",
                      stringValue(payload["phase"]) == "final_answer" {
                let message = messageText(payload["content"])
                candidates.append(contentsOf: finalMessageCandidates(
                    provider: "codex",
                    sessionId: sessionId,
                    cwd: cwd,
                    message: message,
                    sourceEvent: "TranscriptFinalAnswer",
                    includeFinalText: false,
                    timestamp: timestamp
                ))
            } else if envelopeType == "event_msg", payloadType == "task_complete" {
                let message = stringValue(payload["last_agent_message"]) ?? ""
                candidates.append(contentsOf: finalMessageCandidates(
                    provider: "codex",
                    sessionId: sessionId,
                    cwd: cwd,
                    message: message,
                    sourceEvent: "TranscriptTaskComplete",
                    includeFinalText: false,
                    timestamp: timestamp
                ))
            }
        }
        return uniqueCandidates(candidates)
    }

    private static func extractToolUse(provider: String, event: HookEvent, sessionId: String) -> [SessionArtifactCandidate] {
        let tool = (event.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return [] }
        let normalizedTool = tool.lowercased()
        let input = event.toolInputDict ?? [:]
        let output = event.toolOutputDict ?? [:]
        let timestamp = event.timestamp ?? Date()

        if normalizedTool == "bash" || normalizedTool.hasSuffix("__bash") {
            return bashCandidate(provider: provider, event: event, sessionId: sessionId, input: input, output: output, timestamp: timestamp)
                .map { [$0] } ?? []
        }

        if normalizedTool == "apply_patch" || normalizedTool == "edit" || normalizedTool == "write" || normalizedTool.contains("apply_patch") {
            return editCandidate(provider: provider, event: event, sessionId: sessionId, input: input, timestamp: timestamp)
                .map { [$0] } ?? []
        }

        if let candidate = fileToolCandidate(provider: provider, event: event, sessionId: sessionId, input: input, output: output, timestamp: timestamp) {
            return [candidate]
        }

        return urlCandidates(provider: provider, event: event, sessionId: sessionId, output: output, timestamp: timestamp)
    }

    private static func extractStop(provider: String, event: HookEvent, sessionId: String) -> [SessionArtifactCandidate] {
        guard let message = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return [] }
        let urls = extractURLs(from: message)
        let timestamp = event.timestamp ?? Date()
        var candidates = urls.prefix(5).map { url in
            candidate(
                provider: provider,
                sessionId: sessionId,
                cwd: event.cwd,
                title: titleForURL(url),
                kind: url.contains("github.com") && url.contains("/pull/") ? "impl-pr" : "url",
                sourceEvent: event.event?.rawValue ?? "Stop",
                toolName: nil,
                toolUseId: event.toolUseId,
                references: [SessionArtifactReference(kind: "url", value: url, label: nil)],
                summary: "Assistant final message referenced \(url)",
                createdAt: timestamp
            )
        }
        if let final = finalTextCandidate(provider: provider, event: event, sessionId: sessionId, message: message, timestamp: timestamp) {
            candidates.append(final)
        }
        return candidates
    }

    private static func finalMessageCandidates(
        provider: String,
        sessionId: String,
        cwd: String?,
        message: String,
        sourceEvent: String,
        includeFinalText: Bool = true,
        timestamp: Date
    ) -> [SessionArtifactCandidate] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = urlCandidatesFromText(
            provider: provider,
            sessionId: sessionId,
            cwd: cwd,
            sourceEvent: sourceEvent,
            toolName: nil,
            toolUseId: nil,
            text: trimmed,
            summaryPrefix: "Codex final answer referenced",
            urlFilter: isMaterialTranscriptURL,
            timestamp: timestamp
        )
        guard includeFinalText else { return candidates }
        if let final = finalTextCandidate(
            provider: provider,
            eventCwd: cwd,
            eventName: sourceEvent,
            toolUseId: nil,
            sessionId: sessionId,
            message: trimmed,
            timestamp: timestamp
        ) {
            candidates.append(final)
        }
        return candidates
    }

    private static func finalTextCandidate(
        provider: String,
        event: HookEvent,
        sessionId: String,
        message: String,
        timestamp: Date
    ) -> SessionArtifactCandidate? {
        finalTextCandidate(
            provider: provider,
            eventCwd: event.cwd,
            eventName: event.event?.rawValue ?? "Stop",
            toolUseId: event.toolUseId,
            sessionId: sessionId,
            message: message,
            timestamp: timestamp
        )
    }

    private static func finalTextCandidate(
        provider: String,
        eventCwd: String?,
        eventName: String,
        toolUseId: String?,
        sessionId: String,
        message: String,
        timestamp: Date
    ) -> SessionArtifactCandidate? {
        guard finalMessageLooksMaterial(message), !finalMessageLooksInteractive(message) else {
            return nil
        }
        let ref = SessionArtifactReference(
            kind: "session-final",
            value: "session:\(sessionId):final:\(shortHash(message))",
            label: "Final message"
        )
        return candidate(
            provider: provider,
            sessionId: sessionId,
            cwd: eventCwd,
            title: finalMessageTitle(message),
            kind: "final-text",
            sourceEvent: eventName,
            toolName: nil,
            toolUseId: toolUseId,
            references: [ref],
            summary: "Final response summary: \(truncate(message, limit: 360))",
            createdAt: timestamp
        )
    }

    private static func bashCandidate(
        provider: String,
        event: HookEvent,
        sessionId: String,
        input: [String: Any],
        output: [String: Any],
        timestamp: Date
    ) -> SessionArtifactCandidate? {
        let command = stringValue(input["command"]) ?? stringValue(input["cmd"]) ?? ""
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, commandLooksMaterial(trimmed) else { return nil }
        var refs = referencesFromCommand(trimmed, cwd: event.cwd)
        let outputText = [stringValue(output["stdout"]), stringValue(output["stderr"]), stringValue(output["output"])]
            .compactMap { $0 }
            .joined(separator: "\n")
        for url in extractURLs(from: outputText) where !refs.contains(where: { $0.value == url }) {
            refs.append(SessionArtifactReference(kind: "url", value: url, label: nil))
        }
        let summary = commandSummary(trimmed, output: output)
        let title = refs.first?.label ?? refs.first?.value ?? firstCommandToken(trimmed)
        return candidate(
            provider: provider,
            sessionId: sessionId,
            cwd: event.cwd,
            title: title,
            kind: commandKind(trimmed),
            sourceEvent: event.event?.rawValue ?? "PostToolUse",
            toolName: event.toolName,
            toolUseId: event.toolUseId,
            references: refs.isEmpty ? [SessionArtifactReference(kind: "command", value: trimmed, label: "Command")] : refs,
            summary: summary,
            createdAt: timestamp
        )
    }

    private static func editCandidate(
        provider: String,
        event: HookEvent,
        sessionId: String,
        input: [String: Any],
        timestamp: Date
    ) -> SessionArtifactCandidate? {
        let command = stringValue(input["command"]) ?? stringValue(input["patch"]) ?? event.toolInput ?? ""
        let paths = extractPatchPaths(from: command)
        let refs = paths.map { SessionArtifactReference(kind: "file", value: resolvePath($0, cwd: event.cwd), label: $0) }
        guard !refs.isEmpty || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return candidate(
            provider: provider,
            sessionId: sessionId,
            cwd: event.cwd,
            title: refs.first?.label ?? "Code changes",
            kind: "file-diff",
            sourceEvent: event.event?.rawValue ?? "PostToolUse",
            toolName: event.toolName,
            toolUseId: event.toolUseId,
            references: refs,
            summary: refs.isEmpty ? "Applied a code patch." : "Changed \(refs.count) file\(refs.count == 1 ? "" : "s").",
            createdAt: timestamp
        )
    }

    private static func fileToolCandidate(
        provider: String,
        event: HookEvent,
        sessionId: String,
        input: [String: Any],
        output: [String: Any],
        timestamp: Date
    ) -> SessionArtifactCandidate? {
        let possiblePath = stringValue(input["path"])
            ?? stringValue(input["file_path"])
            ?? stringValue(input["filename"])
            ?? stringValue(output["path"])
            ?? stringValue(output["file_path"])
        guard let path = possiblePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let lowerTool = (event.toolName ?? "").lowercased()
        guard lowerTool.contains("write") || lowerTool.contains("edit") || lowerTool.contains("create") || lowerTool.contains("screenshot") else {
            return nil
        }
        let ref = SessionArtifactReference(kind: "file", value: resolvePath(path, cwd: event.cwd), label: path)
        return candidate(
            provider: provider,
            sessionId: sessionId,
            cwd: event.cwd,
            title: (path as NSString).lastPathComponent,
            kind: lowerTool.contains("screenshot") ? "screenshot" : "file",
            sourceEvent: event.event?.rawValue ?? "PostToolUse",
            toolName: event.toolName,
            toolUseId: event.toolUseId,
            references: [ref],
            summary: "Tool \(event.toolName ?? "tool") produced \(path).",
            createdAt: timestamp
        )
    }

    private static func urlCandidates(
        provider: String,
        event: HookEvent,
        sessionId: String,
        output: [String: Any],
        timestamp: Date
    ) -> [SessionArtifactCandidate] {
        let text = [event.toolOutput, stringValue(output["stdout"]), stringValue(output["stderr"]), stringValue(output["output"])]
            .compactMap { $0 }
            .joined(separator: "\n")
        return extractURLs(from: text).prefix(5).map { url in
            candidate(
                provider: provider,
                sessionId: sessionId,
                cwd: event.cwd,
                title: titleForURL(url),
                kind: url.contains("github.com") && url.contains("/pull/") ? "impl-pr" : "url",
                sourceEvent: event.event?.rawValue ?? "PostToolUse",
                toolName: event.toolName,
                toolUseId: event.toolUseId,
                references: [SessionArtifactReference(kind: "url", value: url, label: nil)],
                summary: "Tool output referenced \(url).",
                createdAt: timestamp
            )
        }
    }

    private static func candidate(
        provider: String,
        sessionId: String,
        cwd: String?,
        title: String,
        kind: String,
        sourceEvent: String,
        toolName: String?,
        toolUseId: String?,
        references: [SessionArtifactReference],
        summary: String,
        createdAt: Date
    ) -> SessionArtifactCandidate {
        let referenceKey = references.map(\.value).joined(separator: "|").nilIfEmpty ?? title
        let stable = "\(sessionId)-\(toolUseId ?? referenceKey)-\(kind)-\(referenceKey)"
        return SessionArtifactCandidate(
            id: "candidate-\(shortHash(stable))",
            sessionId: sessionId,
            provider: provider,
            cwd: cwd,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? kind,
            kind: kind,
            status: .candidate,
            createdAt: createdAt,
            updatedAt: createdAt,
            sourceEvent: sourceEvent,
            toolName: toolName,
            toolUseId: toolUseId,
            references: references,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Captured artifact candidate.",
            promotedCanvasId: nil,
            promotedNodeId: nil,
            promotedArtifactId: nil
        )
    }

    private static func commandLooksMaterial(_ command: String) -> Bool {
        let lower = command.lowercased()
        let readOnlyPrefixes = ["ls", "rg", "grep", "cat", "sed -n", "pwd", "git status", "git diff", "git show", "find "]
        if readOnlyPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
            return false
        }
        let materialTokens = [
            "swift test", "swift build", "npm test", "pnpm test", "yarn test", "pytest", "xcodebuild",
            "git commit", "git push", "gh pr", "curl -o", "wget", "tee ", "> ", ">> ",
            "touch ", "mkdir ", "cp ", "mv ", "convert ", "screencapture", "playwright"
        ]
        return materialTokens.contains(where: { lower.contains($0) })
    }

    private static func commandKind(_ command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("test") || lower.contains("build") || lower.contains("xcodebuild") {
            return "check-result"
        }
        if lower.contains("gh pr") || lower.contains("git push") {
            return "impl-pr"
        }
        if lower.contains("screencapture") || lower.contains("playwright") {
            return "screenshot"
        }
        return "command-result"
    }

    private static func finalMessageLooksMaterial(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 24 else { return false }
        let lower = normalized.lowercased()
        let lowSignal = [
            "done",
            "ok",
            "sounds good",
            "thanks",
            "you're welcome",
            "好的",
            "可以",
            "谢谢"
        ]
        if lowSignal.contains(where: { lower == $0 }) {
            return false
        }
        return true
    }

    private static func finalMessageLooksInteractive(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        if normalized.hasSuffix("?") || normalized.hasSuffix("？") {
            return true
        }
        let interactiveMarkers = [
            "please choose",
            "choose one",
            "which option",
            "which one",
            "let me know",
            "tell me which",
            "do you want",
            "would you like",
            "should i",
            "请选择",
            "选哪个",
            "哪一个",
            "你希望",
            "要不要",
            "是否要",
            "是否需要",
            "请确认",
            "需要你确认",
            "你想让我"
        ]
        return interactiveMarkers.contains(where: { lower.contains($0) })
    }

    private static func finalMessageTitle(_ message: String) -> String {
        let firstLine = message.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " #*-`").union(.whitespacesAndNewlines))
            ?? ""
        if !firstLine.isEmpty {
            return truncate(firstLine, limit: 72)
        }
        return "Final response"
    }

    private static func referencesFromCommand(_ command: String, cwd: String?) -> [SessionArtifactReference] {
        var refs: [SessionArtifactReference] = []
        for url in extractURLs(from: command) {
            refs.append(SessionArtifactReference(kind: "url", value: url, label: nil))
        }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var nextIsOutput = false
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,"))
            if nextIsOutput {
                refs.append(SessionArtifactReference(kind: "file", value: resolvePath(cleaned, cwd: cwd), label: cleaned))
                nextIsOutput = false
                continue
            }
            if cleaned == ">" || cleaned == ">>" || cleaned == "-o" || cleaned == "--output" {
                nextIsOutput = true
            }
        }
        return refs
    }

    private static func commandSummary(_ command: String, output: [String: Any]) -> String {
        var parts = ["Command: \(truncate(command, limit: 180))"]
        if let exitCode = intValue(output["exit_code"]) ?? intValue(output["exitCode"]) {
            parts.append("exit \(exitCode)")
        }
        if let stdout = stringValue(output["stdout"])?.trimmingCharacters(in: .whitespacesAndNewlines), !stdout.isEmpty {
            parts.append(truncate(stdout, limit: 220))
        } else if let outputText = stringValue(output["output"])?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
            parts.append(truncate(outputText, limit: 220))
        }
        return parts.joined(separator: " · ")
    }

    private static func extractPatchPaths(from text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let prefixes = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "]
            for prefix in prefixes where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, !result.contains(path) {
                    result.append(path)
                }
            }
        }
        return result
    }

    private static func urlCandidatesFromText(
        provider: String,
        sessionId: String,
        cwd: String?,
        sourceEvent: String,
        toolName: String?,
        toolUseId: String?,
        text: String,
        summaryPrefix: String,
        urlFilter: ((String) -> Bool)? = nil,
        timestamp: Date
    ) -> [SessionArtifactCandidate] {
        extractURLs(from: text)
            .filter { urlFilter?($0) ?? true }
            .prefix(5)
            .map { url in
            candidate(
                provider: provider,
                sessionId: sessionId,
                cwd: cwd,
                title: titleForURL(url),
                kind: url.contains("github.com") && url.contains("/pull/") ? "impl-pr" : "url",
                sourceEvent: sourceEvent,
                toolName: toolName,
                toolUseId: toolUseId,
                references: [SessionArtifactReference(kind: "url", value: url, label: nil)],
                summary: "\(summaryPrefix) \(url).",
                createdAt: timestamp
            )
        }
    }

    private static func isMaterialTranscriptURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".id") || host.hasSuffix(".is") {
            return false
        }
        if host.contains("larksuite.com") || host.contains("feishu.cn") || host == "docs.google.com" {
            return true
        }
        if host == "github.com" {
            return parsed.path.contains("/pull/")
        }
        let path = parsed.path.lowercased()
        return [".pdf", ".docx", ".xlsx", ".pptx", ".md", ".html"].contains { path.hasSuffix($0) }
    }

    private static func uniqueCandidates(_ candidates: [SessionArtifactCandidate]) -> [SessionArtifactCandidate] {
        var seen = Set<String>()
        var unique: [SessionArtifactCandidate] = []
        for candidate in candidates {
            guard !seen.contains(candidate.id) else { continue }
            seen.insert(candidate.id)
            unique.append(candidate)
        }
        return unique
    }

    private static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let ns = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var urls: [String] = []
        for match in matches {
            guard let raw = match.url?.absoluteString else { continue }
            let url = sanitizeURL(raw)
            guard !url.isEmpty, !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func sanitizeURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`),.; \n\t"))
        while value.hasSuffix("%5C") || value.hasSuffix("%5c") {
            value.removeLast(3)
        }
        while value.hasSuffix("\\") {
            value.removeLast()
        }
        return value
    }

    private static func resolvePath(_ path: String, cwd: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return expanded
        }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL.path
    }

    private static func titleForURL(_ url: String) -> String {
        if url.contains("github.com"), let last = URL(string: url)?.lastPathComponent, !last.isEmpty {
            return "GitHub \(last)"
        }
        return URL(string: url)?.host ?? url
    }

    private static func firstCommandToken(_ command: String) -> String {
        command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "Command result"
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let value = raw as? String { return value }
        if let value = raw { return String(describing: value) }
        return nil
    }

    private static func timestampValue(_ raw: Any?) -> Date? {
        guard let value = stringValue(raw) else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }

    private static func transcriptToolName(_ raw: Any?) -> String? {
        guard let invocation = raw as? [String: Any] else { return nil }
        let server = stringValue(invocation["server"])?.nilIfEmpty
        let tool = stringValue(invocation["tool"])?.nilIfEmpty
        return [server, tool].compactMap { $0 }.joined(separator: ".").nilIfEmpty
    }

    private static func collectStringValues(_ raw: Any?) -> [String] {
        if let value = raw as? String { return [value] }
        if let array = raw as? [Any] {
            return array.flatMap { collectStringValues($0) }
        }
        if let object = raw as? [String: Any] {
            return object.values.flatMap { collectStringValues($0) }
        }
        return []
    }

    private static func messageText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let array = raw as? [Any] {
            return array.map(messageText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if let object = raw as? [String: Any] {
            return stringValue(object["text"]) ?? stringValue(object["message"]) ?? ""
        }
        return ""
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "..."
    }

    private static func shortHash(_ text: String) -> String {
        var hasher = Hasher()
        hasher.combine(text)
        return String(abs(hasher.finalize()), radix: 36)
    }
}

private extension JSONDecoder {
    static var codexHookDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func safePathComponent(_ raw: String) -> String {
    let mapped = raw.map { char in char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" ? char : "-" }
    let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_/ "))
    return value.isEmpty ? "item" : value
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
