import Foundation

// MARK: - CanvasRuntimeView (canvas-spec §7.2 / §14)
//
// The READ-ONLY whole-canvas runtime snapshot a Monitor
// (Artifact{source:canvas-runtime, widget:html}) consumes. The board-app
// injects an instance of this shape into the sandboxed monitor iframe via
// `postMessage` and re-posts on change so the monitor stays live.
//
// Source-of-truth for the shape is the Zod twin in
// `meee2-online/src/planner-runtime/contract/canvas-runtime-view.ts`; the
// board-app TS twin lives in `packages/board-app/src/types.ts`. All three are
// hand-mirrored; the JSON contract carries it for drift detection.
//
// Purely derived/read-only — nothing here is hand-authored or written back. It
// is surfaced additively on `PlannerGraphState.canvasRuntime`; every existing
// PlannerGraphState field is unchanged.

struct CanvasRuntimeNode: Codable, Equatable {
    var id: String
    var title: String
    /// 4-state node status (`ready | blocked | done` + forward-compat).
    var status: String
    /// Latest workflow run state (`running | awaiting-input | gate-wait | …`).
    var workflowRunState: String?
    var doerId: String
    /// When the node entered an awaiting state (ISO-8601 via .iso8601 encoder).
    var awaitingInputSince: Date?
}

struct CanvasRuntimeAttempt: Codable, Equatable {
    var nodeId: String
    var index: Int
    /// TriggerOrigin.kind — `human | auto-workflow | auto-agent | external | inherited`.
    var originKind: String?
    var runState: String
    var startedAt: Date?
    var finishedAt: Date?
}

struct CanvasRuntimeArtifact: Codable, Equatable {
    var nodeId: String
    var reference: String
    var title: String
    /// 1-based index of this artifact's version within its slot chain.
    var versionIndex: Int?
    /// Total versions in the slot chain (pairs with versionIndex → `v2 / 3`).
    var versionCount: Int?
    /// §3.C clipboard position tag (`latest | candidate | discarded | …`).
    var positionTag: String?
}

struct CanvasRuntimeEdge: Codable, Equatable {
    /// `nodeId.sourceKey` or a DataSource id when the edge sources a pool.
    var sourceRef: String
    /// `nodeId.inputKey` or a DataSource id.
    var targetRef: String
    /// EdgeMode.mode — `dependency | document-snapshot | queue-claim`.
    var mode: String
}

struct CanvasRuntimeDataSource: Codable, Equatable {
    var id: String
    var title: String
    var partitionRule: String
    var currentVersion: Int
    /// Ready (unclaimed) item count — present only when queueClaimable.
    var queueReadyDepth: Int?
}

struct CanvasRuntimeView: Codable, Equatable {
    var canvasId: String
    var generatedAt: Date
    var nodes: [CanvasRuntimeNode]
    var attempts: [CanvasRuntimeAttempt]
    var artifacts: [CanvasRuntimeArtifact]
    var edges: [CanvasRuntimeEdge]
    var dataSources: [CanvasRuntimeDataSource]
}

extension PlannerBoardBridge {
    /// Build the read-only `CanvasRuntimeView` snapshot for a canvas from its
    /// already-resolved graph pieces plus the active run's attempt history and
    /// per-DataSource queue depths.
    ///
    /// `attemptsByNode` is the active run's `RunNodeState.attempts` map (empty
    /// when the canvas has no active run yet). `queueDepth` resolves the ready
    /// depth for a queueClaimable source via `DataSourceAdapter.readyDepth`; it
    /// is best-effort — a failure yields `nil` rather than throwing, so a single
    /// flaky source never blocks the whole monitor.
    static func buildCanvasRuntimeView(
        canvasId: String,
        nodes: [PlanningNode],
        states: [NodeStateSnapshot],
        artifacts: [PlannerArtifact],
        edges: [Edge],
        dataSources: [DataSourceRecord],
        attemptsByNode: [String: [NodeAttempt]],
        now: Date = Date()
    ) -> CanvasRuntimeView {
        let runtimeNodes: [CanvasRuntimeNode] = nodes.map { node in
            // Pull the awaiting timestamp from the live attempt when present.
            let liveAttempt = attemptsByNode[node.id]?.last
            return CanvasRuntimeNode(
                id: node.id,
                title: node.title,
                status: node.status.rawValue,
                workflowRunState: node.workflowRunState?.rawValue,
                doerId: node.doerId,
                awaitingInputSince: liveAttempt?.awaitingInputSince
            )
        }

        var runtimeAttempts: [CanvasRuntimeAttempt] = []
        for node in nodes {
            for attempt in attemptsByNode[node.id] ?? [] {
                runtimeAttempts.append(CanvasRuntimeAttempt(
                    nodeId: node.id,
                    index: attempt.index,
                    originKind: attempt.origin.kind,
                    runState: attempt.runState.rawValue,
                    startedAt: attempt.startedAt,
                    finishedAt: attempt.finishedAt
                ))
            }
        }

        let runtimeArtifacts: [CanvasRuntimeArtifact] = artifacts.map { artifact in
            CanvasRuntimeArtifact(
                nodeId: artifact.nodeId,
                reference: artifact.reference,
                title: artifact.title,
                versionIndex: artifact.versionIndex,
                versionCount: artifact.versionCount,
                positionTag: nil // PlannerArtifact has no positionTag on the desktop projection yet.
            )
        }

        let runtimeEdges: [CanvasRuntimeEdge] = edges.map { edge in
            let src = edge.sourceRef.dataSourceId
                ?? "\(edge.sourceRef.nodeId).\(edge.sourceRef.sourceKey)"
            let dst = edge.targetRef.dataSourceId
                ?? "\(edge.targetRef.nodeId).\(edge.targetRef.inputKey)"
            return CanvasRuntimeEdge(sourceRef: src, targetRef: dst, mode: edge.edgeMode.mode)
        }

        let runtimeSources: [CanvasRuntimeDataSource] = dataSources
            .filter { !$0.archived }
            .map { source in
                var depth: Int?
                if source.capabilities.queueClaimable {
                    depth = (try? dataSourceAdapter(canvasId: canvasId, sourceId: source.id))
                        .flatMap { ($0 as? ManagedAdapter)?.readyDepth() }
                }
                return CanvasRuntimeDataSource(
                    id: source.id,
                    title: source.label,
                    partitionRule: source.partitionRule,
                    currentVersion: source.currentVersion,
                    queueReadyDepth: depth
                )
            }

        return CanvasRuntimeView(
            canvasId: canvasId,
            generatedAt: now,
            nodes: runtimeNodes,
            attempts: runtimeAttempts,
            artifacts: runtimeArtifacts,
            edges: runtimeEdges,
            dataSources: runtimeSources
        )
    }
}
