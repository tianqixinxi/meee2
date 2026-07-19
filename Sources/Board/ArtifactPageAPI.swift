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
        status: String = "all",
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
            status: value("status") ?? "all",
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
    private final class Bucket {
        let source: ArtifactPageSource
        let node: PlanningNode?
        var artifacts: [PlannerArtifact]

        init(source: ArtifactPageSource, node: PlanningNode?, artifact: PlannerArtifact) {
            self.source = source
            self.node = node
            self.artifacts = [artifact]
        }
    }

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
        query: ArtifactPageQuery
    ) throws -> ArtifactPageEnvelope {
        let records = deduplicatedRecords(sources: sources)
        let requestedProjectTokens = projectTokens(query.project)
        let baseFiltered = records.filter { record in
            matchesBaseFilters(record, query: query, requestedProjectTokens: requestedProjectTokens)
        }
        let statusFiltered = baseFiltered.filter { record in
            if query.status.isEmpty || query.status == "all" { return true }
            if query.status == "promoted" {
                return record.item.artifacts.first?.status.lowercased() == "promoted"
            }
            return record.displayStatus == query.status
                || record.item.artifacts.first?.status.lowercased() == query.status
        }
        var statusCounts: [String: Int] = [:]
        for record in baseFiltered {
            statusCounts[record.displayStatus, default: 0] += 1
            if record.item.artifacts.first?.status.lowercased() == "promoted" {
                statusCounts["promoted", default: 0] += 1
            }
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
            availableTotal: baseFiltered.count,
            hasMore: hasMore,
            canvasCount: Set(filtered.map { $0.item.canvas.id }).count,
            groupCounts: groupCounts,
            statusCounts: statusCounts
        )
    }

    private static func deduplicatedRecords(sources: [ArtifactPageSource]) -> [Record] {
        // Reference buckets avoid repeatedly copying a growing versions array.
        // A value-tuple `[PlannerArtifact]` here turns a long version chain into
        // quadratic copy-on-write work while building the index.
        var artifactsBySlot: [String: Bucket] = [:]
        for source in sources {
            let nodesById = Dictionary(uniqueKeysWithValues: source.nodes.map { ($0.id, $0) })
            for artifact in source.artifacts {
                let key = artifactSlotKey(artifact)
                if let current = artifactsBySlot[key] {
                    current.artifacts.append(artifact)
                } else {
                    artifactsBySlot[key] = Bucket(
                        source: source,
                        node: nodesById[artifact.nodeId],
                        artifact: artifact
                    )
                }
            }
        }

        let records = artifactsBySlot.map { key, value -> Record in
            let sortedArtifacts = value.artifacts.sorted { $0.createdAt > $1.createdAt }
            let latest = sortedArtifacts[0]
            let sessionId = value.source.sessionIdOverride ?? value.node?.sessionId
            let item = ArtifactPageItemDTO(
                canvas: value.source.canvas,
                node: value.node,
                sessionId: sessionId,
                artifacts: sortedArtifacts
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

        return records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.key < $1.key
        }
    }

    private static func matchesBaseFilters(
        _ record: Record,
        query: ArtifactPageQuery,
        requestedProjectTokens: Set<String>
    ) -> Bool {
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
                .contains { requestedProjectTokens.contains($0) }
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
        let actor = PlannerPermission.currentActorId()
        var sources: [ArtifactPageSource] = []
        for canvas in snapshot.canvases {
            if let canvasId = query.canvasId, canvasId != "all", canvas.id != canvasId { continue }
            if let scope = query.scope, scope != "all", canvas.scope.rawValue != scope { continue }
            guard let record = try? PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvas.id) else {
                continue
            }
            let access = PlannerPermission.access(for: record.canvas, nodes: record.nodes, actorId: actor)
            guard PlannerBoardBridge.canViewCanvas(record.canvas, access: access) else { continue }
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

        do {
            return jsonResponse(try ArtifactPageBuilder.build(
                sources: sources,
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

}
