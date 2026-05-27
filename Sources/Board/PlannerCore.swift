import Foundation
import Meee2PluginKit

/// Who can see a planning canvas. `private` (the default) restricts the canvas
/// to its owner plus anyone holding a role on it (doer / assigned); `public`
/// makes it visible to every actor.
enum PlannerCanvasVisibility: String, Codable, Equatable {
    case `public`
    case `private`
}

struct PlanningCanvas: Codable, Equatable {
    var id: String
    var ownerId: String
    var title: String
    var plannerContext: String
    /// Visibility tier. Defaults to `.private` for newly created canvases.
    var visibility: PlannerCanvasVisibility
    /// ENG-4: parent canvas when this canvas was created via
    /// `assign_node` (i.e. is a sub-canvas). `nil` for top-level canvases.
    var parentCanvasId: String?
    /// ENG-4: id of the parent canvas's node that owns this sub-canvas as
    /// its `sub_canvas_ref`. Must be set iff `parentCanvasId` is set.
    var parentNodeId: String?
    /// ENG-4: frozen Node Contract v2 snapshot captured at assign time.
    /// Parent owner reads this to surface the I/O boundary; child cannot
    /// change it without re-assigning. JSON shape mirrors `NodeContractV2`.
    var frozenIOContract: NodeContractV2?

    init(
        id: String,
        ownerId: String,
        title: String,
        plannerContext: String,
        visibility: PlannerCanvasVisibility = .private,
        parentCanvasId: String? = nil,
        parentNodeId: String? = nil,
        frozenIOContract: NodeContractV2? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.title = title
        self.plannerContext = plannerContext
        self.visibility = visibility
        self.parentCanvasId = parentCanvasId
        self.parentNodeId = parentNodeId
        self.frozenIOContract = frozenIOContract
    }
}

struct NodeSchema: Codable, Equatable {
    var inputs: [String]
    var outputs: [String]
    var goal: String
}

struct ContextSource: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case chatHistory
        case repository
        case web
        case document
        case artifact
    }

    var kind: Kind
    var title: String
    var reference: String
}

// MARK: - Cross-language enums (Swift ↔ Zod twin)
//
// The next three enums are also declared on the meee2-online side as Zod
// schemas in `meee2-online/src/planner-runtime/contract/enums.ts` (ExecutionMode
// / ExecutorType / NodeStatus). They MUST stay in sync — desktop and online
// both round-trip these as raw strings through Supabase, and a divergence
// will surface as silent Codable/Zod parse failures.
//
// If you add or remove a case here, mirror it in `enums.ts` (in the same PR
// or the immediately following workspace-bump PR). A future codegen step can
// collapse this back to one source; until then the rule is "edit both."

/// Twin · meee2-online/src/planner-runtime/contract/enums.ts (ExecutionMode)
enum ExecutionMode: String, Codable, Equatable, CaseIterable {
    case auto
    case human
}

/// Twin · meee2-online/src/planner-runtime/contract/enums.ts (ExecutorType)
enum ExecutorType: String, Codable, Equatable, CaseIterable {
    case claude
    case codex
    case cursor
    case openClaw
    case devin
    case human
    case mock
}

/// Twin · meee2-online/src/planner-runtime/contract/enums.ts (NodeStatus)
enum PlanningNodeStatus: String, Codable, Equatable, CaseIterable {
    case draft
    case ready
    case working
    case blocked
    case done
}

enum PlanningNodeSource: String, Codable, Equatable {
    case planner
    case session
}

enum PlanningNodeKind: String, Codable, Equatable {
    case step
    case session
    case artifact
    case subCanvas
    case external
}

struct PlannerNodeLayout: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double?
    var height: Double?
}

enum PlannerWorkflowRunState: String, Codable, Equatable {
    case pending
    case readyToStart = "ready_to_start"
    case dispatched
    case running
    /// Session is alive but idle, waiting for a human to supply context or a
    /// decision before it can continue. Distinct from `dispatched` (just
    /// spun up) and `gateWait` (an explicit planner/permission gate).
    case awaitingInput = "awaiting-input"
    case gateWait = "gate-wait"
    case done
    case failed
}

struct PlannerNodeTrigger: Codable, Equatable {
    var type: String
    var label: String
    var eventSource: String?
}

struct PlannerNodeSchedule: Codable, Equatable {
    var enabled: Bool
    var intervalSeconds: Int
    var prompt: String
    var lastSentAt: Date?
    var nextRunAt: Date?
}

struct PlannerNodeGate: Codable, Equatable {
    var type: String
    var label: String
    var requiredArtifactRefs: [String]
    var approvers: [String]
    var onFailGotoNodeId: String?
}

enum PlannerDispatchRunner: String, Codable, Equatable {
    /// Spawns a local Claude session (the BYOA default).
    case claude
    /// Spawns a local Codex session.
    case codex
    /// Spawns a local CLI session, command picked from `PlannerNodeDispatch.command`.
    case byoaLocal = "byoa-local"
    /// Proposal-only runner — no execution wired up yet (CI worker). Phase 2
    /// leaves this as a pure proposal: dispatch records intent but never spawns
    /// a session node. See `PlannerDispatchRunner.spawnsSession`.
    case ciAgent = "ci-agent"
    /// No session — the step waits at a human gate (`workflowRunState == .gateWait`).
    case human

    /// Runners that produce a real spawned session (and therefore a `session`
    /// PlanningNode at apply time). `ciAgent` is proposal-only; `human` gates.
    var spawnsSession: Bool {
        switch self {
        case .claude, .codex, .byoaLocal:
            return true
        case .ciAgent, .human:
            return false
        }
    }

    /// CLI command used when spawning a session for this runner.
    var spawnCommand: String? {
        switch self {
        case .claude:
            return AgentLaunchCommand.fullAccessCommand(forProvider: "claude")
        case .codex:
            return AgentLaunchCommand.fullAccessCommand(forProvider: "codex")
        case .byoaLocal:
            return AgentLaunchCommand.fullAccessCommand(forProvider: "claude")
        case .ciAgent, .human:
            return nil
        }
    }
}

struct PlannerNodeDispatch: Codable, Equatable {
    var runner: PlannerDispatchRunner
    var skill: String?
    var actor: String
    var command: String?
    var fallbackRunner: PlannerDispatchRunner?
}

enum PlannerArtifactKind: String, Codable, Equatable, CaseIterable {
    case ideaDraft = "idea-draft"
    case kanban
    case prd
    case implPR = "impl-pr"
    case prereleaseVerdict = "prerelease-verdict"
    case mainMerge = "main-merge"
    case larkDoc = "lark-doc"
    case checkResult = "check-result"
    case generic
}

/// Who produced an artifact. Artifact production is source-agnostic — a human,
/// an AI agent/session, or an external integration can all attach evidence.
enum PlannerArtifactProducer: String, Codable, Equatable {
    case human
    case agent
    case integration
}

struct PlannerArtifact: Codable, Equatable {
    var id: String
    var canvasId: String
    var nodeId: String
    var kind: PlannerArtifactKind
    var title: String
    var reference: String
    var status: String
    var createdAt: Date
    var payload: BoardJSONValue?
    /// Who produced this artifact.
    var producedBy: PlannerArtifactProducer
    /// The workflow run this artifact belongs to.
    var runId: String?

    init(
        id: String,
        canvasId: String,
        nodeId: String,
        kind: PlannerArtifactKind,
        title: String,
        reference: String,
        status: String,
        createdAt: Date,
        payload: BoardJSONValue? = nil,
        producedBy: PlannerArtifactProducer = .integration,
        runId: String? = nil
    ) {
        self.id = id
        self.canvasId = canvasId
        self.nodeId = nodeId
        self.kind = kind
        self.title = title
        self.reference = reference
        self.status = status
        self.createdAt = createdAt
        self.payload = payload
        self.producedBy = producedBy
        self.runId = runId
    }
}

// MARK: - ENG-3 · Artifact Version Chain
//
// Every submit_node_output appends a new PlannerArtifactVersion row (never
// physically replaces the previous one). `parent_version_id` chains the
// history; `input_snapshot` records the upstream / external / dialogue
// inputs that produced this version so it can be re-viewed in context.
//
// The Supabase mirror lives in `meee2_artifact_versions` /
// `meee2_artifact_input_snapshots` (migration 20260522232332).

/// How the UI should pick which version of an artifact slot to show.
/// Default `latest`; `mergedView` is for fan-in nodes (list cardinality)
/// where the UI accumulates entries across versions.
///
/// Renamed from v1 `replace_strategy`: see `NodeContractValidator
/// .rejectedReplaceStrategy` — the runtime never physically replaces;
/// "replace" is now purely a display-time choice.
enum PlannerArtifactDisplayStrategy: String, Codable, Equatable, CaseIterable {
    case latest
    case mergedView = "merged_view"
}

/// Who submitted a version. Mirrors the `submitted_by_kind` enum on the
/// `meee2_artifact_versions` row.
enum PlannerArtifactVersionSubmitterKind: String, Codable, Equatable, CaseIterable {
    case agent
    case human
    case system
    case integration
}

/// Snapshot of the three input sources captured at version-submit time.
/// Without this, re-viewing an old artifact version cannot reconstruct
/// the context that produced it (Jaxon's版本回看 case).
struct PlannerArtifactInputSnapshot: Codable, Equatable {
    /// Upstream artifact ref captured at run time (same scheme as
    /// `PlannerArtifact.reference`). `nil` for root / external nodes.
    var upstreamArtifactRef: String?
    /// Per-external-input connector outputs at run time. Each entry mirrors
    /// `NodeContractExternalInput` plus the fetched payload pointer.
    var externalOutputs: [BoardJSONValue]
    /// Rolling N-turn dialogue window slice used as input. Shape mirrors
    /// `NodeContractDialogueWindow` plus the materialised turns.
    var dialogueWindow: BoardJSONValue?

    init(
        upstreamArtifactRef: String? = nil,
        externalOutputs: [BoardJSONValue] = [],
        dialogueWindow: BoardJSONValue? = nil
    ) {
        self.upstreamArtifactRef = upstreamArtifactRef
        self.externalOutputs = externalOutputs
        self.dialogueWindow = dialogueWindow
    }

    enum CodingKeys: String, CodingKey {
        case upstreamArtifactRef = "upstream_artifact_ref"
        case externalOutputs = "external_outputs"
        case dialogueWindow = "dialogue_window"
    }
}

/// One version row in an artifact's append-only history. The "slot" is
/// `(canvasId, nodeId, normalized reference)` — multiple versions share a
/// slot, chained via `parentVersionId`.
struct PlannerArtifactVersion: Codable, Equatable {
    var versionId: String
    var parentVersionId: String?
    var canvasId: String
    var nodeId: String
    var artifactId: String
    /// Stable key for the logical artifact slot. Matches
    /// `PlannerStore.sameArtifactSlot` (canvasId|nodeId|normalized-reference).
    var artifactSlotKey: String
    var payloadRef: String
    /// Inline payload mirror for small (<=64KB) artifacts; large payloads
    /// live at `payloadRef`. Matches the desktop's 64 KB inline cap in
    /// `PlannerArtifactStorage.inlinePayloadLimitBytes`.
    var payloadInline: BoardJSONValue?
    var inputSnapshot: PlannerArtifactInputSnapshot?
    var displayStrategy: PlannerArtifactDisplayStrategy
    var forceNewVersion: Bool
    var submittedBy: String?
    var submittedByKind: PlannerArtifactVersionSubmitterKind
    var metadata: BoardJSONValue?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case versionId = "version_id"
        case parentVersionId = "parent_version_id"
        case canvasId = "canvas_id"
        case nodeId = "node_id"
        case artifactId = "artifact_id"
        case artifactSlotKey = "artifact_slot_key"
        case payloadRef = "payload_ref"
        case payloadInline = "payload_inline"
        case inputSnapshot = "input_snapshot"
        case displayStrategy = "display_strategy"
        case forceNewVersion = "force_new_version"
        case submittedBy = "submitted_by"
        case submittedByKind = "submitted_by_kind"
        case metadata
        case createdAt = "created_at"
    }
}

struct PlannerGraphEdge: Codable, Equatable {
    var id: String
    var sourceNodeId: String
    var targetNodeId: String
    var kind: String
}

struct PlannerWorkflowTemplate: Codable, Equatable {
    var id: String
    var title: String
    var activePhase: String
    var nodes: [PlanningNode]
    var artifacts: [PlannerArtifact]
}

struct PlannerGraphState: Codable, Equatable {
    var canvas: PlanningCanvas
    var nodes: [PlanningNode]
    var states: [NodeStateSnapshot]
    var proposals: [PlanProposal]
    var access: PlannerAccess
    var activities: [PlannerActivity]
    var events: [PlannerEvent]
    var artifacts: [PlannerArtifact]
    var edges: [PlannerGraphEdge]
}

enum PlannerCanvasRole: String, Codable, Equatable {
    case owner
    case doer
    case viewer
    case suggestion
}

struct PlannerAccess: Codable, Equatable {
    var actorId: String
    var role: PlannerCanvasRole
    var canCreateProposal: Bool
    var canApproveProposal: Bool
    var canApplyProposal: Bool
    var canRejectProposal: Bool
    var canUpdateAssignedNode: Bool
}

struct PlannerActivity: Codable, Equatable {
    var userId: String
    var displayName: String
    var currentCanvasId: String
    var selectedNodeId: String?
    var selectedSessionId: String?
    var lastActiveAt: Date
}

final class PlannerActivityStore {
    static let shared = PlannerActivityStore()

    private let lock = NSLock()
    private var activitiesByUserId: [String: PlannerActivity] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 90) {
        self.ttl = ttl
    }

    @discardableResult
    func heartbeat(
        userId: String,
        displayName: String,
        currentCanvasId: String,
        selectedNodeId: String?,
        selectedSessionId: String?,
        now: Date = Date()
    ) -> PlannerActivity {
        let activity = PlannerActivity(
            userId: userId,
            displayName: displayName,
            currentCanvasId: currentCanvasId,
            selectedNodeId: selectedNodeId,
            selectedSessionId: selectedSessionId,
            lastActiveAt: now
        )
        lock.lock()
        activitiesByUserId[userId] = activity
        pruneLocked(now: now)
        lock.unlock()
        return activity
    }

    func activities(
        for canvasId: String,
        fallback: PlannerActivity,
        now: Date = Date()
    ) -> [PlannerActivity] {
        lock.lock()
        pruneLocked(now: now)
        var values = activitiesByUserId.values
            .filter { $0.currentCanvasId == canvasId }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        if !values.contains(where: { $0.userId == fallback.userId }) {
            values.insert(fallback, at: 0)
        }
        lock.unlock()
        return values
    }

    func reset() {
        lock.lock()
        activitiesByUserId.removeAll()
        lock.unlock()
    }

    private func pruneLocked(now: Date) {
        activitiesByUserId = activitiesByUserId.filter { _, activity in
            now.timeIntervalSince(activity.lastActiveAt) <= ttl
        }
    }
}

struct PlanningNode: Codable, Equatable {
    var id: String
    var canvasId: String
    var title: String
    var schema: NodeSchema
    var contextSources: [ContextSource]
    var executionMode: ExecutionMode
    var executorType: ExecutorType
    var doerId: String
    var status: PlanningNodeStatus
    var sessionId: String?
    var chatThreadId: String?
    var source: PlanningNodeSource?
    var dependsOnNodeIds: [String]?
    var subCanvasId: String?
    var nodeKind: PlanningNodeKind?
    var layout: PlannerNodeLayout?
    var trigger: PlannerNodeTrigger?
    var schedule: PlannerNodeSchedule?
    var gate: PlannerNodeGate?
    var dispatch: PlannerNodeDispatch?
    var approvers: [String]?
    var artifactRefs: [String]?
    var eventRefs: [String]?
    var workflowRunState: PlannerWorkflowRunState?
    var blockedReason: String?
    /// Set by `PlannerStore.submitNodeOutput` whenever an agent explicitly
    /// submits a terminal-ish status (done / blocked / needsReview). While
    /// non-nil, `applySessionRunStateLocked` treats the node as latched and
    /// refuses to overwrite its `status` / `workflowRunState` /
    /// `blockedReason` from transient session-status mirrors (e.g. Claude
    /// returning to idle right after `submit_node_output blocked`). Cleared
    /// on re-dispatch / abandon so a fresh session can take over.
    var outputSubmittedAt: Date?

    init(
        id: String,
        canvasId: String,
        title: String,
        schema: NodeSchema,
        contextSources: [ContextSource],
        executionMode: ExecutionMode,
        executorType: ExecutorType,
        doerId: String,
        status: PlanningNodeStatus,
        sessionId: String? = nil,
        chatThreadId: String? = nil,
        source: PlanningNodeSource? = .planner,
        dependsOnNodeIds: [String]? = nil,
        subCanvasId: String? = nil,
        nodeKind: PlanningNodeKind? = .step,
        layout: PlannerNodeLayout? = nil,
        trigger: PlannerNodeTrigger? = nil,
        schedule: PlannerNodeSchedule? = nil,
        gate: PlannerNodeGate? = nil,
        dispatch: PlannerNodeDispatch? = nil,
        approvers: [String]? = nil,
        artifactRefs: [String]? = nil,
        eventRefs: [String]? = nil,
        workflowRunState: PlannerWorkflowRunState? = nil,
        blockedReason: String? = nil,
        outputSubmittedAt: Date? = nil
    ) {
        self.id = id
        self.canvasId = canvasId
        self.title = title
        self.schema = schema
        self.contextSources = contextSources
        self.executionMode = executionMode
        self.executorType = executorType
        self.doerId = doerId
        self.status = status
        self.sessionId = sessionId
        self.chatThreadId = chatThreadId
        self.source = source
        self.dependsOnNodeIds = dependsOnNodeIds
        self.subCanvasId = subCanvasId
        self.nodeKind = nodeKind
        self.layout = layout
        self.trigger = trigger
        self.schedule = schedule
        self.gate = gate
        self.dispatch = dispatch
        self.approvers = approvers
        self.artifactRefs = artifactRefs
        self.eventRefs = eventRefs
        self.workflowRunState = workflowRunState
        self.blockedReason = blockedReason
        self.outputSubmittedAt = outputSubmittedAt
    }

    // MARK: - Workflow guidance (Phase 6)

    /// Stored keys. `nextAction` is intentionally absent — it is a *derived*
    /// guidance string (see `nextAction`), not part of the on-disk shape, so
    /// it must never be decoded or persisted. `encode(to:)` adds it for the
    /// API response only.
    private enum CodingKeys: String, CodingKey {
        case id, canvasId, title, schema, contextSources, executionMode
        case executorType, doerId, status, sessionId, chatThreadId, source
        case dependsOnNodeIds, subCanvasId, nodeKind, layout, trigger, gate
        case schedule, dispatch, approvers, artifactRefs, eventRefs, workflowRunState
        case blockedReason, outputSubmittedAt
    }

    /// Extra (encode-only) keys layered on top of the stored shape.
    private enum DerivedCodingKeys: String, CodingKey {
        case nextAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        canvasId = try container.decode(String.self, forKey: .canvasId)
        title = try container.decode(String.self, forKey: .title)
        schema = try container.decode(NodeSchema.self, forKey: .schema)
        contextSources = try container.decode([ContextSource].self, forKey: .contextSources)
        executionMode = try container.decode(ExecutionMode.self, forKey: .executionMode)
        executorType = try container.decode(ExecutorType.self, forKey: .executorType)
        doerId = try container.decode(String.self, forKey: .doerId)
        status = try container.decode(PlanningNodeStatus.self, forKey: .status)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        chatThreadId = try container.decodeIfPresent(String.self, forKey: .chatThreadId)
        source = try container.decodeIfPresent(PlanningNodeSource.self, forKey: .source)
        dependsOnNodeIds = try container.decodeIfPresent([String].self, forKey: .dependsOnNodeIds)
        subCanvasId = try container.decodeIfPresent(String.self, forKey: .subCanvasId)
        nodeKind = try container.decodeIfPresent(PlanningNodeKind.self, forKey: .nodeKind)
        layout = try container.decodeIfPresent(PlannerNodeLayout.self, forKey: .layout)
        trigger = try container.decodeIfPresent(PlannerNodeTrigger.self, forKey: .trigger)
        schedule = try container.decodeIfPresent(PlannerNodeSchedule.self, forKey: .schedule)
        gate = try container.decodeIfPresent(PlannerNodeGate.self, forKey: .gate)
        dispatch = try container.decodeIfPresent(PlannerNodeDispatch.self, forKey: .dispatch)
        approvers = try container.decodeIfPresent([String].self, forKey: .approvers)
        artifactRefs = try container.decodeIfPresent([String].self, forKey: .artifactRefs)
        eventRefs = try container.decodeIfPresent([String].self, forKey: .eventRefs)
        workflowRunState = try container.decodeIfPresent(PlannerWorkflowRunState.self, forKey: .workflowRunState)
        blockedReason = try container.decodeIfPresent(String.self, forKey: .blockedReason)
        outputSubmittedAt = try container.decodeIfPresent(Date.self, forKey: .outputSubmittedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(canvasId, forKey: .canvasId)
        try container.encode(title, forKey: .title)
        try container.encode(schema, forKey: .schema)
        try container.encode(contextSources, forKey: .contextSources)
        try container.encode(executionMode, forKey: .executionMode)
        try container.encode(executorType, forKey: .executorType)
        try container.encode(doerId, forKey: .doerId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(chatThreadId, forKey: .chatThreadId)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(dependsOnNodeIds, forKey: .dependsOnNodeIds)
        try container.encodeIfPresent(subCanvasId, forKey: .subCanvasId)
        try container.encodeIfPresent(nodeKind, forKey: .nodeKind)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encodeIfPresent(dispatch, forKey: .dispatch)
        try container.encodeIfPresent(approvers, forKey: .approvers)
        try container.encodeIfPresent(artifactRefs, forKey: .artifactRefs)
        try container.encodeIfPresent(eventRefs, forKey: .eventRefs)
        try container.encodeIfPresent(workflowRunState, forKey: .workflowRunState)
        try container.encodeIfPresent(blockedReason, forKey: .blockedReason)
        try container.encodeIfPresent(outputSubmittedAt, forKey: .outputSubmittedAt)
        // Derived guidance — encode-only, never decoded back.
        var derived = encoder.container(keyedBy: DerivedCodingKeys.self)
        try derived.encodeIfPresent(nextAction, forKey: .nextAction)
    }

    /// A short imperative "what to do next" guidance line for this node,
    /// derived purely from `workflowRunState` plus node context (gate,
    /// review mode, bound session). Pure function of stored fields — never
    /// persisted, never set by the LLM/adapter. `nil` for nodes that carry
    /// no actionable workflow state (e.g. a node with no `workflowRunState`).
    var nextAction: String? {
        PlannerWorkflowGuidance.nextAction(for: self, blockers: nil)
    }
}

/// Derives the per-node workflow-guidance string (Phase 6). Pure, stateless —
/// the single source of truth so the graph-state response and the workspace
/// monitor agree. Guidance is computed from `workflowRunState` and node
/// context; it is never stored or proposed.
enum PlannerWorkflowGuidance {
    /// - Parameters:
    ///   - node: the planning node to derive guidance for.
    ///   - blockers: optional blocker list from the node's `NodeStateSnapshot`.
    ///     When provided it sharpens `pending`/`failed` guidance; pass `nil`
    ///     when only the node is in hand.
    static func nextAction(for node: PlanningNode, blockers: [String]?) -> String? {
        // Only `step` nodes carry actionable workflow guidance. Session /
        // artifact / sub-canvas nodes are tracked elsewhere.
        if let kind = node.nodeKind, kind != .step { return nil }
        guard let runState = node.workflowRunState else { return nil }

        let hasGate = node.gate != nil
        let hasBlockers = !(blockers?.isEmpty ?? true)
        let requiresHumanCompletion = node.executionMode == .human
        let hasSession = node.sessionId != nil
        let hasDependencies = !(node.dependsOnNodeIds?.isEmpty ?? true)

        switch runState {
        case .readyToStart:
            return "Ready — start work or attach an existing session."
        case .awaitingInput:
            return "Waiting for your input — open the session and reply."
        case .gateWait:
            return "Review the output and confirm or send it back."
        case .failed:
            if hasBlockers {
                return "Failed — clear the blockers, then start work again."
            }
            return "Failed — inspect the failure and start work again."
        case .pending:
            if hasDependencies {
                return "Waiting on an upstream step — start work once it clears."
            }
            return "Ready — start work on this step."
        case .dispatched:
            if hasSession {
                return "Started — open the session to follow progress."
            }
            return "Starting — waiting for the session to spin up."
        case .running:
            return "In progress — open the session to monitor work."
        case .done:
            if hasGate || requiresHumanCompletion {
                return "Done — verify the delivery evidence."
            }
            return "Done — confirm the artifact is attached."
        }
    }
}

enum PlanProposalStatus: String, Codable, Equatable {
    case pending
    case approved
    case applied
    case rejected
}

struct PlanArtifactDraft: Codable, Equatable {
    var nodeId: String?
    var kind: PlannerArtifactKind
    var title: String
    var reference: String
    var status: String?
    var payload: BoardJSONValue?
}

struct PlanChange: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case addNode
        case updateNode
        case attachArtifact
        /// ENG-2 bonus: refine the bound session's next-turn prompt without
        /// mutating canvas schema. `nodeId` identifies the node; the
        /// directive text rides in `title`. Apply-side routes it to the
        /// node's bound session via the operator channel.
        case refineSessionPrompt
    }

    var kind: Kind
    var node: PlanningNode?
    var nodeId: String?
    var title: String?
    var status: PlanningNodeStatus?
    var schema: NodeSchema?
    var contextSources: [ContextSource]?
    var dependsOnNodeIds: [String]?
    var subCanvasId: String?
    var nodeKind: PlanningNodeKind?
    var layout: PlannerNodeLayout?
    var trigger: PlannerNodeTrigger?
    var schedule: PlannerNodeSchedule?
    var executionMode: ExecutionMode?
    var clearGate: Bool?
    var gate: PlannerNodeGate?
    var dispatch: PlannerNodeDispatch?
    var approvers: [String]?
    var artifactRefs: [String]?
    var eventRefs: [String]?
    var workflowRunState: PlannerWorkflowRunState?
    var sessionId: String?
    var chatThreadId: String?
    var source: PlanningNodeSource?
    var doerId: String?
    var artifact: PlanArtifactDraft?

    private enum CodingKeys: String, CodingKey {
        case kind, node, nodeId, title, status, schema, contextSources
        case dependsOnNodeIds, subCanvasId, nodeKind, layout, trigger, schedule, gate
        case executionMode, clearGate, dispatch, approvers, artifactRefs, eventRefs, workflowRunState
        case sessionId, chatThreadId, source, doerId, artifact
    }

    init(
        kind: Kind,
        node: PlanningNode?,
        nodeId: String?,
        title: String?,
        status: PlanningNodeStatus?,
        schema: NodeSchema? = nil,
        contextSources: [ContextSource]? = nil,
        dependsOnNodeIds: [String]? = nil,
        subCanvasId: String? = nil,
        nodeKind: PlanningNodeKind? = nil,
        layout: PlannerNodeLayout? = nil,
        trigger: PlannerNodeTrigger? = nil,
        schedule: PlannerNodeSchedule? = nil,
        executionMode: ExecutionMode? = nil,
        clearGate: Bool? = nil,
        gate: PlannerNodeGate? = nil,
        dispatch: PlannerNodeDispatch? = nil,
        approvers: [String]? = nil,
        artifactRefs: [String]? = nil,
        eventRefs: [String]? = nil,
        workflowRunState: PlannerWorkflowRunState? = nil,
        sessionId: String? = nil,
        chatThreadId: String? = nil,
        source: PlanningNodeSource? = nil,
        doerId: String? = nil,
        artifact: PlanArtifactDraft? = nil
    ) {
        self.kind = kind
        self.node = node
        self.nodeId = nodeId
        self.title = title
        self.status = status
        self.schema = schema
        self.contextSources = contextSources
        self.dependsOnNodeIds = dependsOnNodeIds
        self.subCanvasId = subCanvasId
        self.nodeKind = nodeKind
        self.layout = layout
        self.trigger = trigger
        self.schedule = schedule
        self.executionMode = executionMode
        self.clearGate = clearGate
        self.gate = gate
        self.dispatch = dispatch
        self.approvers = approvers
        self.artifactRefs = artifactRefs
        self.eventRefs = eventRefs
        self.workflowRunState = workflowRunState
        self.sessionId = sessionId
        self.chatThreadId = chatThreadId
        self.source = source
        self.doerId = doerId
        self.artifact = artifact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        node = try container.decodeIfPresent(PlanningNode.self, forKey: .node)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        status = try container.decodeIfPresent(PlanningNodeStatus.self, forKey: .status)
        schema = try container.decodeIfPresent(NodeSchema.self, forKey: .schema)
        contextSources = try container.decodeIfPresent([ContextSource].self, forKey: .contextSources)
        dependsOnNodeIds = try container.decodeIfPresent([String].self, forKey: .dependsOnNodeIds)
        subCanvasId = try container.decodeIfPresent(String.self, forKey: .subCanvasId)
        nodeKind = try container.decodeIfPresent(PlanningNodeKind.self, forKey: .nodeKind)
        layout = try container.decodeIfPresent(PlannerNodeLayout.self, forKey: .layout)
        trigger = try container.decodeIfPresent(PlannerNodeTrigger.self, forKey: .trigger)
        schedule = try container.decodeIfPresent(PlannerNodeSchedule.self, forKey: .schedule)
        executionMode = try container.decodeIfPresent(ExecutionMode.self, forKey: .executionMode)
        clearGate = try container.decodeIfPresent(Bool.self, forKey: .clearGate)
        gate = try container.decodeIfPresent(PlannerNodeGate.self, forKey: .gate)
        dispatch = try container.decodeIfPresent(PlannerNodeDispatch.self, forKey: .dispatch)
        approvers = try container.decodeIfPresent([String].self, forKey: .approvers)
        artifactRefs = try container.decodeIfPresent([String].self, forKey: .artifactRefs)
        eventRefs = try container.decodeIfPresent([String].self, forKey: .eventRefs)
        workflowRunState = try container.decodeIfPresent(PlannerWorkflowRunState.self, forKey: .workflowRunState)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        chatThreadId = try container.decodeIfPresent(String.self, forKey: .chatThreadId)
        source = try container.decodeIfPresent(PlanningNodeSource.self, forKey: .source)
        doerId = try container.decodeIfPresent(String.self, forKey: .doerId)
        artifact = try container.decodeIfPresent(PlanArtifactDraft.self, forKey: .artifact)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(node, forKey: .node)
        try container.encodeIfPresent(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(schema, forKey: .schema)
        try container.encodeIfPresent(contextSources, forKey: .contextSources)
        try container.encodeIfPresent(dependsOnNodeIds, forKey: .dependsOnNodeIds)
        try container.encodeIfPresent(subCanvasId, forKey: .subCanvasId)
        try container.encodeIfPresent(nodeKind, forKey: .nodeKind)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(executionMode, forKey: .executionMode)
        try container.encodeIfPresent(clearGate, forKey: .clearGate)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encodeIfPresent(dispatch, forKey: .dispatch)
        try container.encodeIfPresent(approvers, forKey: .approvers)
        try container.encodeIfPresent(artifactRefs, forKey: .artifactRefs)
        try container.encodeIfPresent(eventRefs, forKey: .eventRefs)
        try container.encodeIfPresent(workflowRunState, forKey: .workflowRunState)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(chatThreadId, forKey: .chatThreadId)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(doerId, forKey: .doerId)
        try container.encodeIfPresent(artifact, forKey: .artifact)
    }

    static func addNode(_ node: PlanningNode) -> PlanChange {
        PlanChange(kind: .addNode, node: node, nodeId: nil, title: nil, status: nil)
    }

    /// ENG-2 bonus: build a `refineSessionPrompt` change. The directive is
    /// stored in `title` (lightweight reuse of the existing field — no new
    /// codable surface needed).
    static func refineSessionPrompt(nodeId: String, directive: String) -> PlanChange {
        PlanChange(
            kind: .refineSessionPrompt,
            node: nil,
            nodeId: nodeId,
            title: directive,
            status: nil
        )
    }

    static func attachArtifact(
        nodeId: String,
        kind: PlannerArtifactKind,
        title: String,
        reference: String,
        status: String = "attached",
        payload: BoardJSONValue? = nil
    ) -> PlanChange {
        PlanChange(
            kind: .attachArtifact,
            node: nil,
            nodeId: nodeId,
            title: nil,
            status: nil,
            artifact: PlanArtifactDraft(
                nodeId: nodeId,
                kind: kind,
                title: title,
                reference: reference,
                status: status,
                payload: payload
            )
        )
    }

    static func updateNode(
        id: String,
        title: String? = nil,
        status: PlanningNodeStatus? = nil,
        schema: NodeSchema? = nil,
        contextSources: [ContextSource]? = nil,
        dependsOnNodeIds: [String]? = nil,
        subCanvasId: String? = nil,
        nodeKind: PlanningNodeKind? = nil,
        layout: PlannerNodeLayout? = nil,
        trigger: PlannerNodeTrigger? = nil,
        executionMode: ExecutionMode? = nil,
        clearGate: Bool? = nil,
        gate: PlannerNodeGate? = nil,
        dispatch: PlannerNodeDispatch? = nil,
        approvers: [String]? = nil,
        artifactRefs: [String]? = nil,
        eventRefs: [String]? = nil,
        workflowRunState: PlannerWorkflowRunState? = nil,
        sessionId: String? = nil,
        chatThreadId: String? = nil,
        source: PlanningNodeSource? = nil,
        doerId: String? = nil
    ) -> PlanChange {
        PlanChange(
            kind: .updateNode,
            node: nil,
            nodeId: id,
            title: title,
            status: status,
            schema: schema,
            contextSources: contextSources,
            dependsOnNodeIds: dependsOnNodeIds,
            subCanvasId: subCanvasId,
            nodeKind: nodeKind,
            layout: layout,
            trigger: trigger,
            executionMode: executionMode,
            clearGate: clearGate,
            gate: gate,
            dispatch: dispatch,
            approvers: approvers,
            artifactRefs: artifactRefs,
            eventRefs: eventRefs,
            workflowRunState: workflowRunState,
            sessionId: sessionId,
            chatThreadId: chatThreadId,
            source: source,
            doerId: doerId
        )
    }
}

struct PlanProposal: Codable, Equatable {
    var id: String
    var canvasId: String
    var summary: String
    var changes: [PlanChange]
    var status: PlanProposalStatus
}

enum NodeRunState: String, Codable, Equatable {
    case draft
    case ready
    case working
    case blocked
    case done
}

struct NodeStateSnapshot: Codable, Equatable {
    var nodeId: String
    var runState: NodeRunState
    var blockers: [String]
    var artifactRefs: [String]
    var needsOwnerReview: Bool
}

struct SubCanvasSummary: Codable, Equatable {
    var subCanvasId: String
    var runState: NodeRunState
    var blockers: [String]
    var pendingProposalCount: Int
    var needsOwnerReview: Bool
}

enum PlannerEventType: String, Codable, Equatable {
    case nodeCreated = "node.created"
    case nodeUpdated = "node.updated"
    case nodeStateChanged = "node.state_changed"
    case nodeOutputSubmitted = "node.output_submitted"
    case proposalCreated = "proposal.created"
    case proposalApproved = "proposal.approved"
    case proposalApplied = "proposal.applied"
    case proposalRejected = "proposal.rejected"
    case artifactAttached = "artifact.attached"
}

enum PlannerNodeOutputStatus: String, Codable, Equatable {
    case done
    case blocked
    case needsReview = "needs_review"
}

enum PlannerNodeOutputNext: String, Codable, Equatable {
    case complete
    case blocked
    case needsOwnerReview = "needs_owner_review"
}

struct PlannerNodeOutputMessage: Codable, Equatable {
    var summary: String
    var routeTo: [String]
}

struct PlannerNodeOutputArtifact: Codable, Equatable {
    var kind: PlannerArtifactKind
    var title: String
    var reference: String
    var payload: BoardJSONValue?
    var routeTo: [String]
}

struct PlannerNodeOutput: Codable, Equatable {
    var nodeId: String
    var status: PlannerNodeOutputStatus
    var message: PlannerNodeOutputMessage?
    var artifacts: [PlannerNodeOutputArtifact]
    var next: PlannerNodeOutputNext
    /// ENG-2 / ENG-3 · When `true`, the store ALWAYS appends a new version on
    /// this submit — even if the node is already in a terminal state and the
    /// artifact slot has no observable change. UI "re-run" / "force re-fetch"
    /// wires here. Defaults to `false`. The flag is recorded on the version
    /// row so the UI can distinguish a user-initiated re-run from an
    /// agent-driven follow-up.
    var forceNewVersion: Bool

    enum CodingKeys: String, CodingKey {
        case nodeId
        case status
        case message
        case artifacts
        case next
        case forceNewVersion = "force_new_version"
    }

    init(
        nodeId: String,
        status: PlannerNodeOutputStatus,
        message: PlannerNodeOutputMessage? = nil,
        artifacts: [PlannerNodeOutputArtifact] = [],
        next: PlannerNodeOutputNext,
        forceNewVersion: Bool = false
    ) {
        self.nodeId = nodeId
        self.status = status
        self.message = message
        self.artifacts = artifacts
        self.next = next
        self.forceNewVersion = forceNewVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.nodeId = try container.decode(String.self, forKey: .nodeId)
        self.status = try container.decode(PlannerNodeOutputStatus.self, forKey: .status)
        self.message = try container.decodeIfPresent(PlannerNodeOutputMessage.self, forKey: .message)
        self.artifacts = try container.decodeIfPresent([PlannerNodeOutputArtifact].self, forKey: .artifacts) ?? []
        self.next = try container.decode(PlannerNodeOutputNext.self, forKey: .next)
        // Accept both camelCase and snake_case for legacy callers / hand-rolled
        // JSON. `force_new_version` is canonical (matches ENG-2 / ENG-3 spec).
        if let v = try container.decodeIfPresent(Bool.self, forKey: .forceNewVersion) {
            self.forceNewVersion = v
        } else {
            self.forceNewVersion = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodeId, forKey: .nodeId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encode(artifacts, forKey: .artifacts)
        try c.encode(next, forKey: .next)
        try c.encode(forceNewVersion, forKey: .forceNewVersion)
    }
}

struct PlannerRouteTarget: Codable, Equatable {
    var id: String
    var label: String
    var kind: String
    var hasDoer: Bool
    var hasSession: Bool
}

struct PlannerNodeContract: Codable, Equatable {
    var canvas: PlanningCanvas
    var node: PlanningNode
    var upstreamNodes: [PlanningNode]
    var downstreamNodes: [PlanningNode]
    var allowedRouteTargets: [PlannerRouteTarget]
    var expectedArtifactKinds: [PlannerArtifactKind]
    var inlinePayloadLimitBytes: Int
    var artifactPayloadTypes: [PlannerArtifactPayloadType]
    var completionCriteria: [String]
    /// v2 contract block — three-source input model + cardinality/payload_kind
    /// output model. See `NodeContractV2`. Embedded inside the existing
    /// `PlannerNodeContract` envelope so v1 consumers keep working while v2
    /// consumers (ENG-2/3/4 and the UI) can opt in by reading `v2`.
    var v2: NodeContractV2
}

// MARK: - Node Contract v2 (ENG-1)
//
// The v2 contract redefines node input/output to match the post-meeting decisions:
//   • input is a 3-source合流 (upstream output, external data sources, dialogue补齐)
//     — not a single upstream stream
//   • output is always full (no increment vs full encoding)
//   • `replace_strategy` is removed; replace is a display-time concept (ENG-3)
//
// The v1 envelope (`PlannerNodeContract`) still wraps the runtime types so
// downstream code can migrate incrementally. Auto-migration from v1 fields
// (`dependsOnNodeIds`, `contextSources`) happens in `NodeContractV2.derive(...)`.

enum NodeContractUpstreamMode: String, Codable, Equatable, CaseIterable {
    /// Workflow-node downchain: the upstream node's full output flows through.
    case passthrough
    /// Sub-canvas inheriting one item from an upstream list output.
    case itemScoped = "item_scoped"
}

struct NodeContractUpstreamInput: Codable, Equatable {
    var mode: NodeContractUpstreamMode
    /// Source node id. `nil` means the canvas root entry (no upstream node).
    var sourceNodeId: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case sourceNodeId = "source_node"
    }
}

struct NodeContractExternalInput: Codable, Equatable {
    /// Connector id (e.g. `"notion"`, `"lark"`, `"gmail"`). Free-form for now;
    /// ENG-1 open question — the canonical enum location is deferred to INT-2.
    var connector: String
    /// Opaque connector-specific reference (e.g. `"db://abc"`, `"doc://xyz"`).
    var ref: String
    /// Bound sync session id, if any. ENG-2 may auto-create this on first run.
    var syncSessionId: String?

    enum CodingKeys: String, CodingKey {
        case connector
        case ref
        case syncSessionId = "sync_session"
    }
}

enum NodeContractDialogueWindowKind: String, Codable, Equatable, CaseIterable {
    case rolling
}

struct NodeContractDialogueWindow: Codable, Equatable {
    var kind: NodeContractDialogueWindowKind
    var nTurns: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case nTurns = "n_turns"
    }
}

struct NodeContractDialogueInput: Codable, Equatable {
    var enabled: Bool
    var window: NodeContractDialogueWindow
}

struct NodeContractInput: Codable, Equatable {
    var upstream: NodeContractUpstreamInput
    var external: [NodeContractExternalInput]
    var dialogue: NodeContractDialogueInput
}

enum NodeContractCardinality: String, Codable, Equatable, CaseIterable {
    case single
    case list
}

enum NodeContractPayloadKind: String, Codable, Equatable, CaseIterable {
    case artifactRef = "artifact_ref"
    case inline
}

struct NodeContractExternalWriteTarget: Codable, Equatable {
    var connector: String
    var ref: String
}

struct NodeContractOutput: Codable, Equatable {
    var cardinality: NodeContractCardinality
    var payloadKind: NodeContractPayloadKind
    var externalWriteTarget: NodeContractExternalWriteTarget?

    enum CodingKeys: String, CodingKey {
        case cardinality
        case payloadKind = "payload_kind"
        case externalWriteTarget = "external_write_target"
    }
}

struct NodeContractV2: Codable, Equatable {
    static let version = 2

    var version: Int
    var input: NodeContractInput
    var output: NodeContractOutput

    enum CodingKeys: String, CodingKey {
        case version
        case input
        case output
    }

    init(input: NodeContractInput, output: NodeContractOutput) {
        self.version = Self.version
        self.input = input
        self.output = output
    }

    init(version: Int, input: NodeContractInput, output: NodeContractOutput) {
        self.version = version
        self.input = input
        self.output = output
    }
}

/// Validation errors for v2 contract / output payloads. The validator is
/// intentionally strict — it rejects v1-style shapes with actionable messages
/// so adapters fail loudly instead of silently dropping fields.
enum NodeContractValidationError: Error, Equatable, LocalizedError {
    case rejectedFieldMapping(String)
    case rejectedReplaceStrategy
    case rejectedIncrementOutput
    case unknownContractVersion(Int)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .rejectedFieldMapping(let detail):
            return "Node Contract v2 rejects v1 field-level input mapping (\(detail)). Inputs are a 3-source合流 (upstream/external/dialogue) — remove per-field bindings and use input.upstream / input.external instead."
        case .rejectedReplaceStrategy:
            return "Node Contract v2 rejects `replace_strategy`. Replace is a display-time concept handled by the version chain (ENG-3); outputs are always full snapshots."
        case .rejectedIncrementOutput:
            return "Node Contract v2 rejects `output.kind: increment`. Outputs are always全量 — submit a full snapshot."
        case .unknownContractVersion(let version):
            return "Unknown node contract version \(version). Supported: v2 (current). v1 contracts auto-migrate at read time."
        case .missingRequiredField(let field):
            return "Node Contract v2 is missing required field `\(field)`."
        }
    }
}

enum NodeContractValidator {
    /// Reject v1-style raw JSON contracts. Inspects unknown keys at the top
    /// level (`replace_strategy`, `field_mapping`, `inputs[].source_field`, …)
    /// and refuses with an actionable error message.
    static func validateRawContract(_ raw: BoardJSONValue?) throws {
        guard let raw = raw, let object = raw.objectValue else { return }
        if object["replace_strategy"] != nil {
            throw NodeContractValidationError.rejectedReplaceStrategy
        }
        if let output = object["output"]?.objectValue,
           let kind = output["kind"]?.stringValue,
           kind.lowercased() == "increment" {
            throw NodeContractValidationError.rejectedIncrementOutput
        }
        // v1 used `field_mapping` / `inputs[].source_field` / `inputs[].target_field`
        // to wire individual fields between nodes. v2 collapses these into the
        // three-source合流 model — reject explicitly so the failure is loud.
        if object["field_mapping"] != nil {
            throw NodeContractValidationError.rejectedFieldMapping("field_mapping at contract root")
        }
        if let inputs = object["inputs"]?.arrayValue {
            for entry in inputs {
                guard let entryObj = entry.objectValue else { continue }
                if entryObj["source_field"] != nil || entryObj["target_field"] != nil {
                    throw NodeContractValidationError.rejectedFieldMapping("inputs[].source_field / inputs[].target_field")
                }
            }
        }
        if let version = object["version"]?.intValue, version != NodeContractV2.version {
            // v1 had no `version` field; an explicit `version: 1` here is a
            // contract that callers must migrate themselves.
            throw NodeContractValidationError.unknownContractVersion(version)
        }
    }

    /// Reject v1-style raw output payloads. The current submit_node_output
    /// shape never carried `replace_strategy` or `output.kind: increment` —
    /// this guard exists so external adapters / replay scripts can't sneak
    /// them through.
    static func validateRawOutputPayload(_ raw: [String: Any]) throws {
        if raw["replace_strategy"] != nil {
            throw NodeContractValidationError.rejectedReplaceStrategy
        }
        if let output = raw["output"] as? [String: Any],
           let kind = output["kind"] as? String,
           kind.lowercased() == "increment" {
            throw NodeContractValidationError.rejectedIncrementOutput
        }
        if let outputKind = raw["output_kind"] as? String, outputKind.lowercased() == "increment" {
            throw NodeContractValidationError.rejectedIncrementOutput
        }
    }
}

extension NodeContractV2 {
    /// Default dialogue-window size for derived contracts. Picked as a
    /// conservative round number; the real default lives in session config
    /// once ENG-2 wires runtime input merging through.
    static let defaultDialogueTurns = 20

    /// Auto-migrate / derive a v2 contract from v1 fields on a `PlanningNode`.
    ///
    /// Mapping:
    ///   • `dependsOnNodeIds.first`  → `input.upstream.source_node`
    ///     (sub-canvas nodes default to `item_scoped`; everything else is
    ///     `passthrough`)
    ///   • `contextSources` of kind `.document` / `.repository` / `.web` /
    ///     `.artifact` → `input.external[]` (best-effort connector inference
    ///     from the reference scheme; `lossy` entries are logged via the
    ///     returned `warnings` list so callers can surface them)
    ///   • dialogue defaults to enabled + rolling 20 turns
    ///   • `output.cardinality` defaults to `list` for `nodeKind == .external`
    ///     (likely a data source) and `single` otherwise
    ///   • `output.payload_kind` defaults to `artifact_ref` — inline-only
    ///     legacy nodes will keep working, just labeled `artifact_ref` until
    ///     they're re-declared explicitly
    static func derive(from node: PlanningNode) -> (contract: NodeContractV2, warnings: [String]) {
        var warnings: [String] = []

        let upstreamMode: NodeContractUpstreamMode = (node.nodeKind == .subCanvas) ? .itemScoped : .passthrough
        let sourceNodeId = node.dependsOnNodeIds?.first
        if let deps = node.dependsOnNodeIds, deps.count > 1 {
            warnings.append("Node \(node.id) had \(deps.count) upstream deps; v2 upstream.source_node keeps only \(deps.first ?? "<none>") — declare extras as external inputs.")
        }
        let upstream = NodeContractUpstreamInput(mode: upstreamMode, sourceNodeId: sourceNodeId)

        var external: [NodeContractExternalInput] = []
        for source in node.contextSources where source.kind != .chatHistory {
            let connector = inferConnector(from: source.reference)
            if connector == nil {
                warnings.append("ContextSource '\(source.title)' has reference '\(source.reference)' — could not infer connector; left as opaque.")
            }
            external.append(NodeContractExternalInput(
                connector: connector ?? "unknown",
                ref: source.reference,
                syncSessionId: nil
            ))
        }

        let dialogue = NodeContractDialogueInput(
            enabled: true,
            window: NodeContractDialogueWindow(kind: .rolling, nTurns: defaultDialogueTurns)
        )

        let cardinality: NodeContractCardinality = (node.nodeKind == .external) ? .list : .single
        let output = NodeContractOutput(
            cardinality: cardinality,
            payloadKind: .artifactRef,
            externalWriteTarget: nil
        )

        let v2 = NodeContractV2(
            input: NodeContractInput(upstream: upstream, external: external, dialogue: dialogue),
            output: output
        )
        return (v2, warnings)
    }

    /// Best-effort connector inference from a context-source reference. This
    /// is a temporary heuristic until INT-2 lands a real connector enum.
    private static func inferConnector(from reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixToConnector: [(String, String)] = [
            ("notion://", "notion"),
            ("notion.so", "notion"),
            ("lark://", "lark"),
            ("feishu.cn", "lark"),
            ("larksuite.com", "lark"),
            ("gmail:", "gmail"),
            ("mailto:", "gmail"),
            ("https://github.com", "github"),
            ("git@github.com", "github"),
            ("github://", "github"),
            ("https://docs.google.com", "google-docs"),
            ("gdoc://", "google-docs"),
            ("file://", "file"),
            ("meee2-artifact://", "meee2-artifact"),
            ("http://", "http"),
            ("https://", "http")
        ]
        for (prefix, connector) in prefixToConnector where trimmed.hasPrefix(prefix) {
            return connector
        }
        return nil
    }
}

struct PlannerOutputRoute: Codable, Equatable {
    var target: String
    var targetNodeId: String?
    var targetSessionId: String?
    var routedMessage: String?
    var artifactRefs: [String]
}

struct PlannerNodeOutputResult: Codable, Equatable {
    var graph: PlannerGraphState
    var routes: [PlannerOutputRoute]
    var hint: String?
    /// ENG-2 / E2.1: id of the version appended by this submit. UI can use
    /// this to navigate to the new version's pane.
    var versionId: String?
    /// ENG-2 / E2.1: 1-based version index within `(canvasId, nodeId)`.
    var versionIndex: Int?
    /// ENG-2 / E2.2: downstream nodes that flipped to readyToStart and are
    /// marked auto-mode — BoardAPI auto-dispatches them so users see "session
    /// creating…" without a manual click. UI surfaces the same node ids so it
    /// can render the affordance immediately on the optimistic path.
    var autoDispatchedNodeIds: [String]?
}

struct PlannerEvent: Codable, Equatable {
    var id: String
    var canvasId: String
    var type: PlannerEventType
    var nodeId: String?
    var proposalId: String?
    var summary: String
    var artifactRefs: [String]
    var createdAt: Date
}

enum PlannerCrossCanvasSuggestionStatus: String, Codable, Equatable {
    case pending
    case accepted
    case rejected
}

struct PlannerCrossCanvasSuggestion: Codable, Equatable {
    var id: String
    var sourceCanvasId: String
    var targetCanvasId: String
    var sourcePlannerId: String
    var targetOwnerId: String
    var suggestedProposal: PlanProposal
    var reason: String
    var status: PlannerCrossCanvasSuggestionStatus
}

enum PlannerMonitorItemKind: String, Codable, Equatable {
    case node
    case proposal
    case delivery
}

struct PlannerMonitorItem: Codable, Equatable {
    var id: String
    var kind: PlannerMonitorItemKind
    var canvasId: String
    var canvasTitle: String
    var nodeId: String?
    var nodeTitle: String?
    var sessionId: String?
    var deliveryId: String?
    var proposalId: String?
    var proposalStatus: PlanProposalStatus?
    var summary: String
    var runState: NodeRunState?
    var blockers: [String]
    var needsOwnerReview: Bool
    var doerId: String?
    var riskRank: Int
    var evidenceCount: Int
    var updatedAt: Date?
    /// Derived workflow-guidance line for `node`-kind items (Phase 6). `nil`
    /// for proposal items or nodes with no actionable workflow state.
    var nextAction: String?

    init(
        id: String,
        kind: PlannerMonitorItemKind,
        canvasId: String,
        canvasTitle: String,
        nodeId: String?,
        nodeTitle: String?,
        sessionId: String? = nil,
        deliveryId: String? = nil,
        proposalId: String?,
        proposalStatus: PlanProposalStatus?,
        summary: String,
        runState: NodeRunState?,
        blockers: [String],
        needsOwnerReview: Bool,
        doerId: String?,
        riskRank: Int,
        evidenceCount: Int = 0,
        updatedAt: Date? = nil,
        nextAction: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.canvasId = canvasId
        self.canvasTitle = canvasTitle
        self.nodeId = nodeId
        self.nodeTitle = nodeTitle
        self.sessionId = sessionId
        self.deliveryId = deliveryId
        self.proposalId = proposalId
        self.proposalStatus = proposalStatus
        self.summary = summary
        self.runState = runState
        self.blockers = blockers
        self.needsOwnerReview = needsOwnerReview
        self.doerId = doerId
        self.riskRank = riskRank
        self.evidenceCount = evidenceCount
        self.updatedAt = updatedAt
        self.nextAction = nextAction
    }
}

struct PlannerMonitorState: Codable, Equatable {
    var generatedAt: Date
    var items: [PlannerMonitorItem]
}

enum PlannerCoreError: LocalizedError, Equatable {
    case invalidPlannerProposalJSON
    case proposalNotApproved
    case proposalNotFound(String)
    case canvasMismatch(expected: String, actual: String)
    case emptyProposalChanges
    case missingNodeForAdd
    case missingNodeId
    case nodeNotFound(String)
    case updateNodeNoFields(String)
    case canvasNotFound(String)
    case runNotFound(String)
    case monitorClearNotAllowed(String)
    case permissionDenied(action: String, role: PlannerCanvasRole)
    /// A change references a node whose id belongs to a different canvas.
    case crossCanvasNodeReference(nodeId: String, expectedCanvas: String)
    /// A change carries a node `kind` outside the known PlanningNodeKind set.
    case unknownNodeKind(String)
    /// A change carries a change `kind` outside the known PlanChange.Kind set.
    case unknownChangeKind(String)
    case invalidNodeOutput(String)
    case activeSessionExists(nodeId: String)

    var errorDescription: String? {
        switch self {
        case .invalidPlannerProposalJSON:
            return "meee2 AI proposal output is not valid JSON"
        case .proposalNotApproved:
            return "plan proposal must be approved before apply"
        case .proposalNotFound(let id):
            return "plan proposal not found: \(id)"
        case .canvasMismatch(let expected, let actual):
            return "proposal canvas mismatch: expected \(expected), got \(actual)"
        case .emptyProposalChanges:
            return "meee2 AI proposal must contain at least one change"
        case .missingNodeForAdd:
            return "addNode change is missing node"
        case .missingNodeId:
            return "updateNode change is missing nodeId"
        case .nodeNotFound(let id):
            return "planning node not found: \(id)"
        case .updateNodeNoFields(let id):
            return "updateNode change for \(id) must set title or status"
        case .canvasNotFound(let id):
            return "planning canvas not found: \(id)"
        case .runNotFound(let id):
            return "workflow run not found: \(id)"
        case .monitorClearNotAllowed(let id):
            return "monitor canvas cannot be cleared: \(id)"
        case .permissionDenied(let action, let role):
            return "meee2 AI \(action) is not allowed for \(role.rawValue)"
        case .crossCanvasNodeReference(let nodeId, let expectedCanvas):
            return "meee2 AI proposal references node \(nodeId) outside canvas \(expectedCanvas)"
        case .unknownNodeKind(let kind):
            return "meee2 AI proposal uses unknown node kind: \(kind)"
        case .unknownChangeKind(let kind):
            return "meee2 AI proposal uses unknown change kind: \(kind)"
        case .invalidNodeOutput(let hint):
            return hint
        case .activeSessionExists(let nodeId):
            return "node \(nodeId) already has an active session; complete or split the node before starting another"
        }
    }
}

enum PlannerPermissionAction: String {
    case createProposal = "create proposal"
    case approveProposal = "approve proposal"
    case applyProposal = "apply proposal"
    case rejectProposal = "reject proposal"
    case updateAssignedNode = "update assigned node"
}

enum PlannerPermission {
    static func currentActorId() -> String? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "meee2Connected") else { return nil }
        let actorId = defaults.string(forKey: "meee2UserId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return actorId.isEmpty ? nil : actorId
    }

    static func access(
        for canvas: PlanningCanvas,
        nodes: [PlanningNode],
        actorId explicitActorId: String? = nil
    ) -> PlannerAccess {
        let actorId = explicitActorId ?? canvas.ownerId
        let role: PlannerCanvasRole
        if explicitActorId == nil || actorId == canvas.ownerId {
            role = .owner
        } else if nodes.contains(where: { $0.doerId == actorId }) {
            role = .doer
        } else {
            role = .viewer
        }

        return PlannerAccess(
            actorId: actorId,
            role: role,
            canCreateProposal: role == .owner || role == .suggestion,
            canApproveProposal: role == .owner,
            canApplyProposal: role == .owner,
            canRejectProposal: role == .owner,
            canUpdateAssignedNode: role == .owner || role == .doer
        )
    }

    static func require(_ action: PlannerPermissionAction, access: PlannerAccess) throws {
        let allowed: Bool
        switch action {
        case .createProposal:
            allowed = access.canCreateProposal
        case .approveProposal:
            allowed = access.canApproveProposal
        case .applyProposal:
            allowed = access.canApplyProposal
        case .rejectProposal:
            allowed = access.canRejectProposal
        case .updateAssignedNode:
            allowed = access.canUpdateAssignedNode
        }
        guard allowed else {
            throw PlannerCoreError.permissionDenied(action: action.rawValue, role: access.role)
        }
    }

    /// Enforce node-scoped execution-state mutations (dispatch / layout /
    /// bind-session / attach-artifact). The owner may touch any node; a doer
    /// may touch ONLY a node where `node.doerId == access.actorId`; a viewer
    /// is always denied. `node` is the target node; pass `nil` when the node
    /// is missing so the caller still surfaces `nodeNotFound` separately.
    static func requireNodeUpdate(
        on node: PlanningNode,
        access: PlannerAccess
    ) throws {
        // Base capability gate (owner + doer pass, viewer/suggestion denied).
        try require(.updateAssignedNode, access: access)
        // Owner is unrestricted; a doer is confined to their own node.
        guard access.role == .owner || node.doerId == access.actorId else {
            throw PlannerCoreError.permissionDenied(
                action: PlannerPermissionAction.updateAssignedNode.rawValue,
                role: access.role
            )
        }
    }
}

enum PlannerProposalValidator {
    /// Allowed enum sets: derived from `PlannerContract.generated.swift`, whose
    /// source of truth is meee2-online/src/planner-runtime/contract/{enums,proposal}.ts.
    /// Re-emit via `pnpm contract:emit` in meee2-online. The static-let initializers
    /// below assert (at first access via `precondition`) that every Swift-side enum
    /// case is represented in the contract — surfaces drift loudly if a Swift enum
    /// gains a case but the Zod side hasn't.
    static let knownNodeKinds: Set<String> = {
        let s = PlannerContract.nodeKinds
        for kind in [PlanningNodeKind.step, .session, .artifact, .subCanvas, .external] {
            precondition(
                s.contains(kind.rawValue),
                "planner contract drift: PlanningNodeKind.\(kind) missing from PlannerContract.nodeKinds — run `pnpm contract:emit`"
            )
        }
        return s
    }()

    static let knownChangeKinds: Set<String> = {
        let s = PlannerContract.changeKinds
        for kind in [PlanChange.Kind.addNode, .updateNode, .attachArtifact] {
            precondition(
                s.contains(kind.rawValue),
                "planner contract drift: PlanChange.Kind.\(kind) missing from PlannerContract.changeKinds — run `pnpm contract:emit`"
            )
        }
        return s
    }()

    static func decodeProposal(from rawOutput: String) throws -> PlanProposal {
        let decoder = JSONDecoder()
        var lastDecodeError: Error?
        for candidate in jsonCandidates(from: rawOutput) {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                return try decoder.decode(PlanProposal.self, from: data)
            } catch {
                lastDecodeError = error
            }
            // Strict decode failed — surface a precise error for an unknown
            // `kind` value instead of an opaque "not valid JSON". A strict
            // String-backed enum rejects unknown raw values, so without this
            // a typo'd kind would look like malformed JSON to the caller.
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                try assertKnownKinds(in: obj)
            }
        }
        // Log the exact decode failure (which field / value) — the thrown
        // error stays a generic case, but the log pinpoints the cause.
        if let lastDecodeError {
            NSLog("[PlannerProposalValidator] proposal decode failed: %@",
                  String(describing: lastDecodeError))
        }
        throw PlannerCoreError.invalidPlannerProposalJSON
    }

    /// Scan a loosely-typed proposal object for unknown change/node `kind`
    /// values before strict decoding swallows them as a generic JSON error.
    private static func assertKnownKinds(in object: [String: Any]) throws {
        guard let changes = object["changes"] as? [[String: Any]] else { return }
        for change in changes {
            if let changeKind = change["kind"] as? String,
               !knownChangeKinds.contains(changeKind) {
                throw PlannerCoreError.unknownChangeKind(changeKind)
            }
            if let node = change["node"] as? [String: Any],
               let nodeKind = node["nodeKind"] as? String,
               !knownNodeKinds.contains(nodeKind) {
                throw PlannerCoreError.unknownNodeKind(nodeKind)
            }
            if let nodeKind = change["nodeKind"] as? String,
               !knownNodeKinds.contains(nodeKind) {
                throw PlannerCoreError.unknownNodeKind(nodeKind)
            }
        }
    }

    static func validate(
        _ proposal: PlanProposal,
        canvas: PlanningCanvas,
        nodes: [PlanningNode]
    ) throws {
        guard proposal.canvasId == canvas.id else {
            throw PlannerCoreError.canvasMismatch(expected: canvas.id, actual: proposal.canvasId)
        }
        guard !proposal.changes.isEmpty else {
            throw PlannerCoreError.emptyProposalChanges
        }

        let existingNodeIds = Set(nodes.map(\.id))
        // Node ids the proposal itself introduces — a valid target for an
        // intra-proposal `dependsOnNodeIds` reference.
        let addedNodeIds = Set(proposal.changes.compactMap { $0.node?.id })
        // Every node id this canvas may legitimately reference.
        let canvasNodeIds = existingNodeIds.union(addedNodeIds)

        for change in proposal.changes {
            switch change.kind {
            case .addNode:
                guard let node = change.node else { throw PlannerCoreError.missingNodeForAdd }
                guard node.canvasId == canvas.id else {
                    throw PlannerCoreError.canvasMismatch(expected: canvas.id, actual: node.canvasId)
                }
                if let kind = node.nodeKind, !knownNodeKinds.contains(kind.rawValue) {
                    throw PlannerCoreError.unknownNodeKind(kind.rawValue)
                }
                try assertSameCanvasReferences(
                    nodeId: node.id,
                    dependsOnNodeIds: node.dependsOnNodeIds,
                    canvasNodeIds: canvasNodeIds,
                    canvasId: canvas.id
                )
            case .updateNode:
                guard let nodeId = change.nodeId else { throw PlannerCoreError.missingNodeId }
                guard existingNodeIds.contains(nodeId) else {
                    throw PlannerCoreError.nodeNotFound(nodeId)
                }
                if let kind = change.nodeKind, !knownNodeKinds.contains(kind.rawValue) {
                    throw PlannerCoreError.unknownNodeKind(kind.rawValue)
                }
                try assertSameCanvasReferences(
                    nodeId: nodeId,
                    dependsOnNodeIds: change.dependsOnNodeIds,
                    canvasNodeIds: canvasNodeIds,
                    canvasId: canvas.id
                )
                guard change.title != nil ||
                    change.status != nil ||
                    change.schema != nil ||
                    change.contextSources != nil ||
                    change.dependsOnNodeIds != nil ||
                    change.subCanvasId != nil ||
                    change.nodeKind != nil ||
                    change.layout != nil ||
                    change.trigger != nil ||
                    change.executionMode != nil ||
                    change.clearGate == true ||
                    change.gate != nil ||
                    change.dispatch != nil ||
                    change.approvers != nil ||
                    change.artifactRefs != nil ||
                    change.eventRefs != nil ||
                    change.workflowRunState != nil ||
                    change.sessionId != nil ||
                    change.chatThreadId != nil ||
                    change.source != nil ||
                    change.doerId != nil else {
                    throw PlannerCoreError.updateNodeNoFields(nodeId)
                }
            case .attachArtifact:
                guard let artifact = change.artifact else {
                    throw PlannerCoreError.invalidNodeOutput("attachArtifact change is missing artifact")
                }
                let targetNodeId = artifact.nodeId ?? change.nodeId
                guard let targetNodeId else { throw PlannerCoreError.missingNodeId }
                guard canvasNodeIds.contains(targetNodeId) else {
                    throw PlannerCoreError.nodeNotFound(targetNodeId)
                }
                guard !artifact.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !artifact.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("attachArtifact requires non-empty title and reference")
                }
            case .refineSessionPrompt:
                guard let nodeId = change.nodeId else { throw PlannerCoreError.missingNodeId }
                guard existingNodeIds.contains(nodeId) else {
                    throw PlannerCoreError.nodeNotFound(nodeId)
                }
                // Directive lives in `title`. Empty is allowed (no-op refine
                // pings the session to re-think) but we log if missing.
                _ = change.title
            }
        }
    }

    /// Reject `dependsOnNodeIds` entries that point at nodes outside this
    /// canvas. A reference is cross-canvas when it is neither an existing
    /// canvas node nor a node introduced by the same proposal.
    private static func assertSameCanvasReferences(
        nodeId: String,
        dependsOnNodeIds: [String]?,
        canvasNodeIds: Set<String>,
        canvasId: String
    ) throws {
        for dependencyId in dependsOnNodeIds ?? [] {
            guard !canvasNodeIds.contains(dependencyId) else { continue }
            throw PlannerCoreError.crossCanvasNodeReference(
                nodeId: dependencyId,
                expectedCanvas: canvasId
            )
        }
        _ = nodeId
    }

    private static func jsonCandidates(from rawOutput: String) -> [String] {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let first = trimmed.firstIndex(of: "{"),
           let last = trimmed.lastIndex(of: "}"),
           first <= last {
            candidates.append(String(trimmed[first...last]))
        }
        return candidates.reduce(into: []) { unique, candidate in
            if !candidate.isEmpty && !unique.contains(candidate) {
                unique.append(candidate)
            }
        }
    }
}

final class PlannerCoreService {
    func nodeMock(canvasId: String) -> [PlanningNode] {
        [
            PlanningNode(
                id: "\(canvasId)-node-1",
                canvasId: canvasId,
                title: "meee2 AI LLM Spike",
                schema: NodeSchema(
                    inputs: ["owner goal", "canvas context"],
                    outputs: ["initial meee2 AI proposal"],
                    goal: "proposal created"
                ),
                contextSources: [
                    ContextSource(kind: .document, title: "Feature list", reference: "doc/meee2-feature-list-wjk-codex.md")
                ],
                executionMode: .human,
                executorType: .codex,
                doerId: "A",
                status: .working,
                dependsOnNodeIds: []
            ),
            PlanningNode(
                id: "\(canvasId)-node-2",
                canvasId: canvasId,
                title: "Canvas + Permission Shell",
                schema: NodeSchema(
                    inputs: ["node mock", "owner policy"],
                    outputs: ["owner-only canvas shell"],
                    goal: "shell renders mocked nodes"
                ),
                contextSources: [
                    ContextSource(kind: .repository, title: "Board module", reference: "Sources/Board")
                ],
                executionMode: .human,
                executorType: .human,
                doerId: "B",
                status: .ready,
                dependsOnNodeIds: ["\(canvasId)-node-1"]
            ),
            PlanningNode(
                id: "\(canvasId)-node-3",
                canvasId: canvasId,
                title: "Proposal Apply Contract",
                schema: NodeSchema(
                    inputs: ["approved plan proposal"],
                    outputs: ["updated planning nodes"],
                    goal: "approved proposal applied"
                ),
                contextSources: [
                    ContextSource(kind: .artifact, title: "PlanProposal", reference: "PlannerCore.PlanProposal")
                ],
                executionMode: .human,
                executorType: .mock,
                doerId: "A",
                status: .blocked,
                dependsOnNodeIds: ["\(canvasId)-node-2"]
            ),
            PlanningNode(
                id: "\(canvasId)-node-4",
                canvasId: canvasId,
                title: "NodeState Read",
                schema: NodeSchema(
                    inputs: ["planning nodes"],
                    outputs: ["node state snapshots"],
                    goal: "blocked/running/done states visible"
                ),
                contextSources: [
                    ContextSource(kind: .artifact, title: "PlanningNode", reference: "PlannerCore.PlanningNode")
                ],
                executionMode: .auto,
                executorType: .mock,
                doerId: "B",
                status: .done,
                dependsOnNodeIds: ["\(canvasId)-node-3"],
                subCanvasId: "\(canvasId)-subcanvas-node-state"
            )
        ]
    }

    func approve(_ proposal: PlanProposal) -> PlanProposal {
        PlanProposal(
            id: proposal.id,
            canvasId: proposal.canvasId,
            summary: proposal.summary,
            changes: proposal.changes,
            status: .approved
        )
    }

    func applyNodeChange(nodes: [PlanningNode], proposal: PlanProposal) throws -> [PlanningNode] {
        guard proposal.status == .approved else {
            throw PlannerCoreError.proposalNotApproved
        }

        var updatedNodes = nodes
        var dependencyInvalidationNodeIds = Set<String>()
        for change in proposal.changes {
            switch change.kind {
            case .addNode:
                guard let node = change.node else { throw PlannerCoreError.missingNodeForAdd }
                guard node.canvasId == proposal.canvasId else {
                    throw PlannerCoreError.canvasMismatch(expected: proposal.canvasId, actual: node.canvasId)
                }
                updatedNodes.append(node)
            case .updateNode:
                guard let nodeId = change.nodeId else { throw PlannerCoreError.missingNodeId }
                guard let index = updatedNodes.firstIndex(where: { $0.id == nodeId }) else {
                    throw PlannerCoreError.nodeNotFound(nodeId)
                }
                guard updatedNodes[index].canvasId == proposal.canvasId else {
                    throw PlannerCoreError.canvasMismatch(expected: proposal.canvasId, actual: updatedNodes[index].canvasId)
                }
                if let title = change.title {
                    updatedNodes[index].title = title
                }
                if let schema = change.schema {
                    updatedNodes[index].schema = schema
                    dependencyInvalidationNodeIds.insert(nodeId)
                }
                if let contextSources = change.contextSources {
                    updatedNodes[index].contextSources = contextSources
                    dependencyInvalidationNodeIds.insert(nodeId)
                }
                if let dependsOnNodeIds = change.dependsOnNodeIds {
                    updatedNodes[index].dependsOnNodeIds = dependsOnNodeIds
                }
                if let subCanvasId = change.subCanvasId {
                    updatedNodes[index].subCanvasId = subCanvasId
                }
                if let nodeKind = change.nodeKind {
                    updatedNodes[index].nodeKind = nodeKind
                }
                if let layout = change.layout {
                    updatedNodes[index].layout = layout
                }
                if let trigger = change.trigger {
                    updatedNodes[index].trigger = trigger
                }
                if let schedule = change.schedule {
                    updatedNodes[index].schedule = schedule
                }
                if let executionMode = change.executionMode {
                    updatedNodes[index].executionMode = executionMode
                }
                if change.clearGate == true {
                    updatedNodes[index].gate = nil
                    updatedNodes[index].approvers = nil
                }
                if let gate = change.gate {
                    updatedNodes[index].gate = gate
                }
                if let dispatch = change.dispatch {
                    updatedNodes[index].dispatch = dispatch
                }
                if let approvers = change.approvers {
                    updatedNodes[index].approvers = approvers
                }
                if let artifactRefs = change.artifactRefs {
                    updatedNodes[index].artifactRefs = artifactRefs
                }
                if let eventRefs = change.eventRefs {
                    updatedNodes[index].eventRefs = eventRefs
                }
                if let workflowRunState = change.workflowRunState {
                    updatedNodes[index].workflowRunState = workflowRunState
                }
                if let sessionId = change.sessionId {
                    updatedNodes[index].sessionId = sessionId
                }
                if let chatThreadId = change.chatThreadId {
                    updatedNodes[index].chatThreadId = chatThreadId
                }
                if let source = change.source {
                    updatedNodes[index].source = source
                }
                if let doerId = change.doerId {
                    updatedNodes[index].doerId = doerId
                }
                if let status = change.status {
                    updatedNodes[index].status = status
                }
            case .attachArtifact:
                continue
            case .refineSessionPrompt:
                // ENG-2 bonus: schema-level no-op at preview/apply time.
                // The directive is delivered to the bound session by the
                // BoardAPI handler (via the operator-channel inject path).
                continue
            }
        }

        if !dependencyInvalidationNodeIds.isEmpty {
            for index in updatedNodes.indices where updatedNodes[index].canvasId == proposal.canvasId {
                guard updatedNodes[index].dependsOnNodeIds?.contains(where: dependencyInvalidationNodeIds.contains) == true else {
                    continue
                }
                guard !dependencyInvalidationNodeIds.contains(updatedNodes[index].id) else {
                    continue
                }
                updatedNodes[index].status = .draft
            }
        }

        return updatedNodes
    }

    /// Build the `session`-kind PlanningNode created when a step node is
    /// dispatched to a spawning runner. The node depends on the originating
    /// step so the graph edge (step → session) is derived; `sessionId` stays
    /// nil until the spawned session is observed and bound.
    static func sessionNode(for step: PlanningNode, proposalId: String) -> PlanningNode {
        PlanningNode(
            id: "node-session-\(step.id)-\(proposalId)",
            canvasId: step.canvasId,
            title: "Session · \(step.title)",
            schema: step.schema,
            contextSources: step.contextSources,
            executionMode: step.executionMode,
            executorType: step.executorType,
            doerId: step.doerId,
            status: .working,
            source: .session,
            dependsOnNodeIds: [step.id],
            nodeKind: .session,
            dispatch: step.dispatch,
            workflowRunState: .dispatched
        )
    }

    func readNodeState(nodes: [PlanningNode]) -> [NodeStateSnapshot] {
        nodes.map { node in
            let runState = NodeRunState(status: node.status)
            return NodeStateSnapshot(
                nodeId: node.id,
                runState: runState,
                blockers: blockers(for: node),
                artifactRefs: artifactRefs(for: node),
                needsOwnerReview: false
            )
        }
    }

    func summarizeSubCanvas(
        subCanvasId: String,
        states: [NodeStateSnapshot],
        proposals: [PlanProposal]
    ) -> SubCanvasSummary {
        let pendingProposalCount = proposals.filter { proposal in
            proposal.canvasId == subCanvasId && (proposal.status == .pending || proposal.status == .approved)
        }.count
        let scopedStates = states
        let blockers = scopedStates.flatMap(\.blockers)
        let runState: NodeRunState
        if scopedStates.contains(where: { $0.runState == .blocked }) {
            runState = .blocked
        } else if pendingProposalCount > 0 || scopedStates.contains(where: { $0.needsOwnerReview }) {
            runState = .draft
        } else if !scopedStates.isEmpty && scopedStates.allSatisfy({ $0.runState == .done }) {
            runState = .done
        } else if scopedStates.contains(where: { $0.runState == .working }) {
            runState = .working
        } else if scopedStates.contains(where: { $0.runState == .draft }) {
            runState = .draft
        } else {
            runState = .ready
        }
        return SubCanvasSummary(
            subCanvasId: subCanvasId,
            runState: runState,
            blockers: blockers,
            pendingProposalCount: pendingProposalCount,
            needsOwnerReview: pendingProposalCount > 0 || scopedStates.contains(where: \.needsOwnerReview)
        )
    }

    func createCrossCanvasSuggestion(
        id: String = "suggestion-\(UUID().uuidString.lowercased())",
        sourceCanvasId: String,
        targetCanvas: PlanningCanvas,
        sourcePlannerId: String,
        suggestedProposal: PlanProposal,
        reason: String
    ) throws -> PlannerCrossCanvasSuggestion {
        guard suggestedProposal.canvasId == targetCanvas.id else {
            throw PlannerCoreError.canvasMismatch(
                expected: targetCanvas.id,
                actual: suggestedProposal.canvasId
            )
        }
        return PlannerCrossCanvasSuggestion(
            id: id,
            sourceCanvasId: sourceCanvasId,
            targetCanvasId: targetCanvas.id,
            sourcePlannerId: sourcePlannerId,
            targetOwnerId: targetCanvas.ownerId,
            suggestedProposal: suggestedProposal,
            reason: reason,
            status: .pending
        )
    }

    func acceptCrossCanvasSuggestion(
        _ suggestion: PlannerCrossCanvasSuggestion,
        byOwnerId ownerId: String
    ) throws -> PlannerCrossCanvasSuggestion {
        guard ownerId == suggestion.targetOwnerId else {
            throw PlannerCoreError.permissionDenied(
                action: "accept cross-canvas suggestion",
                role: .viewer
            )
        }
        var accepted = suggestion
        accepted.status = .accepted
        return accepted
    }

    func rejectCrossCanvasSuggestion(
        _ suggestion: PlannerCrossCanvasSuggestion,
        byOwnerId ownerId: String
    ) throws -> PlannerCrossCanvasSuggestion {
        guard ownerId == suggestion.targetOwnerId else {
            throw PlannerCoreError.permissionDenied(
                action: "reject cross-canvas suggestion",
                role: .viewer
            )
        }
        var rejected = suggestion
        rejected.status = .rejected
        return rejected
    }

    private func artifactRefs(for node: PlanningNode) -> [String] {
        var refs = node.artifactRefs ?? []
        // Synthetic fallback handle — only for a done node that produced no
        // concrete artifact of its own. Once a real artifact exists it is
        // pure noise (a duplicate "output" entry alongside the real refs).
        if node.status == .done && refs.isEmpty {
            refs.append("artifact://\(node.id)/output")
        }
        if let subCanvasId = node.subCanvasId {
            refs.append("subcanvas:\(subCanvasId)")
        }
        return Array(Set(refs)).sorted()
    }

    private func blockers(for node: PlanningNode) -> [String] {
        switch node.status {
        case .blocked:
            let reason = node.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty {
                return [reason]
            }
            return ["Blocked: no reason was provided by the session."]
        default:
            return []
        }
    }
}

enum SessionToPlanningNodeMapper {
    static func map(
        session: PluginSession,
        canvasId: String,
        doerId: String
    ) -> PlanningNode {
        PlanningNode(
            id: "\(canvasId)-session-\(stableNodeSuffix(for: session.id))",
            canvasId: canvasId,
            title: session.title.isEmpty ? session.projectName : session.title,
            schema: NodeSchema(
                inputs: sessionInputHints(session),
                outputs: ["session output"],
                goal: goal(for: session.status)
            ),
            contextSources: contextSources(session),
            executionMode: session.status == .permissionRequired ? .human : .auto,
            executorType: executorType(pluginId: session.pluginId),
            doerId: doerId,
            status: nodeStatus(session.status),
            sessionId: session.id,
            chatThreadId: chatThreadId(session),
            source: .session,
            dependsOnNodeIds: [],
            nodeKind: .session
        )
    }

    private static func stableNodeSuffix(for sessionId: String) -> String {
        sessionId
            .lowercased()
            .map { char in
                char.isLetter || char.isNumber ? char : "-"
            }
            .reduce(into: "") { $0.append($1) }
    }

    private static func sessionInputHints(_ session: PluginSession) -> [String] {
        var hints: [String] = []
        if let cwd = session.cwd, !cwd.isEmpty {
            hints.append("cwd:\(cwd)")
        }
        if let subtitle = session.subtitle, !subtitle.isEmpty {
            hints.append("task:\(subtitle)")
        }
        if hints.isEmpty {
            hints.append("session:\(session.id)")
        }
        return hints
    }

    private static func contextSources(_ session: PluginSession) -> [ContextSource] {
        var sources: [ContextSource] = []
        if let cwd = session.cwd, !cwd.isEmpty {
            sources.append(ContextSource(kind: .repository, title: session.projectName, reference: cwd))
        }
        if let transcriptPath = session.transcriptPath, !transcriptPath.isEmpty {
            sources.append(ContextSource(kind: .chatHistory, title: "Session transcript", reference: transcriptPath))
        }
        if let lastMessage = session.lastMessage, !lastMessage.isEmpty {
            sources.append(ContextSource(kind: .artifact, title: "Last message", reference: lastMessage))
        }
        return sources
    }

    private static func executorType(pluginId: String) -> ExecutorType {
        let normalized = pluginId.lowercased()
        if normalized.contains("claude") { return .claude }
        if normalized.contains("codex") { return .codex }
        if normalized.contains("cursor") { return .cursor }
        if normalized.contains("openclaw") { return .openClaw }
        return .mock
    }

    private static func nodeStatus(_ status: SessionStatus) -> PlanningNodeStatus {
        switch status {
        case .thinking, .tooling, .active, .compacting:
            return .working
        case .permissionRequired, .dead:
            return .blocked
        case .completed:
            return .done
        case .idle, .waitingForUser:
            return .ready
        }
    }

    private static func goal(for status: SessionStatus) -> String {
        switch status {
        case .permissionRequired:
            return "owner permission required"
        case .completed:
            return "session completed"
        case .dead:
            return "session failed or disappeared"
        default:
            return "session state changed"
        }
    }

    private static func chatThreadId(_ session: PluginSession) -> String? {
        if session.pluginId.lowercased().contains("codex") {
            return session.id
        }
        return nil
    }
}

final class PlannerStore {
    struct DueScheduledNode {
        let canvasId: String
        let nodeId: String
        let title: String
        let sessionId: String
        let prompt: String
        let intervalSeconds: Int
    }

    struct CanvasRecord: Codable, Equatable {
        var canvas: PlanningCanvas
        var nodes: [PlanningNode]
        var proposals: [PlanProposal]
        var events: [PlannerEvent]
        var artifacts: [PlannerArtifact]
        /// ENG-3 · Append-only version chain. Every `submitNodeOutput` adds
        /// one row per artifact; latest-per-slot is what `artifacts` mirrors.
        var artifactVersions: [PlannerArtifactVersion]
        /// Execution-layer history (P1 Run layer).
        var runs: [WorkflowRun]
        /// The run that execution-layer mutations currently mirror into. `nil`
        /// when no run is in progress (e.g. a finished canvas awaiting re-run).
        var activeRunId: String?
        /// ENG-2 / E2.1: per-(canvasId, nodeId) version chain. Every
        /// `submit_node_output` appends; old versions stay queryable.
        /// ENG-3 owns long-term storage in `meee2_session_versions`; this
        /// in-process slice is the source of truth for the running engine.
        var nodeVersions: [NodeVersion]

        init(
            canvas: PlanningCanvas,
            nodes: [PlanningNode],
            proposals: [PlanProposal],
            events: [PlannerEvent] = [],
            artifacts: [PlannerArtifact] = [],
            artifactVersions: [PlannerArtifactVersion] = [],
            runs: [WorkflowRun] = [],
            activeRunId: String? = nil,
            nodeVersions: [NodeVersion] = []
        ) {
            self.canvas = canvas
            self.nodes = nodes
            self.proposals = proposals
            self.events = events
            self.artifacts = artifacts
            self.artifactVersions = artifactVersions
            self.runs = runs
            self.activeRunId = activeRunId
            self.nodeVersions = nodeVersions
        }

        enum CodingKeys: String, CodingKey {
            case canvas, nodes, proposals, events, artifacts, artifactVersions, runs, activeRunId, nodeVersions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.canvas = try container.decode(PlanningCanvas.self, forKey: .canvas)
            self.nodes = try container.decode([PlanningNode].self, forKey: .nodes)
            self.proposals = try container.decode([PlanProposal].self, forKey: .proposals)
            self.events = try container.decodeIfPresent([PlannerEvent].self, forKey: .events) ?? []
            self.artifacts = try container.decodeIfPresent([PlannerArtifact].self, forKey: .artifacts) ?? []
            // ENG-3 back-compat: legacy records on disk have no version chain
            // — start with an empty array; first re-submit seeds it.
            self.artifactVersions = try container.decodeIfPresent([PlannerArtifactVersion].self, forKey: .artifactVersions) ?? []
            self.runs = try container.decodeIfPresent([WorkflowRun].self, forKey: .runs) ?? []
            self.activeRunId = try container.decodeIfPresent(String.self, forKey: .activeRunId)
            self.nodeVersions = try container.decodeIfPresent([NodeVersion].self, forKey: .nodeVersions) ?? []
        }
    }

    private struct StoreDocument: Codable {
        var canvases: [String: CanvasRecord]
    }

    private struct StoreIndex: Codable {
        var canvasIds: [String]
        var updatedAt: Date
    }

    static let shared = PlannerStore(
        fileURL: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent("planner", isDirectory: true)
    )

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()
    private var document: StoreDocument

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.rootURL = fileURL.pathExtension == "json"
            ? fileURL.deletingPathExtension()
            : fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.document = Self.loadDocument(rootURL: rootURL, fileManager: fileManager, decoder: decoder)
    }

    func record(
        for canvas: PlanningCanvas,
        seedNodes: [PlanningNode]
    ) throws -> CanvasRecord {
        try withLock {
            if let existing = document.canvases[canvas.id] {
                // `visibility` is owned by the store, not by the per-request
                // `PlanningCanvas` projection (which defaults to `.private`).
                // Preserve the persisted tier so a read never clobbers it.
                var incoming = canvas
                incoming.visibility = existing.canvas.visibility
                if existing.canvas == incoming {
                    return existing
                }
                var updated = existing
                updated.canvas = incoming
                document.canvases[canvas.id] = updated
                try save(canvasId: canvas.id)
                return updated
            }

            let record = CanvasRecord(canvas: canvas, nodes: seedNodes, proposals: [])
            document.canvases[canvas.id] = record
            try save(canvasId: canvas.id)
            return record
        }
    }

    /// Owner-driven visibility change. Persisted under the store lock like
    /// every other mutation.
    func setCanvasVisibility(
        _ visibility: PlannerCanvasVisibility,
        canvasId: String
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            record.canvas.visibility = visibility
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func setCanvasContext(
        _ context: String,
        canvasId: String
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            record.canvas.plannerContext = context
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func replaceNodesIfUnmodified(
        canvasId: String,
        matching expectedNodes: [PlanningNode],
        with replacementNodes: [PlanningNode]
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard record.proposals.isEmpty,
                  record.events.isEmpty,
                  record.nodes == expectedNodes else {
                return record
            }
            record.nodes = replacementNodes
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func seedNodesIfEmpty(
        canvasId: String,
        seedNodes: [PlanningNode]
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard record.nodes.isEmpty,
                  record.proposals.isEmpty,
                  record.events.isEmpty,
                  record.artifacts.isEmpty,
                  record.runs.isEmpty,
                  !seedNodes.isEmpty else {
                return record
            }
            record.nodes = seedNodes
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func clearCanvasContent(canvasId: String) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            record.nodes = []
            record.proposals = []
            record.events = []
            record.artifacts = []
            record.runs = []
            record.activeRunId = nil
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func saveProposal(
        _ proposal: PlanProposal,
        canvas: PlanningCanvas,
        seedNodes: [PlanningNode],
        validationNodes: [PlanningNode]? = nil
    ) throws -> PlanProposal {
        try withLock {
            var record = try record(for: canvas, seedNodes: seedNodes)
            try PlannerProposalValidator.validate(
                proposal,
                canvas: canvas,
                nodes: validationNodes ?? record.nodes
            )
            if let index = record.proposals.firstIndex(where: { $0.id == proposal.id }) {
                record.proposals[index] = proposal
            } else {
                record.proposals.append(proposal)
                record.events.append(event(
                    canvasId: canvas.id,
                    type: .proposalCreated,
                    proposalId: proposal.id,
                    summary: proposal.summary
                ))
            }
            document.canvases[canvas.id] = record
            try save(canvasId: canvas.id)
            return proposal
        }
    }

    func approveProposal(
        proposalId: String,
        canvasId: String
    ) throws -> PlanProposal {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
                throw PlannerCoreError.proposalNotFound(proposalId)
            }
            guard record.proposals[index].canvasId == canvasId else {
                throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: record.proposals[index].canvasId)
            }
            record.proposals[index].status = .approved
            record.events.append(event(
                canvasId: canvasId,
                type: .proposalApproved,
                proposalId: proposalId,
                summary: record.proposals[index].summary
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record.proposals[index]
        }
    }

    func rejectProposal(
        proposalId: String,
        canvasId: String
    ) throws -> PlanProposal {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
                throw PlannerCoreError.proposalNotFound(proposalId)
            }
            guard record.proposals[index].canvasId == canvasId else {
                throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: record.proposals[index].canvasId)
            }
            record.proposals[index].status = .rejected
            record.events.append(event(
                canvasId: canvasId,
                type: .proposalRejected,
                proposalId: proposalId,
                summary: record.proposals[index].summary
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record.proposals[index]
        }
    }

    func applyProposal(
        proposalId: String,
        canvasId: String,
        service: PlannerCoreService
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
                throw PlannerCoreError.proposalNotFound(proposalId)
            }
            let proposal = record.proposals[index]
            try PlannerProposalValidator.validate(proposal, canvas: record.canvas, nodes: record.nodes)
            let nodes = try service.applyNodeChange(nodes: record.nodes, proposal: proposal)
            record.events.append(contentsOf: events(for: proposal, before: record.nodes, after: nodes))
            record.nodes = nodes
            record.proposals[index].status = .applied
            record.artifacts = mergeArtifacts(
                record.artifacts,
                proposalArtifacts(from: proposal, nodes: nodes, canvasId: canvasId)
                    + derivedArtifacts(from: nodes, canvasId: canvasId)
            )
            record.events.append(event(
                canvasId: canvasId,
                type: .proposalApplied,
                proposalId: proposalId,
                summary: proposal.summary
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func preview(
        proposal: PlanProposal,
        canvas: PlanningCanvas,
        seedNodes: [PlanningNode],
        service: PlannerCoreService
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode]) {
        try withLock {
            let record = try record(for: canvas, seedNodes: seedNodes)
            try PlannerProposalValidator.validate(proposal, canvas: canvas, nodes: record.nodes)
            let approved = service.approve(proposal)
            let nodes = try service.applyNodeChange(nodes: record.nodes, proposal: approved)
            return (approved, nodes)
        }
    }

    /// Phase 2 — runState 回流.
    ///
    /// Called when a spawned planner session (tagged `purpose=planner:<stepId>`)
    /// is observed. `stepId` is the *step* node id from the purpose tag.
    /// This binds `sessionId` onto the step's `session` PlanningNode (the one
    /// that `dependsOnNodeIds` the step) and writes `runState` onto both the
    /// session node and — when meaningful — the step node, so the step reflects
    /// the live execution state of its child session.
    ///
    /// Returns the updated record, or `nil` if no session node is found for the
    /// step (e.g. the step was dispatched to `human`, never spawning a session).
    /// Persisted under the store lock, like every other mutation here.
    @discardableResult
    func applySessionRunState(
        stepNodeId: String,
        sessionId: String,
        runState: PlannerWorkflowRunState
    ) throws -> CanvasRecord? {
        try withLock {
            try applySessionRunStateLocked(
                stepNodeId: stepNodeId,
                sessionId: sessionId,
                runState: runState
            )
        }
    }

    /// Lock-free core of `applySessionRunState` — callers must already hold the
    /// store lock (`withLock`). Binds `sessionId` directly onto the step node
    /// and mirrors the spawned session's run state onto that step.
    private func applySessionRunStateLocked(
        stepNodeId: String,
        sessionId: String,
        runState: PlannerWorkflowRunState
    ) throws -> CanvasRecord? {
        for (canvasId, var record) in document.canvases {
            guard let stepIndex = record.nodes.firstIndex(where: { $0.id == stepNodeId }) else {
                continue
            }
            let legacySessionIndex = record.nodes.firstIndex(where: { node in
                node.nodeKind == .session
                    && (node.dependsOnNodeIds ?? []).contains(stepNodeId)
            })

            var changed = false
            let stepRunState = Self.stepRunState(
                for: runState,
                hasGate: record.nodes[stepIndex].gate != nil
            )
            let currentStepRunState = record.nodes[stepIndex].workflowRunState
            if record.nodes[stepIndex].sessionId != sessionId {
                record.nodes[stepIndex].sessionId = sessionId
                record.nodes[stepIndex].chatThreadId = sessionId
                record.nodes[stepIndex].source = .session
                changed = true
            }
            let shouldProtectCompletedStep = currentStepRunState == .done && stepRunState != .done
            // Once an agent has explicitly submitted output (done / blocked /
            // needsReview), latch that state — don't let transient
            // session-status observations overwrite it. Without this, a
            // Claude session returning to idle right after
            // `submit_node_output blocked` flips the node back to dispatched
            // and wipes `blockedReason`. Released by `dispatchNode` /
            // `abandonNodeSession` so a re-dispatch can resume normal mirror.
            let agentSubmitted = record.nodes[stepIndex].outputSubmittedAt != nil
            if shouldProtectCompletedStep {
                if record.nodes[stepIndex].blockedReason != nil {
                    record.nodes[stepIndex].blockedReason = nil
                    changed = true
                }
            } else if agentSubmitted {
                // Skip mirror — the node has a latched terminal state from
                // an explicit submit. sessionId/chatThreadId binding above
                // still applies so the session stays linked to the node.
            } else if record.nodes[stepIndex].workflowRunState != stepRunState {
                record.nodes[stepIndex].workflowRunState = stepRunState
                record.nodes[stepIndex].status = Self.nodeStatus(for: stepRunState)
                if stepRunState == .failed || stepRunState == .gateWait || stepRunState == .awaitingInput {
                    record.nodes[stepIndex].blockedReason = Self.sessionFailureReason(
                        for: runState,
                        sessionId: sessionId
                    )
                } else {
                    record.nodes[stepIndex].blockedReason = nil
                }
                changed = true
                record.events.append(event(
                    canvasId: canvasId,
                    type: .nodeStateChanged,
                    nodeId: record.nodes[stepIndex].id,
                    summary: "\(record.nodes[stepIndex].title) -> \(stepRunState.rawValue)"
                ))
            }
            if let legacySessionIndex {
                if record.nodes[legacySessionIndex].sessionId != sessionId {
                    record.nodes[legacySessionIndex].sessionId = sessionId
                    record.nodes[legacySessionIndex].chatThreadId = sessionId
                    changed = true
                }
                if record.nodes[legacySessionIndex].workflowRunState != runState {
                    record.nodes[legacySessionIndex].workflowRunState = runState
                    record.nodes[legacySessionIndex].status = Self.nodeStatus(for: runState)
                    changed = true
                }
            }

            guard changed else { return record }
            if !shouldProtectCompletedStep && !agentSubmitted {
                mirrorIntoActiveRun(&record, nodeId: stepNodeId) { state in
                    state.sessionId = sessionId
                    state.chatThreadId = sessionId
                    state.runState = stepRunState
                    if stepRunState == .done || stepRunState == .failed {
                        state.finishedAt = state.finishedAt ?? Date()
                    }
                }
            }
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
        return nil
    }

    /// Phase 2 — runState 回流, status-driven path.
    ///
    /// Update an already-bound planner session node (looked up by its
    /// `sessionId`) plus its originating step. Used when SessionMonitor
    /// observes a status change on a session whose spawn intent was already
    /// consumed (so the `purpose` tag is no longer available). No-op if no
    /// session node currently carries `sessionId`.
    @discardableResult
    func applyRunStateForSession(
        sessionId: String,
        runState: PlannerWorkflowRunState
    ) throws -> CanvasRecord? {
        try withLock {
            for (_, record) in document.canvases {
                if let step = record.nodes.first(where: {
                    ($0.nodeKind ?? .step) == .step && $0.sessionId == sessionId
                }) {
                    return try applySessionRunStateLocked(
                        stepNodeId: step.id,
                        sessionId: sessionId,
                        runState: runState
                    )
                }
                guard let sessionNode = record.nodes.first(where: {
                    $0.nodeKind == .session && $0.sessionId == sessionId
                }) else { continue }
                let stepNodeId = (sessionNode.dependsOnNodeIds ?? []).first
                // Reuse the step-keyed path so step + session stay consistent.
                if let stepNodeId {
                    return try applySessionRunStateLocked(
                        stepNodeId: stepNodeId,
                        sessionId: sessionId,
                        runState: runState
                    )
                }
            }
            return nil
        }
    }

    /// Map a workflow run state to the public `PlanningNodeStatus`, keeping the
    /// two status dimensions consistent on the node.
    private static func nodeStatus(for runState: PlannerWorkflowRunState) -> PlanningNodeStatus {
        switch runState {
        case .pending, .readyToStart:
            return .ready
        case .dispatched, .running:
            return .working
        case .awaitingInput, .gateWait:
            return .blocked
        case .done:
            return .done
        case .failed:
            return .blocked
        }
    }

    private static func sessionFailureReason(
        for sessionRunState: PlannerWorkflowRunState,
        sessionId: String
    ) -> String {
        switch sessionRunState {
        case .failed:
            return "Session \(String(sessionId.prefix(8))) ended before this node submitted a completion output."
        case .gateWait:
            return "Session \(String(sessionId.prefix(8))) needs human attention before this node can continue."
        case .awaitingInput:
            return "Session \(String(sessionId.prefix(8))) is waiting for your input — open it and reply."
        case .pending, .readyToStart, .dispatched, .running, .done:
            return "Session \(String(sessionId.prefix(8))) could not continue this node."
        }
    }

    /// A step node finishing its spawned session: if it carries a gate it
    /// parks at `gateWait` (awaiting approval); otherwise it is `done`.
    /// Non-terminal session states propagate verbatim.
    private static func stepRunState(
        for sessionRunState: PlannerWorkflowRunState,
        hasGate: Bool
    ) -> PlannerWorkflowRunState {
        switch sessionRunState {
        case .done:
            return hasGate ? .gateWait : .done
        case .failed:
            return .failed
        case .pending, .readyToStart, .dispatched, .running, .awaitingInput, .gateWait:
            return sessionRunState
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func requireRecord(canvasId: String) throws -> CanvasRecord {
        guard let record = document.canvases[canvasId] else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        var normalized = record
        normalized.artifacts = mergeArtifacts([], record.artifacts)
        return normalized
    }

    // MARK: - Run layer (P1)

    /// Index of the canvas's active run, if one is in progress.
    private func activeRunIndex(in record: CanvasRecord) -> Int? {
        guard let id = record.activeRunId else { return nil }
        return record.runs.firstIndex { $0.id == id }
    }

    /// Mirror a node's execution-state change into the canvas's active run.
    ///
    /// Behaviour-preserving by design: `PlanningNode` stays the read projection
    /// every existing surface uses, while the run accumulates the source of
    /// truth. A no-op when the canvas has no active run (e.g. a post-P1 canvas
    /// that has not started a run yet) — old behaviour is unchanged.
    private func mirrorIntoActiveRun(
        _ record: inout CanvasRecord,
        nodeId: String,
        mutate: (inout RunNodeState) -> Void
    ) {
        guard let runIdx = activeRunIndex(in: record) else { return }
        var state = record.runs[runIdx].nodeStates[nodeId] ?? RunNodeState(nodeId: nodeId)
        mutate(&state)
        record.runs[runIdx].nodeStates[nodeId] = state
    }

    /// Recompute the active run (status + per-node `nextAction`) after an
    /// execution-layer mutation. Decision B lives in `WorkflowRunEngine`. When
    /// the run reaches a terminal status it stops being the active run.
    private func recomputeActiveRun(_ record: inout CanvasRecord) {
        guard let runIdx = activeRunIndex(in: record) else { return }
        let advanced = WorkflowRunEngine.advance(record.runs[runIdx], nodes: record.nodes)
        record.runs[runIdx] = advanced
        record.runs[runIdx].updatedAt = Date()
        if advanced.status != .active {
            record.activeRunId = nil
        }
    }

    /// Start a fresh run over the canvas's current node structure. `runIndex`
    /// is one past the highest existing run. Becomes the active run.
    func startRun(
        canvasId: String,
        trigger: String,
        title: String? = nil,
        summary: String? = nil,
        responsibleUserId: String? = nil,
        linkedArtifactRefs: [String] = []
    ) throws -> WorkflowRun {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            let nextIndex = (record.runs.map { $0.runIndex }.max() ?? 0) + 1
            let run = WorkflowRun.start(
                canvasId: canvasId,
                runIndex: nextIndex,
                trigger: trigger,
                nodes: record.nodes,
                title: title,
                summary: summary,
                responsibleUserId: responsibleUserId,
                linkedArtifactRefs: linkedArtifactRefs
            )
            record.runs.append(run)
            record.activeRunId = run.id
            // Populate per-node next-actions for the fresh run (root nodes
            // become `readyToDispatch`, the rest `waitingOnUpstream`).
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record.runs.last ?? run
        }
    }

    /// All runs of a canvas, newest run last (creation order).
    func runs(canvasId: String) throws -> [WorkflowRun] {
        try withLock { try requireRecord(canvasId: canvasId).runs }
    }

    /// A single run looked up across all canvases.
    func run(runId: String) -> WorkflowRun? {
        withLock {
            for (_, record) in document.canvases {
                if let run = record.runs.first(where: { $0.id == runId }) {
                    return run
                }
            }
            return nil
        }
    }

    /// Human-terminate a run. Clears `activeRunId` if it was the active one.
    func abortRun(runId: String) throws -> WorkflowRun {
        try withLock {
            for (canvasId, var record) in document.canvases {
                guard let idx = record.runs.firstIndex(where: { $0.id == runId }) else { continue }
                record.runs[idx].status = .aborted
                record.runs[idx].finishedAt = Date()
                record.runs[idx].updatedAt = Date()
                if record.activeRunId == runId {
                    record.activeRunId = nil
                }
                document.canvases[canvasId] = record
                try save(canvasId: canvasId)
                return record.runs[idx]
            }
            throw PlannerCoreError.runNotFound(runId)
        }
    }

    private func save(canvasId: String) throws {
        guard let record = document.canvases[canvasId] else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        let directory = canvasDirectory(canvasId: canvasId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        try saveIndex()
    }

    private func saveIndex() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let index = StoreIndex(
            canvasIds: document.canvases.keys.sorted(),
            updatedAt: Date()
        )
        let data = try encoder.encode(index)
        try data.write(to: rootURL.appendingPathComponent("index.json"), options: .atomic)
    }

    private func canvasDirectory(canvasId: String) -> URL {
        rootURL
            .appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(canvasId), isDirectory: true)
    }

    private func events(
        for proposal: PlanProposal,
        before: [PlanningNode],
        after: [PlanningNode]
    ) -> [PlannerEvent] {
        let beforeById = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let afterById = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        var events: [PlannerEvent] = []
        var changedNodeIds = Set<String>()
        for change in proposal.changes {
            switch change.kind {
            case .addNode:
                guard let node = change.node else { continue }
                changedNodeIds.insert(node.id)
                events.append(event(
                    canvasId: proposal.canvasId,
                    type: .nodeCreated,
                    nodeId: node.id,
                    proposalId: proposal.id,
                    summary: node.title
                ))
            case .updateNode:
                guard let nodeId = change.nodeId,
                      let afterNode = afterById[nodeId] else { continue }
                changedNodeIds.insert(nodeId)
                let beforeNode = beforeById[nodeId]
                events.append(event(
                    canvasId: proposal.canvasId,
                    type: .nodeUpdated,
                    nodeId: nodeId,
                    proposalId: proposal.id,
                    summary: afterNode.title
                ))
                if beforeNode?.status != afterNode.status {
                    events.append(event(
                        canvasId: proposal.canvasId,
                        type: .nodeStateChanged,
                        nodeId: nodeId,
                        proposalId: proposal.id,
                        summary: "\(afterNode.title) -> \(afterNode.status.rawValue)"
                    ))
                }
            case .attachArtifact:
                guard let draft = change.artifact,
                      let nodeId = draft.nodeId ?? change.nodeId else { continue }
                events.append(event(
                    canvasId: proposal.canvasId,
                    type: .artifactAttached,
                    nodeId: nodeId,
                    proposalId: proposal.id,
                    summary: draft.title,
                    artifactRefs: [draft.reference]
                ))
            case .refineSessionPrompt:
                guard let nodeId = change.nodeId else { continue }
                let directive = change.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                events.append(event(
                    canvasId: proposal.canvasId,
                    type: .nodeStateChanged,
                    nodeId: nodeId,
                    proposalId: proposal.id,
                    summary: directive.isEmpty
                        ? "Refine session prompt"
                        : "Refine session prompt: \(directive)"
                ))
            }
        }
        for node in after where changedNodeIds.contains(node.id) && node.status == .done {
            let refs = serviceArtifactRefs(node: node)
            guard !refs.isEmpty else { continue }
            events.append(event(
                canvasId: proposal.canvasId,
                type: .artifactAttached,
                nodeId: node.id,
                proposalId: proposal.id,
                summary: node.title,
                artifactRefs: refs
            ))
        }
        return events
    }

    func attachArtifact(_ artifact: PlannerArtifact, canvasId: String) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard artifact.canvasId == canvasId else {
                throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: artifact.canvasId)
            }
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == artifact.nodeId }) else {
                throw PlannerCoreError.nodeNotFound(artifact.nodeId)
            }
            // Stamp the artifact with the active run so re-runs keep their own
            // evidence separate (workflow-run-spec §6).
            var artifact = artifact
            if let existingId = artifactIdForSlot(
                existing: record.artifacts,
                canvasId: canvasId,
                nodeId: artifact.nodeId,
                reference: artifact.reference
            ) {
                artifact.id = existingId
            }
            if artifact.runId == nil {
                artifact.runId = record.activeRunId
            }
            record.artifacts = mergeArtifacts(record.artifacts, [artifact])
            var refs = record.nodes[nodeIndex].artifactRefs ?? []
            if !refs.contains(artifact.reference) {
                refs.append(artifact.reference)
            }
            record.nodes[nodeIndex].artifactRefs = refs
            mirrorIntoActiveRun(&record, nodeId: artifact.nodeId) { state in
                if !state.artifactIds.contains(artifact.id) {
                    state.artifactIds.append(artifact.id)
                }
                if !state.outputRefs.contains(artifact.reference) {
                    state.outputRefs.append(artifact.reference)
                }
            }
            recomputeActiveRun(&record)
            record.events.append(event(
                canvasId: canvasId,
                type: .artifactAttached,
                nodeId: artifact.nodeId,
                summary: artifact.title,
                artifactRefs: [artifact.reference]
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func updateNodeStatus(
        canvasId: String,
        nodeId: String,
        status: PlanningNodeStatus
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            let nodeKind = record.nodes[nodeIndex].nodeKind ?? .step
            guard nodeKind == .step else {
                throw PlannerCoreError.invalidNodeOutput("Only step nodes can change status.")
            }
            let previous = record.nodes[nodeIndex].status
            guard previous != status else { return record }
            record.nodes[nodeIndex].status = status
            if status != .blocked {
                record.nodes[nodeIndex].blockedReason = nil
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "\(record.nodes[nodeIndex].title) -> \(status.rawValue)"
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func updateNodeGate(
        canvasId: String,
        nodeId: String,
        executionMode: ExecutionMode
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            let nodeKind = record.nodes[nodeIndex].nodeKind ?? .step
            guard nodeKind == .step else {
                throw PlannerCoreError.invalidNodeOutput("Only step nodes can change gate mode.")
            }
            var node = record.nodes[nodeIndex]
            node.executionMode = executionMode
            switch executionMode {
            case .human:
                let approverCandidates = (node.approvers ?? [])
                    + (node.gate?.approvers ?? [])
                    + [record.canvas.ownerId, node.doerId]
                var seenApprovers = Set<String>()
                let approvers = approverCandidates.compactMap { raw -> String? in
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, !seenApprovers.contains(value) else { return nil }
                    seenApprovers.insert(value)
                    return value
                }
                node.approvers = approvers
                node.gate = PlannerNodeGate(
                    type: node.gate?.type ?? "human",
                    label: node.gate?.label ?? "Human review",
                    requiredArtifactRefs: node.gate?.requiredArtifactRefs ?? [],
                    approvers: approvers,
                    onFailGotoNodeId: node.gate?.onFailGotoNodeId
                )
            case .auto:
                node.gate = nil
                node.approvers = nil
            }
            record.nodes[nodeIndex] = node
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeUpdated,
                nodeId: nodeId,
                summary: "\(node.title) gate -> \(executionMode.rawValue)"
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func updateNodeSchedule(
        canvasId: String,
        nodeId: String,
        schedule: PlannerNodeSchedule?
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            let nodeKind = record.nodes[nodeIndex].nodeKind ?? .step
            guard nodeKind == .step else {
                throw PlannerCoreError.invalidNodeOutput("Only step nodes can be scheduled.")
            }

            var normalized = schedule
            if var value = normalized {
                value.intervalSeconds = max(60, value.intervalSeconds)
                value.prompt = value.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.enabled && value.prompt.isEmpty {
                    value.prompt = Self.defaultSchedulePrompt(for: record.nodes[nodeIndex])
                }
                if value.enabled {
                    value.nextRunAt = value.nextRunAt ?? Date().addingTimeInterval(TimeInterval(value.intervalSeconds))
                } else {
                    value.nextRunAt = nil
                }
                normalized = value
            }

            record.nodes[nodeIndex].schedule = normalized
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: normalized?.enabled == true
                    ? "Scheduled \(record.nodes[nodeIndex].title) every \(normalized?.intervalSeconds ?? 0)s"
                    : "Disabled schedule for \(record.nodes[nodeIndex].title)"
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func dueScheduledNodes(now: Date = Date()) -> [DueScheduledNode] {
        withLock {
            var due: [DueScheduledNode] = []
            for (canvasId, record) in document.canvases {
                for node in record.nodes {
                    guard let schedule = node.schedule,
                          schedule.enabled,
                          schedule.intervalSeconds >= 60,
                          (node.nodeKind ?? .step) == .step,
                          let sessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !sessionId.isEmpty else { continue }
                    let nextRunAt = schedule.nextRunAt ?? schedule.lastSentAt?.addingTimeInterval(TimeInterval(schedule.intervalSeconds)) ?? now
                    guard nextRunAt <= now else { continue }
                    due.append(DueScheduledNode(
                        canvasId: canvasId,
                        nodeId: node.id,
                        title: node.title,
                        sessionId: sessionId,
                        prompt: schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Self.defaultSchedulePrompt(for: node)
                            : schedule.prompt,
                        intervalSeconds: schedule.intervalSeconds
                    ))
                }
            }
            return due
        }
    }

    func markScheduledTickSent(
        canvasId: String,
        nodeId: String,
        sentAt: Date = Date()
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            guard var schedule = record.nodes[nodeIndex].schedule, schedule.enabled else {
                return record
            }
            schedule.intervalSeconds = max(60, schedule.intervalSeconds)
            schedule.lastSentAt = sentAt
            schedule.nextRunAt = sentAt.addingTimeInterval(TimeInterval(schedule.intervalSeconds))
            record.nodes[nodeIndex].schedule = schedule
            record.nodes[nodeIndex].workflowRunState = .readyToStart
            record.nodes[nodeIndex].status = .ready
            record.nodes[nodeIndex].blockedReason = nil
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Scheduled tick queued for \(record.nodes[nodeIndex].title)"
            ))
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = .readyToStart
                state.startedAt = sentAt
                state.finishedAt = nil
            }
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func deleteNode(canvasId: String, nodeId: String) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            let deletedNode = record.nodes.remove(at: nodeIndex)
            let remainingNodeIds = Set(record.nodes.map(\.id))
            let deletedUpstreamIds = (deletedNode.dependsOnNodeIds ?? [])
                .filter { $0 != nodeId && remainingNodeIds.contains($0) }
            let deletedArtifactRefs = Set(record.artifacts
                .filter { $0.nodeId == nodeId }
                .map(\.reference))

            record.nodes = record.nodes.map { node in
                var node = node
                if var dependsOnNodeIds = node.dependsOnNodeIds {
                    let dependedOnDeletedNode = dependsOnNodeIds.contains(nodeId)
                    dependsOnNodeIds.removeAll { $0 == nodeId }
                    if dependedOnDeletedNode {
                        for upstreamId in deletedUpstreamIds where upstreamId != node.id && !dependsOnNodeIds.contains(upstreamId) {
                            dependsOnNodeIds.append(upstreamId)
                        }
                    }
                    node.dependsOnNodeIds = dependsOnNodeIds
                }
                if !deletedArtifactRefs.isEmpty, var artifactRefs = node.artifactRefs {
                    artifactRefs.removeAll { deletedArtifactRefs.contains($0) }
                    node.artifactRefs = artifactRefs
                }
                return node
            }
            record.artifacts.removeAll { $0.nodeId == nodeId }
            for runIndex in record.runs.indices {
                record.runs[runIndex].nodeStates.removeValue(forKey: nodeId)
                record.runs[runIndex].updatedAt = Date()
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeUpdated,
                nodeId: nodeId,
                summary: "Deleted \(deletedNode.title)"
            ))
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func nodeContract(canvasId: String, nodeId: String) throws -> PlannerNodeContract {
        try withLock {
            let record = try requireRecord(canvasId: canvasId)
            guard let node = record.nodes.first(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            return makeNodeContract(record: record, node: node)
        }
    }

    func submitNodeOutput(
        canvasId: String,
        nodeId: String,
        output: PlannerNodeOutput
    ) throws -> (
        record: CanvasRecord,
        routes: [PlannerOutputRoute],
        version: NodeVersion?,
        autoDispatchCandidates: [PlanningNode]
    ) {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard output.nodeId == nodeId else {
                throw PlannerCoreError.invalidNodeOutput("node output nodeId must match the URL node id")
            }
            guard let sourceIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }

            let downstreamNodeIds = Set(record.nodes.filter { ($0.dependsOnNodeIds ?? []).contains(nodeId) }.map(\.id))
            let allowedTargets = downstreamNodeIds.union(["owner"])
            let routeTargets = allOutputRouteTargets(output)
            let invalidTargets = routeTargets.filter { !allowedTargets.contains($0) }
            if let invalid = invalidTargets.sorted().first {
                let allowed = allowedTargets.sorted().joined(separator: ", ")
                throw PlannerCoreError.invalidNodeOutput(
                    "Invalid routeTo '\(invalid)'. Route only to downstream nodes or owner. Allowed: \(allowed)."
                )
            }
            let summary = output.message?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if output.status == .done && summary.isEmpty && output.artifacts.isEmpty {
                throw PlannerCoreError.invalidNodeOutput(
                    "A done node output must include a message summary or at least one artifact."
                )
            }

            var current = record.nodes[sourceIndex]
            switch output.status {
            case .done:
                current.blockedReason = nil
                if current.executionMode == .human {
                    // Parked at a human gate — plan-layer status mirrors
                    // `nodeStatus(for: .gateWait)` so design mode shows it
                    // in the attention bucket, not as "In progress".
                    current.status = Self.nodeStatus(for: .gateWait)
                    current.workflowRunState = .gateWait
                } else {
                    current.status = .done
                    current.workflowRunState = .done
                }
            case .blocked:
                current.status = .blocked
                current.workflowRunState = .failed
                current.blockedReason = summary.isEmpty ? nil : summary
            case .needsReview:
                current.status = Self.nodeStatus(for: .gateWait)
                current.workflowRunState = .gateWait
                current.blockedReason = summary.isEmpty ? nil : summary
            }
            // Latch the explicit-submit marker. `applySessionRunStateLocked`
            // checks this to refuse overwriting the just-submitted state from
            // a transient session-status mirror (e.g. Claude returning to idle
            // right after `submit_node_output blocked`). Cleared on
            // re-dispatch / abandon.
            current.outputSubmittedAt = Date()

            var artifactRefs = current.artifactRefs ?? []
            var newArtifacts: [PlannerArtifact] = []
            var newVersions: [PlannerArtifactVersion] = []
            // ENG-3 · Capture the input snapshot once per submit — same bundle
            // attaches to every artifact in this output (they all came from
            // the same node tick).
            let inputSnapshot = buildInputSnapshot(node: current, record: record)
            let now = Date()
            for item in output.artifacts {
                let reference = item.reference.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reference.isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("Artifact reference cannot be empty.")
                }
                let artifactId = artifactIdForSlot(
                    existing: record.artifacts,
                    canvasId: canvasId,
                    nodeId: nodeId,
                    reference: reference
                ) ?? "artifact-\(canvasId)-\(nodeId)-\(stableSuffix(reference))"
                let artifact = PlannerArtifact(
                    id: artifactId,
                    canvasId: canvasId,
                    nodeId: nodeId,
                    kind: item.kind,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? reference : item.title,
                    reference: reference,
                    status: output.status.rawValue,
                    createdAt: now,
                    payload: item.payload
                )
                newArtifacts.append(artifact)
                if !artifactRefs.contains(reference) {
                    artifactRefs.append(reference)
                }

                // ENG-3 · Append one version row per artifact in this submit.
                // The store NEVER physically replaces — `mergeArtifacts`
                // below still de-dupes the latest-per-slot mirror for the
                // UI default surface, but the version chain is preserved
                // here for re-viewing old context.
                let slotKey = artifactSlotKey(canvasId: canvasId, nodeId: nodeId, reference: reference)
                let parent = latestVersion(
                    in: record.artifactVersions,
                    slotKey: slotKey
                )?.versionId
                let payloadRef = (item.payload?.objectValue?["blobRef"]?.stringValue).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? reference
                let version = PlannerArtifactVersion(
                    versionId: "ver-\(canvasId)-\(nodeId)-\(stableSuffix("\(reference)-\(artifactId)-\(now.timeIntervalSince1970)"))",
                    parentVersionId: parent,
                    canvasId: canvasId,
                    nodeId: nodeId,
                    artifactId: artifactId,
                    artifactSlotKey: slotKey,
                    payloadRef: payloadRef,
                    payloadInline: item.payload,
                    inputSnapshot: inputSnapshot,
                    displayStrategy: .latest,
                    forceNewVersion: output.forceNewVersion,
                    submittedBy: nil,
                    submittedByKind: .agent,
                    metadata: .object([
                        "title": .string(artifact.title),
                        "kind": .string(item.kind.rawValue),
                        "status": .string(output.status.rawValue)
                    ]),
                    createdAt: now
                )
                newVersions.append(version)
            }
            current.artifactRefs = artifactRefs
            record.nodes[sourceIndex] = current
            record.artifacts = mergeArtifacts(record.artifacts, newArtifacts)
            record.artifactVersions.append(contentsOf: newVersions)
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = current.workflowRunState ?? state.runState
                if current.workflowRunState == .done || current.workflowRunState == .failed {
                    state.finishedAt = state.finishedAt ?? Date()
                }
                for artifact in newArtifacts {
                    if !state.artifactIds.contains(artifact.id) {
                        state.artifactIds.append(artifact.id)
                    }
                    if !state.outputRefs.contains(artifact.reference) {
                        state.outputRefs.append(artifact.reference)
                    }
                }
            }

            var routes: [PlannerOutputRoute] = []
            let outputEvent = event(
                canvasId: canvasId,
                type: .nodeOutputSubmitted,
                nodeId: nodeId,
                summary: summary.isEmpty ? "Output submitted for \(current.title)" : summary,
                artifactRefs: newArtifacts.map(\.reference)
            )
            record.events.append(outputEvent)
            for artifact in newArtifacts {
                record.events.append(event(
                    canvasId: canvasId,
                    type: .artifactAttached,
                    nodeId: nodeId,
                    summary: artifact.title,
                    artifactRefs: [artifact.reference]
                ))
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Node output moved \(current.title) to \(output.status.rawValue)"
            ))

            let routedMessage = summary.isEmpty ? nil : summary
            for target in routeTargets.sorted() {
                if target == "owner" {
                    routes.append(PlannerOutputRoute(
                        target: target,
                        targetNodeId: nil,
                        targetSessionId: nil,
                        routedMessage: routedMessage,
                        artifactRefs: newArtifacts.filter { artifact in outputArtifact(artifact.reference, routesTo: target, in: output) }.map(\.reference)
                    ))
                    continue
                }
                guard let targetIndex = record.nodes.firstIndex(where: { $0.id == target }) else { continue }
                let routedArtifacts = newArtifacts.filter { artifact in
                    outputArtifact(artifact.reference, routesTo: target, in: output)
                }
                if routedMessage != nil, output.message?.routeTo.contains(target) == true {
                    appendContextSource(
                        to: &record.nodes[targetIndex],
                        title: "Output from \(current.title)",
                        reference: "planner-output://\(outputEvent.id)"
                    )
                }
                for artifact in routedArtifacts {
                    appendContextSource(
                        to: &record.nodes[targetIndex],
                        title: artifact.title,
                        reference: artifact.reference
                    )
                }
                if record.nodes[targetIndex].doerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.nodes[targetIndex].status = .blocked
                    record.nodes[targetIndex].workflowRunState = .gateWait
                    mirrorIntoActiveRun(&record, nodeId: record.nodes[targetIndex].id) { state in
                        state.runState = .gateWait
                    }
                } else if record.nodes[targetIndex].sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    record.nodes[targetIndex].status = .ready
                    record.nodes[targetIndex].workflowRunState = .readyToStart
                    mirrorIntoActiveRun(&record, nodeId: record.nodes[targetIndex].id) { state in
                        state.runState = .readyToStart
                    }
                }
                routes.append(PlannerOutputRoute(
                    target: target,
                    targetNodeId: target,
                    targetSessionId: record.nodes[targetIndex].sessionId,
                    routedMessage: routedMessage,
                    artifactRefs: routedArtifacts.map(\.reference)
                ))
            }

            // ENG-2 / E2.1: append a NodeVersion to the per-(canvas,node)
            // chain. `force_new_version: true` (E2.3) bypasses the "already
            // latched" check — we always create a fresh version. The default
            // path also appends, since every submit produces a new version
            // (there's no overwrite in the post-meeting model). Inputs are
            // captured from the v2 contract derived off the current node.
            let (derivedV2, _) = NodeContractV2.derive(from: current)
            let priorVersion = record.nodeVersions.latest(canvasId: canvasId, nodeId: nodeId)
            let trigger: NodeVersionTrigger = {
                if output.forceNewVersion { return .forceRerun }
                if priorVersion == nil { return .manual }
                return .manual
            }()
            let externalSnapshot: [NodeVersionExternalSnapshot] = derivedV2.input.external.map { ext in
                NodeVersionExternalSnapshot(
                    connector: ext.connector,
                    ref: ext.ref,
                    syncSessionId: ext.syncSessionId,
                    fetchedArtifactId: nil
                )
            }
            // At submit time we don't re-run the merge — but we do capture
            // the contract shape that *would* have driven it so the version
            // is a faithful "what input did this produce on" record.
            // (Distinct from `inputSnapshot` above which is the ENG-3
            // PlannerArtifactInputSnapshot bundle for the artifact chain.)
            let nodeVersionInputSnapshot = NodeVersionInputSnapshot(
                upstreamNodeId: derivedV2.input.upstream.sourceNodeId,
                upstreamVersionId: derivedV2.input.upstream.sourceNodeId.flatMap { upId in
                    record.nodeVersions.latest(canvasId: canvasId, nodeId: upId)?.id
                },
                external: externalSnapshot,
                dialogueTurns: derivedV2.input.dialogue.enabled ? derivedV2.input.dialogue.window.nTurns : nil,
                mergeLog: ["submit by session=\(current.sessionId ?? "none") trigger=\(trigger.rawValue)"]
            )
            let version = NodeVersion.append(
                canvasId: canvasId,
                nodeId: nodeId,
                previousVersions: record.nodeVersions,
                sessionId: current.sessionId,
                trigger: trigger,
                inputs: nodeVersionInputSnapshot,
                artifactIds: newArtifacts.map(\.id),
                status: output.status,
                startedAt: Date(),
                finishedAt: Date()
            )
            record.nodeVersions.append(version)
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Appended version v\(version.versionIndex) (\(version.id)) for \(current.title)"
            ))

            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)

            // ENG-2 / E2.2: auto-dispatch candidates — downstream nodes that
            // (a) just flipped to readyToStart, (b) have no live session, and
            // (c) declare auto execution mode. The BoardAPI layer is
            // responsible for materializing the session (spawn terminal etc).
            // This list intentionally excludes human-mode nodes (those wait on
            // a human dispatch click).
            let candidates: [PlanningNode] = record.nodes.filter { node in
                guard routeTargets.contains(node.id) else { return false }
                guard node.workflowRunState == .readyToStart else { return false }
                let hasSession = (node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                if hasSession { return false }
                return node.executionMode == .auto
            }
            return (record, routes, version, candidates)
        }
    }

    func bindNodeInput(
        canvasId: String,
        nodeId: String,
        input: String,
        source: ContextSource
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var node = record.nodes[nodeIndex]
            guard node.schema.inputs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedInput }) else {
                throw PlannerCoreError.invalidNodeOutput("Unknown input '\(input)' for node \(nodeId).")
            }
            node.contextSources.removeAll { existing in
                existing.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedInput
            }
            node.contextSources.append(source)
            record.nodes[nodeIndex] = node
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeUpdated,
                nodeId: nodeId,
                summary: "Set input \(input) for \(node.title)"
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func bindKanbanItemSubCanvas(
        canvasId: String,
        artifactId: String,
        itemId: String,
        subCanvasId: String
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let artifactIndex = record.artifacts.firstIndex(where: { $0.id == artifactId }) else {
                throw PlannerCoreError.invalidNodeOutput("Kanban artifact not found.")
            }
            guard record.artifacts[artifactIndex].kind == .kanban else {
                throw PlannerCoreError.invalidNodeOutput("Artifact \(artifactId) is not a kanban artifact.")
            }
            let payload = record.artifacts[artifactIndex].payload
            let kanbanPayload = setKanbanItemSubCanvas(
                payload: payload,
                itemId: itemId,
                subCanvasId: subCanvasId
            ) ?? setKanbanItemSubCanvas(
                payload: kanbanPayloadFromContentArtifact(record.artifacts[artifactIndex]),
                itemId: itemId,
                subCanvasId: subCanvasId
            )
            guard let updatedPayload = kanbanPayload else {
                throw PlannerCoreError.invalidNodeOutput("Kanban item \(itemId) was not found.")
            }
            record.artifacts[artifactIndex].payload = updatedPayload
            record.events.append(event(
                canvasId: canvasId,
                type: .artifactAttached,
                nodeId: record.artifacts[artifactIndex].nodeId,
                summary: "Linked kanban item to sub-canvas",
                artifactRefs: [record.artifacts[artifactIndex].reference]
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    private func setKanbanItemSubCanvas(
        payload: BoardJSONValue?,
        itemId: String,
        subCanvasId: String
    ) -> BoardJSONValue? {
        guard case .object(var object) = payload,
              case .array(let rawItems)? = object["items"] else {
            return nil
        }
        var didUpdate = false
        let items = rawItems.map { value -> BoardJSONValue in
            guard case .object(var item) = value,
                  case .string(let id)? = item["id"],
                  id == itemId else {
                return value
            }
            item["subCanvasId"] = .string(subCanvasId)
            didUpdate = true
            return .object(item)
        }
        guard didUpdate else { return nil }
        object["items"] = .array(items)
        return .object(object)
    }

    private func kanbanPayloadFromContentArtifact(_ artifact: PlannerArtifact) -> BoardJSONValue? {
        guard artifact.kind == .kanban,
              let content = try? PlannerArtifactStorage.content(for: artifact).content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return kanbanPayloadFromMarkdownTable(content)
    }

    private func kanbanPayloadFromMarkdownTable(_ content: String) -> BoardJSONValue? {
        let rows = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("|") && $0.hasSuffix("|") }
            .map { line in
                line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { cleanupMarkdownCell(String($0)) }
            }
        guard rows.count >= 2 else { return nil }
        let header = rows[0].map { $0.lowercased() }
        let bodyRows = rows.dropFirst().filter { !isMarkdownSeparatorRow($0) }
        guard let titleIndex = header.firstIndex(where: { $0.contains("idea") || $0.contains("title") || $0.contains("name") }) else {
            return nil
        }
        let descriptionIndex = header.firstIndex(where: { $0.contains("description") || $0.contains("note") || $0.contains("summary") })
        let priorityIndex = header.firstIndex(where: { $0.contains("priority") })
        let statusIndex = header.firstIndex(where: { $0.contains("status") || $0.contains("column") })
        var columnsById: [String: String] = [:]
        var items: [BoardJSONValue] = []
        for (index, row) in bodyRows.enumerated() {
            guard row.indices.contains(titleIndex) else { continue }
            let title = row[titleIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let rawStatus = statusIndex.flatMap { row.indices.contains($0) ? row[$0] : nil }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let columnTitle = rawStatus?.isEmpty == false ? rawStatus! : "Backlog"
            let columnId = stableSuffix(columnTitle)
            columnsById[columnId] = columnTitle
            var descriptionParts: [String] = []
            if let priority = priorityIndex.flatMap({ row.indices.contains($0) ? row[$0] : nil })?.trimmingCharacters(in: .whitespacesAndNewlines),
               !priority.isEmpty, priority != "-" {
                descriptionParts.append("Priority: \(priority)")
            }
            if let description = descriptionIndex.flatMap({ row.indices.contains($0) ? row[$0] : nil })?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty, description != "-" {
                descriptionParts.append(description)
            }
            var item: [String: BoardJSONValue] = [
                "id": .string("item-\(index + 1)"),
                "columnId": .string(columnId),
                "title": .string(title),
                "subCanvasId": .null
            ]
            if !descriptionParts.isEmpty {
                item["description"] = .string(descriptionParts.joined(separator: "\n"))
            }
            items.append(.object(item))
        }
        guard !items.isEmpty else { return nil }
        let columns = columnsById
            .sorted { $0.value < $1.value }
            .map { BoardJSONValue.object(["id": .string($0.key), "title": .string($0.value)]) }
        return .object([
            "version": .number(1),
            "columns": .array(columns),
            "items": .array(items)
        ])
    }

    private func isMarkdownSeparatorRow(_ row: [String]) -> Bool {
        row.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private func cleanupMarkdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateRunNodeAssignee(
        canvasId: String,
        runId: String,
        nodeId: String,
        assigneeId: String?
    ) throws -> WorkflowRun {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard record.nodes.contains(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            guard let runIndex = record.runs.firstIndex(where: { $0.id == runId }) else {
                throw PlannerCoreError.runNotFound(runId)
            }
            let trimmed = assigneeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var state = record.runs[runIndex].nodeStates[nodeId] ?? RunNodeState(nodeId: nodeId)
            state.assigneeId = trimmed.isEmpty ? nil : trimmed
            record.runs[runIndex].nodeStates[nodeId] = state
            record.runs[runIndex].updatedAt = Date()
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeUpdated,
                nodeId: nodeId,
                summary: trimmed.isEmpty ? "Cleared delivery assignee" : "Updated delivery assignee"
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record.runs[runIndex]
        }
    }

    func updateNodeLayout(canvasId: String, nodeId: String, layout: PlannerNodeLayout) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            record.nodes[index].layout = layout
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeUpdated,
                nodeId: nodeId,
                summary: "Updated layout for \(record.nodes[index].title)"
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    /// Execution-layer mutation: bind an existing session onto a node DIRECTLY,
    /// no proposal / owner gate. Sets `sessionId`, mirrors it onto
    /// `chatThreadId`, marks the node as session-sourced and moves it to
    /// `running`. Permission is enforced by the caller (`requireNodeUpdate`).
    func bindSession(
        canvasId: String,
        nodeId: String,
        sessionId: String
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            guard !hasActiveSessionLocked(nodeId: nodeId, nodes: record.nodes) else {
                throw PlannerCoreError.activeSessionExists(nodeId: nodeId)
            }
            record.nodes[index].sessionId = sessionId
            record.nodes[index].chatThreadId = sessionId
            record.nodes[index].source = .session
            record.nodes[index].workflowRunState = .running
            record.nodes[index].status = .working
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Bound session to \(record.nodes[index].title)"
            ))
            // Mirror into the active run: a bind starts a new attempt. Q3 lock —
            // one active session per (run, node); re-binding opens a fresh attempt.
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.sessionId = sessionId
                state.chatThreadId = sessionId
                state.runState = .running
                state.startedAt = state.startedAt ?? Date()
                state.attempts.append(NodeAttempt(
                    index: state.attempts.count,
                    sessionId: sessionId,
                    runState: .running
                ))
            }
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    /// Execution-layer mutation: dispatch a node DIRECTLY, no proposal / owner
    /// gate. Sets `dispatch` + `workflowRunState`, and for spawning runners
    /// (claude/codex/byoa-local) materializes the `session` PlanningNode +
    /// derived step → session edge immediately. `human` gates at `gateWait`;
    /// `ci-agent` records no session node (proposal-less no-op per existing
    /// behavior). Returns the updated record plus the dispatched node so the
    /// caller can record the spawn intent. Permission is enforced by the
    /// caller (`requireNodeUpdate`).
    func dispatchNode(
        canvasId: String,
        nodeId: String,
        dispatch: PlannerNodeDispatch
    ) throws -> (record: CanvasRecord, dispatchedNode: PlanningNode) {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            guard !hasActiveSessionLocked(nodeId: nodeId, nodes: record.nodes) else {
                throw PlannerCoreError.activeSessionExists(nodeId: nodeId)
            }
            let runner = dispatch.runner
            let runState: PlannerWorkflowRunState = runner == .human ? .running : .dispatched
            record.nodes[index].dispatch = dispatch
            record.nodes[index].workflowRunState = runState
            record.nodes[index].status = .working
            // Release the explicit-submit latch — a fresh dispatch means the
            // node is taking new work and any subsequent session-state mirror
            // is once again the authoritative signal.
            record.nodes[index].outputSubmittedAt = nil
            record.nodes[index].blockedReason = nil
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Dispatched \(record.nodes[index].title) via \(runner.rawValue)"
            ))
            // Mirror the dispatched step's run-state into the active run.
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = runState
                state.startedAt = state.startedAt ?? Date()
            }
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return (record, record.nodes[index])
        }
    }

    func abandonNodeSession(canvasId: String, nodeId: String) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            guard record.nodes[index].sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                throw PlannerCoreError.activeSessionExists(nodeId: nodeId)
            }
            record.nodes[index].dispatch = nil
            record.nodes[index].workflowRunState = nil
            record.nodes[index].sessionId = nil
            record.nodes[index].chatThreadId = nil
            record.nodes[index].outputSubmittedAt = nil
            if record.nodes[index].status == .working {
                record.nodes[index].status = .ready
            }
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = .pending
                state.sessionId = nil
                state.chatThreadId = nil
                state.startedAt = nil
                state.finishedAt = nil
                state.nextAction = nil
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Abandoned session creation for \(record.nodes[index].title)"
            ))
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func detachNodeSession(canvasId: String, nodeId: String) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            record.nodes[index].dispatch = nil
            record.nodes[index].workflowRunState = nil
            record.nodes[index].sessionId = nil
            record.nodes[index].chatThreadId = nil
            record.nodes[index].outputSubmittedAt = nil
            if record.nodes[index].status == .working {
                record.nodes[index].status = .ready
            }
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = .pending
                state.sessionId = nil
                state.chatThreadId = nil
                state.startedAt = nil
                state.finishedAt = nil
                state.nextAction = nil
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Detached session from \(record.nodes[index].title)"
            ))
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    private func hasActiveSessionLocked(nodeId: String, nodes: [PlanningNode]) -> Bool {
        if let node = nodes.first(where: { $0.id == nodeId }),
           node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           node.workflowRunState != .done,
           node.workflowRunState != .failed {
            return true
        }
        return nodes.contains { node in
            node.nodeKind == .session
                && (node.dependsOnNodeIds ?? []).contains(nodeId)
                && node.workflowRunState != .done
                && node.workflowRunState != .failed
        }
    }

    private func makeNodeContract(record: CanvasRecord, node: PlanningNode) -> PlannerNodeContract {
        let upstreamIds = Set(node.dependsOnNodeIds ?? [])
        let upstreamNodes = record.nodes.filter { upstreamIds.contains($0.id) }
        let downstreamNodes = record.nodes.filter { ($0.dependsOnNodeIds ?? []).contains(node.id) }
        let routeTargets = downstreamNodes.map { target in
            PlannerRouteTarget(
                id: target.id,
                label: target.title,
                kind: (target.nodeKind ?? .step).rawValue,
                hasDoer: !target.doerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasSession: target.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            )
        } + [
            PlannerRouteTarget(
                id: "owner",
                label: "Canvas owner",
                kind: "owner",
                hasDoer: true,
                hasSession: false
            )
        ]
        let (v2, migrationWarnings) = NodeContractV2.derive(from: node)
        for warning in migrationWarnings {
            MLog("[NodeContractV2][migrate] canvas=\(record.canvas.id) node=\(node.id) — \(warning)")
        }
        return PlannerNodeContract(
            canvas: record.canvas,
            node: node,
            upstreamNodes: upstreamNodes,
            downstreamNodes: downstreamNodes,
            allowedRouteTargets: routeTargets,
            expectedArtifactKinds: PlannerArtifactKind.allCases,
            inlinePayloadLimitBytes: PlannerArtifactStorage.inlinePayloadLimitBytes,
            artifactPayloadTypes: PlannerArtifactPayloadType.allCases,
            completionCriteria: [
                node.schema.goal,
                "Submit output with status done, blocked, or needs_review.",
                "Small artifact payloads may be inline; large text/html/json/file content must be submitted as payload.file.path inside the session cwd or canvas workspace.",
                "Route messages and artifacts only to downstream nodes or owner.",
                "Output is always a full snapshot — never submit an increment / diff payload (see Node Contract v2)."
            ],
            v2: v2
        )
    }

    private func allOutputRouteTargets(_ output: PlannerNodeOutput) -> Set<String> {
        var targets = Set(output.message?.routeTo ?? [])
        for artifact in output.artifacts {
            targets.formUnion(artifact.routeTo)
        }
        return Set(targets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private func outputArtifact(_ reference: String, routesTo target: String, in output: PlannerNodeOutput) -> Bool {
        output.artifacts.contains { artifact in
            artifact.reference == reference && artifact.routeTo.contains(target)
        }
    }

    private static func defaultSchedulePrompt(for node: PlanningNode) -> String {
        [
            "Scheduled meee2 planner tick.",
            "Node ID: \(node.id)",
            "Node: \(node.title)",
            "Goal: \(node.schema.goal)",
            "Call read_node_contract first. If this tick produces new output, call submit_node_output; if there is nothing to update, reply with a brief status summary."
        ].joined(separator: "\n")
    }

    private func appendContextSource(to node: inout PlanningNode, title: String, reference: String) {
        guard !node.contextSources.contains(where: { $0.reference == reference }) else { return }
        node.contextSources.append(ContextSource(kind: .artifact, title: title, reference: reference))
    }

    // MARK: - ENG-3 helpers · artifact version chain

    /// Stable key for the logical artifact "slot" — matches the dedupe rule
    /// used by `sameArtifactSlot` so versions and the latest-per-slot mirror
    /// share one identity.
    private func artifactSlotKey(canvasId: String, nodeId: String, reference: String) -> String {
        "\(canvasId)|\(nodeId)|\(normalizeArtifactReference(reference))"
    }

    /// Most recent version for a slot, or `nil` if this is the first submit.
    private func latestVersion(
        in versions: [PlannerArtifactVersion],
        slotKey: String
    ) -> PlannerArtifactVersion? {
        versions
            .filter { $0.artifactSlotKey == slotKey }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Capture the three input sources for the snapshot bundle. Best-effort:
    /// this populates upstream artifact ref + dialogue window descriptor.
    /// External-output backfill happens via the bound sync sessions (INT-2).
    private func buildInputSnapshot(
        node: PlanningNode,
        record: CanvasRecord
    ) -> PlannerArtifactInputSnapshot {
        // Upstream: pick the most recent artifact attached to the first
        // upstream dependency. Matches `NodeContractUpstreamInput.sourceNodeId`.
        var upstreamRef: String?
        if let upstreamId = node.dependsOnNodeIds?.first {
            upstreamRef = record.artifacts
                .filter { $0.nodeId == upstreamId }
                .max(by: { $0.createdAt < $1.createdAt })?.reference
        }
        // External: surface the declared external inputs as opaque entries.
        // The actual fetched payload pointers get filled in by sync sessions
        // (INT-2); recording the declaration is the lossless minimum.
        var external: [BoardJSONValue] = []
        for source in node.contextSources where source.kind != .chatHistory {
            external.append(.object([
                "title": .string(source.title),
                "ref": .string(source.reference),
                "kind": .string(source.kind.rawValue)
            ]))
        }
        // Dialogue window: record the rolling-N descriptor; the actual turns
        // get filled in by the runtime (ENG-2) when input合流 lands.
        let dialogue: BoardJSONValue = .object([
            "kind": .string("rolling"),
            "n_turns": .number(Double(NodeContractV2.defaultDialogueTurns))
        ])
        return PlannerArtifactInputSnapshot(
            upstreamArtifactRef: upstreamRef,
            externalOutputs: external,
            dialogueWindow: dialogue
        )
    }

    /// Public read API · list all versions for an artifact slot, ordered
    /// newest-first. UI-1 / version dropdown call this.
    func artifactVersions(
        canvasId: String,
        nodeId: String,
        reference: String
    ) throws -> [PlannerArtifactVersion] {
        try withLock {
            let record = try requireRecord(canvasId: canvasId)
            let slotKey = artifactSlotKey(canvasId: canvasId, nodeId: nodeId, reference: reference)
            return record.artifactVersions
                .filter { $0.artifactSlotKey == slotKey }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Public read API · fetch one version by id. Returns the version row
    /// plus its input snapshot — caller can reconstruct the context.
    func artifactVersion(
        canvasId: String,
        versionId: String
    ) throws -> PlannerArtifactVersion? {
        try withLock {
            let record = try requireRecord(canvasId: canvasId)
            return record.artifactVersions.first { $0.versionId == versionId }
        }
    }

    private func mergeArtifacts(
        _ existing: [PlannerArtifact],
        _ incoming: [PlannerArtifact]
    ) -> [PlannerArtifact] {
        var result = existing
        for artifact in incoming {
            var next = artifact
            if let existingSlot = result.first(where: { sameArtifactSlot($0, next) }),
               artifactMergeScore(existingSlot) > artifactMergeScore(next) {
                continue
            }
            if let existingSlot = result.first(where: { sameArtifactSlot($0, next) }) {
                next.id = existingSlot.id
            }
            result.removeAll { existing in
                existing.id == next.id || sameArtifactSlot(existing, next)
            }
            result.append(next)
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    private func artifactIdForSlot(
        existing: [PlannerArtifact],
        canvasId: String,
        nodeId: String,
        reference: String
    ) -> String? {
        existing.first { artifact in
            artifact.canvasId == canvasId
                && artifact.nodeId == nodeId
                && normalizeArtifactReference(artifact.reference) == normalizeArtifactReference(reference)
        }?.id
    }

    private func sameArtifactSlot(_ lhs: PlannerArtifact, _ rhs: PlannerArtifact) -> Bool {
        lhs.canvasId == rhs.canvasId
            && lhs.nodeId == rhs.nodeId
            && normalizeArtifactReference(lhs.reference) == normalizeArtifactReference(rhs.reference)
    }

    private func normalizeArtifactReference(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func artifactMergeScore(_ artifact: PlannerArtifact) -> Int {
        var score = 0
        if artifact.kind != .generic { score += 100 }
        if artifact.producedBy == .agent { score += 50 }
        guard let payload = artifact.payload?.objectValue else { return score }
        score += 1_000
        if payload["blobRef"]?.stringValue?.isEmpty == false { score += 2_000 }
        if case .array(let items)? = payload["items"], !items.isEmpty {
            score += 10_000 + items.count
        }
        return score
    }

    private func derivedArtifacts(from nodes: [PlanningNode], canvasId: String) -> [PlannerArtifact] {
        nodes.flatMap { node in
            (node.artifactRefs ?? []).map { ref in
                PlannerArtifact(
                    id: "artifact-\(stableSuffix(ref))",
                    canvasId: canvasId,
                    nodeId: node.id,
                    kind: .generic,
                    title: ref,
                    reference: ref,
                    status: node.status.rawValue,
                    createdAt: Date()
                )
            }
        }
    }

    private func proposalArtifacts(
        from proposal: PlanProposal,
        nodes: [PlanningNode],
        canvasId: String
    ) -> [PlannerArtifact] {
        let nodeIds = Set(nodes.map(\.id))
        return proposal.changes.enumerated().compactMap { index, change in
            guard change.kind == .attachArtifact,
                  let draft = change.artifact,
                  let nodeId = draft.nodeId ?? change.nodeId,
                  nodeIds.contains(nodeId) else {
                return nil
            }
            let reference = draft.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = draft.status?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty else { return nil }
            return PlannerArtifact(
                id: "artifact-\(canvasId)-\(nodeId)-proposal-\(index)-\(stableSuffix(reference))",
                canvasId: canvasId,
                nodeId: nodeId,
                kind: draft.kind,
                title: title.isEmpty ? reference : title,
                reference: reference,
                status: status?.isEmpty == false ? status! : "attached",
                createdAt: Date(),
                payload: draft.payload,
                producedBy: .agent
            )
        }
    }

    private func serviceArtifactRefs(node: PlanningNode) -> [String] {
        var refs = node.artifactRefs ?? []
        // See `artifactRefs(for:)` — synthetic handle only when the done node
        // has no concrete artifact, otherwise it is a duplicate "output" entry.
        if node.status == .done && refs.isEmpty {
            refs.append("artifact://\(node.id)/output")
        }
        if let subCanvasId = node.subCanvasId {
            refs.append("subcanvas:\(subCanvasId)")
        }
        return Array(Set(refs)).sorted()
    }

    private func stableSuffix(_ raw: String) -> String {
        let normalized = raw
            .lowercased()
            .map { char in char.isLetter || char.isNumber ? char : "-" }
            .reduce(into: "") { $0.append($1) }
        return normalized.isEmpty ? UUID().uuidString.lowercased() : normalized
    }

    private func event(
        canvasId: String,
        type: PlannerEventType,
        nodeId: String? = nil,
        proposalId: String? = nil,
        summary: String,
        artifactRefs: [String] = []
    ) -> PlannerEvent {
        PlannerEvent(
            id: "event-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            type: type,
            nodeId: nodeId,
            proposalId: proposalId,
            summary: summary,
            artifactRefs: artifactRefs,
            createdAt: Date()
        )
    }

    private static func loadDocument(
        rootURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> StoreDocument {
        let canvasesURL = rootURL.appendingPathComponent("canvases", isDirectory: true)
        guard let canvasDirectories = try? fileManager.contentsOfDirectory(
            at: canvasesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StoreDocument(canvases: [:])
        }
        var canvases: [String: CanvasRecord] = [:]
        for directory in canvasDirectories {
            let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            let stateURL = directory.appendingPathComponent("state.json")
            guard fileManager.fileExists(atPath: stateURL.path),
                  let data = try? Data(contentsOf: stateURL),
                  let record = try? decoder.decode(CanvasRecord.self, from: data) else {
                continue
            }
            canvases[record.canvas.id] = record
        }
        return StoreDocument(canvases: canvases)
    }

    private static func safePathComponent(_ raw: String) -> String {
        let mapped = raw.map { char in
            char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" ? char : "-"
        }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_/ "))
        return value.isEmpty ? "canvas" : value
    }
}

enum PlannerBoardBridge {
    private static let service = PlannerCoreService()
    static var store = PlannerStore.shared

    static func canvasState(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> (
        canvas: PlanningCanvas,
        nodes: [PlanningNode],
        states: [NodeStateSnapshot],
        proposals: [PlanProposal],
        access: PlannerAccess,
        activities: [PlannerActivity],
        events: [PlannerEvent],
        artifacts: [PlannerArtifact],
        edges: [PlannerGraphEdge]
    ) {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas, actorUserId: actorUserId)
        let isTemplate = (boardCanvas.kind ?? .board) == .template
        let seedNodes = isTemplate ? PlannerDeliveryPipelineTemplate.build(canvas: canvas).nodes : []
        var record = try store.record(for: canvas, seedNodes: seedNodes)
        if isTemplate {
            record = try store.seedNodesIfEmpty(canvasId: canvas.id, seedNodes: seedNodes)
        } else {
            record = try store.replaceNodesIfUnmodified(
                canvasId: canvas.id,
                matching: service.nodeMock(canvasId: canvas.id),
                with: []
            )
        }
        let nodes = record.nodes
        let access = PlannerPermission.access(for: record.canvas, nodes: nodes, actorId: actorUserId)
        // Visibility gate: a private canvas is only readable by its owner or a
        // role-holder. A bare viewer on a private canvas is not a member.
        try requireCanvasVisible(record.canvas, access: access)
        return (
            record.canvas,
            nodes,
            service.readNodeState(nodes: nodes),
            record.proposals,
            access,
            PlannerActivityStore.shared.activities(
                for: record.canvas.id,
                fallback: fallbackActivity(for: record.canvas, nodes: nodes, actorId: access.actorId)
            ),
            record.events.sorted { $0.createdAt > $1.createdAt },
            record.artifacts,
            graphEdges(for: nodes)
        )
    }

    static func graphState(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return PlannerGraphState(
            canvas: state.canvas,
            nodes: state.nodes,
            states: state.states,
            proposals: state.proposals,
            access: state.access,
            activities: state.activities,
            events: state.events,
            artifacts: state.artifacts,
            edges: state.edges
        )
    }

    static func clearCanvasContent(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        if boardCanvas.kind == .monitor {
            throw PlannerCoreError.monitorClearNotAllowed(canvasId)
        }
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.applyProposal, access: state.access)
        let record = try store.clearCanvasContent(canvasId: canvasId)
        return PlannerGraphState(
            canvas: record.canvas,
            nodes: record.nodes,
            states: service.readNodeState(nodes: record.nodes),
            proposals: record.proposals,
            access: state.access,
            activities: PlannerActivityStore.shared.activities(
                for: record.canvas.id,
                fallback: fallbackActivity(for: record.canvas, nodes: record.nodes, actorId: state.access.actorId)
            ),
            events: record.events,
            artifacts: record.artifacts,
            edges: graphEdges(for: record.nodes)
        )
    }

    static func recordActivity(
        canvasId: String,
        selectedNodeId: String?,
        selectedSessionId: String?,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerActivity {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        let selectedNode = selectedNodeId.flatMap { id in state.nodes.first(where: { $0.id == id }) }
        let safeSelectedNodeId = selectedNode?.id
        let safeSelectedSessionId = selectedNode?.sessionId
        return PlannerActivityStore.shared.heartbeat(
            userId: state.access.actorId,
            displayName: state.access.role == .owner ? "Owner" : state.access.actorId,
            currentCanvasId: state.canvas.id,
            selectedNodeId: safeSelectedNodeId,
            selectedSessionId: safeSelectedSessionId
        )
    }

    static func generateProposal(
        goal: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas, actorUserId: actorUserId)
        let record = try store.record(for: canvas, seedNodes: [])
        let access = PlannerPermission.access(for: record.canvas, nodes: record.nodes, actorId: actorUserId)
        try PlannerPermission.require(.createProposal, access: access)
        let title = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposalUUID = UUID().uuidString.lowercased()
        let node = PlanningNode(
            id: "\(canvas.id)-proposal-node-\(proposalUUID)",
            canvasId: canvas.id,
            title: title.isEmpty ? "Generated meee2 AI node" : title,
            schema: NodeSchema(
                inputs: ["owner goal", "meee2 AI context"],
                outputs: ["executable node output"],
                goal: "owner approves generated proposal"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .human,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .ready
        )
        return try PlanProposal(
            id: "proposal-\(canvas.id)-generate-\(proposalUUID)",
            canvasId: canvas.id,
            summary: "Generate meee2 AI graph for \(canvas.title)",
            changes: [.addNode(node)],
            status: .pending
        )
        .saved(in: store, canvas: canvas, seedNodes: [])
    }

    /// Persist a proposal produced by a `PlannerAdapter` (a real LLM/CLI).
    ///
    /// Re-runs full RBAC + `PlannerProposalValidator` against the live canvas
    /// state — the adapter is untrusted, so its output is validated again here
    /// before it can touch the store. Adapter-produced ids are namespaced so
    /// they never collide with the heuristic fallback's ids.
    static func saveAdapterProposal(
        _ proposal: PlanProposal,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        let normalized = PlanProposal(
            id: "proposal-\(canvasId)-adapter-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            summary: proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Generate meee2 AI graph for \(state.canvas.title)"
                : proposal.summary,
            changes: proposal.changes,
            status: .pending
        )
        return try normalized.saved(
            in: store,
            canvas: state.canvas,
            seedNodes: [],
            validationNodes: state.nodes
        )
    }

    static func graphChangeProposal(
        summary: String,
        changes: [PlanChange],
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        let proposal = PlanProposal(
            id: "proposal-\(canvasId)-graph-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Update meee2 AI graph"
                : summary,
            changes: changes,
            status: .pending
        )
        return try proposal.saved(
            in: store,
            canvas: state.canvas,
            seedNodes: [],
            validationNodes: state.nodes
        )
    }

    /// Execution-layer action: bind a session to a node DIRECTLY (no proposal,
    /// no owner approval). Gated only by `requireNodeUpdate`. Returns the
    /// updated graph state — same shape as `attachArtifact` / `updateNodeLayout`.
    static func bindSession(
        nodeId: String,
        sessionId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        // bind-session is a node execution-state mutation: owner anywhere, doer
        // only on their own node, viewer denied.
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.bindSession(canvasId: canvasId, nodeId: nodeId, sessionId: sessionId)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    /// Execution-layer action: dispatch a node DIRECTLY (no proposal, no owner
    /// approval). Gated only by `requireNodeUpdate`. Sets dispatch + run state
    /// and, for spawning runners, materializes the session node + edge in one
    /// locked operation. Returns the updated graph state plus the dispatched
    /// node so the caller can record the spawn intent.
    static func dispatchNode(
        nodeId: String,
        runner: PlannerDispatchRunner,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> (graph: PlannerGraphState, dispatchedNode: PlanningNode) {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        // dispatch is a node execution-state mutation: owner anywhere, doer
        // only on their own node, viewer denied.
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        let dispatch = PlannerNodeDispatch(
            runner: runner,
            skill: node.dispatch?.skill ?? "m3-coding",
            actor: node.doerId,
            command: runner.spawnCommand,
            fallbackRunner: runner == .ciAgent ? .byoaLocal : nil
        )
        let result = try store.dispatchNode(canvasId: canvasId, nodeId: nodeId, dispatch: dispatch)
        let graph = try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return (graph, result.dispatchedNode)
    }

    static func abandonNodeSession(
        nodeId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.abandonNodeSession(canvasId: canvasId, nodeId: nodeId)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func detachNodeSession(
        nodeId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.detachNodeSession(canvasId: canvasId, nodeId: nodeId)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    // MARK: - Run layer (P1)

    /// Start a new workflow run over the canvas's current node structure.
    /// `canvasState` is called first purely to ensure the store record exists
    /// (seeded from the board snapshot).
    static func startRun(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        responsibleUserId: String? = nil,
        linkedArtifactRefs: [String] = []
    ) throws -> WorkflowRun {
        _ = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return try store.startRun(
            canvasId: canvasId,
            trigger: actorUserId ?? "unknown",
            title: title,
            summary: summary,
            responsibleUserId: responsibleUserId,
            linkedArtifactRefs: linkedArtifactRefs
        )
    }

    /// All runs of a canvas — run history, creation order.
    static func runs(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> [WorkflowRun] {
        _ = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return try store.runs(canvasId: canvasId)
    }

    /// A single run by id, across all canvases.
    static func run(runId: String) throws -> WorkflowRun {
        guard let run = store.run(runId: runId) else {
            throw PlannerCoreError.runNotFound(runId)
        }
        return run
    }

    /// Human-terminate a run.
    static func abortRun(runId: String) throws -> WorkflowRun {
        try store.abortRun(runId: runId)
    }

    static func updateRunNodeAssignee(
        runId: String,
        nodeId: String,
        assigneeId: String?,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> WorkflowRun {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        return try store.updateRunNodeAssignee(
            canvasId: canvasId,
            runId: runId,
            nodeId: nodeId,
            assigneeId: assigneeId
        )
    }

    static func attachArtifact(
        nodeId: String,
        kind: PlannerArtifactKind,
        title: String,
        reference: String,
        status: String,
        payload: BoardJSONValue? = nil,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        // attach-artifact is a node execution-state mutation: owner anywhere,
        // doer only on their own node, viewer denied.
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        let artifactId = "artifact-\(canvasId)-\(nodeId)-\(UUID().uuidString.lowercased())"
        let workspacePath = try? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
        let normalizedPayload = try PlannerArtifactStorage.normalizePayload(
            payload,
            canvasId: canvasId,
            artifactId: artifactId,
            workspacePath: workspacePath
        )
        let artifact = PlannerArtifact(
            id: artifactId,
            canvasId: canvasId,
            nodeId: nodeId,
            kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? reference : title,
            reference: reference,
            status: status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "attached" : status,
            createdAt: Date(),
            payload: normalizedPayload
        )
        _ = try store.attachArtifact(artifact, canvasId: canvasId)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func updateNodeStatus(
        nodeId: String,
        status: PlanningNodeStatus,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        guard (node.nodeKind ?? .step) == .step else {
            throw PlannerCoreError.invalidNodeOutput("Only step nodes can change status.")
        }
        guard status != .working else {
            throw PlannerCoreError.invalidNodeOutput("In progress is derived from the bound session; start or resume the session instead.")
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.updateNodeStatus(canvasId: canvasId, nodeId: nodeId, status: status)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func updateNodeGate(
        nodeId: String,
        executionMode: ExecutionMode,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        guard (node.nodeKind ?? .step) == .step else {
            throw PlannerCoreError.invalidNodeOutput("Only step nodes can change gate mode.")
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.updateNodeGate(canvasId: canvasId, nodeId: nodeId, executionMode: executionMode)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func updateNodeSchedule(
        nodeId: String,
        schedule: PlannerNodeSchedule?,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        guard (node.nodeKind ?? .step) == .step else {
            throw PlannerCoreError.invalidNodeOutput("Only step nodes can be scheduled.")
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.updateNodeSchedule(canvasId: canvasId, nodeId: nodeId, schedule: schedule)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func deleteNode(
        nodeId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.deleteNode(canvasId: canvasId, nodeId: nodeId)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func bindNodeInput(
        nodeId: String,
        input: String,
        source: ContextSource,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.bindNodeInput(canvasId: canvasId, nodeId: nodeId, input: input, source: source)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func bindKanbanItemSubCanvas(
        artifactId: String,
        itemId: String,
        subCanvasId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let artifact = state.artifacts.first(where: { $0.id == artifactId }) else {
            throw PlannerCoreError.invalidNodeOutput("Kanban artifact not found.")
        }
        guard let node = state.nodes.first(where: { $0.id == artifact.nodeId }) else {
            throw PlannerCoreError.nodeNotFound(artifact.nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.bindKanbanItemSubCanvas(
            canvasId: canvasId,
            artifactId: artifactId,
            itemId: itemId,
            subCanvasId: subCanvasId
        )
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func nodeContract(
        nodeId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerNodeContract {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard state.nodes.contains(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        return try store.nodeContract(canvasId: canvasId, nodeId: nodeId)
    }

    static func submitNodeOutput(
        nodeId: String,
        output: PlannerNodeOutput,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerNodeOutputResult {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        let workspacePath = try? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
        var normalizedOutput = output
        normalizedOutput.artifacts = try output.artifacts.map { artifact in
            let reference = artifact.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let artifactId = "artifact-\(canvasId)-\(nodeId)-\(stableArtifactSuffix(reference))"
            let payload = try PlannerArtifactStorage.normalizePayload(
                artifact.payload,
                canvasId: canvasId,
                artifactId: artifactId,
                workspacePath: workspacePath
            )
            var next = artifact
            next.payload = payload
            return next
        }
        let submitted = try store.submitNodeOutput(canvasId: canvasId, nodeId: nodeId, output: normalizedOutput)
        // ENG-2 / E2.2: auto-dispatch downstream auto-mode nodes. Done at
        // bridge layer so the engine path stays pure (BoardAPI is the place
        // that actually spawns terminals — see `recordPlannerDispatchIntent`
        // + `startTerminalSession`). We only auto-dispatch here at the store
        // level — the BoardAPI handler observes `autoDispatchedNodeIds` and
        // kicks off the terminal spawn in the background so the response
        // can return inside the spec's 500ms budget.
        var autoIds: [String] = []
        for candidate in submitted.autoDispatchCandidates {
            do {
                _ = try store.dispatchNode(
                    canvasId: canvasId,
                    nodeId: candidate.id,
                    dispatch: PlannerNodeDispatch(
                        runner: .claude,
                        skill: nil,
                        actor: candidate.doerId,
                        command: nil,
                        fallbackRunner: nil
                    )
                )
                autoIds.append(candidate.id)
            } catch {
                MLog("[ENG-2][auto-dispatch] skip node=\(candidate.id) reason=\(error.localizedDescription)")
            }
        }
        let graph = try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return PlannerNodeOutputResult(
            graph: graph,
            routes: submitted.routes,
            hint: nil,
            versionId: submitted.version?.id,
            versionIndex: submitted.version?.versionIndex,
            autoDispatchedNodeIds: autoIds.isEmpty ? nil : autoIds
        )
    }

    /// ENG-3 · List the append-only version chain for one artifact slot,
    /// newest-first. UI-1 / version dropdown consume this.
    static func listArtifactVersions(
        canvasId: String,
        nodeId: String,
        reference: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> [PlannerArtifactVersion] {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard state.nodes.contains(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        return try store.artifactVersions(canvasId: canvasId, nodeId: nodeId, reference: reference)
    }

    /// ENG-3 · Fetch one version by id, including its input snapshot.
    static func getArtifactVersion(
        canvasId: String,
        versionId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerArtifactVersion? {
        _ = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return try store.artifactVersion(canvasId: canvasId, versionId: versionId)
    }

    private static func stableArtifactSuffix(_ raw: String) -> String {
        let normalized = raw
            .lowercased()
            .map { char in char.isLetter || char.isNumber ? char : "-" }
            .reduce(into: "") { $0.append($1) }
        return normalized.isEmpty ? UUID().uuidString.lowercased() : normalized
    }

    static func updateNodeLayout(
        nodeId: String,
        layout: PlannerNodeLayout,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        // layout is a node execution-state mutation: owner anywhere, doer only
        // on their own node, viewer denied.
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.updateNodeLayout(canvasId: canvasId, nodeId: nodeId, layout: layout)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func createSubCanvasProposal(
        nodeId: String,
        subCanvasId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        return try PlanProposal(
            id: "proposal-\(nodeId)-subcanvas-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            summary: "Create sub-canvas for \(node.title)",
            changes: [
                .updateNode(id: nodeId, subCanvasId: subCanvasId, nodeKind: .subCanvas)
            ],
            status: .pending
        )
        .saved(in: store, canvas: state.canvas, seedNodes: [], validationNodes: state.nodes)
    }

    static func deliveryPipelineProposal(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        let template = PlannerDeliveryPipelineTemplate.build(canvas: state.canvas)
        return try PlanProposal(
            id: "proposal-\(canvasId)-delivery-pipeline-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            summary: "Create meee2 delivery pipeline graph",
            changes: template.nodes.map { .addNode($0) },
            status: .pending
        )
        .saved(in: store, canvas: state.canvas, seedNodes: [], validationNodes: state.nodes)
    }

    static func driftProposal(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal? {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        guard let blocked = state.states.first(where: { $0.runState == .blocked }),
              let node = state.nodes.first(where: { $0.id == blocked.nodeId }) else {
            return nil
        }
        return try PlanProposal(
            id: "proposal-\(node.id)-drift-\(UUID().uuidString.lowercased())",
            canvasId: node.canvasId,
            summary: "meee2 AI detected drift for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs attention)", status: .draft)
            ],
            status: .pending
        )
        .saved(
            in: store,
            canvas: state.canvas,
            seedNodes: [],
            validationNodes: state.nodes
        )
    }

    static func refineProposal(
        nodeId: String,
        reason: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        let proposal = PlannerProposalFactory.refineNode(
            node: node,
            reason: reason,
            idSuffix: UUID().uuidString.lowercased()
        )
        return try proposal.saved(
            in: store,
            canvas: state.canvas,
            seedNodes: [],
            validationNodes: state.nodes
        )
    }

    /// ENG-2 bonus deliverable: clean engine path for "refine the session
    /// prompt for this node" (no schema mutation). Builds + persists a
    /// proposal with an empty `changes[]` and the directive in `summary`.
    /// The caller is responsible for routing the directive to the bound
    /// session — current implementation reuses the existing operator-channel
    /// inject path so behaviour matches the ENG-5 workaround, but the
    /// proposal is now first-class: it shows up in proposals list, has an
    /// id, can be approved/rejected, and is audited like every other plan
    /// change.
    static func refineSessionPromptProposal(
        nodeId: String,
        directive: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> (proposal: PlanProposal, sessionId: String?) {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        let proposal = PlannerProposalFactory.refineSessionPrompt(node: node, directive: directive)
        let saved = try proposal.saved(
            in: store,
            canvas: state.canvas,
            seedNodes: [],
            validationNodes: state.nodes
        )
        let trimmedSession = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = (trimmedSession?.isEmpty == false) ? trimmedSession : nil
        return (saved, sessionId)
    }

    static func applyPreview(
        proposal: PlanProposal,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], states: [NodeStateSnapshot]) {
        guard proposal.canvasId == canvasId else {
            throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: proposal.canvasId)
        }
        // apply-preview previews an owner-only apply — gate it identically.
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.applyProposal, access: state.access)
        let canvas = state.canvas
        let preview = try store.preview(
            proposal: proposal,
            canvas: canvas,
            seedNodes: [],
            service: service
        )
        let approved = preview.proposal
        let nodes = preview.nodes
        return (approved, nodes, service.readNodeState(nodes: nodes))
    }

    static func approveProposal(
        proposalId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.approveProposal, access: state.access)
        return try store.approveProposal(proposalId: proposalId, canvasId: canvasId)
    }

    static func rejectProposal(
        proposalId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.rejectProposal, access: state.access)
        return try store.rejectProposal(proposalId: proposalId, canvasId: canvasId)
    }

    static func applyProposal(
        proposalId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], states: [NodeStateSnapshot]) {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.applyProposal, access: state.access)
        let record = try store.applyProposal(proposalId: proposalId, canvasId: canvasId, service: service)
        guard let proposal = record.proposals.first(where: { $0.id == proposalId }) else {
            throw PlannerCoreError.proposalNotFound(proposalId)
        }
        return (proposal, record.nodes, service.readNodeState(nodes: record.nodes))
    }

    static func workspaceMonitor(
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerMonitorState {
        var items: [PlannerMonitorItem] = []
        for boardCanvas in snapshot.canvases {
            // Skip canvases the actor cannot see — a private canvas only shows
            // up in the monitor for its owner / role-holders.
            let state: (
                canvas: PlanningCanvas,
                nodes: [PlanningNode],
                states: [NodeStateSnapshot],
                proposals: [PlanProposal],
                access: PlannerAccess,
                activities: [PlannerActivity],
                events: [PlannerEvent],
                artifacts: [PlannerArtifact],
                edges: [PlannerGraphEdge]
            )
            do {
                state = try canvasState(
                    for: boardCanvas.id,
                    snapshot: snapshot,
                    actorUserId: actorUserId
                )
            } catch PlannerCoreError.permissionDenied {
                continue
            }
            let actorId = state.access.actorId
            let statesByNodeId = Dictionary(uniqueKeysWithValues: state.states.map { ($0.nodeId, $0) })
            let visibleNodes = state.access.role == .doer
                ? state.nodes.filter { $0.doerId == actorId }
                : state.nodes

            let runs = (try? store.runs(canvasId: state.canvas.id)) ?? []
            let artifactsByNodeId = Dictionary(grouping: state.artifacts, by: \.nodeId)
            for run in runs {
                let runStates = Array(run.nodeStates.values)
                let attentionCount = runStates.filter { nodeState in
                    // `awaitingInput` needs a human reply just like `gateWait`
                    // / `failed` — keep such deliveries in the attention bucket
                    // so operators don't miss a run blocked on their input.
                    nodeState.runState == .failed
                        || nodeState.runState == .gateWait
                        || nodeState.runState == .awaitingInput
                }.count
                let doneCount = runStates.filter { $0.runState == .done }.count
                let totalCount = max(runStates.count, 1)
                let includeForDoer = state.access.role != .doer || runStates.contains { nodeState in
                    return nodeState.assigneeId == actorId
                }
                guard includeForDoer else { continue }
                let liveSessionId = runStates
                    .sorted { lhs, rhs in
                        monitorSessionPriority(for: lhs) < monitorSessionPriority(for: rhs)
                    }
                    .first { nodeState in
                        guard let sessionId = nodeState.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !sessionId.isEmpty else { return false }
                        return monitorSessionPriority(for: nodeState) < Int.max
                    }?
                    .sessionId
                items.append(PlannerMonitorItem(
                    id: "delivery-\(run.id)",
                    kind: .delivery,
                    canvasId: state.canvas.id,
                    canvasTitle: state.canvas.title,
                    nodeId: nil,
                    nodeTitle: nil,
                    sessionId: liveSessionId,
                    deliveryId: run.id,
                    proposalId: nil,
                    proposalStatus: nil,
                    summary: run.title,
                    runState: nil,
                    blockers: run.summary.map { [$0] } ?? [],
                    needsOwnerReview: attentionCount > 0,
                    doerId: run.responsibleUserId,
                    riskRank: attentionCount > 0 ? 1 : (run.status == .active ? 3 : 5),
                    evidenceCount: runStates.reduce(0) { $0 + $1.artifactIds.count },
                    updatedAt: run.updatedAt,
                    nextAction: "\(doneCount)/\(totalCount) steps"
                ))
            }

            for node in visibleNodes {
                guard let snapshot = statesByNodeId[node.id],
                      snapshot.runState != .done else { continue }
                let rank = monitorRank(for: snapshot)
                items.append(PlannerMonitorItem(
                    id: "node-\(node.id)",
                    kind: .node,
                    canvasId: state.canvas.id,
                    canvasTitle: state.canvas.title,
                    nodeId: node.id,
                    nodeTitle: node.title,
                    sessionId: node.sessionId,
                    proposalId: nil,
                    proposalStatus: nil,
                    summary: node.title,
                    runState: snapshot.runState,
                    blockers: snapshot.blockers,
                    needsOwnerReview: snapshot.needsOwnerReview,
                    doerId: node.doerId,
                    riskRank: rank,
                    evidenceCount: (node.artifactRefs ?? []).count + (artifactsByNodeId[node.id]?.count ?? 0),
                    updatedAt: latestPlannerEventDate(in: state.events, nodeId: node.id)
                        ?? node.outputSubmittedAt,
                    nextAction: PlannerWorkflowGuidance.nextAction(
                        for: node,
                        blockers: snapshot.blockers
                    )
                ))
            }

            if state.access.role == .owner {
                for proposal in state.proposals where proposal.status == .pending || proposal.status == .approved {
                    items.append(PlannerMonitorItem(
                        id: "proposal-\(proposal.id)",
                        kind: .proposal,
                        canvasId: state.canvas.id,
                        canvasTitle: state.canvas.title,
                        nodeId: nil,
                        nodeTitle: nil,
                        proposalId: proposal.id,
                        proposalStatus: proposal.status,
                        summary: proposal.summary,
                        runState: nil,
                        blockers: [],
                        needsOwnerReview: proposal.status == .pending,
                        doerId: nil,
                        riskRank: proposal.status == .pending ? 1 : 2,
                        evidenceCount: proposal.changes.reduce(0) { total, change in
                            total + (change.artifactRefs?.count ?? 0) + (change.artifact == nil ? 0 : 1)
                        },
                        updatedAt: latestPlannerEventDate(in: state.events, proposalId: proposal.id)
                    ))
                }
            }
        }

        items.sort {
            if $0.riskRank != $1.riskRank { return $0.riskRank < $1.riskRank }
            if $0.canvasTitle != $1.canvasTitle { return $0.canvasTitle < $1.canvasTitle }
            return $0.summary < $1.summary
        }
        return PlannerMonitorState(generatedAt: Date(), items: items)
    }

    private static func latestPlannerEventDate(
        in events: [PlannerEvent],
        nodeId: String? = nil,
        proposalId: String? = nil
    ) -> Date? {
        events
            .filter { event in
                if let nodeId, event.nodeId == nodeId { return true }
                if let proposalId, event.proposalId == proposalId { return true }
                return false
            }
            .map(\.createdAt)
            .max()
    }

    private static func monitorSessionPriority(for nodeState: RunNodeState) -> Int {
        switch nodeState.runState {
        case .awaitingInput, .gateWait, .failed:
            return 0
        case .running:
            return 1
        case .pending, .readyToStart, .dispatched:
            return 2
        case .done:
            return Int.max
        }
    }

    private static func requireCanvas(
        _ canvasId: String,
        in snapshot: BoardLayoutStore.Snapshot
    ) throws -> BoardLayoutStore.Canvas {
        guard let canvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        return canvas
    }

    /// Whether `access` is allowed to *see* `canvas`. A `public` canvas is
    /// visible to everyone; a `private` canvas is visible only to its owner or
    /// to an actor that holds a role on it (doer / assigned to a node). A bare
    /// viewer with no role on a private canvas is not a member.
    static func canViewCanvas(_ canvas: PlanningCanvas, access: PlannerAccess) -> Bool {
        switch canvas.visibility {
        case .public:
            return true
        case .private:
            // owner / doer are members; viewer (no role) is not.
            return access.role == .owner || access.role == .doer
        }
    }

    /// Throw `permissionDenied` if `access` cannot see `canvas`.
    private static func requireCanvasVisible(
        _ canvas: PlanningCanvas,
        access: PlannerAccess
    ) throws {
        guard canViewCanvas(canvas, access: access) else {
            throw PlannerCoreError.permissionDenied(action: "view canvas", role: access.role)
        }
    }

    /// Owner-only update of a canvas's visibility tier. Returns the updated
    /// `PlanningCanvas`. Used by `PATCH .../canvases/:id/visibility`.
    static func setCanvasVisibility(
        _ visibility: PlannerCanvasVisibility,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanningCanvas {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas, actorUserId: actorUserId)
        var record = try store.record(for: canvas, seedNodes: [])
        let access = PlannerPermission.access(for: record.canvas, nodes: record.nodes, actorId: actorUserId)
        // Only the owner may change visibility.
        guard access.role == .owner else {
            throw PlannerCoreError.permissionDenied(action: "set canvas visibility", role: access.role)
        }
        record = try store.setCanvasVisibility(visibility, canvasId: canvasId)
        return record.canvas
    }

    static func setCanvasDescription(
        _ description: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanningCanvas {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas, actorUserId: actorUserId)
        var record = try store.record(for: canvas, seedNodes: [])
        let access = PlannerPermission.access(for: record.canvas, nodes: record.nodes, actorId: actorUserId)
        guard access.role == .owner else {
            throw PlannerCoreError.permissionDenied(action: "set canvas description", role: access.role)
        }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        record = try store.setCanvasContext(trimmed.isEmpty ? "canvas:\(canvasId)" : trimmed, canvasId: canvasId)
        return record.canvas
    }

    private static func planningCanvas(
        from canvas: BoardLayoutStore.Canvas,
        actorUserId: String?
    ) -> PlanningCanvas {
        let ownerId: String
        if canvas.scope == .personal {
            let currentActorId = PlannerPermission.currentActorId()
            if let actorUserId,
               let currentActorId,
               actorUserId == currentActorId {
                ownerId = currentActorId
            } else {
                ownerId = canvas.ownerUserId ?? canvas.createdBy ?? "local-owner"
            }
        } else {
            ownerId = canvas.ownerUserId ?? canvas.createdBy ?? "local-owner"
        }
        return PlanningCanvas(
            id: canvas.id,
            ownerId: ownerId,
            title: canvas.name,
            plannerContext: "canvas:\(canvas.id)"
        )
    }

    private static func monitorRank(for state: NodeStateSnapshot) -> Int {
        if state.runState == .blocked { return 0 }
        if state.needsOwnerReview { return 1 }
        switch state.runState {
        case .working:
            return 2
        case .draft:
            return 3
        case .ready:
            return 4
        case .blocked:
            return 0
        case .done:
            return 9
        }
    }

    private static func fallbackActivity(
        for canvas: PlanningCanvas,
        nodes: [PlanningNode],
        actorId: String
    ) -> PlannerActivity {
        let selected = nodes.first { node in
            node.doerId == actorId && (node.status == .working || node.status == .blocked || node.status == .draft)
        }
        return PlannerActivity(
            userId: actorId,
            displayName: actorId == canvas.ownerId ? "Owner" : actorId,
            currentCanvasId: canvas.id,
            selectedNodeId: selected?.id,
            selectedSessionId: selected?.sessionId,
            lastActiveAt: Date()
        )
    }

    private static func graphEdges(for nodes: [PlanningNode]) -> [PlannerGraphEdge] {
        let nodeIds = Set(nodes.map(\.id))
        var edges: [PlannerGraphEdge] = []
        for node in nodes {
            for dependencyId in node.dependsOnNodeIds ?? [] where nodeIds.contains(dependencyId) {
                edges.append(PlannerGraphEdge(
                    id: "edge-\(dependencyId)-\(node.id)",
                    sourceNodeId: dependencyId,
                    targetNodeId: node.id,
                    kind: "dependency"
                ))
            }
            if let subCanvasId = node.subCanvasId {
                edges.append(PlannerGraphEdge(
                    id: "edge-\(node.id)-subcanvas-\(subCanvasId)",
                    sourceNodeId: node.id,
                    targetNodeId: subCanvasId,
                    kind: "subCanvas"
                ))
            }
        }
        return edges
    }
}

private extension PlanProposal {
    func saved(
        in store: PlannerStore,
        canvas: PlanningCanvas,
        seedNodes: [PlanningNode],
        validationNodes: [PlanningNode]? = nil
    ) throws -> PlanProposal {
        try store.saveProposal(
            self,
            canvas: canvas,
            seedNodes: seedNodes,
            validationNodes: validationNodes
        )
    }
}

/// Phase 2 — runState 回流.
///
/// Bridges observed session status back into the planner graph. Spawned
/// planner sessions carry a `purpose` tag of the form `planner:<stepNodeId>`
/// (see `BoardLayoutStore.recordSpawnIntent` callers). When a session with
/// such a tag is observed — newly bound or with a changed status — this maps
/// `SessionStatus` → `PlannerWorkflowRunState` and persists it via
/// `PlannerStore.applySessionRunState`, which holds the store lock.
enum PlannerSessionRunStateBridge {
    static let purposePrefix = "planner:"

    /// Extract the step node id out of a `planner:<stepNodeId>` purpose tag.
    /// Returns `nil` for any non-planner purpose (`global`, etc.).
    static func stepNodeId(fromPurpose purpose: String?) -> String? {
        guard let purpose,
              purpose.hasPrefix(purposePrefix) else { return nil }
        let id = String(purpose.dropFirst(purposePrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Map a live `SessionStatus` to the node `workflowRunState`.
    ///
    /// - working states (thinking / tooling / active / compacting) → `running`
    /// - `idle` → `dispatched` (session alive, just spun up / between turns)
    /// - `waitingForUser` → `awaitingInput` (session idle, ball is in the
    ///   human's court — needs context or a decision to advance)
    /// - `permissionRequired` → `gateWait` (blocked awaiting a human)
    /// - `completed` → `done`
    /// - `dead` → `failed`
    static func runState(for status: SessionStatus) -> PlannerWorkflowRunState {
        switch status {
        case .thinking, .tooling, .active, .compacting:
            return .running
        case .idle:
            return .dispatched
        case .waitingForUser:
            return .awaitingInput
        case .permissionRequired:
            return .gateWait
        case .completed:
            return .done
        case .dead:
            return .failed
        }
    }

    /// Observe a session status change for a possibly-planner-tagged session.
    /// No-ops when `purpose` is not a planner tag or no session node is found.
    /// `store` defaults to the shared planner store but is injectable for tests.
    ///
    /// Used at spawn-intent match time, when the `purpose` tag (and thus the
    /// step node id) is still known — this is what *binds* the session id.
    @discardableResult
    static func observe(
        sessionId: String,
        purpose: String?,
        status: SessionStatus,
        store: PlannerStore = PlannerBoardBridge.store
    ) -> PlannerStore.CanvasRecord? {
        guard let stepNodeId = stepNodeId(fromPurpose: purpose) else { return nil }
        return try? store.applySessionRunState(
            stepNodeId: stepNodeId,
            sessionId: sessionId,
            runState: runState(for: status)
        )
    }

    /// Observe a status change for an already-bound planner session — keyed by
    /// `sessionId` only (the spawn intent's `purpose` tag has been consumed).
    /// No-op if no planner session node carries this `sessionId`.
    @discardableResult
    static func observeBound(
        sessionId: String,
        status: SessionStatus,
        store: PlannerStore = PlannerBoardBridge.store
    ) -> PlannerStore.CanvasRecord? {
        // TODO(evolution): emit PlannerAgentEvent.nodeRunStateChanged here —
        // once the persisted record gives us the canvas id + step node id, feed
        // a `.nodeRunStateChanged(canvasId:, nodeId:, runState:)` event into
        // `PlannerAgentRuntimeRegistry.shared` so a replacement runtime can
        // react to run-state changes. Deliberately NOT wired yet: the Phase 8
        // abstraction must merely be ready for auto-evolution, not perform it.
        try? store.applyRunStateForSession(
            sessionId: sessionId,
            runState: runState(for: status)
        )
    }
}

enum PlannerProposalFactory {
    static func refineNode(
        node: PlanningNode,
        reason: String,
        idSuffix: String? = nil
    ) -> PlanProposal {
        let suffix = idSuffix.map { "-\($0)" } ?? ""
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let followUp = PlanningNode(
            id: "\(node.id)-refine\(suffix)",
            canvasId: node.canvasId,
            title: trimmedReason.isEmpty ? "\(node.title) refinement" : trimmedReason,
            schema: NodeSchema(
                inputs: [node.schema.outputs.joined(separator: ", ")],
                outputs: ["refined output"],
                goal: "refinement reviewed"
            ),
            contextSources: node.contextSources,
            executionMode: .human,
            executorType: node.executorType,
            doerId: node.doerId,
            status: .draft,
            dependsOnNodeIds: [node.id]
        )
        return PlanProposal(
            id: "proposal-\(node.id)-refine\(suffix)",
            canvasId: node.canvasId,
            summary: "Refine \(node.title)",
            changes: [
                .updateNode(id: node.id, status: .draft),
                .addNode(followUp)
            ],
            status: .pending
        )
    }

    /// ENG-2 bonus: build a proposal that re-prompts the bound session for a
    /// node, without mutating the canvas schema. Apply-side is the engine's
    /// job (see `PlannerStore.applyRefineSessionPrompt`) — the proposal
    /// carries the directive text in `summary`, and the empty `changes`
    /// array signals "no schema mutation". Callers should route the
    /// proposal through the standard approve/apply pipeline so a) the
    /// directive is recorded in the canvas event log, and b) approval
    /// permissions are enforced uniformly.
    ///
    /// Previously ENG-5 worked around the missing engine path by
    /// reusing `injectToSession` directly; with this proposal kind the UI
    /// has a single, auditable channel for "improve the next session
    /// prompt without changing the plan."
    static func refineSessionPrompt(
        node: PlanningNode,
        directive: String
    ) -> PlanProposal {
        let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed.isEmpty
            ? "Refine session prompt for \(node.title)"
            : "Refine session prompt for \(node.title) — \(trimmed)"
        let randomSuffix = UUID().uuidString.lowercased().prefix(8)
        return PlanProposal(
            id: "proposal-\(node.id)-refine-session-prompt-\(randomSuffix)",
            canvasId: node.canvasId,
            summary: summary,
            changes: [
                .refineSessionPrompt(nodeId: node.id, directive: trimmed)
            ],
            status: .pending
        )
    }
}

enum PlannerDeliveryPipelineTemplate {
    static let id = "meee2-delivery-pipeline"

    static func build(canvas: PlanningCanvas) -> PlannerWorkflowTemplate {
        let artifacts = [
            artifact(canvas: canvas, nodeId: "m1-idea", kind: .ideaDraft, title: "idea-draft", ref: "lark://wiki/prd-draft/<date>"),
            artifact(canvas: canvas, nodeId: "m2-prd-decision", kind: .prd, title: "PRD / ADR", ref: "repo://meee2-workspace/doc/prd/<slug>.md"),
            artifact(canvas: canvas, nodeId: "m3-impl-verify", kind: .implPR, title: "implementation PR", ref: "git://targetRepo/pull/<id>"),
            artifact(canvas: canvas, nodeId: "m3-impl-verify", kind: .prereleaseVerdict, title: "pre-release verdict", ref: "artifact://prerelease-verdict"),
            artifact(canvas: canvas, nodeId: "m4-tech-merge-main", kind: .mainMerge, title: "main merge", ref: "git://targetRepo/main")
        ]
        let nodes = [
            step(
                canvas: canvas,
                id: "m1-idea",
                title: "M1 本地产 idea -> prd-draft",
                x: 0,
                y: 0,
                trigger: PlannerNodeTrigger(type: "manual", label: "手动", eventSource: nil),
                gate: PlannerNodeGate(
                    type: "artifact-exists",
                    label: "idea-draft 写入 Lark Wiki /prd-draft/<date>/",
                    requiredArtifactRefs: ["lark://wiki/prd-draft/<date>"],
                    approvers: [],
                    onFailGotoNodeId: nil
                ),
                dispatch: PlannerNodeDispatch(runner: .byoaLocal, skill: "m1-idea", actor: "any-member", command: "claude", fallbackRunner: nil),
                artifactRefs: ["lark://wiki/prd-draft/<date>"],
                dependsOn: []
            ),
            step(
                canvas: canvas,
                id: "m2-prd-decision",
                title: "M2 会后产 PRD PR",
                x: 360,
                y: 0,
                trigger: PlannerNodeTrigger(type: "manual", label: "会议后人工触发", eventSource: nil),
                gate: PlannerNodeGate(
                    type: "pr-merged",
                    label: "PRD PR 合入 meee2-workspace/main",
                    requiredArtifactRefs: ["repo://meee2-workspace/doc/prd/**"],
                    approvers: ["product-owner", "tech-lead"],
                    onFailGotoNodeId: "m2-prd-decision"
                ),
                dispatch: PlannerNodeDispatch(runner: .byoaLocal, skill: "m2-prd", actor: "meeting-recorder", command: "claude", fallbackRunner: nil),
                artifactRefs: ["repo://meee2-workspace/doc/prd/<slug>.md"],
                dependsOn: ["m1-idea"]
            ),
            step(
                canvas: canvas,
                id: "m3-impl-verify",
                title: "M3 实现 + pre-release + 验证",
                x: 720,
                y: 0,
                trigger: PlannerNodeTrigger(type: "event", label: "PRD PR merged", eventSource: "git.meee2-workspace"),
                gate: PlannerNodeGate(
                    type: "check-success",
                    label: "负责人在 pre-release 版本验证通过",
                    requiredArtifactRefs: ["artifact://prerelease-verdict"],
                    approvers: ["pipeline-owner"],
                    onFailGotoNodeId: "m3-impl-verify"
                ),
                dispatch: PlannerNodeDispatch(runner: .byoaLocal, skill: "m3-coding", actor: "pipeline-owner", command: "claude", fallbackRunner: .byoaLocal),
                artifactRefs: ["git://targetRepo/pull/<id>", "artifact://prerelease-verdict"],
                dependsOn: ["m2-prd-decision"]
            ),
            step(
                canvas: canvas,
                id: "m4-tech-merge-main",
                title: "M4 技术验证 + 合并 main",
                x: 1080,
                y: 0,
                trigger: PlannerNodeTrigger(type: "event", label: "prerelease-verified check passed", eventSource: "git.${prd.targetRepo}"),
                gate: PlannerNodeGate(
                    type: "branch-updated",
                    label: "pre-release 合入 main",
                    requiredArtifactRefs: ["git://targetRepo/main"],
                    approvers: ["tech-reviewer"],
                    onFailGotoNodeId: nil
                ),
                dispatch: PlannerNodeDispatch(runner: .human, skill: nil, actor: "tech-reviewer", command: nil, fallbackRunner: nil),
                artifactRefs: ["git://targetRepo/main"],
                dependsOn: ["m3-impl-verify"]
            ),
            external(
                canvas: canvas,
                id: "n6-release",
                title: "N6 正式发布自动化",
                x: 1440,
                y: 0,
                dependsOn: ["m4-tech-merge-main"]
            )
        ]
        return PlannerWorkflowTemplate(
            id: id,
            title: "MEEE2 Delivery Pipeline",
            activePhase: "phase-1",
            nodes: nodes,
            artifacts: artifacts
        )
    }

    private static func step(
        canvas: PlanningCanvas,
        id: String,
        title: String,
        x: Double,
        y: Double,
        trigger: PlannerNodeTrigger,
        gate: PlannerNodeGate,
        dispatch: PlannerNodeDispatch,
        artifactRefs: [String],
        dependsOn: [String]
    ) -> PlanningNode {
        PlanningNode(
            id: "\(canvas.id)-\(id)",
            canvasId: canvas.id,
            title: title,
            schema: NodeSchema(
                inputs: dependsOn.isEmpty ? ["owner intent"] : dependsOn,
                outputs: artifactRefs,
                goal: gate.label
            ),
            contextSources: artifactRefs.map {
                ContextSource(kind: .artifact, title: $0, reference: $0)
            },
            executionMode: dispatch.runner == .human ? .human : .auto,
            executorType: executorType(for: dispatch.runner),
            doerId: dispatch.actor,
            status: .ready,
            dependsOnNodeIds: dependsOn.map { "\(canvas.id)-\($0)" },
            nodeKind: .step,
            layout: PlannerNodeLayout(x: x, y: y, width: 300, height: 168),
            trigger: trigger,
            gate: gate,
            dispatch: dispatch,
            approvers: gate.approvers,
            artifactRefs: artifactRefs,
            workflowRunState: .pending
        )
    }

    private static func external(
        canvas: PlanningCanvas,
        id: String,
        title: String,
        x: Double,
        y: Double,
        dependsOn: [String]
    ) -> PlanningNode {
        PlanningNode(
            id: "\(canvas.id)-\(id)",
            canvasId: canvas.id,
            title: title,
            schema: NodeSchema(
                inputs: ["main branch update"],
                outputs: ["external release automation"],
                goal: "external:N6"
            ),
            contextSources: [
                ContextSource(kind: .artifact, title: "external automation", reference: "external:N6")
            ],
            executionMode: .auto,
            executorType: .mock,
            doerId: "external",
            status: .ready,
            dependsOnNodeIds: dependsOn.map { "\(canvas.id)-\($0)" },
            nodeKind: .external,
            layout: PlannerNodeLayout(x: x, y: y, width: 260, height: 132),
            artifactRefs: ["external:N6"],
            workflowRunState: .pending
        )
    }

    private static func artifact(
        canvas: PlanningCanvas,
        nodeId: String,
        kind: PlannerArtifactKind,
        title: String,
        ref: String
    ) -> PlannerArtifact {
        PlannerArtifact(
            id: "artifact-\(canvas.id)-\(nodeId)-\(kind.rawValue)",
            canvasId: canvas.id,
            nodeId: "\(canvas.id)-\(nodeId)",
            kind: kind,
            title: title,
            reference: ref,
            status: "required",
            createdAt: Date()
        )
    }

    private static func executorType(for runner: PlannerDispatchRunner) -> ExecutorType {
        switch runner {
        case .claude, .codex, .byoaLocal:
            return .claude
        case .ciAgent:
            return .mock
        case .human:
            return .human
        }
    }
}

enum PlannerDriftAdvisor {
    static func repairPlanningProposal(
        for node: PlanningNode,
        state: NodeStateSnapshot
    ) -> PlanProposal {
        PlanProposal(
            id: "proposal-\(node.id)-repair-planning",
            canvasId: node.canvasId,
            summary: "Repair planning state for \(node.title)",
            changes: [
                .updateNode(
                    id: node.id,
                    title: "\(node.title) (schema repair planned)",
                    status: .draft,
                    contextSources: node.contextSources + [
                        ContextSource(
                            kind: .artifact,
                            title: "Planning repair reason",
                            reference: state.blockers.joined(separator: "; ")
                        )
                    ]
                )
            ],
            status: .pending
        )
    }

    static func splitProposal(
        for node: PlanningNode,
        state: NodeStateSnapshot,
        reason: String
    ) -> PlanProposal {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let splitNode = PlanningNode(
            id: "\(node.id)-split",
            canvasId: node.canvasId,
            title: trimmedReason.isEmpty ? "\(node.title) split follow-up" : trimmedReason,
            schema: NodeSchema(
                inputs: node.schema.inputs,
                outputs: ["split node output"],
                goal: "split output reviewed"
            ),
            contextSources: node.contextSources,
            executionMode: .human,
            executorType: node.executorType,
            doerId: node.doerId,
            status: .draft,
            dependsOnNodeIds: [node.id]
        )
        let blockerSummary = state.blockers.isEmpty ? "blocked state" : state.blockers.joined(separator: "; ")
        return PlanProposal(
            id: "proposal-\(node.id)-split",
            canvasId: node.canvasId,
            summary: "Split \(node.title) because \(blockerSummary)",
            changes: [
                .updateNode(id: node.id, status: .draft),
                .addNode(splitNode)
            ],
            status: .pending
        )
    }
}

protocol PlannerAgent {
    func generatePlan(goal: String, canvas: PlanningCanvas) async throws -> PlanProposal
    func refineNode(node: PlanningNode, reason: String) async throws -> PlanProposal
    func inspectDrift(nodes: [PlanningNode], states: [NodeStateSnapshot]) async throws -> PlanProposal?
}

final class MockPlannerAgent: PlannerAgent {
    func generatePlan(goal: String, canvas: PlanningCanvas) async throws -> PlanProposal {
        let node = PlanningNode(
            id: "\(canvas.id)-planner-generated-1",
            canvasId: canvas.id,
            title: goal.isEmpty ? "Generated meee2 AI node" : goal,
            schema: NodeSchema(
                inputs: ["owner goal"],
                outputs: ["first executable output"],
                goal: "complete the generated node"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .human,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .ready
        )
        return PlanProposal(
            id: "proposal-\(canvas.id)-generate",
            canvasId: canvas.id,
            summary: "Generate initial meee2 AI graph for \(canvas.title)",
            changes: [.addNode(node)],
            status: .pending
        )
    }

    func refineNode(node: PlanningNode, reason: String) async throws -> PlanProposal {
        PlannerProposalFactory.refineNode(node: node, reason: reason)
    }

    func inspectDrift(nodes: [PlanningNode], states: [NodeStateSnapshot]) async throws -> PlanProposal? {
        guard let state = states.first(where: { $0.runState == .blocked }),
              let node = nodes.first(where: { $0.id == state.nodeId }) else {
            if let planningState = states.first(where: { $0.runState == .draft }),
               let planningNode = nodes.first(where: { $0.id == planningState.nodeId }) {
                return PlannerDriftAdvisor.repairPlanningProposal(
                    for: planningNode,
                    state: planningState
                )
            }
            return nil
        }
        if state.blockers.contains(where: { blocker in
            let normalized = blocker.lowercased()
            return normalized.contains("repeated") || normalized.contains("failed")
        }) {
            return PlannerDriftAdvisor.splitProposal(
                for: node,
                state: state,
                reason: "\(node.title) split after repeated failure"
            )
        }
        return PlanProposal(
            id: "proposal-\(node.id)-drift",
            canvasId: node.canvasId,
            summary: "meee2 AI detected drift for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs attention)", status: .draft)
            ],
            status: .pending
        )
    }
}

protocol PlannerTextClient {
    func complete(systemPrompt: String, userPrompt: String) async throws -> String
}

struct AssistantProviderPlannerClient: PlannerTextClient {
    var provider: AssistantProvider
    var settings: AssistantSettings

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        var output = ""
        let stream = provider.runTurn(
            systemPrompt: systemPrompt,
            messages: [ChatMessage(role: .user, content: userPrompt)],
            tools: [],
            settings: settings
        )
        for try await event in stream {
            switch event {
            case .textDelta(let delta):
                output += delta
            case .turnDone:
                return output
            case .error(let message):
                throw NSError(
                    domain: "PlannerAgent",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            case .toolCall:
                continue
            }
        }
        return output
    }
}

final class LLMPlannerAgent: PlannerAgent {
    private let client: PlannerTextClient

    init(client: PlannerTextClient) {
        self.client = client
    }

    func generatePlan(goal: String, canvas: PlanningCanvas) async throws -> PlanProposal {
        let output = try await client.complete(
            systemPrompt: PlannerPromptFactory.systemPrompt,
            userPrompt: PlannerPromptFactory.generatePrompt(goal: goal, canvas: canvas)
        )
        let proposal = try PlannerProposalValidator.decodeProposal(from: output)
        try PlannerProposalValidator.validate(proposal, canvas: canvas, nodes: [])
        return proposal
    }

    func refineNode(node: PlanningNode, reason: String) async throws -> PlanProposal {
        let canvas = PlanningCanvas(
            id: node.canvasId,
            ownerId: node.doerId,
            title: node.canvasId,
            plannerContext: "canvas:\(node.canvasId)"
        )
        let output = try await client.complete(
            systemPrompt: PlannerPromptFactory.systemPrompt,
            userPrompt: PlannerPromptFactory.refinePrompt(node: node, reason: reason)
        )
        let proposal = try PlannerProposalValidator.decodeProposal(from: output)
        try PlannerProposalValidator.validate(proposal, canvas: canvas, nodes: [node])
        return proposal
    }

    func inspectDrift(nodes: [PlanningNode], states: [NodeStateSnapshot]) async throws -> PlanProposal? {
        guard let firstNode = nodes.first else { return nil }
        let canvas = PlanningCanvas(
            id: firstNode.canvasId,
            ownerId: firstNode.doerId,
            title: firstNode.canvasId,
            plannerContext: "canvas:\(firstNode.canvasId)"
        )
        let output = try await client.complete(
            systemPrompt: PlannerPromptFactory.systemPrompt,
            userPrompt: PlannerPromptFactory.driftPrompt(nodes: nodes, states: states)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty || output == "null" { return nil }
        let proposal = try PlannerProposalValidator.decodeProposal(from: output)
        try PlannerProposalValidator.validate(proposal, canvas: canvas, nodes: nodes)
        return proposal
    }
}

enum PlannerPromptFactory {
    static let systemPrompt = """
    You are meee2 AI. Return only strict JSON for PlanProposal, or null when no proposal is needed.
    You may propose topology changes, but the owner approval API is the only path that can apply them.
    Never invent another canvasId. Never update unknown node ids. Keep changes small and executable.
    Supported PlanChange kinds are addNode and updateNode.
    updateNode may change title, status, schema, contextSources, dependsOnNodeIds, doerId, nodeKind, subCanvasId, executionMode, clearGate, gate, dispatch, approvers, artifactRefs, workflowRunState, sessionId, chatThreadId, and source.
    Use dependsOnNodeIds for graph dependencies. Use schema/contextSources for contract changes. Use doerId only for explicit assignment proposals.
    """

    static func generatePrompt(goal: String, canvas: PlanningCanvas) -> String {
        """
        Generate a PlanProposal for this canvas.
        Canvas JSON:
        \(json(canvas))

        Owner goal:
        \(goal)
        """
    }

    static func refinePrompt(node: PlanningNode, reason: String) -> String {
        """
        Refine the selected PlanningNode by returning a PlanProposal.
        Existing node JSON:
        \(json(node))

        Refinement reason:
        \(reason)
        """
    }

    static func driftPrompt(nodes: [PlanningNode], states: [NodeStateSnapshot]) -> String {
        """
        Inspect drift between planning nodes and runtime states. Return a PlanProposal or null.
        Nodes JSON:
        \(json(nodes))

        State snapshots JSON:
        \(json(states))
        """
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

private extension NodeRunState {
    init(status: PlanningNodeStatus) {
        switch status {
        case .draft:
            self = .draft
        case .ready:
            self = .ready
        case .working:
            self = .working
        case .blocked:
            self = .blocked
        case .done:
            self = .done
        }
    }
}
