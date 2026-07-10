import Foundation
import Swifter

struct ArtifactPageSource {
    let canvas: CanvasInfoDTO
    let nodes: [PlanningNode]
    let artifacts: [PlannerArtifact]
    let sessionIdOverride: String?

    init(
        canvas: CanvasInfoDTO,
        nodes: [PlanningNode] = [],
        artifacts: [PlannerArtifact],
        sessionIdOverride: String? = nil
    ) {
        self.canvas = canvas
        self.nodes = nodes
        self.artifacts = artifacts
        self.sessionIdOverride = sessionIdOverride
    }
}

struct ArtifactPageQuery {
    let cursor: String?
    let limit: Int
    let status: String
    let canvasId: String?
    let query: String?
    let sessionIds: Set<String>
    let project: String?
    let scope: String?
    let group: String?

    init(
        cursor: String? = nil,
        limit: Int = 50,
        status: String = "ready",
        canvasId: String? = nil,
        query: String? = nil,
        sessionIds: Set<String> = [],
        project: String? = nil,
        scope: String? = nil,
        group: String? = nil
    ) {
        self.cursor = Self.nonEmpty(cursor)
        self.limit = min(100, max(1, limit))
        self.status = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.canvasId = Self.nonEmpty(canvasId)
        self.query = Self.nonEmpty(query)
        self.sessionIds = Set(sessionIds.map(Self.normalizedToken).filter { !$0.isEmpty })
        self.project = Self.nonEmpty(project)
        self.scope = Self.nonEmpty(scope)?.lowercased()
        self.group = Self.nonEmpty(group)?.lowercased()
    }

    init(request: HttpRequest) {
        func value(_ key: String) -> String? {
            let raw = request.queryParams.first(where: { $0.0 == key })?.1
            return raw?
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? raw
        }

        let rawSessionIds = value("sessionId")?
            .split(separator: ",")
            .map(String.init) ?? []
        self.init(
            cursor: value("cursor"),
            limit: Int(value("limit") ?? "") ?? 50,
            status: value("status") ?? "ready",
            canvasId: value("canvasId"),
            query: value("query"),
            sessionIds: Set(rawSessionIds),
            project: value("project"),
            scope: value("scope"),
            group: value("group")
        )
    }

    private static func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum ArtifactPageBuilderError: LocalizedError {
    case invalidCursor

    var errorDescription: String? {
        switch self {
        case .invalidCursor:
            return "artifact cursor is invalid"
        }
    }
}

enum ArtifactPageBuilder {
    private struct Record {
        let key: String
        let item: ArtifactPageItemDTO
        let createdAt: Date
        let displayStatus: String
        let group: String
        let haystack: String
    }

    static func build(
        sources: [ArtifactPageSource],
        candidates: [SessionArtifactCandidate],
        query: ArtifactPageQuery
    ) throws -> ArtifactPageEnvelope {
        let records = deduplicatedRecords(sources: sources, candidates: candidates)
        let baseFiltered = records.filter { record in
            matchesBaseFilters(record, query: query)
        }
        let candidateTotal = baseFiltered.filter { record in
            guard record.item.sourceKind == "candidate" else { return false }
            guard let group = query.group, group != "all" else { return true }
            return record.group == group
        }.count
        let statusFiltered = baseFiltered.filter { record in
            if query.status == "candidate" {
                return record.item.sourceKind == "candidate"
            }
            guard record.item.sourceKind == "artifact" else { return false }
            if query.status.isEmpty || query.status == "all" { return true }
            if query.status == "promoted" {
                return record.item.artifacts.first?.status.lowercased() == "promoted"
            }
            return record.displayStatus == query.status
                || record.item.artifacts.first?.status.lowercased() == query.status
        }
        var groupCounts = emptyGroupCounts()
        for record in statusFiltered {
            groupCounts[record.group, default: 0] += 1
        }
        let filtered = statusFiltered.filter { record in
            guard let group = query.group, group != "all" else { return true }
            return record.group == group
        }
        let offset = try decodedOffset(query.cursor)
        guard offset <= filtered.count else { throw ArtifactPageBuilderError.invalidCursor }
        let end = min(filtered.count, offset + query.limit)
        let page = Array(filtered[offset..<end])
        let hasMore = end < filtered.count
        return ArtifactPageEnvelope(
            items: page.map(\.item),
            cursor: hasMore ? encodedOffset(end) : nil,
            total: filtered.count,
            hasMore: hasMore,
            candidateTotal: candidateTotal,
            canvasCount: Set(filtered.map { $0.item.canvas.id }).count,
            groupCounts: groupCounts
        )
    }

    private static func deduplicatedRecords(
        sources: [ArtifactPageSource],
        candidates: [SessionArtifactCandidate]
    ) -> [Record] {
        var artifactsBySlot: [String: (ArtifactPageSource, PlanningNode?, [PlannerArtifact])] = [:]
        for source in sources {
            let nodesById = Dictionary(uniqueKeysWithValues: source.nodes.map { ($0.id, $0) })
            for artifact in source.artifacts {
                let key = artifactSlotKey(artifact)
                if var current = artifactsBySlot[key] {
                    current.2.append(artifact)
                    artifactsBySlot[key] = current
                } else {
                    artifactsBySlot[key] = (source, nodesById[artifact.nodeId], [artifact])
                }
            }
        }

        var records = artifactsBySlot.map { key, value -> Record in
            let sortedArtifacts = value.2.sorted { $0.createdAt > $1.createdAt }
            let latest = sortedArtifacts[0]
            let sessionId = value.0.sessionIdOverride ?? value.1?.sessionId
            let item = ArtifactPageItemDTO(
                sourceKind: "artifact",
                canvas: value.0.canvas,
                node: value.1,
                sessionId: sessionId,
                artifacts: sortedArtifacts,
                candidate: nil
            )
            return Record(
                key: key,
                item: item,
                createdAt: latest.createdAt,
                displayStatus: artifactDisplayStatus(latest),
                group: artifactGroup(kind: latest.kind.rawValue),
                haystack: artifactHaystack(latest, item: item)
            )
        }

        var candidatesByTurnTool: [String: SessionArtifactCandidate] = [:]
        for candidate in candidates where candidate.status == .candidate {
            let key = candidateDedupeKey(candidate)
            guard let current = candidatesByTurnTool[key] else {
                candidatesByTurnTool[key] = candidate
                continue
            }
            if candidate.updatedAt > current.updatedAt {
                candidatesByTurnTool[key] = candidate
            }
        }
        records.append(contentsOf: candidatesByTurnTool.map { key, candidate in
            let canvas = candidateCanvas(candidate)
            let item = ArtifactPageItemDTO(
                sourceKind: "candidate",
                canvas: canvas,
                node: nil,
                sessionId: candidate.sessionId,
                artifacts: [],
                candidate: candidate
            )
            return Record(
                key: "candidate:\(key)",
                item: item,
                createdAt: candidate.updatedAt,
                displayStatus: "candidate",
                group: artifactGroup(kind: candidate.kind),
                haystack: candidateHaystack(candidate, canvas: canvas)
            )
        })
        return records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.key < $1.key
        }
    }

    private static func matchesBaseFilters(_ record: Record, query: ArtifactPageQuery) -> Bool {
        if let canvasId = query.canvasId, canvasId != "all", record.item.canvas.id != canvasId {
            return false
        }
        if let scope = query.scope, scope != "all", record.item.canvas.scope != scope {
            return false
        }
        if !query.sessionIds.isEmpty || query.project != nil {
            let sessionId = record.item.sessionId?.lowercased() ?? ""
            let matchesSession = query.sessionIds.contains(sessionId)
            let matchesProject = projectTokens(record.item.canvas.workspacePath, record.item.canvas.name, record.item.canvas.id)
                .contains { projectTokens(query.project).contains($0) }
            if !matchesSession && !matchesProject { return false }
        }
        if let text = query.query?.lowercased(), !record.haystack.contains(text) {
            return false
        }
        return true
    }

    private static func artifactSlotKey(_ artifact: PlannerArtifact) -> String {
        let reference = artifact.reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(artifact.canvasId):\(artifact.nodeId):\(reference)"
    }

    private static func candidateDedupeKey(_ candidate: SessionArtifactCandidate) -> String {
        let tool = nonEmpty(candidate.toolName)
            ?? candidate.kind
        if let toolUseId = nonEmpty(candidate.toolUseId) {
            return [candidate.sessionId, toolUseId, tool]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .joined(separator: ":")
        }
        let fallbackReference = candidate.references.first?.value ?? candidate.title
        return [candidate.sessionId, candidate.sourceEvent, tool, fallbackReference]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: ":")
    }

    private static func artifactDisplayStatus(_ artifact: PlannerArtifact) -> String {
        switch artifact.reviewStatus?.lowercased() {
        case "pending": return "needs-review"
        case "rejected": return "rejected"
        default: break
        }
        switch artifact.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "failed", "error": return "failed"
        case "stale", "superseded": return "stale"
        case "running", "working", "pending": return "working"
        case "", "attached", "created", "updated", "done", "promoted": return "ready"
        default: return "other"
        }
    }

    private static func artifactGroup(kind: String) -> String {
        switch kind.lowercased() {
        case "prd", "lark-doc": return "docs"
        case "kanban", "idea-draft": return "boards"
        case "impl-pr", "main-merge": return "implementation"
        case "check-result", "prerelease-verdict": return "validation"
        case "generic", "file", "directory", "diff": return "files-data"
        default: return "other"
        }
    }

    private static func artifactHaystack(_ artifact: PlannerArtifact, item: ArtifactPageItemDTO) -> String {
        [
            artifact.id,
            artifact.title,
            artifact.reference,
            artifact.kind.rawValue,
            artifact.status,
            artifact.reviewStatus,
            item.canvas.id,
            item.canvas.name,
            item.canvas.workspacePath,
            item.node?.id,
            item.node?.title,
            item.sessionId
        ].compactMap { $0 }.joined(separator: " ").lowercased()
    }

    private static func candidateHaystack(
        _ candidate: SessionArtifactCandidate,
        canvas: CanvasInfoDTO
    ) -> String {
        var values = [
            candidate.id,
            candidate.sessionId,
            candidate.provider,
            candidate.cwd,
            candidate.title,
            candidate.kind,
            candidate.sourceEvent,
            candidate.toolName,
            candidate.summary,
            canvas.id,
            canvas.name
        ].compactMap { $0 }
        values.append(contentsOf: candidate.references.flatMap { [$0.kind, $0.label, $0.value].compactMap { $0 } })
        return values.joined(separator: " ").lowercased()
    }

    private static func candidateCanvas(_ candidate: SessionArtifactCandidate) -> CanvasInfoDTO {
        CanvasInfoDTO(
            id: "session:\(candidate.sessionId)",
            name: "Session",
            scope: "personal",
            visibility: "private",
            kind: "monitor",
            isDefault: false,
            workspacePath: candidate.cwd ?? "",
            parentCanvasId: nil,
            parentNodeId: nil,
            teamId: nil,
            ownerUserId: nil,
            remoteId: nil,
            remoteVersion: nil,
            syncStatus: nil,
            dirtySince: nil,
            lastSyncedAt: nil,
            lastRemoteUpdatedAt: nil,
            conflictRemoteVersion: nil,
            conflictRemoteDeleted: nil,
            draftOfTemplateId: nil
        )
    }

    private static func projectTokens(_ values: String?...) -> Set<String> {
        Set(values.compactMap { value -> [String]? in
            guard let normalized = value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression),
                  !normalized.isEmpty else { return nil }
            let base = normalized.split(separator: "/").last.map(String.init)
            return [normalized, base].compactMap { $0 }
        }.flatMap { $0 })
    }

    private static func emptyGroupCounts() -> [String: Int] {
        [
            "docs": 0,
            "boards": 0,
            "implementation": 0,
            "validation": 0,
            "files-data": 0,
            "other": 0
        ]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func encodedOffset(_ offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }

    private static func decodedOffset(_ cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor),
              let value = String(data: data, encoding: .utf8),
              value.hasPrefix("offset:"),
              let offset = Int(value.dropFirst("offset:".count)),
              offset >= 0 else {
            throw ArtifactPageBuilderError.invalidCursor
        }
        return offset
    }
}

extension BoardAPI {
    /// Global read-only Artifacts index. It reads planner records directly so
    /// listing cannot trigger graph reconciliation, session spawning, or writes.
    static func listArtifacts(_ req: HttpRequest) -> HttpResponse {
        let query = ArtifactPageQuery(request: req)
        let snapshot = BoardLayoutStore.shared.snapshot()
        let workspacePaths = BoardLayoutStore.shared.loadAllWorkspacePaths()
        let parentRefs = PlannerBoardBridge.store.canvasParentRefs()
        let candidateStore = SessionArtifactCandidateStore.shared
        let candidates: [SessionArtifactCandidate]
        if query.sessionIds.isEmpty {
            candidates = candidateStore.list(includeDiscarded: false)
        } else {
            candidates = candidateStore.list(sessionIds: Array(query.sessionIds), includeDiscarded: false)
        }

        var sources: [ArtifactPageSource] = []
        for canvas in snapshot.canvases {
            if let canvasId = query.canvasId, canvasId != "all", canvas.id != canvasId { continue }
            if let scope = query.scope, scope != "all", canvas.scope.rawValue != scope { continue }
            guard let record = try? PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvas.id) else {
                continue
            }
            let artifacts = PlannerBoardBridge.store.artifactsWithVersionInfo(
                record.artifacts,
                versions: record.artifactVersions
            )
            guard !artifacts.isEmpty else { continue }
            sources.append(ArtifactPageSource(
                canvas: artifactCanvasDTO(
                    canvas,
                    workspacePath: workspacePaths[canvas.id] ?? "",
                    parentCanvasId: parentRefs[canvas.id]?.parentCanvasId,
                    parentNodeId: parentRefs[canvas.id]?.parentNodeId
                ),
                nodes: record.nodes,
                artifacts: artifacts
            ))
        }

        // Promoted candidates without a Canvas attachment are formal,
        // session-scoped artifacts and belong in the default Ready view.
        for candidate in candidates where candidate.status == .promoted && candidate.promotedCanvasId == nil {
            let artifact = candidateStore.sessionScopedArtifact(for: candidate)
            sources.append(ArtifactPageSource(
                canvas: sessionCanvasDTO(candidate),
                artifacts: [artifact],
                sessionIdOverride: candidate.sessionId
            ))
        }

        do {
            return jsonResponse(try ArtifactPageBuilder.build(
                sources: sources,
                candidates: candidates,
                query: query
            ))
        } catch let error as ArtifactPageBuilderError {
            return errorResponse("invalid_cursor", error.localizedDescription, status: 400)
        } catch {
            return errorResponse("artifact_index_error", error.localizedDescription, status: 500)
        }
    }

    private static func artifactCanvasDTO(
        _ canvas: BoardLayoutStore.Canvas,
        workspacePath: String,
        parentCanvasId: String?,
        parentNodeId: String?
    ) -> CanvasInfoDTO {
        CanvasInfoDTO(
            id: canvas.id,
            name: canvas.name,
            scope: canvas.scope.rawValue,
            visibility: canvas.scope == .team ? "public" : "private",
            kind: (canvas.kind ?? .board).rawValue,
            isDefault: canvas.isDefault,
            workspacePath: workspacePath,
            parentCanvasId: parentCanvasId,
            parentNodeId: parentNodeId,
            teamId: canvas.teamId,
            ownerUserId: canvas.ownerUserId ?? canvas.createdBy,
            remoteId: canvas.remoteId,
            remoteVersion: canvas.remoteVersion,
            syncStatus: canvas.syncStatus,
            dirtySince: BoardDTOBuilder.iso(canvas.dirtySince),
            lastSyncedAt: BoardDTOBuilder.iso(canvas.lastSyncedAt),
            lastRemoteUpdatedAt: BoardDTOBuilder.iso(canvas.lastRemoteUpdatedAt),
            conflictRemoteVersion: canvas.conflictRemoteVersion,
            conflictRemoteDeleted: canvas.conflictRemoteDeleted,
            draftOfTemplateId: canvas.draftOfTemplateId
        )
    }

    private static func sessionCanvasDTO(_ candidate: SessionArtifactCandidate) -> CanvasInfoDTO {
        CanvasInfoDTO(
            id: "session:\(candidate.sessionId)",
            name: "Session",
            scope: "personal",
            visibility: "private",
            kind: "monitor",
            isDefault: false,
            workspacePath: candidate.cwd ?? "",
            parentCanvasId: nil,
            parentNodeId: nil,
            teamId: nil,
            ownerUserId: nil,
            remoteId: nil,
            remoteVersion: nil,
            syncStatus: nil,
            dirtySince: nil,
            lastSyncedAt: nil,
            lastRemoteUpdatedAt: nil,
            conflictRemoteVersion: nil,
            conflictRemoteDeleted: nil,
            draftOfTemplateId: nil
        )
    }
}
