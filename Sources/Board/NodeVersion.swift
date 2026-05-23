import Foundation

// MARK: - Node Version (ENG-2 / E2.1)
//
// In the post-meeting model there is no `run` / `instance` per execution —
// instead, every `submit_node_output` appends a `NodeVersion` to a per-node
// chain. The latest version is the canonical view; old versions stay queryable
// for history / diff. ENG-3 owns the on-disk version store (DB table
// `meee2_session_versions`); this file defines the in-process model + helpers
// the engine uses to build, append, and merge inputs into a version.
//
// Back-compat: existing `WorkflowRun` / `runId` references on artifacts still
// work. `versionId` is additive on `PlannerArtifact` and `RunNodeState`. A
// `versionId == nil` record is treated as "pre-versioning" and migrated lazily
// on next submit (a fresh version is appended pointing at `parent == nil`).

/// Where the outbound trigger for this version came from.
enum NodeVersionTrigger: String, Codable, Equatable, CaseIterable {
    /// User clicked "run" / submitted via UI.
    case manual
    /// An upstream node's output arrived, auto-triggering this one.
    case upstream
    /// Scheduled tick (`PlannerNodeSchedule`).
    case schedule
    /// External signal (e.g. inbound webhook, mail sync).
    case external
    /// Re-run requested with `force_new_version: true` (E2.3).
    case forceRerun
    /// Synthesized when migrating a pre-ENG-2 record.
    case legacy
}

/// One frozen input snapshot — captures the three sources that fed this
/// version's prompt context at the moment of execution. Mirrors the v2
/// contract input model so downstream tools can replay or diff.
struct NodeVersionInputSnapshot: Codable, Equatable {
    /// Upstream node id + the *exact* upstream version id that was consumed.
    /// Both nil means "no upstream / root node".
    var upstreamNodeId: String?
    var upstreamVersionId: String?

    /// One entry per `external_inputs[]` declared on the v2 contract. The
    /// snapshot records the connector / ref pair + the sync-session id that
    /// was fired at this tick (nil if the connector is in-process).
    var external: [NodeVersionExternalSnapshot]

    /// Window of dialogue turns sliced into context. `nil` means the dialogue
    /// source was disabled for this version.
    var dialogueTurns: Int?

    /// Free-form merge log — human-readable lines that ENG-5 surfaces in the
    /// session history panel ("merged: upstream X@v3, external notion(db//abc)
    /// → fetched 12 items, dialogue 20 turns").
    var mergeLog: [String]
}

struct NodeVersionExternalSnapshot: Codable, Equatable {
    var connector: String
    var ref: String
    var syncSessionId: String?
    /// Set when the connector returned a stable ref pointing at the fetched
    /// snapshot (e.g. an artifact id). Optional — INT-2 will define the canonical
    /// shape per connector.
    var fetchedArtifactId: String?
}

/// One immutable execution of a node. Each `submit_node_output` (or
/// `force_new_version: true` re-run) appends a fresh `NodeVersion` to the
/// canvas record's `nodeVersions` map.
struct NodeVersion: Codable, Equatable {
    /// Globally unique id: `nodever-<canvasShort>-<nodeShort>-<seq>-<uuid8>`.
    var id: String
    var canvasId: String
    var nodeId: String
    /// 1-based version index within `(canvasId, nodeId)`. v1, v2, …
    var versionIndex: Int
    /// The previous version's `id`. `nil` for v1.
    var parentVersionId: String?
    /// Session that produced this version. `nil` for human / system inputs.
    var sessionId: String?
    /// What kicked this version off.
    var trigger: NodeVersionTrigger
    /// Frozen input snapshot — what the runtime merged into prompt context.
    var inputs: NodeVersionInputSnapshot
    /// References to the artifacts produced. Mirrors `PlannerArtifact.id` so
    /// the artifact store stays the single source of truth for payload.
    var artifactIds: [String]
    /// Terminal-ish status this version landed in.
    var status: PlannerNodeOutputStatus
    var startedAt: Date
    var finishedAt: Date?
}

// MARK: - Per-node version chain helpers

extension Array where Element == NodeVersion {
    /// Latest (highest `versionIndex`) version for `(canvasId, nodeId)`, or
    /// `nil` if the node has never been executed.
    func latest(canvasId: String, nodeId: String) -> NodeVersion? {
        self.filter { $0.canvasId == canvasId && $0.nodeId == nodeId }
            .max(by: { $0.versionIndex < $1.versionIndex })
    }

    /// Next 1-based version index for `(canvasId, nodeId)`.
    func nextVersionIndex(canvasId: String, nodeId: String) -> Int {
        (latest(canvasId: canvasId, nodeId: nodeId)?.versionIndex ?? 0) + 1
    }

    /// All versions for `(canvasId, nodeId)` sorted oldest → newest.
    func chain(canvasId: String, nodeId: String) -> [NodeVersion] {
        self.filter { $0.canvasId == canvasId && $0.nodeId == nodeId }
            .sorted(by: { $0.versionIndex < $1.versionIndex })
    }
}

// MARK: - Input merge runtime (E2.5)

/// Pure helper that takes a v2 contract + freshly fetched source data and
/// returns a `NodeVersionInputSnapshot` + human-readable merged-prompt
/// preamble. The merge order is **declared by the contract**, not the
/// runtime: upstream first, then external in declaration order, then
/// dialogue tail last. This matches the meeting decision ("input 是 3 路
/// 合流, 顺序按 declared 来").
enum SessionInputMerge {

    /// Output bundle of one merge tick.
    struct Result: Equatable {
        /// The frozen snapshot, ready to attach to the new `NodeVersion`.
        var snapshot: NodeVersionInputSnapshot
        /// The merged prompt preamble — block of text the runner prepends to
        /// the next prompt. Sources are labelled so the agent can tell what
        /// came from where.
        var promptPreamble: String
    }

    /// Run the merge.
    ///
    /// - Parameters:
    ///   - contract: the v2 input contract declared on the node.
    ///   - upstreamLatest: the latest version of the upstream node (or nil
    ///     when upstream isn't bound yet).
    ///   - upstreamPayload: optional inline preview text for the upstream
    ///     output. Runtime will pass `nil` until ENG-3's version-store
    ///     reader is wired — merge still produces a snapshot pointing at
    ///     the version id, just without inline body.
    ///   - externalFetched: per-external-input result (connector / ref /
    ///     fetched-artifact-id / preview). Order MUST match
    ///     `contract.input.external` order. If the runtime skipped an
    ///     entry (connector unavailable), pass an empty `previewLines`.
    ///   - dialogueTurns: turns sliced from the bound session's transcript,
    ///     newest at the end. Pass `nil` if dialogue is disabled.
    static func merge(
        contract: NodeContractV2,
        upstreamLatest: NodeVersion?,
        upstreamPayload: String?,
        externalFetched: [ExternalFetchResult],
        dialogueTurns: [String]?
    ) -> Result {
        var lines: [String] = []
        var mergeLog: [String] = []
        var preamble: [String] = []

        // 1) upstream
        let upstreamSnapshot: (nodeId: String?, versionId: String?) = {
            if let upstream = upstreamLatest {
                mergeLog.append("upstream node=\(upstream.nodeId) version=v\(upstream.versionIndex) (\(upstream.id))")
                preamble.append("## Upstream (\(upstream.nodeId) v\(upstream.versionIndex))")
                if let payload = upstreamPayload, !payload.isEmpty {
                    preamble.append(payload)
                } else {
                    preamble.append("(payload at version_id=\(upstream.id) — load via planner artifact store)")
                }
                preamble.append("")
                return (upstream.nodeId, upstream.id)
            } else if contract.input.upstream.sourceNodeId != nil {
                mergeLog.append("upstream node=\(contract.input.upstream.sourceNodeId ?? "?") — no version yet")
                return (contract.input.upstream.sourceNodeId, nil)
            } else {
                mergeLog.append("upstream none (root node)")
                return (nil, nil)
            }
        }()

        // 2) external — declared order
        var externalSnapshots: [NodeVersionExternalSnapshot] = []
        for (idx, declared) in contract.input.external.enumerated() {
            let fetched = idx < externalFetched.count ? externalFetched[idx] : nil
            externalSnapshots.append(NodeVersionExternalSnapshot(
                connector: declared.connector,
                ref: declared.ref,
                syncSessionId: declared.syncSessionId,
                fetchedArtifactId: fetched?.fetchedArtifactId
            ))
            let previewCount = fetched?.previewLines.count ?? 0
            mergeLog.append("external[\(idx)] connector=\(declared.connector) ref=\(declared.ref) items=\(previewCount)")
            if previewCount > 0 {
                preamble.append("## External: \(declared.connector) (\(declared.ref))")
                preamble.append(contentsOf: fetched!.previewLines)
                preamble.append("")
            }
            _ = lines // silence
        }

        // 3) dialogue — newest at the end of the window
        let dialogueCount: Int? = {
            guard contract.input.dialogue.enabled, let turns = dialogueTurns else {
                mergeLog.append("dialogue disabled")
                return nil
            }
            let n = min(turns.count, contract.input.dialogue.window.nTurns)
            mergeLog.append("dialogue window=\(contract.input.dialogue.window.kind.rawValue) requested=\(contract.input.dialogue.window.nTurns) sliced=\(n)")
            if n > 0 {
                preamble.append("## Recent dialogue (last \(n) turns)")
                preamble.append(contentsOf: turns.suffix(n))
                preamble.append("")
            }
            return n
        }()

        return Result(
            snapshot: NodeVersionInputSnapshot(
                upstreamNodeId: upstreamSnapshot.nodeId,
                upstreamVersionId: upstreamSnapshot.versionId,
                external: externalSnapshots,
                dialogueTurns: dialogueCount,
                mergeLog: mergeLog
            ),
            promptPreamble: preamble.joined(separator: "\n")
        )
    }

    /// Per-external-input fetch result fed into `merge(...)`.
    struct ExternalFetchResult: Equatable {
        var connector: String
        var ref: String
        /// Stable artifact id if the connector materialized one.
        var fetchedArtifactId: String?
        /// Short preview lines to merge into the prompt preamble.
        var previewLines: [String]

        init(connector: String, ref: String, fetchedArtifactId: String? = nil, previewLines: [String] = []) {
            self.connector = connector
            self.ref = ref
            self.fetchedArtifactId = fetchedArtifactId
            self.previewLines = previewLines
        }
    }
}

// MARK: - Construction helpers

extension NodeVersion {
    /// Build a fresh `NodeVersion` for `(canvasId, nodeId)`, given the prior
    /// chain on the canvas. The caller is responsible for appending the
    /// result onto `CanvasRecord.nodeVersions`.
    static func append(
        canvasId: String,
        nodeId: String,
        previousVersions: [NodeVersion],
        sessionId: String?,
        trigger: NodeVersionTrigger,
        inputs: NodeVersionInputSnapshot,
        artifactIds: [String],
        status: PlannerNodeOutputStatus,
        startedAt: Date = Date(),
        finishedAt: Date? = Date()
    ) -> NodeVersion {
        let priorChain = previousVersions.chain(canvasId: canvasId, nodeId: nodeId)
        let index = (priorChain.last?.versionIndex ?? 0) + 1
        let parentId = priorChain.last?.id
        let canvasShort = String(canvasId.prefix(6))
        let nodeShort = String(nodeId.prefix(6))
        let randSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let id = "nodever-\(canvasShort)-\(nodeShort)-\(index)-\(randSuffix)"
        return NodeVersion(
            id: id,
            canvasId: canvasId,
            nodeId: nodeId,
            versionIndex: index,
            parentVersionId: parentId,
            sessionId: sessionId,
            trigger: trigger,
            inputs: inputs,
            artifactIds: artifactIds,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}
