import Foundation

struct SessionArtifactsEnvelope: Encodable {
    var sessionId: String
    var artifacts: [PlannerArtifact]
    var totalCount: Int
}

/// Resolves the formal planner artifacts produced by nodes bound to a session.
/// Session output is intentionally read-only: hooks do not create provisional
/// artifact records and the session UI cannot promote or discard output.
enum SessionArtifactsAPI {
    static func artifacts(sessionId: String) -> SessionArtifactsEnvelope {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = sessionAliases(for: normalizedSessionId)
        let snapshot = BoardLayoutStore.shared.snapshot()
        let actor = PlannerPermission.currentActorId()
        var artifacts: [PlannerArtifact] = []

        for canvas in snapshot.canvases {
            guard let record = try? PlannerBoardBridge.store.canvasRecordForBridge(canvasId: canvas.id) else {
                continue
            }
            let access = PlannerPermission.access(for: record.canvas, nodes: record.nodes, actorId: actor)
            guard PlannerBoardBridge.canViewCanvas(record.canvas, access: access) else { continue }
            let matchingNodeIds = Set(record.nodes.compactMap { node -> String? in
                guard let bound = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !bound.isEmpty,
                      aliases.contains(where: { sessionIdsMatch(bound, $0) }) else {
                    return nil
                }
                return node.id
            })
            let versionedArtifacts = PlannerBoardBridge.store.artifactsWithVersionInfo(
                record.artifacts,
                versions: record.artifactVersions
            )
            artifacts.append(contentsOf: versionedArtifacts.filter { matchingNodeIds.contains($0.nodeId) })
        }

        let uniqueArtifacts = Dictionary(grouping: artifacts, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.createdAt > $1.createdAt }
        return SessionArtifactsEnvelope(
            sessionId: normalizedSessionId,
            artifacts: uniqueArtifacts,
            totalCount: uniqueArtifacts.count
        )
    }

    private static func sessionAliases(for sessionId: String) -> [String] {
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
            let providerResume = normalized(session.providerResumeSessionId)
            let terminalSurfaceId = normalized(session.terminalInfo?.cmuxSurfaceId)
            if sessionIdsMatch(session.sessionId, sessionId)
                || sessionIdsMatch(providerResume, sessionId)
                || sessionIdsMatch(terminalSurfaceId, sessionId) {
                aliases.append(session.sessionId)
                aliases.append(providerResume)
                aliases.append(terminalSurfaceId)
            }
        }

        for (_, terminal) in SessionTerminalStore.shared.getAll() {
            let providerResume = normalized(terminal.providerResumeSessionId)
            let surfaceId = normalized(terminal.cmuxSurfaceId)
            if sessionIdsMatch(terminal.sessionId, sessionId)
                || sessionIdsMatch(providerResume, sessionId)
                || sessionIdsMatch(surfaceId, sessionId) {
                aliases.append(terminal.sessionId)
                aliases.append(providerResume)
                aliases.append(surfaceId)
            }
        }

        return Array(Set(aliases.map(normalized).filter { !$0.isEmpty })).sorted()
    }

    private static func sessionIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.hasSuffix("-\(right)") || right.hasSuffix("-\(left)")
    }

    private static func normalized(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
