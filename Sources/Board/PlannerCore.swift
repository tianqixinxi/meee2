import Foundation
import Darwin
import Meee2CommKit
import Meee2PluginKit

/// Who can see a planning canvas. `private` (the default) restricts the canvas
/// to its owner plus anyone holding a role on it (doer / assigned); `public`
/// makes it visible to every actor.
enum PlannerCanvasVisibility: String, Codable, Equatable {
    case `public`
    case `private`
}

struct CanvasSceneArtifactBinding: Codable, Equatable {
    var id: String
    var nodeId: String
    var reference: String
    var mode: String

    init(id: String, nodeId: String, reference: String, mode: String = "merge") {
        self.id = id
        self.nodeId = nodeId
        self.reference = reference
        self.mode = mode
    }
}

struct CanvasSceneNodeAnchor: Codable, Equatable {
    var id: String
    var label: String
    var nodeId: String
    var x: Double
    var y: Double
    var role: String?

    init(id: String, label: String, nodeId: String, x: Double, y: Double, role: String? = nil) {
        self.id = id
        self.label = label
        self.nodeId = nodeId
        self.x = x
        self.y = y
        self.role = role
    }
}

struct CanvasSceneAction: Codable, Equatable {
    var id: String
    var label: String
    var nodeId: String
    var prompt: String?

    init(id: String, label: String, nodeId: String, prompt: String? = nil) {
        self.id = id
        self.label = label
        self.nodeId = nodeId
        self.prompt = prompt
    }
}

struct CanvasSceneOrchestration: Codable, Equatable {
    var kind: String
    var stateNodeId: String?
    var stateReference: String?
    var logReference: String?

    init(
        kind: String,
        stateNodeId: String? = nil,
        stateReference: String? = nil,
        logReference: String? = nil
    ) {
        self.kind = kind
        self.stateNodeId = stateNodeId
        self.stateReference = stateReference
        self.logReference = logReference
    }
}

/// Canvas-level presentation layer for scene templates such as travel maps or
/// poker tables. The scene is not a node and does not own execution state:
/// initial state comes from the template, runtime state comes from node
/// artifacts, and actions route back to existing node/session flows.
struct CanvasSceneSpec: Codable, Equatable {
    var kind: String
    var assets: [String: BoardJSONValue]
    var initialState: BoardJSONValue?
    var artifactBindings: [CanvasSceneArtifactBinding]
    var nodeAnchors: [CanvasSceneNodeAnchor]
    var actions: [CanvasSceneAction]
    var orchestration: CanvasSceneOrchestration?

    init(
        kind: String,
        assets: [String: BoardJSONValue] = [:],
        initialState: BoardJSONValue? = nil,
        artifactBindings: [CanvasSceneArtifactBinding] = [],
        nodeAnchors: [CanvasSceneNodeAnchor] = [],
        actions: [CanvasSceneAction] = [],
        orchestration: CanvasSceneOrchestration? = nil
    ) {
        self.kind = kind
        self.assets = assets
        self.initialState = initialState
        self.artifactBindings = artifactBindings
        self.nodeAnchors = nodeAnchors
        self.actions = actions
        self.orchestration = orchestration
    }

    enum CodingKeys: String, CodingKey {
        case kind, assets, initialState, artifactBindings, nodeAnchors, actions, orchestration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        assets = try c.decodeIfPresent([String: BoardJSONValue].self, forKey: .assets) ?? [:]
        initialState = try c.decodeIfPresent(BoardJSONValue.self, forKey: .initialState)
        artifactBindings = try c.decodeIfPresent([CanvasSceneArtifactBinding].self, forKey: .artifactBindings) ?? []
        nodeAnchors = try c.decodeIfPresent([CanvasSceneNodeAnchor].self, forKey: .nodeAnchors) ?? []
        actions = try c.decodeIfPresent([CanvasSceneAction].self, forKey: .actions) ?? []
        orchestration = try c.decodeIfPresent(CanvasSceneOrchestration.self, forKey: .orchestration)
    }
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

    // MARK: Canvas runtime 5-atom collections (decode-only — PR2+6.5)
    //
    // Mounted as optional-with-default so existing persisted canvases (which
    // lack these keys) decode unchanged, and new canvases carrying the 5-atom
    // entities round-trip. NOT consumed by apply / proposal-execution logic
    // yet. See `doc/prd/canvas-runtime-data-model.md` §3/§4/§6.

    /// Atom 1 — named addressable storage locations on this canvas. Default `[]`.
    var dataSources: [DataSourceRecord]
    /// Atom 2 — first-class consumption edges. Default `[]`.
    var edges: [Edge]
    /// Atom 4 — owner-facing monitor card grid. `nil` when unset.
    var monitorSpec: MonitorSpec?
    /// Canvas-level scene presentation. `nil` for ordinary workflow/monitor
    /// canvases. Optional so legacy records decode unchanged.
    var sceneSpec: CanvasSceneSpec?

    enum CodingKeys: String, CodingKey {
        case id, ownerId, title, plannerContext, visibility
        case parentCanvasId, parentNodeId, frozenIOContract
        // 5-atom collections — absent on legacy canvases.
        case dataSources, edges, monitorSpec, sceneSpec
    }

    init(
        id: String,
        ownerId: String,
        title: String,
        plannerContext: String,
        visibility: PlannerCanvasVisibility = .private,
        parentCanvasId: String? = nil,
        parentNodeId: String? = nil,
        frozenIOContract: NodeContractV2? = nil,
        dataSources: [DataSourceRecord] = [],
        edges: [Edge] = [],
        monitorSpec: MonitorSpec? = nil,
        sceneSpec: CanvasSceneSpec? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.title = title
        self.plannerContext = plannerContext
        self.visibility = visibility
        self.parentCanvasId = parentCanvasId
        self.parentNodeId = parentNodeId
        self.frozenIOContract = frozenIOContract
        self.dataSources = dataSources
        self.edges = edges
        self.monitorSpec = monitorSpec
        self.sceneSpec = sceneSpec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        title = try c.decode(String.self, forKey: .title)
        plannerContext = try c.decode(String.self, forKey: .plannerContext)
        visibility = try c.decodeIfPresent(PlannerCanvasVisibility.self, forKey: .visibility) ?? .private
        parentCanvasId = try c.decodeIfPresent(String.self, forKey: .parentCanvasId)
        parentNodeId = try c.decodeIfPresent(String.self, forKey: .parentNodeId)
        frozenIOContract = try c.decodeIfPresent(NodeContractV2.self, forKey: .frozenIOContract)
        // Legacy-tolerant: absent ⇒ empty / nil.
        dataSources = try c.decodeIfPresent([DataSourceRecord].self, forKey: .dataSources) ?? []
        edges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        monitorSpec = try c.decodeIfPresent(MonitorSpec.self, forKey: .monitorSpec)
        sceneSpec = try c.decodeIfPresent(CanvasSceneSpec.self, forKey: .sceneSpec)
    }
}

/// Part C —— step 槽对数据源的子视图(投影 + 语义)。decode 透传到前端展示。
struct SubView: Codable, Equatable {
    var semantics: Semantics
    var project: [String]?
}

struct NodeSchema: Codable, Equatable {
    var inputs: [String]
    var outputs: [String]
    var goal: String
    /// Part C:每个槽的子视图(key = 槽名)。canvas-script 生成、随 graph 透传到 UI。
    var subViews: [String: SubView]?

    init(inputs: [String], outputs: [String], goal: String, subViews: [String: SubView]? = nil) {
        self.inputs = inputs
        self.outputs = outputs
        self.goal = goal
        self.subViews = subViews
    }
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
///
/// State-machine PR-A · Public PlanningNodeStatus was narrowed to the
/// four-state lifecycle `draft / ready / blocked / done`. `working` is kept
/// as a raw value for wire-level back-compat (so old JSON still decodes), but
/// it is deprecated and the proposal validator auto-translates it to `.ready`
/// with a warning. New code MUST NOT introduce `.working`; use `.ready` plus
/// a NodeAttempt for in-flight execution state.
///
/// 3-tai cut (2026-05-29): the public surface is now `ready / blocked / done`.
/// `.draft` is deprecated and kept for back-compat decoding only — the
/// proposal validator auto-translates it to `.ready` with the same
/// `deprecated_status_used` warning lane used by `.working`. New agents MUST
/// NOT introduce `.draft`; `.ready` is the initial state — a node is `ready`
/// the moment it exists.
enum PlanningNodeStatus: String, Codable, Equatable, CaseIterable {
    @available(*, deprecated, message: "ready is the initial state. draft removed in 3-tai cut.")
    case draft
    case ready
    @available(*, deprecated, message: "Use .ready + NodeAttempt instead. Will be removed in next major.")
    case working
    case blocked
    case done

    /// State-machine PR-A · Manual `allCases` so deprecating `.working`
    /// doesn't break CaseIterable synthesis (Swift refuses to auto-synthesize
    /// `allCases` once any case is `@available(*, deprecated)`). Wire-level
    /// back-compat is still preserved — `allCases` continues to surface
    /// `.working` so the planner-adapter context lists every legacy value an
    /// agent might send. The validator is what translates it away.
    ///
    /// The legacy `.working` / `.draft` references are reconstructed from
    /// their raw values to avoid emitting a deprecation diagnostic at the
    /// single intentional use-site inside this type.
    /// `PlanningNodeStatus(rawValue:)` for these legacy raw values is
    /// guaranteed to succeed by construction.
    static var allCases: [PlanningNodeStatus] {
        let legacyDraft = PlanningNodeStatus(rawValue: "draft")!
        let legacyWorking = PlanningNodeStatus(rawValue: "working")!
        return [legacyDraft, .ready, legacyWorking, .blocked, .done]
    }
}

private func isLegacyDraftStatus(_ status: PlanningNodeStatus) -> Bool {
    status.rawValue == "draft"
}

private func isLegacyWorkingStatus(_ status: PlanningNodeStatus) -> Bool {
    status.rawValue == "working"
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

/// Twin · meee2-online/src/planner-runtime/contract/proposal.ts (HandoffPolicy).
/// Governs how reviewer / approver signals gate the node's hand-off.
///
///  - `none`                  无审批 / 直接通过
///  - `reviewerMustApprove`   任一 reviewer 拒绝即阻塞
///  - `anyApprover`           任一 approver 同意即放行
///  - `allApprovers`          所有 approver 同意才放行
enum HandoffPolicy: String, Codable, Equatable, CaseIterable {
    case none
    case reviewerMustApprove = "reviewer-must-approve"
    case anyApprover = "any-approver"
    case allApprovers = "all-approvers"
}

// MARK: - Widget (twin · meee2-online/.../contract/widget.ts)
//
// Node-level widget kicks in when a PlanningNode wants to render as something
// other than the default "standard" view (title + assignee + run state). The
// presence of a `widget` field on PlanningNode means the canvas renderer
// should consume the declared data `source` and draw the matching view.

enum WidgetKind: String, Codable, Equatable, CaseIterable {
    case kanban
    case inbox
    case matrix
    case badge
    case artifactPreview = "artifact-preview"
    /// canvas-spec §7.2 — a Monitor is an Artifact{source:canvas-runtime,
    /// widget:html}. `html` carries planner-authored HTML rendered in a
    /// sandboxed iframe (board-app MonitorHtmlFrame). Additive; existing kinds
    /// unchanged.
    case html
}

enum WidgetSourceKind: String, Codable, Equatable, CaseIterable {
    case external                                    // node.input.external[i]
    case upstream                                    // upstream node output
    case subcanvasAggregate = "subcanvas-aggregate"  // sibling canvases runtime
}

struct WidgetSource: Codable, Equatable {
    var inputKind: WidgetSourceKind
    var inputIndex: Int
    /// Only for `subcanvas-aggregate`.
    var subcanvasIds: [String]?

    init(inputKind: WidgetSourceKind, inputIndex: Int = 0, subcanvasIds: [String]? = nil) {
        self.inputKind = inputKind
        self.inputIndex = inputIndex
        self.subcanvasIds = subcanvasIds
    }

    enum CodingKeys: String, CodingKey {
        case inputKind, inputIndex, subcanvasIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputKind = try c.decode(WidgetSourceKind.self, forKey: .inputKind)
        inputIndex = (try c.decodeIfPresent(Int.self, forKey: .inputIndex)) ?? 0
        subcanvasIds = try c.decodeIfPresent([String].self, forKey: .subcanvasIds)
    }
}

struct WidgetMapping: Codable, Equatable {
    var statusField: String?
    var titleField: String?
    var subtitleField: String?
    var sortField: String?
    var rowGroupField: String?
    var colGroupField: String?

    init(
        statusField: String? = nil,
        titleField: String? = nil,
        subtitleField: String? = nil,
        sortField: String? = nil,
        rowGroupField: String? = nil,
        colGroupField: String? = nil
    ) {
        self.statusField = statusField
        self.titleField = titleField
        self.subtitleField = subtitleField
        self.sortField = sortField
        self.rowGroupField = rowGroupField
        self.colGroupField = colGroupField
    }
}

struct Widget: Codable, Equatable {
    var kind: WidgetKind
    var source: WidgetSource?
    var mapping: WidgetMapping?
    /// canvas-spec §7.2 — only meaningful when `kind == .html`: planner-authored
    /// HTML rendered in a sandboxed iframe with the read-only CanvasRuntimeView
    /// injected via postMessage. Ignored for other kinds. Optional-with-default
    /// so legacy widgets round-trip unchanged.
    var html: String?

    init(kind: WidgetKind, source: WidgetSource? = nil, mapping: WidgetMapping? = nil, html: String? = nil) {
        self.kind = kind
        self.source = source
        self.mapping = mapping
        self.html = html
    }

    enum CodingKeys: String, CodingKey { case kind, source, mapping, html }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        source = try c.decodeIfPresent(WidgetSource.self, forKey: .source)
        mapping = try c.decodeIfPresent(WidgetMapping.self, forKey: .mapping)
        html = try c.decodeIfPresent(String.self, forKey: .html)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(mapping, forKey: .mapping)
        try c.encodeIfPresent(html, forKey: .html)
    }
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

enum PlannerArtifactViewKind: String, Codable, Equatable, CaseIterable {
    case table
    case list
    case kanban
    case raw
    case json
    /// integration payload 的投影体(前端经 integration view-schema 渲染:
    /// Sheets 格子 / badge + detail 行)。缺这个 kind 时 integration artifact
    /// 只能派生 raw view → JSON dump。
    case integration
    /// typed payload 的结构化预览(prd tldr / check-result 统计…)。派生默认
    /// view 用 — 否则结构化产物被标成 raw,有原文时直接吐原文丢掉语义。
    case payload
}

struct PlannerArtifactView: Codable, Equatable {
    var id: String
    var title: String
    var kind: PlannerArtifactViewKind
    var sourcePath: String?
    var columns: [String]?
    var filter: BoardJSONValue?
    var sort: BoardJSONValue?
    var groupBy: BoardJSONValue?

    init(
        id: String,
        title: String,
        kind: PlannerArtifactViewKind,
        sourcePath: String? = nil,
        columns: [String]? = nil,
        filter: BoardJSONValue? = nil,
        sort: BoardJSONValue? = nil,
        groupBy: BoardJSONValue? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.sourcePath = sourcePath
        self.columns = columns
        self.filter = filter
        self.sort = sort
        self.groupBy = groupBy
    }
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
    /// theta (2026-05-29) · Review status for the typed payload — drives
    /// the "pending → owner Promote" surface. Mirrors Zod
    /// `ArtifactReviewStatus` (`pending` / `approved` / `rejected`).
    /// `nil` means "absent" (legacy artifacts), which downstream code
    /// treats as `approved` for back-compat.
    var reviewStatus: String?
    /// canvas-spec §7.3 / P4 · 1-based index of THIS artifact's version within
    /// its slot's append-only version chain (the latest-per-slot artifact = the
    /// chain head, so its `versionIndex == versionCount`). Lets the card render
    /// a real `v{n}`. Additive/derived — never persisted on the stored
    /// artifact; populated at read time in `canvasState`. `nil` when the slot
    /// has no version chain yet (legacy / derived artifacts).
    var versionIndex: Int?
    /// canvas-spec §7.3 / P4 · Total number of versions in this artifact's
    /// slot chain (chain length). Pairs with `versionIndex` so the UI can show
    /// e.g. `v2 / 3`. Derived at read time; `nil` when unknown.
    var versionCount: Int?
    /// Artifact-owned named projections over this artifact's data. Views are
    /// presentation metadata, not artifact data versions.
    var views: [PlannerArtifactView]?

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
        runId: String? = nil,
        reviewStatus: String? = nil,
        versionIndex: Int? = nil,
        versionCount: Int? = nil,
        views: [PlannerArtifactView]? = nil
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
        self.reviewStatus = reviewStatus
        self.versionIndex = versionIndex
        self.versionCount = versionCount
        self.views = views
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
    var renderProfile: CanvasRenderProfile?
    var renderProfileStatus: CanvasRenderProfileStatus?
    var renderObjects: [CanvasObject]
    var renderRelations: [CanvasRelation]
    /// canvas-spec §7.2 — read-only whole-canvas runtime snapshot a Monitor
    /// (Artifact{source:canvas-runtime, widget:html}) consumes. Additive: all
    /// existing fields are unchanged; optional-with-default so legacy decoders
    /// (and clients that ignore it) keep working.
    var canvasRuntime: CanvasRuntimeView?

    enum CodingKeys: String, CodingKey {
        case canvas, nodes, states, proposals, access, activities, events
        case artifacts, edges, renderProfile, renderProfileStatus, renderObjects, renderRelations, canvasRuntime
    }

    init(
        canvas: PlanningCanvas,
        nodes: [PlanningNode],
        states: [NodeStateSnapshot],
        proposals: [PlanProposal],
        access: PlannerAccess,
        activities: [PlannerActivity],
        events: [PlannerEvent],
        artifacts: [PlannerArtifact],
        edges: [PlannerGraphEdge],
        renderProfile: CanvasRenderProfile? = nil,
        renderProfileStatus: CanvasRenderProfileStatus? = nil,
        renderObjects: [CanvasObject] = [],
        renderRelations: [CanvasRelation] = [],
        canvasRuntime: CanvasRuntimeView? = nil
    ) {
        self.canvas = canvas
        self.nodes = nodes
        self.states = states
        self.proposals = proposals
        self.access = access
        self.activities = activities
        self.events = events
        self.artifacts = artifacts
        self.edges = edges
        self.renderProfile = renderProfile
        self.renderProfileStatus = renderProfileStatus
        self.renderObjects = renderObjects
        self.renderRelations = renderRelations
        self.canvasRuntime = canvasRuntime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canvas = try c.decode(PlanningCanvas.self, forKey: .canvas)
        nodes = try c.decode([PlanningNode].self, forKey: .nodes)
        states = try c.decode([NodeStateSnapshot].self, forKey: .states)
        proposals = try c.decode([PlanProposal].self, forKey: .proposals)
        access = try c.decode(PlannerAccess.self, forKey: .access)
        activities = try c.decode([PlannerActivity].self, forKey: .activities)
        events = try c.decode([PlannerEvent].self, forKey: .events)
        artifacts = try c.decode([PlannerArtifact].self, forKey: .artifacts)
        edges = try c.decode([PlannerGraphEdge].self, forKey: .edges)
        renderProfile = try c.decodeIfPresent(CanvasRenderProfile.self, forKey: .renderProfile)
        renderProfileStatus = try c.decodeIfPresent(CanvasRenderProfileStatus.self, forKey: .renderProfileStatus)
        renderObjects = try c.decodeIfPresent([CanvasObject].self, forKey: .renderObjects) ?? []
        renderRelations = try c.decodeIfPresent([CanvasRelation].self, forKey: .renderRelations) ?? []
        canvasRuntime = try c.decodeIfPresent(CanvasRuntimeView.self, forKey: .canvasRuntime)
    }
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

/// Derived (read-time only) upstream-staleness signal. Set by `canvasState`'s
/// read projection, **encode-only** on the graph DTO, never decoded or
/// persisted — same contract as `PlanningNode.nextAction`. A node is `.stale`
/// when an upstream it already consumed has since produced a newer *done*
/// version. Pure projection over the append-only `nodeVersions` log; introduces
/// no new stored state (canvas stays a ledger — staleness is computed, not
/// stored). See [[canvas-is-ledger-not-pm]].
struct UpstreamFreshness: Codable, Equatable {
    enum State: String, Codable { case fresh, stale }
    /// One upstream whose head version is newer than what this node consumed.
    struct StaleUpstream: Codable, Equatable {
        var nodeId: String
        var title: String
        /// `versionIndex` of the upstream version this node actually ran on.
        var consumedVersion: Int
        /// `versionIndex` of the upstream's current head (done) version.
        var latestVersion: Int
    }
    var state: State
    var staleUpstreams: [StaleUpstream]
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
    /// Team-ready (#5): reviewer user ids — see `handoffPolicy`. Zod twin: `reviewerIds`.
    /// Defaults to `[]` on decode so legacy fixtures without the key still load.
    var reviewerIds: [String]
    /// Team-ready (#5): approver user ids — see `handoffPolicy`. Zod twin: `approverIds`.
    /// Defaults to `[]` on decode so legacy fixtures without the key still load.
    var approverIds: [String]
    /// Team-ready (#5): governs how reviewer / approver signals gate hand-off.
    /// Zod twin: `handoffPolicy`. Defaults to `.none` on decode.
    var handoffPolicy: HandoffPolicy
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
    /// Legacy approval-target list. Predates the Team-ready (`approverIds`)
    /// field; keep around for back-compat with existing fixtures / gate code.
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
    /// Node-level view widget (2026-05-28). nil = standard view (title +
    /// assignee + run state). non-nil = render as the declared widget kind,
    /// backed by `widget.source`. See Widget struct above.
    var widget: Widget?
    /// Artifact-node data-source mode (2026-05-28). Two-mode enum stored as
    /// String for forward-compat:
    /// - `authored` (default, also implied when nil): node owns its payload.
    /// - `mirrored`: payload bound to an external integration entity;
    ///   lazy pull-on-consume snapshot semantics. Matches step/session
    ///   `input.external[].sync_session` pattern.
    /// Orthogonal to `widget.source` (which controls *view-layer* origin).
    /// nil on non-artifact nodes; nil on legacy artifact nodes is treated as
    /// `authored` per the rollout spec.
    ///
    /// @deprecated by `artifactSource` (2026-05-29 unification). Kept for one
    /// release of decode-compat — the legacy two-mode string still decodes and
    /// is normalized into `artifactSource` via `resolvedArtifactSource`.
    var artifactDataSource: String?
    /// Unified `Artifact.source` (canvas-spec §7 — artifact-unified-model).
    /// Folds the legacy two-mode `artifactDataSource` into the canonical
    /// slot|dataSource|canvas-runtime origin. nil on non-artifact nodes and on
    /// legacy data (decode falls back to deriving from `artifactDataSource`).
    var artifactSource: ArtifactSource?
    /// Part D — 可配置节点状态(spec §5)。nil = 默认 schema(三态+done 门控)。
    /// 用户可经 planner 给节点定义自定义状态集;读 `effectiveStateSchema`。
    var stateSchema: NodeStateSchema?

    /// Derived upstream-staleness signal — set ONLY by `canvasState`'s read
    /// projection (`injectUpstreamFreshness`). Optional ⇒ implicit nil default,
    /// so the custom `init(...)` / `init(from:)` never need to set it and stored
    /// `record.nodes` always carry nil (never persisted; see `DerivedCodingKeys`
    /// + `encode(to:)`). nil on nodes with no upstream or that never ran.
    var upstreamFreshness: UpstreamFreshness?

    /// 生效的状态 schema:显式 `stateSchema` 否则默认。引擎/契约/校验都读这个。
    var effectiveStateSchema: NodeStateSchema { stateSchema ?? .default }

    /// The effective unified source: explicit `artifactSource` if present,
    /// else the legacy `artifactDataSource` string normalized via §7.4 mapping.
    /// Read this (not the raw fields) wherever the artifact data origin matters.
    var resolvedArtifactSource: ArtifactSource? {
        if let artifactSource { return artifactSource }
        return ArtifactSource.fromLegacy(
            mode: artifactDataSource,
            nodeId: id,
            outputSlotKey: schema.outputs.first,
            mirroredSourceId: nil
        )
    }

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
        reviewerIds: [String] = [],
        approverIds: [String] = [],
        handoffPolicy: HandoffPolicy = .none,
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
        outputSubmittedAt: Date? = nil,
        widget: Widget? = nil,
        artifactDataSource: String? = nil,
        artifactSource: ArtifactSource? = nil,
        stateSchema: NodeStateSchema? = nil
    ) {
        self.id = id
        self.canvasId = canvasId
        self.title = title
        self.schema = schema
        self.contextSources = contextSources
        self.executionMode = executionMode
        self.executorType = executorType
        self.doerId = doerId
        self.reviewerIds = reviewerIds
        self.approverIds = approverIds
        self.handoffPolicy = handoffPolicy
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
        self.widget = widget
        self.artifactDataSource = artifactDataSource
        self.artifactSource = artifactSource
        self.stateSchema = stateSchema
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
        // Team-ready (#5) — Zod twin defaults `[]` / `'none'`.
        case reviewerIds, approverIds, handoffPolicy
        // Node-widget (2026-05-28) — absent = standard view.
        case widget
        // Artifact-node data-source mode (2026-05-28). nil ⇒ `authored` per
        // rollout default. Stored as String for forward-compat with new modes.
        case artifactDataSource
        // Unified Artifact.source (2026-05-29). Canonical origin; supersedes
        // the legacy `artifactDataSource` string.
        case artifactSource
        // Part D — 可配置节点状态(2026-06-01). nil = 默认三态+done schema.
        case stateSchema
    }

    /// Extra (encode-only) keys layered on top of the stored shape.
    private enum DerivedCodingKeys: String, CodingKey {
        case nextAction
        case upstreamFreshness
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
        // Team-ready (#5): default to empty / `none` so legacy fixtures
        // without these keys still decode cleanly.
        reviewerIds = (try container.decodeIfPresent([String].self, forKey: .reviewerIds)) ?? []
        approverIds = (try container.decodeIfPresent([String].self, forKey: .approverIds)) ?? []
        handoffPolicy = (try container.decodeIfPresent(HandoffPolicy.self, forKey: .handoffPolicy)) ?? .none
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
        widget = try container.decodeIfPresent(Widget.self, forKey: .widget)
        artifactDataSource = try container.decodeIfPresent(String.self, forKey: .artifactDataSource)
        artifactSource = try container.decodeIfPresent(ArtifactSource.self, forKey: .artifactSource)
        stateSchema = try container.decodeIfPresent(NodeStateSchema.self, forKey: .stateSchema)
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
        // Team-ready (#5) — always encode so consumers see the canonical shape.
        try container.encode(reviewerIds, forKey: .reviewerIds)
        try container.encode(approverIds, forKey: .approverIds)
        try container.encode(handoffPolicy, forKey: .handoffPolicy)
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
        try container.encodeIfPresent(widget, forKey: .widget)
        try container.encodeIfPresent(artifactDataSource, forKey: .artifactDataSource)
        try container.encodeIfPresent(stateSchema, forKey: .stateSchema)
        // Emit the unified source (resolved from legacy if unset) so the
        // board-app reads one canonical `artifactSource`. Legacy
        // `artifactDataSource` is still emitted above for one-release compat.
        try container.encodeIfPresent(resolvedArtifactSource, forKey: .artifactSource)
        // Derived guidance — encode-only, never decoded back.
        var derived = encoder.container(keyedBy: DerivedCodingKeys.self)
        try derived.encodeIfPresent(nextAction, forKey: .nextAction)
        // Derived upstream-staleness — encode-only; nil on stored nodes (set
        // only in the read projection), so storage never carries it.
        try derived.encodeIfPresent(upstreamFreshness, forKey: .upstreamFreshness)
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
    /// Artifact-node three-mode data-source picker (authored / aggregated /
    /// mirrored). nil ⇒ no proposal-level change. When non-nil on an
    /// `attachArtifact` change, apply-path writes it through to the target
    /// PlanningNode's `artifactDataSource`.
    var dataSource: String?
    /// theta (2026-05-29): when non-nil, apply-path stamps this on the
    /// resulting PlannerArtifact.reviewStatus. Lets the Promote button flip
    /// review state without re-shipping a payload (which would clobber the
    /// original content if typedPayload isn't available to spread).
    var reviewStatus: String?
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

        // MARK: Canvas runtime 5-atom governance variants (PR6+7)
        //
        // These mirror the contract's PlanChange discriminated union
        // (meee2-online/src/planner-runtime/contract/proposal.ts). Their
        // payloads ride on the optional `*5Atom*` fields below and are applied
        // at the canvas level by `PlannerStore.applyCanvasAtomChanges`.

        /// Real node removal (governance alias). Carries `nodeId`.
        case removeNode
        // Atom 1 · DataSource
        case addDataSource
        case updateDataSource
        case setPartitionRule
        case archiveDataSource
        // Atom 2 · Edge
        case addEdge
        case updateEdgeMode
        case removeEdge
        // Atom 4 · Monitor
        case setMonitorSpec
        case addMonitorCard
        case updateMonitorCard
        case removeMonitorCard
        case moveMonitorCard
        // Canvas Render Protocol · logic replacement goes through owner-approved proposals.
        case replaceRenderLogic
        // Artifact write (split from legacy attachArtifact)
        case writeSourceVersion
        case attachExternalArtifact
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
    /// Team-ready (#5): proposal-driven update of `PlanningNode.reviewerIds`.
    /// `nil` ⇒ no change; `[]` ⇒ explicit clear.
    var reviewerIds: [String]?
    /// Team-ready (#5): proposal-driven update of `PlanningNode.approverIds`.
    var approverIds: [String]?
    /// Team-ready (#5): proposal-driven update of `PlanningNode.handoffPolicy`.
    var handoffPolicy: HandoffPolicy?
    /// Node-widget (2026-05-28): proposal-driven update of `PlanningNode.widget`.
    var widget: Widget?
    var artifact: PlanArtifactDraft?
    /// Artifact data-source mode (2026-05-28): proposal-driven update of
    /// `PlanningNode.artifactDataSource`. nil ⇒ no change. Carries the same
    /// three-mode enum (authored / aggregated / mirrored) as the inline
    /// artifact draft; whichever lane (attachArtifact or updateNode) carries
    /// it, apply-path writes it onto the target node.
    var artifactDataSource: String?
    /// Unified `Artifact.source` (2026-05-29): proposal-driven update of
    /// `PlanningNode.artifactSource`. nil ⇒ no change. Preferred over the
    /// legacy `artifactDataSource`. Also decoded from the legacy nested wire
    /// shape `artifactConfig.dataSource` (board-app sends that on updateNode)
    /// so old clients keep working — see init(from:).
    var artifactSource: ArtifactSource?

    // MARK: Canvas runtime 5-atom payloads (PR6+7)
    //
    // Carried by-value on the governance PlanChange variants. Decode-tolerant
    // (all optional). Applied at the canvas level by
    // `PlannerStore.applyCanvasAtomChanges`. Wire field names match the TS
    // contract (proposal.ts) exactly.

    /// addDataSource → the new DataSource record. NOTE: shares the wire key
    /// `source` with the node-level `source` (`PlanningNodeSource`). Decode
    /// disambiguates by `kind`: addDataSource decodes the object form here, the
    /// node lanes decode the string form into `source`.
    var dataSourceRecord: DataSourceRecord?
    /// updateDataSource / setPartitionRule / archiveDataSource / writeSourceVersion.
    var sourceId: String?
    /// updateDataSource patch — partial DataSource fields (opaque, applied per-field).
    var dataSourcePatch: BoardJSONValue?
    /// setPartitionRule.
    var partitionRule: String?
    var partitionTimezone: String?
    /// archiveDataSource: `reject-if-referenced | detach-edges`.
    var cascade: String?
    /// addEdge → the new Edge.
    var edge: Edge?
    /// updateEdgeMode / removeEdge.
    var edgeId: String?
    /// updateEdgeMode.
    var edgeMode: EdgeMode?
    /// setMonitorSpec → full spec.
    var spec: MonitorSpec?
    /// setMonitorSpec guard: must be `wipe-and-rebuild` to replace a non-null prior.
    var intent: String?
    /// addMonitorCard.
    var card: MonitorCard?
    /// updateMonitorCard / removeMonitorCard / moveMonitorCard.
    var cardId: String?
    /// moveMonitorCard. Shares wire key `layout` with the node layout; decode
    /// disambiguates by `kind`.
    var cardLayout: MonitorCardLayout?
    /// replaceRenderLogic → full CanvasRenderLogic replacement.
    var renderLogic: CanvasRenderLogic?
    /// updateMonitorCard partial patch (opaque — applied permissively). Shares
    /// wire key `patch` with `dataSourcePatch`; decode disambiguates by `kind`.
    var cardPatch: BoardJSONValue?
    /// writeSourceVersion.
    var slotKey: String?
    var payload: BoardJSONValue?
    var payloadRef: String?
    var parentVersionId: String?
    var submittedBy: String?
    var submittedByKind: String?
    /// Free-text rationale carried by governance variants (§7). Decode-only.
    var rationale: String?

    private enum CodingKeys: String, CodingKey {
        case kind, node, nodeId, title, status, schema, contextSources
        case dependsOnNodeIds, subCanvasId, nodeKind, layout, trigger, schedule, gate
        case executionMode, clearGate, dispatch, approvers, artifactRefs, eventRefs, workflowRunState
        case sessionId, chatThreadId, source, doerId, artifact
        case reviewerIds, approverIds, handoffPolicy, widget
        case artifactDataSource, artifactSource
        // Legacy nested wire shape `artifactConfig: { dataSource: { mode } }`
        // (board-app sends this on updateNode). Decoded into artifactDataSource
        // for one-release compat.
        case artifactConfig
        // 5-atom governance payloads. `source` / `patch` / `layout` collide
        // with node-lane keys and are disambiguated by `kind` in init(from:).
        case sourceId, partitionRule, partitionTimezone, cascade
        case edge, edgeId, edgeMode
        case spec, intent, card, cardId
        case renderLogic
        case slotKey, payload, payloadRef, parentVersionId, submittedBy, submittedByKind
        case patch
        case rationale
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
        reviewerIds: [String]? = nil,
        approverIds: [String]? = nil,
        handoffPolicy: HandoffPolicy? = nil,
        widget: Widget? = nil,
        artifact: PlanArtifactDraft? = nil,
        artifactDataSource: String? = nil,
        artifactSource: ArtifactSource? = nil,
        dataSourceRecord: DataSourceRecord? = nil,
        sourceId: String? = nil,
        dataSourcePatch: BoardJSONValue? = nil,
        partitionRule: String? = nil,
        partitionTimezone: String? = nil,
        cascade: String? = nil,
        edge: Edge? = nil,
        edgeId: String? = nil,
        edgeMode: EdgeMode? = nil,
        spec: MonitorSpec? = nil,
        intent: String? = nil,
        card: MonitorCard? = nil,
        cardId: String? = nil,
        cardLayout: MonitorCardLayout? = nil,
        renderLogic: CanvasRenderLogic? = nil,
        cardPatch: BoardJSONValue? = nil,
        slotKey: String? = nil,
        payload: BoardJSONValue? = nil,
        payloadRef: String? = nil,
        parentVersionId: String? = nil,
        submittedBy: String? = nil,
        submittedByKind: String? = nil,
        rationale: String? = nil
    ) {
        self.kind = kind
        self.node = node
        self.nodeId = nodeId
        self.title = title
        self.status = status
        self.dataSourceRecord = dataSourceRecord
        self.sourceId = sourceId
        self.dataSourcePatch = dataSourcePatch
        self.partitionRule = partitionRule
        self.partitionTimezone = partitionTimezone
        self.cascade = cascade
        self.edge = edge
        self.edgeId = edgeId
        self.edgeMode = edgeMode
        self.spec = spec
        self.intent = intent
        self.card = card
        self.cardId = cardId
        self.cardLayout = cardLayout
        self.renderLogic = renderLogic
        self.cardPatch = cardPatch
        self.slotKey = slotKey
        self.payload = payload
        self.payloadRef = payloadRef
        self.parentVersionId = parentVersionId
        self.submittedBy = submittedBy
        self.submittedByKind = submittedByKind
        self.rationale = rationale
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
        self.reviewerIds = reviewerIds
        self.approverIds = approverIds
        self.handoffPolicy = handoffPolicy
        self.widget = widget
        self.artifact = artifact
        self.artifactDataSource = artifactDataSource
        self.artifactSource = artifactSource
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
        // `layout` is shared between the node lane (PlannerNodeLayout) and the
        // monitor-card lanes (MonitorCardLayout). Disambiguate by kind so a
        // governance card-layout object doesn't fail the node-layout decode.
        if kind == .moveMonitorCard {
            layout = nil
            cardLayout = try container.decodeIfPresent(MonitorCardLayout.self, forKey: .layout)
        } else {
            layout = try container.decodeIfPresent(PlannerNodeLayout.self, forKey: .layout)
            cardLayout = nil
        }
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
        // `source` is shared between the node lane (PlanningNodeSource string)
        // and the addDataSource lane (DataSource object). Disambiguate by kind.
        if kind == .addDataSource {
            source = nil
            dataSourceRecord = try container.decodeIfPresent(DataSourceRecord.self, forKey: .source)
        } else {
            source = try container.decodeIfPresent(PlanningNodeSource.self, forKey: .source)
            dataSourceRecord = nil
        }
        doerId = try container.decodeIfPresent(String.self, forKey: .doerId)
        reviewerIds = try container.decodeIfPresent([String].self, forKey: .reviewerIds)
        approverIds = try container.decodeIfPresent([String].self, forKey: .approverIds)
        handoffPolicy = try container.decodeIfPresent(HandoffPolicy.self, forKey: .handoffPolicy)
        widget = try container.decodeIfPresent(Widget.self, forKey: .widget)
        artifact = try container.decodeIfPresent(PlanArtifactDraft.self, forKey: .artifact)
        artifactSource = try container.decodeIfPresent(ArtifactSource.self, forKey: .artifactSource)
        // Legacy two-mode: prefer the flat `artifactDataSource` string; else
        // pull `mode` out of the nested `artifactConfig.dataSource` wire shape
        // the board-app still sends on updateNode (decode-compat, one release).
        if let flat = try container.decodeIfPresent(String.self, forKey: .artifactDataSource) {
            artifactDataSource = flat
        } else if let cfg = try container.decodeIfPresent(BoardJSONValue.self, forKey: .artifactConfig),
                  let mode = cfg.objectValue?["dataSource"]?.objectValue?["mode"]?.stringValue {
            artifactDataSource = mode
        } else {
            artifactDataSource = nil
        }

        // MARK: 5-atom governance payloads.
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)
        partitionRule = try container.decodeIfPresent(String.self, forKey: .partitionRule)
        partitionTimezone = try container.decodeIfPresent(String.self, forKey: .partitionTimezone)
        cascade = try container.decodeIfPresent(String.self, forKey: .cascade)
        edge = try container.decodeIfPresent(Edge.self, forKey: .edge)
        edgeId = try container.decodeIfPresent(String.self, forKey: .edgeId)
        edgeMode = try container.decodeIfPresent(EdgeMode.self, forKey: .edgeMode)
        spec = try container.decodeIfPresent(MonitorSpec.self, forKey: .spec)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)
        card = try container.decodeIfPresent(MonitorCard.self, forKey: .card)
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
        renderLogic = try container.decodeIfPresent(CanvasRenderLogic.self, forKey: .renderLogic)
        slotKey = try container.decodeIfPresent(String.self, forKey: .slotKey)
        payload = try container.decodeIfPresent(BoardJSONValue.self, forKey: .payload)
        payloadRef = try container.decodeIfPresent(String.self, forKey: .payloadRef)
        parentVersionId = try container.decodeIfPresent(String.self, forKey: .parentVersionId)
        submittedBy = try container.decodeIfPresent(String.self, forKey: .submittedBy)
        submittedByKind = try container.decodeIfPresent(String.self, forKey: .submittedByKind)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        // `patch` is shared between updateDataSource (DataSource fields) and
        // updateMonitorCard (card fields). Both decode into an opaque
        // BoardJSONValue; route by kind.
        let rawPatch = try container.decodeIfPresent(BoardJSONValue.self, forKey: .patch)
        switch kind {
        case .updateDataSource: dataSourcePatch = rawPatch; cardPatch = nil
        case .updateMonitorCard: cardPatch = rawPatch; dataSourcePatch = nil
        default: dataSourcePatch = nil; cardPatch = nil
        }
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
        try container.encodeIfPresent(reviewerIds, forKey: .reviewerIds)
        try container.encodeIfPresent(approverIds, forKey: .approverIds)
        try container.encodeIfPresent(handoffPolicy, forKey: .handoffPolicy)
        try container.encodeIfPresent(widget, forKey: .widget)
        try container.encodeIfPresent(artifact, forKey: .artifact)
        try container.encodeIfPresent(artifactDataSource, forKey: .artifactDataSource)
        try container.encodeIfPresent(artifactSource, forKey: .artifactSource)

        // MARK: 5-atom governance payloads. `source` / `layout` / `patch` are
        // shared keys — encode the governance variant only when the node-lane
        // value is absent (a given change carries exactly one of each).
        if source == nil, let dataSourceRecord {
            try container.encode(dataSourceRecord, forKey: .source)
        }
        if layout == nil, let cardLayout {
            try container.encode(cardLayout, forKey: .layout)
        }
        if let dataSourcePatch {
            try container.encode(dataSourcePatch, forKey: .patch)
        } else if let cardPatch {
            try container.encode(cardPatch, forKey: .patch)
        }
        try container.encodeIfPresent(sourceId, forKey: .sourceId)
        try container.encodeIfPresent(partitionRule, forKey: .partitionRule)
        try container.encodeIfPresent(partitionTimezone, forKey: .partitionTimezone)
        try container.encodeIfPresent(cascade, forKey: .cascade)
        try container.encodeIfPresent(edge, forKey: .edge)
        try container.encodeIfPresent(edgeId, forKey: .edgeId)
        try container.encodeIfPresent(edgeMode, forKey: .edgeMode)
        try container.encodeIfPresent(spec, forKey: .spec)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encodeIfPresent(card, forKey: .card)
        try container.encodeIfPresent(cardId, forKey: .cardId)
        try container.encodeIfPresent(renderLogic, forKey: .renderLogic)
        try container.encodeIfPresent(slotKey, forKey: .slotKey)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encodeIfPresent(payloadRef, forKey: .payloadRef)
        try container.encodeIfPresent(parentVersionId, forKey: .parentVersionId)
        try container.encodeIfPresent(submittedBy, forKey: .submittedBy)
        try container.encodeIfPresent(submittedByKind, forKey: .submittedByKind)
        try container.encodeIfPresent(rationale, forKey: .rationale)
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
        payload: BoardJSONValue? = nil,
        dataSource: String? = nil
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
                payload: payload,
                dataSource: dataSource
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
        doerId: String? = nil,
        reviewerIds: [String]? = nil,
        approverIds: [String]? = nil,
        handoffPolicy: HandoffPolicy? = nil,
        artifactDataSource: String? = nil
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
            doerId: doerId,
            reviewerIds: reviewerIds,
            approverIds: approverIds,
            handoffPolicy: handoffPolicy,
            artifactDataSource: artifactDataSource
        )
    }
}

struct PlanProposal: Codable, Equatable {
    var id: String
    var canvasId: String
    var summary: String
    var changes: [PlanChange]
    var status: PlanProposalStatus
    /// State-machine PR-A · Warnings emitted by the validator/normalizer when a
    /// proposal references a deprecated planner contract surface (e.g. legacy
    /// `working` PlanningNodeStatus auto-translated to `ready`). Optional so
    /// existing JSON without the field decodes cleanly and existing memberwise
    /// initialization (`PlanProposal(id:canvasId:summary:changes:status:)`)
    /// still type-checks.
    var warnings: [String]?
    /// propose_add_node · 提案来源归属:发起方是哪个节点的工作会话。nil ⇒ owner /
    /// planner-agent 渠道(既有提案)。权限按发起节点的 requireNodeUpdate 门控
    /// (doer 只能从自己的节点发起),UI 据此显示「来自节点 X 的提议」。
    var originNodeId: String?
    var originSessionId: String?
}

enum NodeRunState: String, Codable, Equatable {
    case draft
    case ready
    case working
    case blocked
    case done
}

/// Part D — 可配置节点状态(spec §5)。引擎只认 `kind` 这层抽象(驱动会话 UI 与
/// 下游门控);`id/label/definition` 是用户/planner 自定义的皮肤与语义。
enum NodeStateKind: String, Codable, Equatable {
    case notStarted = "not_started"
    case running
    case needsResponse = "needs_response"
    case done
    case custom
}

struct NodeStateDef: Codable, Equatable {
    var id: String
    var label: String
    var kind: NodeStateKind
    /// 进入此态是否解锁下游(取代写死的 done 门控)。默认 schema 里只有 done 为真。
    var gatesDownstream: Bool
    var definition: String?

    init(id: String, label: String, kind: NodeStateKind, gatesDownstream: Bool, definition: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.gatesDownstream = gatesDownstream
        self.definition = definition
    }
}

struct NodeStateSchema: Codable, Equatable {
    var states: [NodeStateDef]
    var defaultStateId: String

    /// flow 默认状态机:三态 + done 门控(spec §6 词表 v1)。
    static let `default` = NodeStateSchema(
        states: [
            NodeStateDef(id: "not_started", label: "待开始", kind: .notStarted, gatesDownstream: false),
            NodeStateDef(id: "running", label: "运行中", kind: .running, gatesDownstream: false),
            NodeStateDef(id: "needs_response", label: "需要人回复", kind: .needsResponse, gatesDownstream: false),
            NodeStateDef(id: "done", label: "完成", kind: .done, gatesDownstream: true)
        ],
        defaultStateId: "not_started"
    )

    /// 动态状态校验:返回该 state id 的定义,不在 schema 内 → nil(调用方把错误返回
    /// 给 agent 自纠,见 meee2-ai-is-claude-harness-self-correct)。
    func def(forStateId id: String) -> NodeStateDef? {
        states.first { $0.id == id.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

extension NodeStateDef {
    /// 作为 submit_node_output 提交时,该状态映射到的引擎 outcome。
    /// done / 任意 gatesDownstream → .done(放行下游);needsResponse → .needsReview;
    /// notStarted / running / 非门控 custom → nil(不是可提交的终态/门控态)。
    var submittableStatus: PlannerNodeOutputStatus? {
        if gatesDownstream || kind == .done { return .done }
        if kind == .needsResponse { return .needsReview }
        return nil
    }
}

/// kanban item 列（spec §6 词表 v1）。canvas-is-ledger-not-pm: item 状态不落库,由
/// 所绑「状态源」派生。slice 1 落「下钻 subcanvas」源 —— item.subCanvasId → 子画板
/// runtime worst-case(summarizeSubCanvas)→ 列。decision #7(b): 与 monitor 共享
/// summarizeSubCanvas 同源派生。
enum KanbanDerivedColumn: String, Codable, Equatable, CaseIterable {
    case notStarted = "not_started"        // 待开始
    case inProgress = "in_progress"        // 进行中
    case needsResponse = "needs_response"  // 需要人回复
    case blocked                           // 阻塞
    case done                              // 完成

    /// subcanvas worst-case runtime → kanban 列。
    static func from(subCanvasRunState runState: NodeRunState) -> KanbanDerivedColumn {
        switch runState {
        case .ready:   return .notStarted
        case .working: return .inProgress
        case .draft:   return .needsResponse   // pending proposal / needsOwnerReview
        case .blocked: return .blocked
        case .done:    return .done
        }
    }

    /// 下游消费订阅(queue-claim): DataSourceItem 消费态 → kanban 列(spec §4.5)。
    /// ready=未认领→待开始 / claimed·in-progress=认领处理中→进行中 / done=消费完成→完成。
    static func from(consumptionState state: DataSourceItemState) -> KanbanDerivedColumn {
        switch state {
        case .ready:      return .notStarted
        case .claimed:    return .inProgress
        case .inProgress: return .inProgress
        case .done:       return .done
        }
    }
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
    /// Part D — 该节点可进入的状态集(可配置;缺省=默认三态+done)。agent 读它知道
    /// 能提交哪些 state、各是什么意思、哪个放行下游(spec §5)。
    var stateSchema: NodeStateSchema
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

// MARK: - Node Contract v2 · external input source (chunk I)
//
// Twin · meee2-online/src/planner-runtime/contract/proposal.ts
//        (`NodeContractExternalInput` discriminatedUnion). Distinct from
// `NodeContractExternalInput` above which is the post-fetch *snapshot* shape
// stored on a node version. This `NodeContractExternalInputSource` is the
// *proposal-level* declaration of what the node wants to consume as an
// external input — its `kind` discriminator selects between a plain URL and
// a typed Meee2 integration entity (PRD `integration.md` §5).

enum NodeContractExternalInputSyncPolicy: String, Codable, Equatable, CaseIterable {
    case poll
    case webhook
    case manual
}

enum NodeContractExternalInputSource: Codable, Equatable {
    case url(URLSource)
    case integration(IntegrationSource)

    struct URLSource: Codable, Equatable {
        var url: String
        var refreshSeconds: Int?
    }

    struct IntegrationSource: Codable, Equatable {
        /// Stable integration id — see IntegrationViewSchema.integrationId.
        var integrationId: String
        /// Per-integration entity kind (`pr` / `issue` / `thread` / …).
        var entityKind: String
        /// Integration-specific stable reference (e.g. `owner/repo#123`).
        var entityRef: String
        var syncPolicy: NodeContractExternalInputSyncPolicy
        var pollSeconds: Int

        init(
            integrationId: String,
            entityKind: String,
            entityRef: String,
            syncPolicy: NodeContractExternalInputSyncPolicy = .poll,
            pollSeconds: Int = 60
        ) {
            self.integrationId = integrationId
            self.entityKind = entityKind
            self.entityRef = entityRef
            self.syncPolicy = syncPolicy
            self.pollSeconds = pollSeconds
        }
    }

    private enum DiscriminatorKey: String, CodingKey { case kind }
    private enum Discriminator: String, Codable { case url, integration }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try container.decode(Discriminator.self, forKey: .kind)
        switch kind {
        case .url:
            self = .url(try URLSource(from: decoder))
        case .integration:
            self = .integration(try IntegrationSource(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DiscriminatorKey.self)
        switch self {
        case .url(let s):
            try container.encode(Discriminator.url, forKey: .kind)
            try s.encode(to: encoder)
        case .integration(let s):
            try container.encode(Discriminator.integration, forKey: .kind)
            try s.encode(to: encoder)
        }
    }
}

// MARK: - Integration view-schema (chunk I)
//
// Twin · meee2-online/src/planner-runtime/contract/integration-view.ts.
// PRD: doc/prd/integration.md §3.1. Per-(integration, entityKind) literals
// live in the TS layer (packages/board-app/src/integrations/viewSchemas/);
// Swift just needs the shape for type-safe round-tripping over BoardServer.

enum IntegrationBadgeStatus: String, Codable, Equatable, CaseIterable {
    case todo, running, awaiting, blocked, done
}

enum IntegrationPreviewDetailKind: String, Codable, Equatable, CaseIterable {
    case text, link, code, diff, image
}

enum IntegrationAffordanceKind: String, Codable, Equatable, CaseIterable {
    case link, mcp_call, shell, copy
}

struct IntegrationBadge: Codable, Equatable {
    var title: String
    var secondary: String?
    var status: IntegrationBadgeStatus
    var icon: String
    var accentColor: String?
}

struct IntegrationPreviewDetail: Codable, Equatable {
    var label: String
    var value: String
    var kind: IntegrationPreviewDetailKind
}

struct IntegrationPreview: Codable, Equatable {
    var summary: String
    var details: [IntegrationPreviewDetail]
    var sourceUrl: String?
    var lastSyncedAt: String?
}

struct IntegrationAffordance: Codable, Equatable {
    var id: String
    var label: String
    var kind: IntegrationAffordanceKind
    // payload is integration-specific; kept as opaque JSON on Swift side.
    var payload: BoardJSONValue?
}

struct IntegrationViewSchema: Codable, Equatable {
    var integrationId: String
    var entityKind: String
    var badge: IntegrationBadge
    var preview: IntegrationPreview
    var affordances: [IntegrationAffordance]
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
        // external-first writeback: an OUTPUT slot whose reference carries a
        // recognized *named* connector scheme (gsheet:// / lark:// / notion:// …)
        // declares the node writes its result directly to that external object —
        // mirror of the input-side `inferConnector`. The executing agent reads
        // `output.external_write_target` + the standing MCP rule and writes
        // external-first (not the mirror); meee2 reconciles the mirror snapshot
        // after a gating submit. Generic http/file/internal schemes are NOT
        // external write targets — only the named connectors below.
        var externalWriteTarget: NodeContractExternalWriteTarget?
        let externalOutputs = node.schema.outputs.compactMap { slot -> NodeContractExternalWriteTarget? in
            externalWriteConnector(forOutputRef: slot).map {
                NodeContractExternalWriteTarget(connector: $0, ref: slot)
            }
        }
        if let first = externalOutputs.first {
            externalWriteTarget = first
            if externalOutputs.count > 1 {
                warnings.append("Node \(node.id) declares \(externalOutputs.count) external output slots; contract external_write_target keeps only \(first.ref) — split extra external writes into separate nodes.")
            }
        }
        let output = NodeContractOutput(
            cardinality: cardinality,
            payloadKind: .artifactRef,
            externalWriteTarget: externalWriteTarget
        )

        let v2 = NodeContractV2(
            input: NodeContractInput(upstream: upstream, external: external, dialogue: dialogue),
            output: output
        )
        return (v2, warnings)
    }

    /// Generic / internal schemes that `inferConnector` recognizes but which are
    /// NOT external-connector write targets: a bare http(s) URL, a local file,
    /// or the internal `meee2-artifact://` mirror scheme. An output slot using
    /// these is just a plain artifact reference, not "write to an external object."
    private static let nonExternalWriteConnectors: Set<String> = ["http", "file", "meee2-artifact"]

    /// The external connector an OUTPUT slot reference writes to, or nil if the
    /// slot is a plain name / generic / internal reference. Reuses the same
    /// scheme table as the input side so input and output stay symmetric.
    static func externalWriteConnector(forOutputRef ref: String) -> String? {
        guard let connector = inferConnector(from: ref) else { return nil }
        return nonExternalWriteConnectors.contains(connector) ? nil : connector
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
            // 顺序敏感:spreadsheets 是 docs.google.com 的子路径,必须排在前面。
            ("https://docs.google.com/spreadsheets", "google-sheets"),
            ("gsheet://", "google-sheets"),
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
    /// external-first writeback: external-object references (e.g.
    /// `gsheet://venture-tracker/Pipeline`) whose mirror should be reconciled
    /// after THIS (gating) submit. Computed engine-side; BoardAPI materializes
    /// each into a dedicated artifact-sync session — same split as
    /// `autoDispatchedNodeIds` (engine decides, BoardAPI spawns). Only populated
    /// on a downstream-gating `.done` submit; nil/empty otherwise.
    var reconcileReferences: [String]?
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
    case session
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
    /// Wall-clock timestamp of the live attempt's entry into
    /// `awaitingInput` / `gateWait`. Surfaced from the active run's last
    /// attempt so the monitor can sort/boost stale-awaiting items and the
    /// card can render "等了 X 小时". Nil for non-awaiting nodes.
    var awaitingInputSince: Date?

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
        nextAction: String? = nil,
        awaitingInputSince: Date? = nil
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
        self.awaitingInputSince = awaitingInputSince
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
    case plannerStateUnreadable(String)
    case runNotFound(String)
    case monitorClearNotAllowed(String)
    case permissionDenied(action: String, role: PlannerCanvasRole)
    /// A change references a node whose id belongs to a different canvas.
    case crossCanvasNodeReference(nodeId: String, expectedCanvas: String)
    /// A change carries a node `kind` outside the known PlanningNodeKind set.
    case unknownNodeKind(String)
    /// epsilon (session-hide): `addNode` proposed a new `session`-kind node.
    /// `session` is preserved on the type for legacy decode / updateNode
    /// compatibility, but is no longer a creatable kind — callers should
    /// instead create a `step` node with `dispatch.runner = .claude`.
    case sessionKindNoLongerCreatable(nodeId: String)
    /// A change carries a change `kind` outside the known PlanChange.Kind set.
    case unknownChangeKind(String)
    case invalidNodeOutput(String)
    case activeSessionExists(nodeId: String)
    /// Direct artifact read/write addressed an artifact (by id or reference)
    /// that doesn't exist on the canvas.
    case artifactNotFound(String)
    // Canvas runtime 5-atom governance (PR6+7).
    case dataSourceNotFound(String)
    case edgeNotFound(String)
    case monitorCardNotFound(String)
    /// §6.6 footgun guard: wholesale `setMonitorSpec` over a non-empty prior
    /// spec is rejected unless `intent == 'wipe-and-rebuild'`.
    case monitorSpecReplaceGuard
    /// 方向 A(Principle 13):apply 委托 meee2-online sidecar 时,sidecar 的
    /// governance 校验(引用完整性 / 事务原子 / footgun)不过,带回 violations。
    case applyRejected([String])

    var errorDescription: String? {
        switch self {
        case .invalidPlannerProposalJSON:
            return "Meee2 AI proposal output is not valid JSON"
        case .proposalNotApproved:
            return "plan proposal must be approved before apply"
        case .proposalNotFound(let id):
            return "plan proposal not found: \(id)"
        case .applyRejected(let violations):
            return "proposal rejected by sidecar: \(violations.joined(separator: "; "))"
        case .canvasMismatch(let expected, let actual):
            return "proposal canvas mismatch: expected \(expected), got \(actual)"
        case .emptyProposalChanges:
            return "Meee2 AI proposal must contain at least one change"
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
        case .plannerStateUnreadable(let id):
            return "planning canvas state is unreadable and will not be overwritten: \(id)"
        case .runNotFound(let id):
            return "workflow run not found: \(id)"
        case .monitorClearNotAllowed(let id):
            return "monitor canvas cannot be cleared: \(id)"
        case .permissionDenied(let action, let role):
            return "Meee2 AI \(action) is not allowed for \(role.rawValue)"
        case .crossCanvasNodeReference(let nodeId, let expectedCanvas):
            return "Meee2 AI proposal references node \(nodeId) outside canvas \(expectedCanvas)"
        case .unknownNodeKind(let kind):
            return "Meee2 AI proposal uses unknown node kind: \(kind)"
        case .sessionKindNoLongerCreatable(let nodeId):
            return "node \(nodeId) uses nodeKind='session', which is deprecated for new nodes; create a 'step' node with dispatch.runner='claude' instead"
        case .unknownChangeKind(let kind):
            return "Meee2 AI proposal uses unknown change kind: \(kind)"
        case .invalidNodeOutput(let hint):
            return hint
        case .activeSessionExists(let nodeId):
            return "node \(nodeId) already has an active session; complete or split the node before starting another"
        case .artifactNotFound(let selector):
            return "artifact not found: \(selector)"
        case .dataSourceNotFound(let id):
            return "data source not found: \(id)"
        case .edgeNotFound(let id):
            return "edge not found: \(id)"
        case .monitorCardNotFound(let id):
            return "monitor card not found: \(id)"
        case .monitorSpecReplaceGuard:
            return "setMonitorSpec cannot replace a non-empty monitor spec without intent='wipe-and-rebuild' (§6.6)"
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
    /// 本地 planner RBAC 的行动者身份。
    ///
    /// 故意 **不看** `authExpired`：nil 在下游（`access(for:)` 等）的语义是
    /// 「纯本地模式 → owner 全权」，token 过期时返回 nil 会把 team 成员在
    /// 本地镜像画布上提权成 owner。过期窗口内保留最后已知身份反而是权限
    /// 最小的选择 —— 人没换，重新登录拿回的还是同一个 userId；身份只在
    /// 显式断开（disconnect 清空 settings.json）时清除。
    static func currentActorId() -> String? {
        let defaults = UserDefaults.standard
        let onlineSettings = OnlineProxy.loadSettings()
        let connected = defaults.bool(forKey: "meee2Connected")
            || (!onlineSettings.teamId.isEmpty && !onlineSettings.userId.isEmpty)
        guard connected else { return nil }
        let defaultsActorId = OnlineProxy.hasEnvironmentOverride ? "" : defaults.string(forKey: "meee2UserId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actorId = defaultsActorId.isEmpty ? onlineSettings.userId : defaultsActorId
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

    /// State-machine PR-A · Normalize deprecated planner contract surfaces
    /// before validation. Translates deprecated `PlanningNodeStatus` raw
    /// values (`working`, `draft`) on `addNode` / `updateNode` changes to
    /// `.ready` and appends a `deprecated_status_used` warning to
    /// `proposal.warnings`. The warning carries enough context for the caller
    /// to surface it as an `X-Planner-Contract-Warning` header or log entry
    /// without breaking the agent (no throw — the agent's intent is preserved
    /// by mapping to the new lifecycle).
    ///
    /// Translations:
    ///  - `working` → `ready` (state-machine PR-A; use NodeAttempt for
    ///                          in-flight state)
    ///  - `draft`   → `ready` (3-tai cut 2026-05-29; ready is the initial
    ///                          state — `draft` no longer exists in the
    ///                          public enum)
    ///
    /// Returns the list of warnings appended in this call so the validator
    /// can fold them into the proposal record.
    @discardableResult
    static func normalizeDeprecatedStatuses(_ proposal: inout PlanProposal) -> [String] {
        var warnings: [String] = []
        // Raw value → (replacement, human-readable rationale).
        let legacyMap: [String: (replacement: PlanningNodeStatus, rationale: String)] = [
            "working": (.ready, "use NodeAttempt for in-flight state"),
            "draft": (.ready, "ready is the initial state; draft removed in 3-tai cut")
        ]
        for i in proposal.changes.indices {
            let change = proposal.changes[i]
            guard change.kind == .addNode || change.kind == .updateNode else { continue }
            // updateNode: status lives directly on the change
            if let status = change.status, let mapping = legacyMap[status.rawValue] {
                proposal.changes[i].status = mapping.replacement
                let id = change.nodeId ?? change.node?.id ?? "<unknown>"
                warnings.append(
                    "deprecated_status_used: change for node \(id) set status='\(status.rawValue)'; auto-translated to '\(mapping.replacement.rawValue)' (\(mapping.rationale))"
                )
            }
            // addNode: status lives on the embedded PlanningNode
            if change.kind == .addNode,
               let node = change.node,
               let mapping = legacyMap[node.status.rawValue] {
                proposal.changes[i].node?.status = mapping.replacement
                warnings.append(
                    "deprecated_status_used: addNode for node \(node.id) used status='\(node.status.rawValue)'; auto-translated to '\(mapping.replacement.rawValue)' (\(mapping.rationale))"
                )
            }
        }
        if !warnings.isEmpty {
            var existing = proposal.warnings ?? []
            existing.append(contentsOf: warnings)
            proposal.warnings = existing
        }
        return warnings
    }

    /// State-machine PR-A · Back-compat overload. Existing tests and callers
    /// that hold an immutable `PlanProposal` keep working: we copy into a
    /// local mutable, run the inout validator (which may translate deprecated
    /// statuses), and discard the warnings. New code paths that want to
    /// surface or persist warnings should call the `inout` overload directly.
    static func validate(
        _ proposal: PlanProposal,
        canvas: PlanningCanvas,
        nodes: [PlanningNode]
    ) throws {
        var copy = proposal
        try validate(&copy, canvas: canvas, nodes: nodes)
    }

    static func validate(
        _ proposal: inout PlanProposal,
        canvas: PlanningCanvas,
        nodes: [PlanningNode]
    ) throws {
        // State-machine PR-A · Normalize deprecated status values before any
        // structural checks. The translation is idempotent and additive — it
        // never widens what the proposal can do, only narrows `working` to
        // the canonical `ready` and records a warning.
        _ = normalizeDeprecatedStatuses(&proposal)
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
                // Canvas Render Protocol: non-work visual identities are
                // Canvas Objects, not newly-created PlanningNode kinds.
                if let nodeKind = node.nodeKind, nodeKind != .step {
                    throw PlannerCoreError.sessionKindNoLongerCreatable(nodeId: node.id)
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
                // Existing legacy non-work node kinds still decode, but new
                // conversions to them are blocked. Render identity now comes
                // from Canvas Object entity refs.
                if let nextKind = change.nodeKind, nextKind != .step {
                    let target = nodes.first(where: { $0.id == nodeId })
                    if target?.nodeKind != nextKind {
                        throw PlannerCoreError.sessionKindNoLongerCreatable(nodeId: nodeId)
                    }
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
                    change.doerId != nil ||
                    // Team-ready (#5 / chunk B) — proposal-driven update path:
                    change.reviewerIds != nil ||
                    change.approverIds != nil ||
                    change.handoffPolicy != nil ||
                    // Node-widget (P2 / 2026-05-28) — view config update:
                    change.widget != nil ||
                    // Artifact-node data-source mode (2026-05-28) — accepts
                    // dataSource via the direct change field OR nested under
                    // an inline artifact draft (e.g. setArtifactDataSource
                    // riding shotgun on an attach).
                    change.artifactDataSource != nil ||
                    change.artifactSource != nil ||
                    change.artifact?.dataSource != nil else {
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

            // MARK: Canvas runtime 5-atom governance variants (PR6+7).
            // Structural validation; canvas-level state mutation happens in
            // `PlannerStore.applyCanvasAtomChanges` after node changes apply.
            case .removeNode:
                guard let nodeId = change.nodeId else { throw PlannerCoreError.missingNodeId }
                guard existingNodeIds.contains(nodeId) else {
                    throw PlannerCoreError.nodeNotFound(nodeId)
                }
            case .addDataSource:
                guard let ds = change.dataSourceRecord else {
                    throw PlannerCoreError.invalidNodeOutput("addDataSource is missing source")
                }
                guard ds.canvasId == canvas.id else {
                    throw PlannerCoreError.canvasMismatch(expected: canvas.id, actual: ds.canvasId)
                }
                guard !ds.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("addDataSource requires a non-empty source id")
                }
            case .updateDataSource, .setPartitionRule, .archiveDataSource, .writeSourceVersion:
                guard let sourceId = change.sourceId,
                      !sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("\(change.kind.rawValue) requires a sourceId")
                }
                guard canvas.dataSources.contains(where: { $0.id == sourceId }) else {
                    throw PlannerCoreError.dataSourceNotFound(sourceId)
                }
                if change.kind == .archiveDataSource {
                    // §10.4 cascade: reject-if-referenced unless detach-edges.
                    let cascade = change.cascade ?? "reject-if-referenced"
                    if cascade == "reject-if-referenced",
                       canvas.edges.contains(where: { _ in false }) == false {
                        // Edge→source linkage is by node slot, not source id, in
                        // the current Edge shape; a stricter cascade check lands
                        // when source-backed edges are modeled. No-op for now.
                    }
                }
            case .addEdge:
                guard let edge = change.edge else {
                    throw PlannerCoreError.invalidNodeOutput("addEdge is missing edge")
                }
                guard edge.canvasId == canvas.id else {
                    throw PlannerCoreError.canvasMismatch(expected: canvas.id, actual: edge.canvasId)
                }
                guard canvasNodeIds.contains(edge.sourceRef.nodeId),
                      canvasNodeIds.contains(edge.targetRef.nodeId) else {
                    throw PlannerCoreError.invalidNodeOutput("addEdge references a node outside canvas \(canvas.id)")
                }
            case .updateEdgeMode, .removeEdge:
                guard let edgeId = change.edgeId,
                      !edgeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("\(change.kind.rawValue) requires an edgeId")
                }
                guard canvas.edges.contains(where: { $0.id == edgeId }) else {
                    throw PlannerCoreError.edgeNotFound(edgeId)
                }
            case .setMonitorSpec:
                guard let spec = change.spec else {
                    throw PlannerCoreError.invalidNodeOutput("setMonitorSpec is missing spec")
                }
                // §6.6 footgun guard: replacing a non-null prior spec wholesale
                // requires an explicit wipe-and-rebuild intent.
                if let existing = canvas.monitorSpec, !existing.cards.isEmpty,
                   change.intent != "wipe-and-rebuild" {
                    throw PlannerCoreError.monitorSpecReplaceGuard
                }
                _ = spec
            case .addMonitorCard:
                guard change.card != nil else {
                    throw PlannerCoreError.invalidNodeOutput("addMonitorCard is missing card")
                }
            case .updateMonitorCard, .removeMonitorCard, .moveMonitorCard:
                guard let cardId = change.cardId,
                      !cardId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("\(change.kind.rawValue) requires a cardId")
                }
                guard canvas.monitorSpec?.cards.contains(where: { $0.id == cardId }) == true else {
                    throw PlannerCoreError.monitorCardNotFound(cardId)
                }
            case .replaceRenderLogic:
                guard change.renderLogic != nil else {
                    throw PlannerCoreError.invalidNodeOutput("replaceRenderLogic requires renderLogic")
                }
            case .attachExternalArtifact:
                guard let nodeId = change.nodeId, canvasNodeIds.contains(nodeId) else {
                    throw PlannerCoreError.missingNodeId
                }
                guard let artifact = change.artifact, !artifact.reference.isEmpty else {
                    throw PlannerCoreError.invalidNodeOutput("attachExternalArtifact requires an artifact with a reference")
                }
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
                title: "Meee2 AI LLM Spike",
                schema: NodeSchema(
                    inputs: ["owner goal", "canvas context"],
                    outputs: ["initial Meee2 AI proposal"],
                    goal: "proposal created"
                ),
                contextSources: [
                    ContextSource(kind: .document, title: "Feature list", reference: "doc/meee2-feature-list-wjk-codex.md")
                ],
                executionMode: .human,
                executorType: .codex,
                doerId: "A",
                status: .ready,
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
                // Team-ready (#5 / chunk B) — proposal-driven update path.
                if let reviewerIds = change.reviewerIds {
                    updatedNodes[index].reviewerIds = reviewerIds
                }
                if let approverIds = change.approverIds {
                    updatedNodes[index].approverIds = approverIds
                }
                if let handoffPolicy = change.handoffPolicy {
                    updatedNodes[index].handoffPolicy = handoffPolicy
                }
                // Node-widget (P2 / 2026-05-28) — view config update.
                if let widget = change.widget {
                    updatedNodes[index].widget = widget
                }
                // Artifact-node data-source mode (2026-05-28). Direct field
                // takes precedence; nested artifact-draft.dataSource is the
                // fallback lane (e.g. dataSource riding on an attach).
                if let dataSource = change.artifactDataSource ?? change.artifact?.dataSource {
                    updatedNodes[index].artifactDataSource = dataSource
                }
                // Unified Artifact.source (2026-05-29). Explicit unified field
                // wins; else normalize the legacy two-mode string into the
                // unified source so the node carries one canonical origin.
                if let unified = change.artifactSource {
                    updatedNodes[index].artifactSource = unified
                } else if let legacy = change.artifactDataSource ?? change.artifact?.dataSource {
                    updatedNodes[index].artifactSource = ArtifactSource.fromLegacy(
                        mode: legacy,
                        nodeId: updatedNodes[index].id,
                        outputSlotKey: updatedNodes[index].schema.outputs.first,
                        mirroredSourceId: nil
                    )
                }
                if let status = change.status {
                    updatedNodes[index].status = status
                }
            case .attachArtifact:
                // Artifact-node data-source mode (2026-05-28). attachArtifact
                // doesn't mutate node schema otherwise, but if the proposal
                // carries a dataSource hint on the inline draft, propagate it
                // to the target PlanningNode.
                if let draft = change.artifact,
                   let dataSource = draft.dataSource,
                   let targetNodeId = draft.nodeId ?? change.nodeId,
                   let index = updatedNodes.firstIndex(where: { $0.id == targetNodeId }) {
                    updatedNodes[index].artifactDataSource = dataSource
                    // Keep the unified source in lock-step (§7.4 mapping).
                    updatedNodes[index].artifactSource = ArtifactSource.fromLegacy(
                        mode: dataSource,
                        nodeId: updatedNodes[index].id,
                        outputSlotKey: updatedNodes[index].schema.outputs.first,
                        mirroredSourceId: nil
                    )
                }
                continue
            case .refineSessionPrompt:
                // ENG-2 bonus: schema-level no-op at preview/apply time.
                // The directive is delivered to the bound session by the
                // BoardAPI handler (via the operator-channel inject path).
                continue

            // MARK: Canvas runtime 5-atom node-level apply (PR6+7).
            case .removeNode:
                guard let nodeId = change.nodeId else { throw PlannerCoreError.missingNodeId }
                guard let removeIndex = updatedNodes.firstIndex(where: { $0.id == nodeId }) else {
                    throw PlannerCoreError.nodeNotFound(nodeId)
                }
                updatedNodes.remove(at: removeIndex)
                // Detach legacy dependency references to the removed node so the
                // graph stays consistent (first-class Edge cleanup happens in
                // the canvas-level pass).
                for i in updatedNodes.indices {
                    if var deps = updatedNodes[i].dependsOnNodeIds, deps.contains(nodeId) {
                        deps.removeAll { $0 == nodeId }
                        updatedNodes[i].dependsOnNodeIds = deps
                    }
                }
            // DataSource / Edge / Monitor / SourceVersion / ExternalArtifact
            // are canvas-level; handled by `applyCanvasAtomChanges` after node
            // changes apply. No node mutation here.
            case .addDataSource, .updateDataSource, .setPartitionRule, .archiveDataSource,
                 .addEdge, .updateEdgeMode, .removeEdge,
                 .setMonitorSpec, .addMonitorCard, .updateMonitorCard, .removeMonitorCard, .moveMonitorCard,
                 .replaceRenderLogic,
                 .writeSourceVersion, .attachExternalArtifact:
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
                updatedNodes[index].status = .ready
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
            status: .ready,
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
            // canvas-spec §8 / §11 ·「待确认」(awaiting-review) distinction.
            // A node parked at `gateWait` after a needs-review `done` shares
            // the `.blocked` plan-status with「卡住」(failure / unassigned),
            // so the display layer needs a separate signal to render it as
            // 待确认 rather than 卡住. `needsOwnerReview = true` is that signal.
            // It is set iff the node is at `gateWait` AND has an assigned doer
            // — an UNassigned downstream is also parked at gateWait but it is
            // "needs assignment / attention", not "review my completed output",
            // so it must NOT light up the review surface.
            let hasDoer = !node.doerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let awaitingReview = node.workflowRunState == .gateWait && hasDoer
            return NodeStateSnapshot(
                nodeId: node.id,
                runState: runState,
                blockers: blockers(for: node),
                artifactRefs: artifactRefs(for: node),
                needsOwnerReview: awaitingReview
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

    /// kanban item 下钻 subcanvas 时派生其列(读时,不落库)。给定子画板 nodes +
    /// proposals → readNodeState → summarizeSubCanvas worst-case → spec §6 列。
    /// decision #1 派生不落库 / #7(b) 复用 summarizeSubCanvas 同源派生(slice 1 先落
    /// subcanvas 源;下游消费 / 单节点源为后续切片)。
    func deriveKanbanColumn(
        subCanvasId: String,
        subCanvasNodes: [PlanningNode],
        subCanvasProposals: [PlanProposal]
    ) -> KanbanDerivedColumn {
        let states = readNodeState(nodes: subCanvasNodes)
        let summary = summarizeSubCanvas(
            subCanvasId: subCanvasId,
            states: states,
            proposals: subCanvasProposals
        )
        return KanbanDerivedColumn.from(subCanvasRunState: summary.runState)
    }

    /// slice 2: 读时把 kanban item 的派生列(下钻 subcanvas 源)注入 payload —— 不落库,
    /// 每次构建 graphState 现算。item 有 subCanvasId 且子画板可达 → 注入
    /// `derivedColumnId`(§6 列);否则不动(前端退回手动 columnId)。
    func injectDerivedKanbanColumns(
        into artifact: PlannerArtifact,
        resolveChild: (String) -> (nodes: [PlanningNode], proposals: [PlanProposal])?,
        resolveConsumption: (String, String) -> DataSourceItemState? = { _, _ in nil }
    ) -> PlannerArtifact {
        guard artifact.kind == .kanban,
              case .object(var object)? = artifact.payload,
              case .array(let rawItems)? = object["items"] else {
            return artifact
        }
        var changed = false
        let items = rawItems.map { value -> BoardJSONValue in
            guard case .object(var item) = value else { return value }
            // 多态状态源派生(spec §4):①下钻 subcanvas ②订阅下游消费(queue-claim)。
            var derived: KanbanDerivedColumn?
            if case .string(let sub)? = item["subCanvasId"],
               !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let child = resolveChild(sub) {
                derived = deriveKanbanColumn(
                    subCanvasId: sub,
                    subCanvasNodes: child.nodes,
                    subCanvasProposals: child.proposals
                )
            } else if case .string(let sid)? = item["consumptionSourceId"],
                      case .string(let iid)? = item["consumptionItemId"],
                      !sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !iid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let state = resolveConsumption(sid, iid) {
                derived = KanbanDerivedColumn.from(consumptionState: state)
            }
            guard let col = derived else { return value }
            item["derivedColumnId"] = .string(col.rawValue)
            changed = true
            return .object(item)
        }
        guard changed else { return artifact }
        object["items"] = .array(items)
        var updated = artifact
        updated.payload = .object(object)
        return updated
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
            return .ready
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

    struct CanvasParentRef {
        let parentCanvasId: String
        let parentNodeId: String?
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

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(canvas, forKey: .canvas)
            try container.encode(nodes, forKey: .nodes)
            try container.encode(proposals, forKey: .proposals)
            try container.encode(artifacts, forKey: .artifacts)
            try container.encode(artifactVersions, forKey: .artifactVersions)
            try container.encode(runs, forKey: .runs)
            try container.encodeIfPresent(activeRunId, forKey: .activeRunId)
            try container.encode(nodeVersions, forKey: .nodeVersions)
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
    private let eventEncoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()
    private var document: StoreDocument
    private var unreadableCanvasPathComponents: Set<String>
    private var lastValidRenderProfiles: [String: CanvasRenderProfile]
    private var renderProfileWatchers: [String: DispatchSourceFileSystemObject]
    private var eventLogSignatures: [String: EventLogSignature]

    private struct EventLogSignature: Equatable {
        var count: Int
        var lastId: String?
        var lastCreatedAt: Date?
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.rootURL = fileURL.pathExtension == "json"
            ? fileURL.deletingPathExtension()
            : fileURL
        self.fileManager = fileManager
        self.encoder = Self.makeStateEncoder()
        self.eventEncoder = Self.makeEventEncoder()
        let loaded = Self.loadDocument(
            rootURL: rootURL,
            fileManager: fileManager,
            stateEncoder: encoder,
            eventEncoder: eventEncoder,
            decoder: decoder
        )
        self.document = loaded.document
        self.unreadableCanvasPathComponents = loaded.unreadableCanvasPathComponents
        self.lastValidRenderProfiles = [:]
        self.renderProfileWatchers = [:]
        self.eventLogSignatures = loaded.document.canvases.mapValues { Self.eventLogSignature(for: $0.events) }
    }

    func canvasParentRefs() -> [String: CanvasParentRef] {
        withLock {
            var refs: [String: CanvasParentRef] = [:]
            let records = document.canvases.values.sorted { $0.canvas.id < $1.canvas.id }

            for record in records {
                guard let parentCanvasId = Self.normalizedCanvasId(record.canvas.parentCanvasId) else { continue }
                refs[record.canvas.id] = CanvasParentRef(
                    parentCanvasId: parentCanvasId,
                    parentNodeId: Self.normalizedCanvasId(record.canvas.parentNodeId)
                )
            }

            for record in records {
                let parentCanvasId = record.canvas.id
                for node in record.nodes.sorted(by: { $0.id < $1.id }) {
                    guard let subCanvasId = Self.normalizedCanvasId(node.subCanvasId),
                          refs[subCanvasId] == nil else { continue }
                    refs[subCanvasId] = CanvasParentRef(parentCanvasId: parentCanvasId, parentNodeId: node.id)
                }
                for artifact in record.artifacts.sorted(by: { $0.id < $1.id }) {
                    for subCanvasId in Self.subCanvasIds(in: artifact.payload) where refs[subCanvasId] == nil {
                        refs[subCanvasId] = CanvasParentRef(parentCanvasId: parentCanvasId, parentNodeId: artifact.nodeId)
                    }
                }
            }

            return refs
        }
    }

    func record(
        for canvas: PlanningCanvas,
        seedNodes: [PlanningNode]
    ) throws -> CanvasRecord {
        try withLock {
            if let existing = document.canvases[canvas.id] {
                var incoming = canvas
                // PR6+7: the 5-atom governance collections (dataSources / edges
                // / monitorSpec) are store-owned too — the per-request board
                // snapshot projection doesn't carry them, so a plain read would
                // otherwise wipe applied governance state. Preserve them.
                incoming.visibility = existing.canvas.visibility
                incoming.parentCanvasId = existing.canvas.parentCanvasId
                incoming.parentNodeId = existing.canvas.parentNodeId
                incoming.frozenIOContract = existing.canvas.frozenIOContract
                incoming.dataSources = existing.canvas.dataSources
                incoming.edges = existing.canvas.edges
                incoming.monitorSpec = existing.canvas.monitorSpec
                incoming.sceneSpec = incoming.sceneSpec ?? existing.canvas.sceneSpec
                if existing.canvas == incoming {
                    return existing
                }
                var updated = existing
                updated.canvas = incoming
                document.canvases[canvas.id] = updated
                try save(canvasId: canvas.id)
                return updated
            }
            let pathComponent = Self.safePathComponent(canvas.id)
            if unreadableCanvasPathComponents.contains(pathComponent) {
                MError("[PlannerStore] refusing to overwrite unreadable planner state for \(canvas.id)")
                throw PlannerCoreError.plannerStateUnreadable(canvas.id)
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
            // Seed nodes may declare `dependsOnNodeIds` (e.g. orchestration
            // templates). Run the same edge↔dependency reconciliation the rest
            // of the engine uses so those dependencies are persisted/rendered as
            // dependency EDGES on the applied canvas — without this, a template's
            // declared flow would have node-level deps but no edges on the graph.
            reconcileEdgesAndDependencies(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    func cloneReusableTemplateContent(
        from sourceCanvasId: String,
        to targetCanvas: PlanningCanvas
    ) throws -> CanvasRecord {
        try withLock {
            let source = try requireRecord(canvasId: sourceCanvasId)
            let record = sanitizedReusableRecord(from: source, targetCanvas: targetCanvas)
            document.canvases[targetCanvas.id] = record
            try save(canvasId: targetCanvas.id)
            try copyRenderProfile(from: sourceCanvasId, to: targetCanvas.id)
            return record
        }
    }

    func replaceReusableTemplateContent(
        templateCanvasId: String,
        from sourceCanvasId: String,
        targetCanvas: PlanningCanvas
    ) throws -> CanvasRecord {
        try withLock {
            let source = try requireRecord(canvasId: sourceCanvasId)
            let record = sanitizedReusableRecord(from: source, targetCanvas: targetCanvas)
            document.canvases[templateCanvasId] = record
            try save(canvasId: templateCanvasId)
            try copyRenderProfile(from: sourceCanvasId, to: templateCanvasId)
            return record
        }
    }

    func reusableNodeCount(canvasId: String) -> Int {
        withLock {
            (try? requireRecord(canvasId: canvasId).nodes.count) ?? 0
        }
    }

    func reusableSceneSpec(canvasId: String) -> CanvasSceneSpec? {
        withLock {
            (try? requireRecord(canvasId: canvasId).canvas.sceneSpec)
        }
    }

    private func sanitizedReusableRecord(
        from source: CanvasRecord,
        targetCanvas: PlanningCanvas
    ) -> CanvasRecord {
        let targetCanvasId = targetCanvas.id
        var canvas = targetCanvas
        canvas.visibility = source.canvas.visibility
        canvas.dataSources = source.canvas.dataSources.map { dataSource in
            var next = dataSource
            next.canvasId = targetCanvasId
            return next
        }
        canvas.edges = source.canvas.edges.map { edge in
            var next = edge
            next.canvasId = targetCanvasId
            return next
        }
        if var monitorSpec = source.canvas.monitorSpec {
            monitorSpec.canvasId = targetCanvasId
            canvas.monitorSpec = monitorSpec
        }
        canvas.sceneSpec = source.canvas.sceneSpec

        let nodes = source.nodes.map { node -> PlanningNode in
            var next = node
            next.canvasId = targetCanvasId
            next.sessionId = nil
            next.chatThreadId = nil
            next.source = .planner
            next.workflowRunState = nil
            next.blockedReason = nil
            next.outputSubmittedAt = nil
            next.eventRefs = nil
            return next
        }

        return CanvasRecord(
            canvas: canvas,
            nodes: nodes,
            proposals: [],
            events: [],
            artifacts: [],
            artifactVersions: [],
            runs: [],
            activeRunId: nil,
            nodeVersions: []
        )
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
            // State-machine PR-A · validate takes inout to fold deprecated
            // status warnings into proposal.warnings before persisting.
            var normalized = proposal
            try PlannerProposalValidator.validate(
                &normalized,
                canvas: canvas,
                nodes: validationNodes ?? record.nodes
            )
            if let index = record.proposals.firstIndex(where: { $0.id == normalized.id }) {
                record.proposals[index] = normalized
            } else {
                record.proposals.append(normalized)
                record.events.append(event(
                    canvasId: canvas.id,
                    type: .proposalCreated,
                    proposalId: normalized.id,
                    summary: normalized.summary
                ))
            }
            document.canvases[canvas.id] = record
            try save(canvasId: canvas.id)
            return normalized
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

    /// Canvas runtime 5-atom governance apply (PR6+7). Mutates `record.canvas`
    /// (dataSources / edges / monitorSpec) and `record.artifactVersions`
    /// (writeSourceVersion) for the governance PlanChange variants. Node-level
    /// variants (removeNode / skill bindings) are applied by `applyNodeChange`
    /// upstream; this pass also reconciles first-class edges against the
    /// post-removal node set so a removeNode drops its dangling edges.
    ///
    /// Caller must hold the store lock (invoked inside `withLock`).
    private func applyCanvasAtomChanges(
        record: inout CanvasRecord,
        proposal: PlanProposal
    ) throws {
        let canvasId = record.canvas.id
        for change in proposal.changes {
            switch change.kind {
            // MARK: Atom 1 · DataSource
            case .addDataSource:
                guard let ds = change.dataSourceRecord else { continue }
                if let idx = record.canvas.dataSources.firstIndex(where: { $0.id == ds.id }) {
                    record.canvas.dataSources[idx] = ds   // idempotent re-apply
                } else {
                    record.canvas.dataSources.append(ds)
                }
            case .updateDataSource:
                guard let sourceId = change.sourceId,
                      let idx = record.canvas.dataSources.firstIndex(where: { $0.id == sourceId })
                else { continue }
                applyDataSourcePatch(&record.canvas.dataSources[idx], patch: change.dataSourcePatch)
            case .setPartitionRule:
                guard let sourceId = change.sourceId,
                      let idx = record.canvas.dataSources.firstIndex(where: { $0.id == sourceId })
                else { continue }
                if let rule = change.partitionRule { record.canvas.dataSources[idx].partitionRule = rule }
                if let tz = change.partitionTimezone { record.canvas.dataSources[idx].partitionTimezone = tz }
            case .archiveDataSource:
                guard let sourceId = change.sourceId,
                      let idx = record.canvas.dataSources.firstIndex(where: { $0.id == sourceId })
                else { continue }
                // §10.4: mark archived (no physical delete). With cascade
                // 'detach-edges', drop edges that name the source's id in a ref
                // (current Edge shape keys by node slot, not source id, so this
                // is a no-op until source-backed edges land — left as TODO).
                record.canvas.dataSources[idx].archived = true

            // MARK: Atom 2 · Edge
            case .addEdge:
                guard let edge = change.edge else { continue }
                if let idx = record.canvas.edges.firstIndex(where: { $0.id == edge.id }) {
                    record.canvas.edges[idx] = edge
                } else {
                    record.canvas.edges.append(edge)
                }
            case .updateEdgeMode:
                guard let edgeId = change.edgeId,
                      let mode = change.edgeMode,
                      let idx = record.canvas.edges.firstIndex(where: { $0.id == edgeId })
                else { continue }
                record.canvas.edges[idx].edgeMode = mode
                record.canvas.edges[idx].modeRevision += 1
            case .removeEdge:
                guard let edgeId = change.edgeId else { continue }
                // edges-authoritative: clear the projected dependency on the
                // target before dropping the edge, so reconcileEdgesAndDependencies
                // (below) does not re-promote it from a stale dependsOnNodeIds.
                if let removed = record.canvas.edges.first(where: { $0.id == edgeId }),
                   let i = record.nodes.firstIndex(where: { $0.id == removed.targetRef.nodeId }) {
                    record.nodes[i].dependsOnNodeIds?.removeAll { $0 == removed.sourceRef.nodeId }
                }
                record.canvas.edges.removeAll { $0.id == edgeId }

            // MARK: Atom 4 · Monitor
            case .setMonitorSpec:
                guard var spec = change.spec else { continue }
                if spec.canvasId.isEmpty { spec.canvasId = canvasId }
                spec.appliedFromProposalId = proposal.id
                record.canvas.monitorSpec = spec
            case .addMonitorCard:
                guard let card = change.card else { continue }
                if record.canvas.monitorSpec == nil {
                    record.canvas.monitorSpec = MonitorSpec(canvasId: canvasId)
                }
                if let i = record.canvas.monitorSpec?.cards.firstIndex(where: { $0.id == card.id }) {
                    record.canvas.monitorSpec?.cards[i] = card
                } else {
                    record.canvas.monitorSpec?.cards.append(card)
                }
                record.canvas.monitorSpec?.version += 1
            case .updateMonitorCard:
                guard let cardId = change.cardId,
                      let i = record.canvas.monitorSpec?.cards.firstIndex(where: { $0.id == cardId })
                else { continue }
                applyMonitorCardPatch(&record.canvas.monitorSpec!.cards[i], patch: change.cardPatch)
                record.canvas.monitorSpec?.version += 1
            case .removeMonitorCard:
                guard let cardId = change.cardId else { continue }
                record.canvas.monitorSpec?.cards.removeAll { $0.id == cardId }
                record.canvas.monitorSpec?.version += 1
            case .moveMonitorCard:
                guard let cardId = change.cardId,
                      let layout = change.cardLayout,
                      let i = record.canvas.monitorSpec?.cards.firstIndex(where: { $0.id == cardId })
                else { continue }
                record.canvas.monitorSpec?.cards[i].layout = layout
                record.canvas.monitorSpec?.version += 1

            case .replaceRenderLogic:
                guard let logic = change.renderLogic else { continue }
                _ = try replaceRenderLogic(canvasId: canvasId, logic: logic)

            // MARK: artifact write (split from legacy attachArtifact)
            case .writeSourceVersion:
                guard let sourceId = change.sourceId else { continue }
                let slotKey = "\(canvasId)|source|\(sourceId)|\(change.slotKey ?? "default")"
                let parent = change.parentVersionId
                    ?? latestVersion(in: record.artifactVersions, slotKey: slotKey)?.versionId
                let submitterKind = PlannerArtifactVersionSubmitterKind(rawValue: change.submittedByKind ?? "agent") ?? .agent
                let createdAt = Date()
                record.artifactVersions.append(PlannerArtifactVersion(
                    versionId: "ver-\(sourceId)-\(stableSuffix("\(slotKey)-\(createdAt.timeIntervalSince1970)"))",
                    parentVersionId: parent,
                    canvasId: canvasId,
                    nodeId: "",
                    artifactId: "source-\(sourceId)",
                    artifactSlotKey: slotKey,
                    payloadRef: change.payloadRef ?? "",
                    payloadInline: change.payload,
                    inputSnapshot: nil,
                    displayStrategy: .latest,
                    forceNewVersion: false,
                    submittedBy: change.submittedBy,
                    submittedByKind: submitterKind,
                    metadata: .object([
                        "source": .string("writeSourceVersion"),
                        "sourceId": .string(sourceId)
                    ]),
                    createdAt: createdAt
                ))
                // Advance the source's currentVersion counter (sequence strategy).
                if let idx = record.canvas.dataSources.firstIndex(where: { $0.id == sourceId }) {
                    record.canvas.dataSources[idx].currentVersion += 1
                }
            case .attachExternalArtifact:
                // External artifact attach: mirror onto the target node's
                // artifactRefs so it surfaces in the graph. Payload is a
                // reference only (lazy pull-on-consume), no version row.
                guard let nodeId = change.nodeId,
                      let draft = change.artifact,
                      let idx = record.nodes.firstIndex(where: { $0.id == nodeId })
                else { continue }
                var refs = record.nodes[idx].artifactRefs ?? []
                if !refs.contains(draft.reference) { refs.append(draft.reference) }
                record.nodes[idx].artifactRefs = refs

            default:
                continue   // node-level variants handled in applyNodeChange.
            }
        }

        reconcileEdgesAndDependencies(&record)
    }

    /// Phase 1 — edge unification. `canvas.edges` is the authoritative
    /// representation of node connectivity; the legacy `node.dependsOnNodeIds`
    /// is kept as a *derived projection* so the ~60 existing consumers
    /// (dataflow legality, graph render, downstream computation) keep working
    /// unchanged. Bidirectional + idempotent:
    ///   a) drop dead-endpoint edges + derived `dep-` edges no longer backed
    ///      by a declared dependency,
    ///   b) promote any node-declared dependency lacking a backing edge into a
    ///      synthetic `mode:"dependency"` edge,
    ///   c) re-project every node's `dependsOnNodeIds` from the live edge set
    ///      (edges win — a dependency exists iff an edge encodes it).
    /// Net effect: add an edge ⇒ the dep appears; remove an edge ⇒ the dep
    /// disappears; declare a dep ⇒ a dependency edge appears. No field dropped.
    private func reconcileEdgesAndDependencies(_ record: inout CanvasRecord) {
        let liveNodeIds = Set(record.nodes.map(\.id))

        // a) drop edges whose endpoints are gone, and derived dependency edges
        //    whose backing dependency was removed (updateNode / removeEdge).
        record.canvas.edges.removeAll { edge in
            if !liveNodeIds.contains(edge.sourceRef.nodeId)
                || !liveNodeIds.contains(edge.targetRef.nodeId) {
                return true
            }
            if edge.edgeMode.mode == "dependency" {
                let backed = record.nodes
                    .first { $0.id == edge.targetRef.nodeId }?
                    .dependsOnNodeIds?.contains(edge.sourceRef.nodeId) ?? false
                return !backed
            }
            return false
        }

        // b) promote node-declared dependencies that lack ANY backing edge.
        for node in record.nodes {
            for dep in (node.dependsOnNodeIds ?? []) where liveNodeIds.contains(dep) && dep != node.id {
                let hasEdge = record.canvas.edges.contains {
                    $0.sourceRef.nodeId == dep && $0.targetRef.nodeId == node.id
                }
                if !hasEdge {
                    record.canvas.edges.append(Edge(
                        id: "dep-\(dep)-\(node.id)",
                        canvasId: record.canvas.id,
                        sourceRef: EdgeSourceRef(nodeId: dep, sourceKey: "out"),
                        targetRef: EdgeTargetRef(nodeId: node.id, inputKey: "in"),
                        edgeMode: EdgeMode(mode: "dependency")
                    ))
                }
            }
        }

        // c) project dependsOnNodeIds from the edge set (edges authoritative).
        for i in record.nodes.indices {
            let nodeId = record.nodes[i].id
            let derived = record.canvas.edges
                .filter { $0.targetRef.nodeId == nodeId && $0.sourceRef.nodeId != nodeId }
                .map(\.sourceRef.nodeId)
            let unique = Array(Set(derived)).sorted()
            // Preserve nil when there are genuinely no dependencies, to keep the
            // on-wire shape byte-identical for dependency-free nodes.
            record.nodes[i].dependsOnNodeIds = unique.isEmpty
                ? (record.nodes[i].dependsOnNodeIds == nil ? nil : [])
                : unique
        }
    }

    /// Apply an `updateDataSource` patch (§9.3) onto a record. Opaque JSON
    /// patch; well-known fields applied, unknown keys ignored (forward-compat).
    private func applyDataSourcePatch(_ ds: inout DataSourceRecord, patch: BoardJSONValue?) {
        guard let fields = patch?.objectValue else { return }
        if let v = fields["partitionRule"]?.stringValue { ds.partitionRule = v }
        if let v = fields["partitionTimezone"]?.stringValue { ds.partitionTimezone = v }
        // Structured sub-objects: round-trip via JSON to replace wholesale. Keys
        // mirror the TS `PlanChangeUpdateDataSource.patch` pick (addendum:
        // `semantics`/`selector` 取代旧 `title`/`pathPattern`;`identity` rebind
        // 是独立治理动作,不在 patch 内)。
        func patchField<T: Decodable>(_ key: String, _ apply: (T) -> Void) {
            guard let raw = fields[key], let data = try? JSONEncoder().encode(raw),
                  let decoded = try? JSONDecoder().decode(T.self, from: data) else { return }
            apply(decoded)
        }
        patchField("semantics") { (v: Semantics) in ds.semantics = v }
        patchField("selector") { (v: Selector) in ds.selector = v }
        patchField("capabilities") { (v: DataSourceCapabilities) in ds.capabilities = v }
        patchField("versionStrategy") { (v: VersionStrategy) in ds.versionStrategy = v }
        patchField("freshness") { (v: FreshnessPolicy) in ds.freshness = v }
        patchField("binding") { (v: DataSourceIntegrationBinding) in ds.binding = v }
        // Legacy patch 兼容(codex P2):旧 client / 升级前持久化的 updateDataSource patch
        // 带 `title`/`pathPattern`;迁移后只认 semantics/selector,直接忽略会让这些旧
        // proposal approve 后无可见效果。翻译:title → semantics.label、pathPattern →
        // declarative selector(仅当对应新字段缺席,不覆盖显式的新 patch)。
        if fields["semantics"] == nil, let legacyTitle = fields["title"]?.stringValue {
            ds.semantics.label = legacyTitle
        }
        if fields["selector"] == nil, let legacyPath = fields["pathPattern"]?.stringValue {
            let dialect = ds.identity.connectorKind == "fs" ? "glob" : "path"
            ds.selector = Selector.declarative(dialect: dialect, expr: legacyPath)
        }
    }

    /// Apply an `updateMonitorCard` patch (§9.3) onto a card. Permissive JSON
    /// patch; the card `type` is immutable here.
    private func applyMonitorCardPatch(_ card: inout MonitorCard, patch: BoardJSONValue?) {
        guard let fields = patch?.objectValue else { return }
        if let v = fields["title"]?.stringValue { card.title = v }
        if let v = fields["attemptVisibility"]?.stringValue { card.attemptVisibility = v }
        if let raw = fields["layout"], let data = try? JSONEncoder().encode(raw),
           let d = try? JSONDecoder().decode(MonitorCardLayout.self, from: data) {
            card.layout = d
        }
        if let raw = fields["viewerFilter"], let data = try? JSONEncoder().encode(raw),
           let d = try? JSONDecoder().decode(MonitorViewerFilter.self, from: data) {
            card.viewerFilter = d
        }
        if let raw = fields["config"] { card.config = raw }
    }

    // MARK: - Apply 委托 sidecar(方向 A / Principle 13:apply 逻辑归 meee2-online)
    //
    // env-gated(MEEE2_PLANNER_RUNTIME_URL + MEEE2_APPLY_VIA_SIDECAR=1),默认关 →
    // 行为与改动前完全一致。开启时把「算结构」这步委托给 meee2-online 的
    // `/api/planner/runtime/apply`(纯函数:输入当前结构 + changes,输出新结构 or
    // violations)。持久化 / 事件 / artifacts / 锁仍在本地 —— sidecar 不碰这些。
    //
    // 委托范围(最小、无 ledger 副作用):add/update node + add/update/remove edge +
    // DataSource 的 add/update/setPartitionRule(addendum 后 Swift 已迁 identity/selector/
    // semantics 新形状,sidecar zod 放行)。删节点(级联清理 dependsOnNodeIds)、Monitor、
    // archiveDataSource(本地 archive-not-delete vs sidecar 物理 delete)、writeSourceVersion /
    // attach*(版本链 ledger 副作用,sidecar 不建模)仍走本地 fallback。

    private struct SidecarStateDTO: Codable {
        var canvasId: String
        var version: Int
        var nodes: [PlanningNode]
        var edges: [Edge]
        var sources: [DataSourceRecord]
        var cards: [MonitorCard]
    }
    private struct SidecarApplyRequest: Codable {
        var state: SidecarStateDTO
        var changes: [PlanChange]
    }
    private struct SidecarApplyResponse: Codable {
        var ok: Bool
        var state: SidecarStateDTO?
        var violations: [String]?
    }

    /// 可委托的 change kind(无本地 ledger 副作用 / 无级联清理)。DataSource 只放
    /// 结构安全的 3 个;archiveDataSource / writeSourceVersion 语义不一致,留本地(见上)。
    private static let sidecarDelegatableKinds: Set<PlanChange.Kind> = [
        .addNode, .updateNode, .addEdge, .updateEdgeMode, .removeEdge,
        .addDataSource, .updateDataSource, .setPartitionRule
    ]

    /// 双重 env gate;任一缺失 ⇒ nil ⇒ 完全走本地(默认行为不变)。
    private func sidecarApplyBaseURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let flag = (env["MEEE2_APPLY_VIA_SIDECAR"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard flag == "1" || flag == "true" else { return nil }
        guard let raw = env[HTTPPlannerAgentRuntime.runtimeUrlEnvVar]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return url
    }

    /// 委托结果 + 它所基于的 pre-apply snapshot —— 锁内据 snapshot 做乐观并发检查(P2)。
    private struct DelegatedApply {
        let resultNodes: [PlanningNode]
        let resultEdges: [Edge]
        let resultSources: [DataSourceRecord]
        let beforeNodes: [PlanningNode]
        let beforeEdges: [Edge]
        let beforeSources: [DataSourceRecord]
    }

    /// 锁外:判 gate + 短锁读 snapshot + POST sidecar。返回委托结果 + 其 snapshot(走委托),
    /// 或 nil(不适用 / 网络失败 → 本地 fallback),或 throw applyRejected(校验拒绝)。
    private func delegateApplyToSidecar(canvasId: String, proposalId: String) throws -> DelegatedApply? {
        guard let base = sidecarApplyBaseURL() else { return nil }
        // 短锁拿 snapshot 后立即释放(performSync 不能持主锁)。
        let snapshot: (
            request: SidecarApplyRequest,
            beforeNodes: [PlanningNode],
            beforeEdges: [Edge],
            beforeSources: [DataSourceRecord]
        )? = withLock {
            guard let record = document.canvases[canvasId],
                  let proposal = record.proposals.first(where: { $0.id == proposalId }),
                  proposal.status == .approved,  // P1:未 approved 绝不委托(本地 applyNodeChange 也只对 approved 生效)
                  !proposal.changes.isEmpty,
                  proposal.changes.allSatisfy({ Self.sidecarDelegatableKinds.contains($0.kind) }) else { return nil }
            // sources 委托后必须把真实 DataSource 带上(zod 放行新形状),否则 update/
            // setPartitionRule 在 sidecar 找不到目标源 → 静默 no-op。
            let req = SidecarApplyRequest(
                state: SidecarStateDTO(
                    canvasId: canvasId, version: 0,
                    nodes: record.nodes, edges: record.canvas.edges,
                    sources: record.canvas.dataSources, cards: []
                ),
                changes: proposal.changes
            )
            return (req, record.nodes, record.canvas.edges, record.canvas.dataSources)
        }
        guard let snapshot, let body = try? JSONEncoder().encode(snapshot.request) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("api/planner/runtime/apply"), timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, status) = Self.sidecarPostSync(req)
        guard let data, let resp = try? JSONDecoder().decode(SidecarApplyResponse.self, from: data) else {
            return nil // 网络 / 解码失败 → 本地 fallback(不破坏 apply)
        }
        if status == 422 || resp.ok == false {
            throw PlannerCoreError.applyRejected(resp.violations ?? ["sidecar rejected without detail"])
        }
        guard let st = resp.state else { return nil }
        return DelegatedApply(
            resultNodes: st.nodes, resultEdges: st.edges, resultSources: st.sources,
            beforeNodes: snapshot.beforeNodes, beforeEdges: snapshot.beforeEdges,
            beforeSources: snapshot.beforeSources
        )
    }

    private static func sidecarPostSync(_ request: URLRequest) -> (Data?, Int) {
        var out: (Data?, Int) = (nil, 0)
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sema.signal() }
            out = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
        _ = sema.wait(timeout: .now() + 13)
        return out
    }

    func applyProposal(
        proposalId: String,
        canvasId: String,
        service: PlannerCoreService
    ) throws -> CanvasRecord {
        // 方向 A:先在锁外把「算结构」委托给 sidecar(env-gated;不适用/失败→nil 走本地;
        // 校验拒绝→throw)。HTTP 不能持主锁,故 snapshot 读 + POST 都在 withLock 之外。
        let delegated = try delegateApplyToSidecar(canvasId: canvasId, proposalId: proposalId)
        return try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
                throw PlannerCoreError.proposalNotFound(proposalId)
            }
            var proposal = record.proposals[index]
            // State-machine PR-A · normalize-on-apply too, in case the stored
            // proposal predates the normalizer (defense-in-depth; the
            // saveProposal path already normalizes).
            try PlannerProposalValidator.validate(&proposal, canvas: record.canvas, nodes: record.nodes)
            record.proposals[index] = proposal
            // P1(codex):委托路绕过了 applyNodeChange 的 approved 门(validate 只查结构);
            // 在此统一 enforce,委托 / 本地两条路都不放过未 approved 的 proposal。
            guard proposal.status == .approved else {
                throw PlannerCoreError.proposalNotApproved
            }
            // P2(codex):委托结果是锁外基于 pre-apply snapshot 算的。只有当 record 自 snapshot
            // 后未被并发 apply 改动(nodes/edges 仍一致)才采用;否则回落本地 apply 重算 ——
            // 避免两个并发 apply 各用各的 stale snapshot 互相覆盖。
            if let delegated,
               delegated.beforeNodes == record.nodes,
               delegated.beforeEdges == record.canvas.edges,
               delegated.beforeSources == record.canvas.dataSources {
                // 方向 A:用 sidecar 算好的结构(node/edge/DataSource),本地只补节点事件 + reconcile。
                // 持久化 / artifacts / status / proposalApplied 事件仍走下方公共后处理。
                let before = record.nodes
                record.nodes = delegated.resultNodes
                record.events.append(contentsOf: events(for: proposal, before: before, after: delegated.resultNodes))
                record.canvas.edges = delegated.resultEdges
                // `archived` 是 Swift-local flag,sidecar 不建模(apply 时被 zod strip)。
                // 按 id 从 pre-apply 快照重挂,避免委托 round-trip 把归档源「复活」。
                let archivedIds = Set(delegated.beforeSources.filter { $0.archived }.map(\.id))
                record.canvas.dataSources = delegated.resultSources.map { source in
                    guard archivedIds.contains(source.id) else { return source }
                    var restored = source
                    restored.archived = true
                    return restored
                }
                reconcileEdgesAndDependencies(&record)
            } else {
                let nodes = try service.applyNodeChange(nodes: record.nodes, proposal: proposal)
                record.events.append(contentsOf: events(for: proposal, before: record.nodes, after: nodes))
                record.nodes = nodes
                // Canvas runtime 5-atom governance (PR6+7): apply DataSource / Edge
                // / Monitor / writeSourceVersion / external-artifact changes onto
                // the canvas + version chain. Node-level changes (removeNode, skill
                // bindings) already applied above in `applyNodeChange`; this pass
                // reconciles first-class edges against the post-removal node set.
                try applyCanvasAtomChanges(record: &record, proposal: proposal)
            }
            record.proposals[index].status = .applied
            // 两个分支(委托 / fallback)都已写好 record.nodes;下方版本链 / artifacts 统一读它。
            let nodes = record.nodes
            let newArtifactsFromProposal = proposalArtifacts(from: proposal, nodes: nodes, canvasId: canvasId)
            record.artifacts = mergeArtifacts(
                record.artifacts,
                newArtifactsFromProposal + derivedArtifacts(from: nodes, canvasId: canvasId)
            )
            // 2026-05-29 codex P2 (PR #92): attachArtifact-only proposals were
            // folding into mergeArtifacts (replaces latest-per-slot mirror) but
            // never appending to artifactVersions, so repeat authored saves on
            // the same reference silently overwrote prior content. Mirror the
            // submit_node_output path: append a PlannerArtifactVersion row per
            // proposal-created artifact so the visible version chain preserves
            // history (same shape as line 4338-4358 in submit_node_output).
            for artifact in newArtifactsFromProposal {
                let slotKey = artifactSlotKey(
                    canvasId: artifact.canvasId,
                    nodeId: artifact.nodeId,
                    reference: artifact.reference
                )
                let parent = latestVersion(in: record.artifactVersions, slotKey: slotKey)?.versionId
                let payloadRef = (artifact.payload?.objectValue?["blobRef"]?.stringValue).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? artifact.reference
                record.artifactVersions.append(PlannerArtifactVersion(
                    versionId: "ver-\(artifact.canvasId)-\(artifact.nodeId)-\(stableSuffix("\(artifact.reference)-\(artifact.id)-\(artifact.createdAt.timeIntervalSince1970)"))",
                    parentVersionId: parent,
                    canvasId: artifact.canvasId,
                    nodeId: artifact.nodeId,
                    artifactId: artifact.id,
                    artifactSlotKey: slotKey,
                    payloadRef: payloadRef,
                    payloadInline: artifact.payload,
                    inputSnapshot: nil,
                    displayStrategy: .latest,
                    forceNewVersion: false,
                    submittedBy: nil,
                    submittedByKind: .agent,
                    metadata: .object([
                        "title": .string(artifact.title),
                        "kind": .string(artifact.kind.rawValue),
                        "status": .string(artifact.status),
                        "source": .string("attachArtifact")
                    ]),
                    createdAt: artifact.createdAt
                ))
            }
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
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], artifacts: [PlannerArtifact]) {
        try withLock {
            let record = try record(for: canvas, seedNodes: seedNodes)
            var normalized = proposal
            try PlannerProposalValidator.validate(&normalized, canvas: canvas, nodes: record.nodes)
            let approved = service.approve(normalized)
            let nodes = try service.applyNodeChange(nodes: record.nodes, proposal: approved)
            let artifacts = mergeArtifacts(
                record.artifacts,
                proposalArtifacts(from: approved, nodes: nodes, canvasId: canvas.id)
                    + derivedArtifacts(from: nodes, canvasId: canvas.id)
            )
            return (approved, nodes, artifacts)
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
            // stepRunState == .pending 只可能来自 runState(for: .dead) ——
            // 绑定的会话结束了。保留 sessionId,把节点置为 awaitingInput/blocked,
            // 让 UI 仍能打开/恢复原会话;不要把绑定擦掉后伪装成从未启动过。
            // 已显式 submit(done/blocked latch)或已是 done 的节点不动;已绑到
            // 另一个活会话的节点忽略这条过期的结束信号。
            if stepRunState == .pending {
                let boundToThisSession = record.nodes[stepIndex].sessionId == sessionId
                let alreadyTerminal = record.nodes[stepIndex].outputSubmittedAt != nil
                    || record.nodes[stepIndex].workflowRunState == .done
                guard boundToThisSession, !alreadyTerminal else { return record }
                let endedReason = "Session \(String(sessionId.prefix(8))) 已结束；可打开恢复，或替换为新会话。"

                // 幂等守卫:节点可能早已被 demote 成「会话已结束 / awaitingInput」这个
                // 稳定终态。缺这个守卫时,每次 /api/state 轮询(多个 board 客户端 × ~1Hz)
                // 都会对一个早已结束的会话重写同样字段、append 一条重复的 nodeStateChanged
                // 事件、再 save() —— events.jsonl 无界膨胀(实测单 canvas 涨到 ~1.5 万条 /
                // ~5MB),每次 save 全量重编码 state.json + events.jsonl,把一个核烧满。
                // 只有字段真有变化才落库,语义对齐下方活会话分支的 `guard changed`。
                // sessionId 已等于入参(boundToThisSession 已校验),无需重新赋值。
                var changed = false
                if record.nodes[stepIndex].source != .session {
                    record.nodes[stepIndex].source = .session
                    changed = true
                }
                if record.nodes[stepIndex].chatThreadId != sessionId {
                    record.nodes[stepIndex].chatThreadId = sessionId
                    changed = true
                }
                if record.nodes[stepIndex].workflowRunState != .awaitingInput {
                    record.nodes[stepIndex].workflowRunState = .awaitingInput
                    changed = true
                }
                if record.nodes[stepIndex].status != .blocked {
                    record.nodes[stepIndex].status = .blocked
                    changed = true
                }
                if record.nodes[stepIndex].blockedReason != endedReason {
                    record.nodes[stepIndex].blockedReason = endedReason
                    changed = true
                }
                if let legacySessionIndex {
                    if record.nodes[legacySessionIndex].sessionId != sessionId {
                        record.nodes[legacySessionIndex].sessionId = sessionId
                        changed = true
                    }
                    if record.nodes[legacySessionIndex].chatThreadId != sessionId {
                        record.nodes[legacySessionIndex].chatThreadId = sessionId
                        changed = true
                    }
                    if record.nodes[legacySessionIndex].workflowRunState != .awaitingInput {
                        record.nodes[legacySessionIndex].workflowRunState = .awaitingInput
                        changed = true
                    }
                    if record.nodes[legacySessionIndex].status != .blocked {
                        record.nodes[legacySessionIndex].status = .blocked
                        changed = true
                    }
                }

                // Active run 的 nodeStates 是独立于蓝图字段的另一份状态:节点
                // demote 后若又启动了新 run,WorkflowRun.start 会把该 run 里的
                // 节点重置回 .pending。守卫只看蓝图字段会在这种漂移下短路,run
                // 一直显示 pending/可派发而不是 awaitingInput。所以把「镜像后
                // run 状态是否有变化」一起算进幂等判断:漂移时照常 mirror +
                // recompute,一次即收敛,不会回到每次轮询都落库的老问题。
                let demoteMirror: (inout RunNodeState) -> Void = { state in
                    state.sessionId = sessionId
                    state.chatThreadId = sessionId
                    state.runState = .awaitingInput
                    state.finishedAt = nil
                    state.nextAction = nil
                    Self.stampAwaitingClockOnActiveAttempt(&state, isAwaiting: true)
                    if !state.attempts.isEmpty {
                        let last = state.attempts.count - 1
                        state.attempts[last].runState = .awaitingInput
                    }
                }
                var runOutOfSync = false
                if let runIdx = activeRunIndex(in: record) {
                    // 只比较 demote 负责的字段。nextAction 归 recomputeActiveRun
                    // (WorkflowRunEngine.advance 每次重算)所有,镜像副本整体对比
                    // 会在 nextAction 上永远不相等,重新退化成每次轮询都落库。
                    let existing = record.runs[runIdx].nodeStates[stepNodeId]
                    runOutOfSync = existing?.runState != .awaitingInput
                        || existing?.sessionId != sessionId
                        || existing?.chatThreadId != sessionId
                        || existing?.finishedAt != nil
                }

                guard changed || runOutOfSync else { return record }

                record.events.append(event(
                    canvasId: canvasId,
                    type: .nodeStateChanged,
                    nodeId: record.nodes[stepIndex].id,
                    summary: "\(record.nodes[stepIndex].title) — session ended, kept binding for resume"
                ))
                mirrorIntoActiveRun(&record, nodeId: stepNodeId, mutate: demoteMirror)
                recomputeActiveRun(&record)
                document.canvases[canvasId] = record
                try save(canvasId: canvasId)
                return record
            }
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
                    // awaitingInputSince clock — stamp on entering
                    // awaitingInput/gateWait, clear on leaving. Only the live
                    // (last) attempt carries the clock; older attempts are
                    // historical and immutable. Helper is shared with the
                    // submit_node_output / routing paths (codex P2 review).
                    let isAwaiting = stepRunState == .awaitingInput || stepRunState == .gateWait
                    Self.stampAwaitingClockOnActiveAttempt(&state, isAwaiting: isAwaiting)
                    if !state.attempts.isEmpty {
                        let last = state.attempts.count - 1
                        state.attempts[last].runState = stepRunState
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

    /// BUG 1.1 — reconcile persisted "running" state against live sessions.
    ///
    /// On load/read, a step (or legacy session) node may still carry
    /// `dispatched`/`running` from before the app was closed, even though the
    /// Claude session it was bound to is long gone. Without this pass the UI
    /// keeps claiming the node is running. For every node whose run state is
    /// `dispatched`/`running` and whose bound `sessionId` is NOT present in the
    /// live session set, demote it to `awaitingInput` (stamping the awaiting
    /// clock) so the UI prompts the user to resume/re-dispatch.
    ///
    /// Tolerant by design: nodes with no `sessionId`, nodes that already
    /// submitted output (`outputSubmittedAt`), terminal nodes (`done`/`failed`),
    /// and genuinely live sessions are left untouched. `isLive` is supplied by
    /// the caller (BoardAPI) so PlannerCore stays decoupled from the session
    /// machinery (PluginManager / terminal backend registry / SessionStore).
    ///
    /// Returns the number of nodes demoted (0 when nothing changed).
    @discardableResult
    func reconcileRunStateAgainstLiveSessions(
        canvasId: String,
        isLive: (String) -> Bool
    ) throws -> Int {
        try withLock {
            guard let record = document.canvases[canvasId] else { return 0 }
            // Collect the step nodes that need demotion first so we can route
            // each through applySessionRunStateLocked (which keeps step+session
            // mirror, blockedReason, awaiting clock and the active run in sync).
            var demotions: [(stepNodeId: String, sessionId: String)] = []
            for node in record.nodes {
                guard let runState = node.workflowRunState,
                      runState == .dispatched || runState == .running else { continue }
                guard let sessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sessionId.isEmpty else { continue }
                // An explicit submit latches terminal state — never demote it.
                if node.outputSubmittedAt != nil { continue }
                if isLive(sessionId) { continue }
                // Map both step and legacy session nodes back to their step id;
                // applySessionRunStateLocked is keyed by step.
                let kind = node.nodeKind ?? .step
                let stepNodeId: String?
                if kind == .session {
                    stepNodeId = (node.dependsOnNodeIds ?? []).first
                } else {
                    stepNodeId = node.id
                }
                if let stepNodeId {
                    demotions.append((stepNodeId, sessionId))
                }
            }
            // De-dup by step (a step + its legacy session node share a sessionId).
            var seen = Set<String>()
            var demoted = 0
            for demotion in demotions where seen.insert(demotion.stepNodeId).inserted {
                if try applySessionRunStateLocked(
                    stepNodeId: demotion.stepNodeId,
                    sessionId: demotion.sessionId,
                    runState: .awaitingInput
                ) != nil {
                    demoted += 1
                }
            }
            return demoted
        }
    }

    /// canvas-spec §8 / §11 · A step "needs review" — i.e. its `done` output
    /// must be confirmed by a human before downstream unblocks — when it
    /// carries an explicit `gate` OR a non-`.none` `handoffPolicy`
    /// (reviewer-must-approve / any-approver / all-approvers). This is the SOLE
    /// trigger for the「待确认」(awaiting-review) park; `executionMode`
    /// (human/auto) is deliberately NOT consulted (the two axes are decoupled).
    static func needsReview(_ node: PlanningNode) -> Bool {
        if node.gate != nil { return true }
        return node.handoffPolicy != .none
    }

    /// Map a workflow run state to the public `PlanningNodeStatus`, keeping the
    /// two status dimensions consistent on the node.
    private static func nodeStatus(for runState: PlannerWorkflowRunState) -> PlanningNodeStatus {
        switch runState {
        case .pending, .readyToStart:
            return .ready
        case .dispatched, .running:
            return .ready
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

    private static func normalizedCanvasId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func subCanvasIds(in value: BoardJSONValue?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        collectSubCanvasIds(in: value, seen: &seen, result: &result)
        return result
    }

    private static func collectSubCanvasIds(
        in value: BoardJSONValue?,
        seen: inout Set<String>,
        result: inout [String]
    ) {
        guard let value else { return }
        switch value {
        case .object(let object):
            if case .string(let raw)? = object["subCanvasId"],
               let subCanvasId = normalizedCanvasId(raw),
               !seen.contains(subCanvasId) {
                seen.insert(subCanvasId)
                result.append(subCanvasId)
            }
            for child in object.values {
                collectSubCanvasIds(in: child, seen: &seen, result: &result)
            }
        case .array(let values):
            for child in values {
                collectSubCanvasIds(in: child, seen: &seen, result: &result)
            }
        case .null, .bool, .number, .string:
            return
        }
    }

    private func requireRecord(canvasId: String) throws -> CanvasRecord {
        guard let record = document.canvases[canvasId] else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        var normalized = record
        normalized.artifacts = mergeArtifacts([], record.artifacts)
        return normalized
    }

    /// PR6+7 · Read-only record accessor for the DataSource adapter bridge.
    /// Takes the store lock; returns the normalized record (no mutation).
    func canvasRecordForBridge(canvasId: String) throws -> CanvasRecord {
        try withLock { try requireRecord(canvasId: canvasId) }
    }

    func renderProfileState(canvasId: String) throws -> (
        profile: CanvasRenderProfile,
        status: CanvasRenderProfileStatus,
        objects: [CanvasObject],
        relations: [CanvasRelation]
    ) {
        try BoardPerfProbe.shared.measure(
            "planner.renderProfile.state",
            title: "render profile state",
            category: "planner",
            detail: "canvas=\(String(canvasId.prefix(24)))"
        ) {
        try withLock {
            let record = try requireRecord(canvasId: canvasId)
            let url = renderProfileURL(canvasId: canvasId)
            let path = url.path
            if fileManager.fileExists(atPath: path) {
                do {
                    let data = try Data(contentsOf: url)
                    let profile = try decoder.decode(CanvasRenderProfile.self, from: data)
                    try Self.validateRenderProfile(profile)
                    lastValidRenderProfiles[canvasId] = profile
                    ensureRenderProfileWatcherLocked(canvasId: canvasId, url: url)
                    let resolved = CanvasRenderResolver.resolve(record: record, profile: profile)
                    return (
                        profile,
                        CanvasRenderProfileStatus(
                            state: .valid,
                            path: path,
                            error: nil,
                            updatedAt: fileUpdatedAt(url)
                        ),
                        resolved.objects,
                        resolved.relations
                    )
                } catch {
                    let fallback = lastValidRenderProfiles[canvasId] ?? Self.migratedRenderProfile(from: record)
                    ensureRenderProfileWatcherLocked(canvasId: canvasId, url: url)
                    let resolved = CanvasRenderResolver.resolve(record: record, profile: fallback)
                    return (
                        fallback,
                        CanvasRenderProfileStatus(
                            state: .invalidUsingLastValid,
                            path: path,
                            error: error.localizedDescription,
                            updatedAt: fileUpdatedAt(url)
                        ),
                        resolved.objects,
                        resolved.relations
                    )
                }
            }

            let profile = Self.migratedRenderProfile(from: record)
            try writeRenderProfile(profile, canvasId: canvasId)
            lastValidRenderProfiles[canvasId] = profile
            ensureRenderProfileWatcherLocked(canvasId: canvasId, url: url)
            let resolved = CanvasRenderResolver.resolve(record: record, profile: profile)
            return (
                profile,
                CanvasRenderProfileStatus(
                    state: .missingMigrated,
                    path: path,
                    error: nil,
                    updatedAt: fileUpdatedAt(url)
                ),
                resolved.objects,
                resolved.relations
            )
        }
        }
    }

    func renderProfilePath(canvasId: String) -> String {
        renderProfileURL(canvasId: canvasId).path
    }

    func replaceRenderLogic(canvasId: String, logic: CanvasRenderLogic) throws -> CanvasRenderProfile {
        try withLock {
            _ = try requireRecord(canvasId: canvasId)
            let current = try renderProfileState(canvasId: canvasId).profile
            var next = current
            next.logic = logic
            try Self.validateRenderProfile(next)
            try writeRenderProfile(next, canvasId: canvasId)
            lastValidRenderProfiles[canvasId] = next
            SessionEventBus.shared.publish(.plannerCanvasChanged(canvasId: canvasId))
            return next
        }
    }

    func patchRenderValues(
        canvasId: String,
        objectValues: [String: CanvasRenderObjectValues],
        relationValues: [String: CanvasRenderRelationValues],
        renderOnlyObjects: [CanvasObject]?
    ) throws -> CanvasRenderProfile {
        try withLock {
            _ = try requireRecord(canvasId: canvasId)
            var profile = try renderProfileState(canvasId: canvasId).profile
            for (id, values) in objectValues {
                if let current = profile.values.objects[id] {
                    profile.values.objects[id] = current.merging(values)
                } else {
                    profile.values.objects[id] = values
                }
            }
            for (id, values) in relationValues {
                if let current = profile.values.relations[id] {
                    profile.values.relations[id] = current.merging(values)
                } else {
                    profile.values.relations[id] = values
                }
            }
            if let renderOnlyObjects {
                profile.values.renderOnlyObjects = renderOnlyObjects
            }
            try Self.validateRenderProfile(profile)
            try writeRenderProfile(profile, canvasId: canvasId)
            lastValidRenderProfiles[canvasId] = profile
            SessionEventBus.shared.publish(.plannerCanvasChanged(canvasId: canvasId))
            return profile
        }
    }

    func copyRenderProfile(from sourceCanvasId: String, to targetCanvasId: String) throws {
        try withLock {
            let source = try requireRecord(canvasId: sourceCanvasId)
            let target = try requireRecord(canvasId: targetCanvasId)
            let profile = try renderProfileState(canvasId: source.canvas.id).profile
            let remapped = Self.remapRenderProfile(profile, from: source.canvas.id, to: target.canvas.id)
            try writeRenderProfile(remapped, canvasId: target.canvas.id)
            lastValidRenderProfiles[target.canvas.id] = remapped
        }
    }

    func writeRenderProfile(_ profile: CanvasRenderProfile, canvasId: String) throws {
        let url = renderProfileURL(canvasId: canvasId)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(profile)
        try BoardPerfProbe.shared.measure(
            "planner.renderProfile.write",
            title: "write render-profile.json",
            category: "io",
            detail: "canvas=\(String(canvasId.prefix(24)))",
            bytes: data.count
        ) {
            try data.write(to: url, options: .atomic)
        }
        ensureRenderProfileWatcherLocked(canvasId: canvasId, url: url)
    }

    private func renderProfileURL(canvasId: String) -> URL {
        canvasDirectory(canvasId: canvasId).appendingPathComponent("render-profile.json")
    }

    private func ensureRenderProfileWatcherLocked(canvasId: String, url: URL) {
        guard renderProfileWatchers[canvasId] == nil,
              fileManager.fileExists(atPath: url.path) else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.handleRenderProfileFileChanged(canvasId: canvasId)
        }
        source.setCancelHandler {
            close(fd)
        }
        renderProfileWatchers[canvasId] = source
        source.resume()
    }

    private func handleRenderProfileFileChanged(canvasId: String) {
        BoardPerfProbe.shared.recordEvent(
            "planner.renderProfile.fileChanged",
            title: "render profile file changed",
            category: "watcher",
            detail: "canvas=\(String(canvasId.prefix(24)))"
        )
        withLock {
            if let watcher = renderProfileWatchers.removeValue(forKey: canvasId) {
                watcher.cancel()
            }
        }
        do {
            _ = try renderProfileState(canvasId: canvasId)
        } catch {
            MWarn("[PlannerStore] render profile reload failed for \(canvasId): \(error)")
        }
        SessionEventBus.shared.publish(.plannerCanvasChanged(canvasId: canvasId))
    }

    private func fileUpdatedAt(_ url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func validateRenderProfile(_ profile: CanvasRenderProfile) throws {
        guard profile.version == CanvasRenderProfile.defaultVersion else {
            throw PlannerCoreError.invalidNodeOutput("unsupported render profile version: \(profile.version)")
        }
        guard CanvasRenderLayoutKind.allCases.contains(profile.logic.layout) else {
            throw PlannerCoreError.invalidNodeOutput("unsupported render layout")
        }
    }

    private static func migratedRenderProfile(from record: CanvasRecord) -> CanvasRenderProfile {
        var profile = CanvasRenderProfile.default(layout: record.canvas.monitorSpec == nil ? .graph : .collection)
        if let scene = record.canvas.sceneSpec {
            profile.logic.layout = .spatial
            var metadata: [String: BoardJSONValue] = ["sceneKind": .string(scene.kind)]
            if let initialState = scene.initialState {
                metadata["initialState"] = initialState
            }
            if let sceneSpecValue = boardJSONValue(scene) {
                metadata["sceneSpec"] = sceneSpecValue
            }
            profile.values.renderOnlyObjects.append(CanvasObject(
                id: "scene:\(scene.kind):background",
                label: "\(scene.kind) background",
                entityRef: nil,
                renderOnly: CanvasRenderOnlyObject(kind: .background, id: "scene:\(scene.kind):background"),
                renderer: .asset,
                values: nil,
                metadata: .object(metadata)
            ))
            for action in scene.actions {
                profile.logic.actions.append(CanvasRenderActionRule(
                    id: "scene-action:\(action.id)",
                    action: .runSceneAction,
                    label: action.label,
                    targetObjectId: "node:\(action.nodeId)",
                    sceneActionId: action.id
                ))
            }
        }
        if let monitorSpec = record.canvas.monitorSpec {
            profile.logic.layout = .collection
            profile.values.renderOnlyObjects.append(CanvasObject(
                id: "monitor:\(monitorSpec.canvasId):region",
                label: "Monitor",
                entityRef: nil,
                renderOnly: CanvasRenderOnlyObject(kind: .region, id: "monitor:\(monitorSpec.canvasId):region"),
                renderer: .container,
                values: nil,
                metadata: nil
            ))
        }
        for node in record.nodes {
            if let layout = node.layout {
                profile.values.objects["node:\(node.id)"] = CanvasRenderObjectValues(
                    x: layout.x,
                    y: layout.y,
                    width: layout.width,
                    height: layout.height,
                    zIndex: nil,
                    hidden: nil,
                    collapsed: nil,
                    pinned: nil,
                    rendererVariant: nil,
                    density: nil,
                    icon: nil,
                    designToken: nil
                )
            }
        }
        return profile
    }

    private static func boardJSONValue<T: Encodable>(_ value: T) -> BoardJSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(BoardJSONValue.self, from: data)
    }

    private static func remapRenderProfile(
        _ profile: CanvasRenderProfile,
        from sourceCanvasId: String,
        to targetCanvasId: String
    ) -> CanvasRenderProfile {
        guard sourceCanvasId != targetCanvasId else { return profile }
        var next = profile
        next.values.renderOnlyObjects = profile.values.renderOnlyObjects.map { object in
            var copy = object
            if case .object(var metadata) = copy.metadata {
                for (key, value) in metadata {
                    if case .string(let raw) = value, raw == sourceCanvasId {
                        metadata[key] = .string(targetCanvasId)
                    }
                }
                copy.metadata = .object(metadata)
            }
            return copy
        }
        return next
    }

    func importGraphState(_ graph: PlannerGraphState, localCanvasId: String) throws {
        try withLock {
            let existing = document.canvases[localCanvasId]
            var canvas = graph.canvas
            canvas.id = localCanvasId
            var artifacts = graph.artifacts
            for idx in artifacts.indices {
                artifacts[idx].payload = nil
            }
            document.canvases[localCanvasId] = CanvasRecord(
                canvas: canvas,
                nodes: graph.nodes,
                proposals: graph.proposals,
                events: graph.events,
                artifacts: artifacts,
                artifactVersions: existing?.artifactVersions ?? [],
                runs: existing?.runs ?? [],
                activeRunId: existing?.activeRunId,
                nodeVersions: existing?.nodeVersions ?? []
            )
            try save(canvasId: localCanvasId, emitChange: false)
        }
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

    // MARK: - Attempt single writer (PR6+7 · §5.2 / §5.5)

    /// Monotonic per-canvas Lamport sequence. Every attempt append bumps it so
    /// the causalKey is wall-clock independent and unique per (canvas, append).
    /// Process-local; durable lamport ordering is the online backend's job.
    private var lamportSeqByCanvas: [String: Int] = [:]

    @discardableResult
    private func nextLamportSeq(canvasId: String) -> Int {
        let next = (lamportSeqByCanvas[canvasId] ?? 0) + 1
        lamportSeqByCanvas[canvasId] = next
        return next
    }

    /// §5.5 causality: `causalKey = hash(canvasId, nodeId, attemptIndex,
    /// lamportSeq)`. Wall-clock independent so replays / re-derivations are
    /// stable. SHA-256 truncated to 16 hex chars (collision-safe at this scale).
    static func causalKey(canvasId: String, nodeId: String, attemptIndex: Int, lamportSeq: Int) -> String {
        let material = "\(canvasId)|\(nodeId)|\(attemptIndex)|\(lamportSeq)"
        return "ck-" + Self.stableHashHex(material)
    }

    /// §5.2 single attempt writer. Every NodeAttempt append goes through here so
    /// each attempt carries a `TriggerOrigin` (never the legacy sentinel for new
    /// attempts) and its `edgeConsumptions`. `origin` is the provenance; the
    /// causalKey on auto/inherited origins is computed from a monotonic
    /// per-canvas lamportSeq. Appends to the live RunNodeState's `attempts`.
    func appendAttempt(
        _ canvasId: String,
        on state: inout RunNodeState,
        origin: TriggerOrigin,
        edgeConsumptions: [EdgeConsumption] = [],
        sessionId: String? = nil,
        runState: PlannerWorkflowRunState = .running
    ) {
        let index = state.attempts.count
        _ = nextLamportSeq(canvasId: canvasId) // bump the per-canvas clock.
        state.attempts.append(NodeAttempt(
            index: index,
            sessionId: sessionId,
            runState: runState,
            origin: origin,
            edgeConsumptions: edgeConsumptions
        ))
    }

    /// Stable hex digest helper for causalKey. Uses a portable FNV-1a fold so
    /// no CryptoKit import is needed (and it stays deterministic across runs).
    static func stableHashHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    /// delta (codex fix): stamp/clear `awaitingInputSince` on the active
    /// (last) NodeAttempt. Entering `awaitingInput` / `gateWait` records the
    /// timestamp once (idempotent — re-entry doesn't reset the clock);
    /// leaving clears it. Older attempts are historical and immutable.
    /// Call this from every code path that transitions a node into or out
    /// of a wait state, not just the session-feedback mirror.
    static func stampAwaitingClockOnActiveAttempt(
        _ state: inout RunNodeState,
        isAwaiting: Bool
    ) {
        guard !state.attempts.isEmpty else { return }
        let last = state.attempts.count - 1
        if isAwaiting {
            if state.attempts[last].awaitingInputSince == nil {
                state.attempts[last].awaitingInputSince = Date()
            }
        } else {
            state.attempts[last].awaitingInputSince = nil
        }
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

    private func save(canvasId: String, emitChange: Bool = true) throws {
        try BoardPerfProbe.shared.measure(
            "planner.store.save",
            title: "PlannerStore.save(canvas)",
            category: "planner",
            detail: "canvas=\(String(canvasId.prefix(24)))"
        ) {
            guard let record = document.canvases[canvasId] else {
                throw PlannerCoreError.canvasNotFound(canvasId)
            }
            let directory = canvasDirectory(canvasId: canvasId)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(record)
            try BoardPerfProbe.shared.measure(
                "planner.store.writeState",
                title: "write state.json",
                category: "io",
                detail: "canvas=\(String(canvasId.prefix(24)))",
                bytes: data.count
            ) {
                try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            }
            try saveEventsIfNeeded(record.events, canvasId: canvasId, directory: directory)
            try saveIndex()
            if emitChange {
                SessionEventBus.shared.publish(.plannerCanvasChanged(canvasId: canvasId))
            }
        }
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

    private func saveEventsIfNeeded(_ events: [PlannerEvent], canvasId: String, directory: URL) throws {
        let signature = Self.eventLogSignature(for: events)
        let url = directory.appendingPathComponent("events.jsonl")
        if eventLogSignatures[canvasId] == signature,
           fileManager.fileExists(atPath: url.path) {
            BoardPerfProbe.shared.recordEvent(
                "planner.store.eventsSkipped",
                title: "skip events.jsonl write",
                category: "io",
                detail: "canvas=\(String(canvasId.prefix(24))) count=\(events.count)"
            )
            return
        }
        try writeEvents(events, to: url)
        eventLogSignatures[canvasId] = signature
    }

    private func writeEvents(_ events: [PlannerEvent], to url: URL) throws {
        let lines = try events.map { event -> Data in
            try eventEncoder.encode(event)
        }
        var data = Data()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                data.append(0x0A)
            }
            data.append(line)
        }
        if !lines.isEmpty {
            data.append(0x0A)
        }
        try BoardPerfProbe.shared.measure(
            "planner.store.writeEvents",
            title: "write events.jsonl",
            category: "io",
            bytes: data.count
        ) {
            try data.write(to: url, options: .atomic)
        }
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
            // Canvas runtime 5-atom governance variants (PR6+7). Emit a
            // proposal-scoped governance event; node-scoped detail (if any) is
            // covered by the node-level events above.
            case .removeNode:
                if let nodeId = change.nodeId {
                    events.append(event(
                        canvasId: proposal.canvasId,
                        type: .nodeUpdated,
                        nodeId: nodeId,
                        proposalId: proposal.id,
                        summary: "Removed node \(nodeId)"
                    ))
                }
            case .addDataSource, .updateDataSource, .setPartitionRule, .archiveDataSource,
                 .addEdge, .updateEdgeMode, .removeEdge,
                 .setMonitorSpec, .addMonitorCard, .updateMonitorCard, .removeMonitorCard, .moveMonitorCard,
                 .replaceRenderLogic,
                 .writeSourceVersion, .attachExternalArtifact:
                events.append(event(
                    canvasId: proposal.canvasId,
                    type: .nodeStateChanged,
                    nodeId: change.nodeId ?? "",
                    proposalId: proposal.id,
                    summary: "Governance: \(change.kind.rawValue)"
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

    /// Direct artifact-layer read · 按 artifactId 精确 / reference 归一匹配,
    /// 返回 latest-per-slot 的 head。session 拉「外部对象当前快照」用。
    func findArtifacts(
        canvasId: String,
        artifactId: String? = nil,
        reference: String? = nil
    ) throws -> [PlannerArtifact] {
        try withLock {
            let record = try requireRecord(canvasId: canvasId)
            return matchArtifacts(record.artifacts, artifactId: artifactId, reference: reference)
        }
    }

    /// Direct artifact-layer write(账本直改)— 不经节点状态机。
    ///
    /// 现状是 artifact 只能借道节点会话生命周期前进(submit_node_output /
    /// attach):人工要改个 tracker 的行数都得先跟 step 节点的 session 说一声、
    /// 等它"操作"一下。这条路径把 artifact 当一等账本对象:人工修正、或任何
    /// session 主动刷新外部对象快照,都直接在这里追加版本 — 节点 status /
    /// run state / artifactRefs 一概不动(引用早已挂上,执行态不该被读写抖动)。
    ///
    /// 寻址:artifactId 精确命中一个;reference 命中所有共享该引用的槽位 —
    /// 同一外部对象在多个节点上的镜像(如 tracker 的 Pipeline tab 被
    /// sourcing/verify 两个节点共享)必须一起前进,否则画布上会出现两个版本
    /// 的"同一张表"。每个命中槽位各追加一条版本行,沿用其自身版本链。
    func updateArtifact(
        canvasId: String,
        artifactId: String? = nil,
        reference: String? = nil,
        title: String? = nil,
        status: String? = nil,
        payload: BoardJSONValue? = nil,
        submittedBy: String? = nil,
        submittedByKind: PlannerArtifactVersionSubmitterKind = .human
    ) throws -> [PlannerArtifact] {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard title != nil || status != nil || payload != nil else {
                throw PlannerCoreError.invalidNodeOutput("updateArtifact requires at least one of title/status/payload")
            }
            let targets = matchArtifacts(record.artifacts, artifactId: artifactId, reference: reference)
            guard !targets.isEmpty else {
                throw PlannerCoreError.artifactNotFound(artifactId ?? reference ?? "(no selector)")
            }
            let now = Date()
            var updated: [PlannerArtifact] = []
            for target in targets {
                var next = target
                if let title { next.title = title }
                if let status { next.status = status }
                if let payload { next.payload = payload }
                next.createdAt = now
                let slotKey = artifactSlotKey(canvasId: canvasId, nodeId: target.nodeId, reference: target.reference)
                let parent = latestVersion(in: record.artifactVersions, slotKey: slotKey)?.versionId
                let payloadRef = (next.payload?.objectValue?["blobRef"]?.stringValue).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? target.reference
                record.artifactVersions.append(PlannerArtifactVersion(
                    versionId: "ver-\(canvasId)-\(target.nodeId)-\(stableSuffix("\(target.reference)-\(target.id)-\(now.timeIntervalSince1970)"))",
                    parentVersionId: parent,
                    canvasId: canvasId,
                    nodeId: target.nodeId,
                    artifactId: target.id,
                    artifactSlotKey: slotKey,
                    payloadRef: payloadRef,
                    payloadInline: next.payload,
                    inputSnapshot: nil,
                    displayStrategy: .latest,
                    forceNewVersion: false,
                    submittedBy: submittedBy,
                    submittedByKind: submittedByKind,
                    metadata: .object([
                        "title": .string(next.title),
                        "source": .string("updateArtifact")
                    ]),
                    createdAt: now
                ))
                // 显式更新不走 mergeArtifacts 的评分仲裁 — 这是用户/调用方的
                // 明确意图,head 必须前进(否则"分高"的旧 payload 会顶掉直改)。
                if let idx = record.artifacts.firstIndex(where: { $0.id == target.id }) {
                    record.artifacts[idx] = next
                }
                updated.append(next)
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .artifactAttached,
                nodeId: targets.first?.nodeId,
                summary: "\(updated.first?.title ?? "artifact") — direct update",
                artifactRefs: Array(Set(updated.map(\.reference)))
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return updated
        }
    }

    func updateArtifactViews(
        canvasId: String,
        artifactId: String? = nil,
        reference: String? = nil,
        views: [PlannerArtifactView],
        deleteViewIds: [String] = [],
        submittedBy: String? = nil
    ) throws -> [PlannerArtifact] {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            let targets = matchArtifacts(record.artifacts, artifactId: artifactId, reference: reference)
            guard !targets.isEmpty else {
                throw PlannerCoreError.artifactNotFound(artifactId ?? reference ?? "(no selector)")
            }
            let normalizedViews = try normalizeArtifactViews(views)
            let deletes = Set(deleteViewIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !normalizedViews.isEmpty || !deletes.isEmpty else {
                throw PlannerCoreError.invalidNodeOutput("updateArtifactViews requires views or deleteViewIds")
            }

            var updated: [PlannerArtifact] = []
            for target in targets {
                guard let idx = record.artifacts.firstIndex(where: { $0.id == target.id }) else { continue }
                var next = record.artifacts[idx]
                var byId: [String: PlannerArtifactView] = [:]
                var order: [String] = []
                for view in next.views ?? [] {
                    let id = view.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty, !deletes.contains(id) else { continue }
                    if byId[id] == nil { order.append(id) }
                    byId[id] = view
                }
                for view in normalizedViews {
                    if byId[view.id] == nil { order.append(view.id) }
                    byId[view.id] = view
                }
                let merged = order.compactMap { byId[$0] }
                next.views = merged.isEmpty ? nil : merged
                record.artifacts[idx] = next
                updated.append(next)
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .artifactAttached,
                nodeId: targets.first?.nodeId,
                summary: "Artifact views updated",
                artifactRefs: Array(Set(updated.map(\.reference)))
            ))
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return updated
        }
    }

    private func normalizeArtifactViews(_ views: [PlannerArtifactView]) throws -> [PlannerArtifactView] {
        var seen = Set<String>()
        return try views.map { view in
            let id = view.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw PlannerCoreError.invalidNodeOutput("Artifact view id cannot be empty.")
            }
            guard seen.insert(id).inserted else {
                throw PlannerCoreError.invalidNodeOutput("Duplicate artifact view id '\(id)'.")
            }
            let title = view.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlannerArtifactView(
                id: id,
                title: title.isEmpty ? id : title,
                kind: view.kind,
                sourcePath: {
                    let value = view.sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return value.isEmpty ? nil : value
                }(),
                columns: view.columns?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                filter: view.filter,
                sort: view.sort,
                groupBy: view.groupBy
            )
        }
    }

    private func matchArtifacts(
        _ artifacts: [PlannerArtifact],
        artifactId: String?,
        reference: String?
    ) -> [PlannerArtifact] {
        if let artifactId, !artifactId.isEmpty {
            return artifacts.filter { $0.id == artifactId }
        }
        guard let reference, !reference.isEmpty else { return [] }
        let normalized = normalizeArtifactReference(reference)
        return artifacts.filter { normalizeArtifactReference($0.reference) == normalized }
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

    /// canvas-spec §8 / §11 · Confirm a node parked at「待确认」(awaiting-review,
    /// `workflowRunState == .gateWait` after a needs-review `done`). This is the
    /// human "approve / sign-off" action: the node transitions to `.done`, and
    /// every downstream node whose dependencies are now all done becomes
    /// startable (`readyToStart`), exactly mirroring the post-`done` routing
    /// flip in `submitNodeOutput`. Idempotent on an already-`done` node.
    func confirmNodeReview(
        canvasId: String,
        nodeId: String
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let nodeIndex = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            // Only a node currently awaiting review (gateWait) is confirmable.
            // An already-done node is a no-op; anything else is an error so the
            // caller doesn't silently "confirm" a still-running / blocked node.
            let runState = record.nodes[nodeIndex].workflowRunState
            if record.nodes[nodeIndex].status == .done && runState != .gateWait {
                return record
            }
            guard runState == .gateWait else {
                throw PlannerCoreError.invalidNodeOutput(
                    "Only a node awaiting review (gate-wait) can be confirmed."
                )
            }
            record.nodes[nodeIndex].status = .done
            record.nodes[nodeIndex].workflowRunState = .done
            record.nodes[nodeIndex].blockedReason = nil
            let confirmedTitle = record.nodes[nodeIndex].title
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = .done
                state.finishedAt = state.finishedAt ?? Date()
                Self.stampAwaitingClockOnActiveAttempt(&state, isAwaiting: false)
            }
            // Dataflow legality (§11): now that the upstream is truly done,
            // unblock every direct downstream node that has no live session yet
            // and whose upstream deps are all done. Mirror the submit flip.
            let doneIds = Set(record.nodes.filter { $0.status == .done }.map(\.id))
            for targetIndex in record.nodes.indices {
                let target = record.nodes[targetIndex]
                guard (target.dependsOnNodeIds ?? []).contains(nodeId) else { continue }
                let hasSession = (target.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                let doerAssigned = !target.doerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let upstreamAllDone = (target.dependsOnNodeIds ?? []).allSatisfy { doneIds.contains($0) }
                guard upstreamAllDone, doerAssigned, !hasSession else { continue }
                // Don't clobber a node that already moved past ready.
                guard target.workflowRunState == nil
                        || target.workflowRunState == .pending
                        || target.workflowRunState == .gateWait else { continue }
                record.nodes[targetIndex].status = .ready
                record.nodes[targetIndex].workflowRunState = .readyToStart
                mirrorIntoActiveRun(&record, nodeId: target.id) { state in
                    state.runState = .readyToStart
                }
            }
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Confirmed review for \(confirmedTitle) — node done, downstream unblocked"
            ))
            recomputeActiveRun(&record)
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

    /// canvas-spec §5/§10 (P3) · Push a node's just-submitted output artifacts
    /// into any DataSource its output slot is bound to. Binding is expressed on
    /// an edge: `sourceRef.nodeId == nodeId`, `sourceRef.sourceKey ==
    /// artifact.reference` (the producer's output slot), and a non-nil
    /// `sourceRef.dataSourceId` naming the intermediary pool. For each such
    /// (artifact, edge) pair we:
    ///   1. advance the DataSource's monotonic `currentVersion`,
    ///   2. append a writeSourceVersion-style `PlannerArtifactVersion` row keyed
    ///      to the source slot (so the version chain is queryable), and
    ///   3. enqueue a `.ready` item into the source's managed adapter so a
    ///      downstream `queue-claim` edge can claim it.
    /// Called from within `submitNodeOutput`'s lock; mutates `record` in place.
    /// Best-effort on the adapter enqueue — a missing/fs adapter must not fail
    /// the submit (the version-chain advance is the durable part).
    private func pushOutputsIntoBoundDataSources(
        _ record: inout CanvasRecord,
        canvasId: String,
        nodeId: String,
        producedArtifacts: [PlannerArtifact]
    ) {
        guard !producedArtifacts.isEmpty, !record.canvas.edges.isEmpty else { return }
        for artifact in producedArtifacts {
            // Find edges whose source endpoint is this node's output slot AND
            // carry a DataSource binding. Multiple edges may bind the same slot
            // (fan-out to several pools); push into each.
            let boundEdges = record.canvas.edges.filter { edge in
                guard let sourceId = edge.sourceRef.dataSourceId, !sourceId.isEmpty else { return false }
                return edge.sourceRef.nodeId == nodeId
                    && edge.sourceRef.sourceKey == artifact.reference
            }
            // De-dup by sourceId so two edges binding the same pool enqueue once.
            var pushedSources = Set<String>()
            for edge in boundEdges {
                guard let sourceId = edge.sourceRef.dataSourceId,
                      !pushedSources.contains(sourceId),
                      let sourceIdx = record.canvas.dataSources.firstIndex(where: { $0.id == sourceId })
                else { continue }
                pushedSources.insert(sourceId)

                // 1) advance currentVersion (sequence strategy, monotonic).
                record.canvas.dataSources[sourceIdx].currentVersion += 1
                let newVersion = record.canvas.dataSources[sourceIdx].currentVersion

                // 2) append a source-keyed version row (writeSourceVersion twin).
                let slotKey = "\(canvasId)|source|\(sourceId)|\(artifact.reference)"
                let parent = latestVersion(in: record.artifactVersions, slotKey: slotKey)?.versionId
                let createdAt = Date()
                let itemId = "item-\(sourceId)-\(newVersion)"
                record.artifactVersions.append(PlannerArtifactVersion(
                    versionId: "ver-\(sourceId)-\(stableSuffix("\(slotKey)-\(createdAt.timeIntervalSince1970)"))",
                    parentVersionId: parent,
                    canvasId: canvasId,
                    nodeId: nodeId,
                    artifactId: artifact.id,
                    artifactSlotKey: slotKey,
                    payloadRef: artifact.reference,
                    payloadInline: artifact.payload,
                    inputSnapshot: nil,
                    displayStrategy: .latest,
                    forceNewVersion: false,
                    submittedBy: nil,
                    submittedByKind: .agent,
                    metadata: .object([
                        "source": .string("writeSourceVersion"),
                        "sourceId": .string(sourceId),
                        "pushedFromNode": .string(nodeId),
                        "itemId": .string(itemId)
                    ]),
                    createdAt: createdAt
                ))

                // 3) enqueue a `.ready` claimable item into the managed adapter
                //    so a downstream queue-claim consumer can claim it. Only the
                //    managed backing keeps an in-memory queue; fs/unknown kinds
                //    surface items by directory enumeration / external state, so
                //    the version-chain advance above is the durable signal there.
                if let adapter = try? PlannerBoardBridge.dataSourceAdapter(canvasId: canvasId, sourceId: sourceId),
                   let managed = adapter as? ManagedAdapter {
                    managed.enqueue(DataSourceItem(
                        itemId: itemId,
                        state: .ready,
                        ref: artifact.reference
                    ))
                    // Keep the adapter's own version counter aligned with the
                    // record so `probeFreshness()` agrees with `currentVersion`.
                    managed.syncVersion(to: newVersion)
                }

                record.events.append(event(
                    canvasId: canvasId,
                    type: .artifactAttached,
                    nodeId: nodeId,
                    summary: "Pushed \(artifact.title) into source \(sourceId) (v\(newVersion))",
                    artifactRefs: [artifact.reference]
                ))
            }
        }
    }

    /// Fan-in gate: is EVERY `dependsOnNodeIds` of `node` in a done state?
    ///
    /// A node with multiple upstreams (e.g. the orchestration 集成 node that
    /// dependsOn 前端/后端/重构) must not auto-start when only the producer that
    /// just routed to it is done — all of its upstreams must be done first.
    /// `gateWait`/`failed`/`running` upstreams do NOT count as done, mirroring
    /// the per-route `producerIsDone` check (a parked「待确认」producer is not
    /// done until `confirmNodeReview`). A node with no deps is trivially ready.
    private func allDependenciesDone(_ node: PlanningNode, in record: CanvasRecord) -> Bool {
        let deps = node.dependsOnNodeIds ?? []
        guard !deps.isEmpty else { return true }
        return deps.allSatisfy { depId in
            record.nodes.first { $0.id == depId }?.workflowRunState == .done
        }
    }

    func submitNodeOutput(
        canvasId: String,
        nodeId: String,
        output: PlannerNodeOutput,
        submittedByKind: PlannerArtifactVersionSubmitterKind = .agent,
        submittedBy: String? = nil
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
                if Self.needsReview(current) {
                    // canvas-spec §8 / §11 · "谁执行" 与 "是否需人工审查" 解耦.
                    // A needs-review node (carries a `gate` OR a non-`.none`
                    // `handoffPolicy`) parks at the distinct「待确认」
                    // (awaiting-review) state — NOT「卡住」(blocked). We keep
                    // `workflowRunState = .gateWait` as the carrier (approach a)
                    // and surface the distinction through the derived display:
                    // `nodeStatus(for: .gateWait)` plus `needsOwnerReview = true`
                    // in the NodeStateSnapshot. A node here is NOT done, so it
                    // blocks downstream until `confirmNodeReview` flips it.
                    current.status = Self.nodeStatus(for: .gateWait)
                    current.workflowRunState = .gateWait
                } else {
                    // No review needed (human OR auto) → straight to done.
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
                // theta (2026-05-29) · Default reviewStatus by payload.type.
                // Snapshot-style payloads (inbox-items / kanban) auto-approve
                // because the owner has nothing meaningful to "promote";
                // narrative-style payloads (markdown / prd / file / html)
                // park in `pending` so the owner explicitly promotes a draft
                // before downstream consumers treat it as canonical.
                let payloadType = item.payload?.objectValue?["type"]?.stringValue
                let defaultReviewStatus: String
                switch payloadType {
                case "inbox-items", "kanban":
                    defaultReviewStatus = "approved"
                case "markdown", "prd", "file", "html":
                    defaultReviewStatus = "pending"
                default:
                    defaultReviewStatus = "approved"
                }
                let explicitReviewStatus = item.payload?.objectValue?["reviewStatus"]?.stringValue
                let artifact = PlannerArtifact(
                    id: artifactId,
                    canvasId: canvasId,
                    nodeId: nodeId,
                    kind: item.kind,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? reference : item.title,
                    reference: reference,
                    status: output.status.rawValue,
                    createdAt: now,
                    payload: item.payload,
                    reviewStatus: explicitReviewStatus ?? defaultReviewStatus
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
                    submittedBy: submittedBy,
                    submittedByKind: submittedByKind,
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

            // canvas-spec §5/§10 (P3) · Output → DataSource push. If this node's
            // output slot is bound to a DataSource via an edge whose
            // `sourceRef.dataSourceId` is set (the producer pushes into an
            // intermediary pool, e.g. 会议产出 push 进 issues source), then on
            // submit we WRITE the produced artifact into that DataSource:
            //  • append a version row (writeSourceVersion-style) + advance the
            //    source's monotonic `currentVersion`,
            //  • enqueue a `.ready` claimable item into the managed adapter so a
            //    downstream queue-claim consumer can claim it.
            // Each produced artifact that targets a bound slot becomes one
            // claimable item. Best-effort: a push failure must not fail submit.
            pushOutputsIntoBoundDataSources(
                &record,
                canvasId: canvasId,
                nodeId: nodeId,
                producedArtifacts: newArtifacts
            )

            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.runState = current.workflowRunState ?? state.runState
                if current.workflowRunState == .done || current.workflowRunState == .failed {
                    state.finishedAt = state.finishedAt ?? Date()
                }
                // delta-fix (codex): submit_node_output paths that park the
                // node at gateWait (executionMode=human .done, .needsReview)
                // must stamp the wait clock too. Without this the monitor
                // wait-duration stays null for those transitions.
                let isAwaiting = current.workflowRunState == .gateWait
                    || current.workflowRunState == .awaitingInput
                Self.stampAwaitingClockOnActiveAttempt(&state, isAwaiting: isAwaiting)
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
                // canvas-spec §11 dataflow legality: a downstream node only
                // becomes startable once its upstream producer is actually
                // `.done`. If the producer parked at「待确认」(gateWait, NOT
                // yet confirmed) it does NOT count as done — leave the
                // downstream node un-flipped (it stays todo / blocked-by-
                // upstream) until `confirmNodeReview` advances the producer.
                //
                // FAN-IN gate (P1, PR #109): for a node with MULTIPLE upstreams
                // (e.g. 集成 dependsOn 前端/后端/重构), the producer that just
                // routed here being done is NOT enough — flipping to
                // readyToStart now would let the FIRST branch to finish
                // auto-start 集成 before the other branches produced their
                // outputs. Require EVERY dependsOnNodeIds to be done. A
                // single-dep (linear ENG-2) chain is unaffected: its one dep is
                // the producer, so `allDependenciesDone` ≡ `producerIsDone`.
                let producerIsDone = current.workflowRunState == .done
                let targetDepsAllDone = allDependenciesDone(record.nodes[targetIndex], in: record)
                if record.nodes[targetIndex].doerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.nodes[targetIndex].status = .blocked
                    record.nodes[targetIndex].workflowRunState = .gateWait
                    mirrorIntoActiveRun(&record, nodeId: record.nodes[targetIndex].id) { state in
                        state.runState = .gateWait
                        // delta-fix (codex): stamp awaitingInputSince on the
                        // active attempt when routing parks node at gateWait.
                        // Without this the monitor wait-clock stays null for
                        // non-session gate transitions (codex P2 review).
                        Self.stampAwaitingClockOnActiveAttempt(&state, isAwaiting: true)
                    }
                } else if producerIsDone, targetDepsAllDone,
                          record.nodes[targetIndex].sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
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
                // FAN-IN gate (P1): never auto-dispatch a node until ALL of its
                // upstreams are done. Belt-and-suspenders with the readyToStart
                // flip above — a node must not auto-spawn a session on the first
                // upstream's completion.
                guard allDependenciesDone(node, in: record) else { return false }
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
    /// PR6+7 · §5.2 auto-advance attempt writer. When a node is auto-dispatched
    /// because an upstream node completed, record the attempt through the single
    /// writer with an `.autoWorkflow` origin carrying the upstream edge + attempt
    /// reference and a computed causalKey. Best-effort: no-op if there is no
    /// active run (manual canvases / preview) so it never blocks the dispatch.
    @discardableResult
    func recordAutoAdvanceAttempt(
        canvasId: String,
        nodeId: String,
        fromNodeId: String
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard activeRunIndex(in: record) != nil else { return record }
            let upstreamAttemptIndex = (activeRunNodeState(in: record, nodeId: fromNodeId)?
                .attempts.last?.index) ?? 0
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                let attemptIndex = state.attempts.count
                let lamport = self.nextLamportSeq(canvasId: canvasId)
                let causalKey = Self.causalKey(
                    canvasId: canvasId,
                    nodeId: nodeId,
                    attemptIndex: attemptIndex,
                    lamportSeq: lamport
                )
                let origin = TriggerOrigin.autoWorkflow(
                    upstreamEdgeRef: TriggerOrigin.AutoWorkflowEdgeRef(
                        canvasId: canvasId,
                        fromNodeId: fromNodeId,
                        toNodeId: nodeId
                    ),
                    upstreamAttemptId: UpstreamAttemptRef(
                        canvasId: canvasId,
                        nodeId: fromNodeId,
                        attemptIndex: upstreamAttemptIndex,
                        causalKey: causalKey
                    )
                )
                // Append directly (lamport already consumed above to feed the
                // causalKey) rather than re-entering appendAttempt's own bump.
                state.attempts.append(NodeAttempt(
                    index: attemptIndex,
                    runState: .dispatched,
                    origin: origin
                ))
            }
            recomputeActiveRun(&record)
            document.canvases[canvasId] = record
            try save(canvasId: canvasId)
            return record
        }
    }

    /// Lock-free read of a node's active-run state (caller holds the lock).
    private func activeRunNodeState(in record: CanvasRecord, nodeId: String) -> RunNodeState? {
        guard let runIdx = activeRunIndex(in: record) else { return nil }
        return record.runs[runIdx].nodeStates[nodeId]
    }

    func bindSession(
        canvasId: String,
        nodeId: String,
        sessionId: String,
        // allowReplace: 调用方(BoardAPI,掌握运行态死活)已确认旧绑定会话已死,
        // 是在「打开会话」时自愈式替换一个死 surface。此时跳过「一个节点一个活
        // 会话」守卫 —— 不变量仍成立(替换的是死的),否则死会话 runState 还停在
        // .running 的窗口里会把节点永久卡成 activeSessionExists。
        allowReplace: Bool = false
    ) throws -> CanvasRecord {
        try withLock {
            var record = try requireRecord(canvasId: canvasId)
            guard let index = record.nodes.firstIndex(where: { $0.id == nodeId }) else {
                throw PlannerCoreError.nodeNotFound(nodeId)
            }
            guard allowReplace || !hasActiveSessionLocked(nodeId: nodeId, nodes: record.nodes) else {
                throw PlannerCoreError.activeSessionExists(nodeId: nodeId)
            }
            record.nodes[index].sessionId = sessionId
            record.nodes[index].chatThreadId = sessionId
            record.nodes[index].source = .session
            record.nodes[index].workflowRunState = .running
            record.nodes[index].status = .ready
            record.events.append(event(
                canvasId: canvasId,
                type: .nodeStateChanged,
                nodeId: nodeId,
                summary: "Bound session to \(record.nodes[index].title)"
            ))
            // Mirror into the active run: a bind starts a new attempt. Q3 lock —
            // one active session per (run, node); re-binding opens a fresh attempt.
            // PR6+7: the attempt is appended through the single writer so it
            // carries a human TriggerOrigin (§5.2). A human bind is attributed
            // to the current actor (falls back to the canvas owner).
            let actorId = PlannerPermission.currentActorId() ?? record.canvas.ownerId
            let humanOrigin = TriggerOrigin.human(actorId: actorId, commentary: nil)
            mirrorIntoActiveRun(&record, nodeId: nodeId) { state in
                state.sessionId = sessionId
                state.chatThreadId = sessionId
                state.runState = .running
                state.startedAt = state.startedAt ?? Date()
                self.appendAttempt(
                    canvasId,
                    on: &state,
                    origin: humanOrigin,
                    sessionId: sessionId,
                    runState: .running
                )
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
            record.nodes[index].status = .ready
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
            if isLegacyWorkingStatus(record.nodes[index].status) {
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
            if isLegacyWorkingStatus(record.nodes[index].status) {
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
                "If output.payload_kind is artifact_ref, submit artifacts[] and set artifact.reference to the expected output slot; do not submit an artifact_ref wrapper.",
                "Inline artifact payloads must be typed objects such as {\"type\":\"json\",\"json\":\"{...}\"} or {\"type\":\"text\",\"text\":\"...\"}; do not use a bare string or {\"content\":...}.",
                "Small artifact payloads may be inline; large text/html/json/file content must be submitted as payload.file.path inside the session cwd or canvas workspace.",
                "Route messages and artifacts only to downstream nodes or owner.",
                "Output is always a full snapshot — never submit an increment / diff payload (see Node Contract v2)."
            ],
            stateSchema: node.effectiveStateSchema,
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

    /// canvas-spec §7.3 / P4 · Enrich each artifact with its slot's version
    /// position so the card can render `v{n}`. The latest-per-slot artifact (the
    /// one surfaced on the canvas) is the chain head, so its `versionIndex`
    /// equals the chain length (`versionCount`). Pure / additive — derived from
    /// `record.artifactVersions`, never persisted onto the artifact.
    /// 只读:取某画板的 nodes+proposals(给 kanban item 派生用)。不触发 mock/seed,
    /// 画板不存在 → nil。
    func canvasNodesProposals(canvasId: String) -> (nodes: [PlanningNode], proposals: [PlanProposal])? {
        withLock {
            guard let record = document.canvases[canvasId] else { return nil }
            return (record.nodes, record.proposals)
        }
    }

    func artifactsWithVersionInfo(
        _ artifacts: [PlannerArtifact],
        versions: [PlannerArtifactVersion]
    ) -> [PlannerArtifact] {
        // Chain length per slot (1-based count of versions in the slot).
        var countBySlot: [String: Int] = [:]
        for version in versions {
            countBySlot[version.artifactSlotKey, default: 0] += 1
        }
        return artifacts.map { artifact in
            var enriched = artifact
            let slotKey = artifactSlotKey(
                canvasId: artifact.canvasId,
                nodeId: artifact.nodeId,
                reference: artifact.reference
            )
            if let count = countBySlot[slotKey], count > 0 {
                // The surfaced artifact is the slot head → its index == count.
                enriched.versionCount = count
                enriched.versionIndex = count
            }
            return enriched
        }
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
                if next.views == nil {
                    next.views = existingSlot.views
                }
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
                producedBy: .agent,
                // theta (2026-05-29): carry reviewStatus from the inline draft
                // so Promote can flip review state without re-shipping payload.
                reviewStatus: draft.reviewStatus
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
        stateEncoder: JSONEncoder,
        eventEncoder: JSONEncoder,
        decoder: JSONDecoder
    ) -> (document: StoreDocument, unreadableCanvasPathComponents: Set<String>) {
        let canvasesURL = rootURL.appendingPathComponent("canvases", isDirectory: true)
        guard let canvasDirectories = try? fileManager.contentsOfDirectory(
            at: canvasesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (StoreDocument(canvases: [:]), [])
        }
        var canvases: [String: CanvasRecord] = [:]
        var unreadableCanvasPathComponents: Set<String> = []
        for directory in canvasDirectories {
            let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            let stateURL = directory.appendingPathComponent("state.json")
            guard fileManager.fileExists(atPath: stateURL.path) else {
                continue
            }
            do {
                let data = try Data(contentsOf: stateURL)
                var record = try decoder.decode(CanvasRecord.self, from: data)
                let inlineEvents = record.events
                let eventsURL = directory.appendingPathComponent("events.jsonl")
                if fileManager.fileExists(atPath: eventsURL.path) {
                    record.events = try readEvents(from: eventsURL, decoder: decoder)
                    if !inlineEvents.isEmpty {
                        let migratedData = try stateEncoder.encode(record)
                        try migratedData.write(to: stateURL, options: .atomic)
                    }
                } else if !record.events.isEmpty {
                    try writeEvents(record.events, to: eventsURL, encoder: eventEncoder)
                    let migratedData = try stateEncoder.encode(record)
                    try migratedData.write(to: stateURL, options: .atomic)
                }
                canvases[record.canvas.id] = record
            } catch {
                unreadableCanvasPathComponents.insert(directory.lastPathComponent)
                MError("[PlannerStore] failed to decode \(stateURL.path): \(error)")
            }
        }
        return (StoreDocument(canvases: canvases), unreadableCanvasPathComponents)
    }

    private static func makeStateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeEventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func readEvents(from url: URL, decoder: JSONDecoder) throws -> [PlannerEvent] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PlannerCoreError.invalidNodeOutput("events.jsonl is not UTF-8")
        }
        var events: [PlannerEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let eventData = Data(line.utf8)
            events.append(try decoder.decode(PlannerEvent.self, from: eventData))
        }
        return events
    }

    private static func writeEvents(_ events: [PlannerEvent], to url: URL, encoder: JSONEncoder) throws {
        var data = Data()
        for (index, event) in events.enumerated() {
            if index > 0 {
                data.append(0x0A)
            }
            data.append(try encoder.encode(event))
        }
        if !events.isEmpty {
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func eventLogSignature(for events: [PlannerEvent]) -> EventLogSignature {
        EventLogSignature(
            count: events.count,
            lastId: events.last?.id,
            lastCreatedAt: events.last?.createdAt
        )
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

    /// Read-time projection: stamp each node with a derived `upstreamFreshness`
    /// by comparing the upstream version it last consumed
    /// (`nodeVersions[D].inputs.upstreamVersionId`) against the upstream's
    /// current head (`nodeVersions.latest(upstream)`). Pure over the append-only
    /// `nodeVersions` log — nothing is written back. Phase 0: `upstreamVersionId`
    /// is singular (primary upstream only), so a fan-in node is checked against
    /// whichever upstream that snapshot recorded; multi-upstream coverage lands
    /// when the snapshot becomes a per-upstream list.
    private static func injectUpstreamFreshness(
        nodes: [PlanningNode],
        nodeVersions: [NodeVersion]
    ) -> [PlanningNode] {
        guard !nodeVersions.isEmpty else { return nodes }
        let versionById = Dictionary(nodeVersions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let titleById = Dictionary(nodes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return nodes.map { node in
            guard let deps = node.dependsOnNodeIds, !deps.isEmpty else { return node }
            // Only flag a node that has actually run at least once.
            guard let myRun = nodeVersions.latest(canvasId: node.canvasId, nodeId: node.id) else { return node }
            // What this run consumed (Phase 0: a single upstream version id).
            let consumed = myRun.inputs.upstreamVersionId.flatMap { versionById[$0] }
            var stale: [UpstreamFreshness.StaleUpstream] = []
            for upId in deps {
                guard let head = nodeVersions.latest(canvasId: node.canvasId, nodeId: upId) else { continue }
                // Don't flag while the newer upstream version is mid-flight —
                // only a settled (done) head counts as a real divergence.
                guard head.status == .done else { continue }
                guard let consumed, consumed.nodeId == upId else { continue }
                if consumed.id != head.id {
                    stale.append(UpstreamFreshness.StaleUpstream(
                        nodeId: upId,
                        title: titleById[upId] ?? upId,
                        consumedVersion: consumed.versionIndex,
                        latestVersion: head.versionIndex
                    ))
                }
            }
            var node = node
            node.upstreamFreshness = UpstreamFreshness(
                state: stale.isEmpty ? .fresh : .stale,
                staleUpstreams: stale
            )
            return node
        }
    }

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
        let isTemplate = boardCanvas.templateMetadata != nil
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
            // P5 · derived upstream-staleness, injected at read time only (never
            // persisted) so cards can flag "上游已更新". Same encode-only contract
            // as `nextAction`.
            injectUpstreamFreshness(nodes: nodes, nodeVersions: record.nodeVersions),
            service.readNodeState(nodes: nodes),
            record.proposals,
            access,
            PlannerActivityStore.shared.activities(
                for: record.canvas.id,
                fallback: fallbackActivity(for: record.canvas, nodes: nodes, actorId: access.actorId)
            ),
            record.events.sorted { $0.createdAt > $1.createdAt },
            // P4 · surface the per-artifact version index/count so the card
            // can render `v{n}` (derived from the slot's version chain).
            // slice 2 (kanban PM 回卷): 读时把有 subCanvasId 的 kanban item 的派生列
            // 注入 payload —— 不落库,子画板 record 从 store 只读取。
            store.artifactsWithVersionInfo(record.artifacts, versions: record.artifactVersions)
                .map { artifact in
                    service.injectDerivedKanbanColumns(
                        into: artifact,
                        resolveChild: { childId in store.canvasNodesProposals(canvasId: childId) },
                        resolveConsumption: { sourceId, itemId in
                            PlannerBoardBridge.dataSourceItemState(
                                canvasId: canvasId, sourceId: sourceId, itemId: itemId
                            )
                        }
                    )
                },
            graphEdges(for: nodes)
        )
    }

    static func graphState(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        try BoardPerfProbe.shared.measure(
            "planner.graphState",
            title: "PlannerBoardBridge.graphState",
            category: "planner",
            detail: "canvas=\(String(canvasId.prefix(24)))"
        ) {
            let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
            let render = try store.renderProfileState(canvasId: canvasId)
            return PlannerGraphState(
                canvas: state.canvas,
                nodes: state.nodes,
                states: state.states,
                proposals: state.proposals,
                access: state.access,
                activities: state.activities,
                events: state.events,
                artifacts: state.artifacts,
                edges: state.edges,
                renderProfile: render.profile,
                renderProfileStatus: render.status,
                renderObjects: render.objects,
                renderRelations: render.relations,
                canvasRuntime: canvasRuntimeView(
                    canvasId: canvasId,
                    canvas: state.canvas,
                    nodes: state.nodes,
                    states: state.states,
                    artifacts: state.artifacts,
                    edges: state.edges
                )
            )
        }
    }

    static func teamSyncGraphPayload(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> Any {
        _ = try requireCanvas(canvasId, in: snapshot)
        let record = try store.canvasRecordForBridge(canvasId: canvasId)
        let access = PlannerPermission.access(for: record.canvas, nodes: record.nodes, actorId: actorUserId)
        try requireCanvasVisible(record.canvas, access: access)
        var artifacts = store.artifactsWithVersionInfo(record.artifacts, versions: record.artifactVersions)
        for idx in artifacts.indices {
            artifacts[idx].payload = nil
        }
        let state = PlannerGraphState(
            canvas: record.canvas,
            nodes: record.nodes,
            states: service.readNodeState(nodes: record.nodes),
            proposals: record.proposals,
            access: access,
            activities: PlannerActivityStore.shared.activities(
                for: record.canvas.id,
                fallback: fallbackActivity(for: record.canvas, nodes: record.nodes, actorId: access.actorId)
            ),
            events: record.events.sorted { $0.createdAt > $1.createdAt },
            artifacts: artifacts,
            edges: graphEdges(for: record.nodes),
            canvasRuntime: nil
        )
        let envelope = PlannerGraphStateEnvelope(
            canvas: state.canvas,
            nodes: state.nodes,
            states: state.states,
            proposals: state.proposals,
            access: state.access,
            activities: state.activities,
            events: state.events,
            artifacts: state.artifacts,
            edges: state.edges,
            nodeAssignments: nodeAssignments(for: state),
            canEditInternals: state.access.role == .owner
        )
        return try jsonObject(envelope)
    }

    @discardableResult
    static func importRemoteGraph(_ raw: Any, localCanvasId: String) -> Bool {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let graph = try? decoder.decode(PlannerGraphState.self, from: data) else {
            return false
        }
        do {
            try store.importGraphState(graph, localCanvasId: localCanvasId)
            return true
        } catch {
            MWarn("[PlannerBoardBridge] failed to import remote graph for \(localCanvasId): \(error)")
            return false
        }
    }

    private static func nodeAssignments(for state: PlannerGraphState) -> [NodeAssignmentDTO] {
        let teamId = UserDefaults.standard.string(forKey: "meee2TeamId") ?? ""
        return state.nodes.compactMap { node in
            guard let subCanvasId = node.subCanvasId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !subCanvasId.isEmpty else {
                return nil
            }
            let contract = NodeContractV2.derive(from: node).contract
            return NodeAssignmentDTO(
                sourceCanvasId: state.canvas.id,
                sourceNodeId: node.id,
                assigneeUserId: node.doerId,
                subCanvasId: subCanvasId,
                subCanvasName: subCanvasId,
                frozenIOContract: contract,
                billingTeamId: teamId,
                sessionCountRebound: nil,
                assignedAt: nil
            )
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Build the read-only `CanvasRuntimeView` (canvas-spec §7.2) for a canvas
    /// from its resolved graph pieces. Reads the active run's attempt history
    /// (empty when no run is active) and per-DataSource queue depths. Best-effort
    /// — never throws; a record-fetch failure yields a snapshot with no attempts
    /// rather than failing the whole graph-state read.
    private static func canvasRuntimeView(
        canvasId: String,
        canvas: PlanningCanvas,
        nodes: [PlanningNode],
        states: [NodeStateSnapshot],
        artifacts: [PlannerArtifact],
        edges: [PlannerGraphEdge]
    ) -> CanvasRuntimeView {
        var attemptsByNode: [String: [NodeAttempt]] = [:]
        if let record = try? store.canvasRecordForBridge(canvasId: canvasId),
           let runId = record.activeRunId,
           let run = record.runs.first(where: { $0.id == runId }) {
            for (nodeId, nodeState) in run.nodeStates {
                attemptsByNode[nodeId] = nodeState.attempts
            }
        }
        return PlannerBoardBridge.buildCanvasRuntimeView(
            canvasId: canvasId,
            nodes: nodes,
            states: states,
            artifacts: artifacts,
            edges: canvas.edges,
            dataSources: canvas.dataSources,
            attemptsByNode: attemptsByNode
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
            title: title.isEmpty ? "Generated Meee2 AI node" : title,
            schema: NodeSchema(
                inputs: ["owner goal", "Meee2 AI context"],
                outputs: ["executable node output"],
                goal: "owner approves generated proposal"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "Meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .human,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .ready
        )
        return try PlanProposal(
            id: "proposal-\(canvas.id)-generate-\(proposalUUID)",
            canvasId: canvas.id,
            summary: "Generate Meee2 AI graph for \(canvas.title)",
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
                ? "Generate Meee2 AI graph for \(state.canvas.title)"
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
                ? "Update Meee2 AI graph"
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

    /// proposal 子功能 · propose_add_node:运行节点的工作会话提议新增一个 step。
    ///
    /// 与 `graphChangeProposal`(owner-only `.createProposal`)不同,这里按
    /// **发起节点** 做 `requireNodeUpdate` 门控 —— doer 可从自己的节点发起
    /// (职责≡权限),但产物仍是 pending 提案,必须 owner approve+apply 才落图。
    /// 校验失败往上抛,MCP 层原样透传给 agent 自纠
    /// (meee2-ai-is-claude-harness-self-correct)。
    ///
    /// 新节点默认 `dependsOnNodeIds = [originNodeId]`(画布上呈现 主→子 边,
    /// 调用方可显式传 `[]` 表示无依赖),执行皮肤(executionMode / executorType /
    /// doer)继承发起节点 —— triage 类主节点孵化出的子 step 默认同一执行形态。
    static func proposeAddNode(
        originNodeId: String,
        originSessionId: String?,
        title: String,
        goal: String?,
        summary: String?,
        dependsOnNodeIds: [String]?,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let origin = state.nodes.first(where: { $0.id == originNodeId }) else {
            throw PlannerCoreError.nodeNotFound(originNodeId)
        }
        try PlannerPermission.requireNodeUpdate(on: origin, access: state.access)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw PlannerCoreError.invalidNodeOutput("propose_add_node requires a non-empty title for the new step")
        }
        let trimmedGoal = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposalUUID = UUID().uuidString.lowercased()
        let node = PlanningNode(
            id: "\(canvasId)-node-\(proposalUUID)",
            canvasId: canvasId,
            title: trimmedTitle,
            schema: NodeSchema(
                inputs: [origin.title],
                outputs: ["\(trimmedTitle) output"],
                goal: (trimmedGoal?.isEmpty == false ? trimmedGoal! : trimmedTitle)
            ),
            contextSources: [],
            executionMode: origin.executionMode,
            executorType: origin.executorType,
            doerId: origin.doerId,
            status: .ready,
            source: .session,
            dependsOnNodeIds: dependsOnNodeIds ?? [originNodeId],
            nodeKind: .step
        )
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        var proposal = PlanProposal(
            id: "proposal-\(canvasId)-node-\(proposalUUID)",
            canvasId: canvasId,
            summary: (trimmedSummary?.isEmpty == false ? trimmedSummary! : "Add step \"\(trimmedTitle)\" (proposed from node \(origin.title))"),
            changes: [.addNode(node)],
            status: .pending
        )
        proposal.originNodeId = originNodeId
        proposal.originSessionId = originSessionId
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
        actorUserId: String? = nil,
        allowReplace: Bool = false
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        // bind-session is a node execution-state mutation: owner anywhere, doer
        // only on their own node, viewer denied.
        try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        _ = try store.bindSession(canvasId: canvasId, nodeId: nodeId, sessionId: sessionId, allowReplace: allowReplace)
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
        try validateArtifactReadback([artifact])
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    /// Direct artifact-layer read — heads matching artifactId / reference.
    /// 读权限即画布访问权限(canvasState 已校验 viewer 起步)。
    static func findArtifacts(
        artifactId: String? = nil,
        reference: String? = nil,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> [PlannerArtifact] {
        _ = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        return try store.findArtifacts(canvasId: canvasId, artifactId: artifactId, reference: reference)
    }

    /// Direct artifact-layer write — 不经节点状态机(见 store.updateArtifact)。
    /// 权限对齐 attach:对每个命中槽位所属的节点要求 node-update 权限
    /// (owner 任意,doer 仅自己的节点,viewer 拒绝)。payload 走与 attach
    /// 同一套 blob 归一化,按各槽位自己的 artifactId 落 blob。
    static func updateArtifact(
        artifactId: String? = nil,
        reference: String? = nil,
        title: String? = nil,
        status: String? = nil,
        payload: BoardJSONValue? = nil,
        submittedByKind: PlannerArtifactVersionSubmitterKind = .human,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> [PlannerArtifact] {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        let targets = try store.findArtifacts(canvasId: canvasId, artifactId: artifactId, reference: reference)
        guard !targets.isEmpty else {
            throw PlannerCoreError.artifactNotFound(artifactId ?? reference ?? "(no selector)")
        }
        for target in targets {
            guard let node = state.nodes.first(where: { $0.id == target.nodeId }) else { continue }
            try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        }
        let workspacePath = try? BoardLayoutStore.shared.workspacePath(canvasId: canvasId)
        var updated: [PlannerArtifact] = []
        for target in targets {
            let normalizedPayload = try payload.flatMap {
                try PlannerArtifactStorage.normalizePayload(
                    $0,
                    canvasId: canvasId,
                    artifactId: target.id,
                    workspacePath: workspacePath
                )
            }
            updated += try store.updateArtifact(
                canvasId: canvasId,
                artifactId: target.id,
                title: title,
                status: status,
                payload: normalizedPayload,
                submittedBy: actorUserId,
                submittedByKind: submittedByKind
            )
        }
        try validateArtifactReadback(updated)
        return updated
    }

    static func updateArtifactViews(
        artifactId: String? = nil,
        reference: String? = nil,
        views: [PlannerArtifactView],
        deleteViewIds: [String] = [],
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> [PlannerArtifact] {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        let targets = try store.findArtifacts(canvasId: canvasId, artifactId: artifactId, reference: reference)
        guard !targets.isEmpty else {
            throw PlannerCoreError.artifactNotFound(artifactId ?? reference ?? "(no selector)")
        }
        for target in targets {
            guard let node = state.nodes.first(where: { $0.id == target.nodeId }) else { continue }
            try PlannerPermission.requireNodeUpdate(on: node, access: state.access)
        }
        return try store.updateArtifactViews(
            canvasId: canvasId,
            artifactId: artifactId,
            reference: reference,
            views: views,
            deleteViewIds: deleteViewIds,
            submittedBy: actorUserId
        )
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
        guard status.rawValue != "working" else {
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

    /// canvas-spec §8 / §11 · Owner confirm/approve of a node parked at
    /// 「待确认」(awaiting-review). Execution-layer action (applies directly,
    /// like dispatch): flips the node to `.done` and unblocks downstream. The
    /// board UI button is a separate task — this is the bridge it calls.
    static func confirmNodeReview(
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
        _ = try store.confirmNodeReview(canvasId: canvasId, nodeId: nodeId)
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
        actorUserId: String? = nil,
        submittedByKind: PlannerArtifactVersionSubmitterKind = .agent,
        submittedBy: String? = nil
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
        let submitted = try store.submitNodeOutput(
            canvasId: canvasId,
            nodeId: nodeId,
            output: normalizedOutput,
            submittedByKind: submittedByKind,
            submittedBy: submittedBy
        )
        try validateArtifactReadback(submitted.record.artifacts.filter { artifact in
            normalizedOutput.artifacts.contains { outputArtifact in
                artifact.nodeId == nodeId
                    && artifact.reference.trimmingCharacters(in: .whitespacesAndNewlines)
                        == outputArtifact.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        })
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
                // PR6+7 · §5.2: an auto-dispatch is a workflow-driven attempt.
                // Record it through the single attempt writer with an
                // `.autoWorkflow` origin (upstream = the node that just
                // submitted). Best-effort — never block the dispatch.
                _ = try? store.recordAutoAdvanceAttempt(
                    canvasId: canvasId,
                    nodeId: candidate.id,
                    fromNodeId: nodeId
                )
                autoIds.append(candidate.id)
            } catch {
                MLog("[ENG-2][auto-dispatch] skip node=\(candidate.id) reason=\(error.localizedDescription)")
            }
        }
        let graph = try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        let requirementHint = graph.nodes
            .first(where: { $0.id == nodeId })
            .flatMap { node in
                artifactRequirementHint(
                    for: node,
                    artifacts: graph.artifacts.filter { $0.nodeId == nodeId }
                )
            }
        // external-first writeback: on a downstream-gating submit (`.done`),
        // reconcile the mirror of every external-object reference this submit
        // wrote — the agent wrote the real object external-first, so meee2 pulls
        // the authoritative snapshot back. Driven by the artifacts ACTUALLY
        // submitted (not just declared slots) so we only reconcile what changed.
        // A custom stateSchema's gatesDownstream state is already folded to
        // `.done` by the BoardAPI handler before decode, so `.done` covers both.
        // blocked / needs_review never reach here — the external write likely
        // didn't happen, and an empty list spawns no sync session.
        var reconcileRefs: [String] = []
        if output.status == .done {
            var seen = Set<String>()
            for artifact in normalizedOutput.artifacts {
                let ref = artifact.reference.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty,
                      NodeContractV2.externalWriteConnector(forOutputRef: ref) != nil,
                      seen.insert(ref).inserted
                else { continue }
                reconcileRefs.append(ref)
            }
        }
        return PlannerNodeOutputResult(
            graph: graph,
            routes: submitted.routes,
            hint: requirementHint,
            versionId: submitted.version?.id,
            versionIndex: submitted.version?.versionIndex,
            autoDispatchedNodeIds: autoIds.isEmpty ? nil : autoIds,
            reconcileReferences: reconcileRefs.isEmpty ? nil : reconcileRefs
        )
    }

    private static func validateArtifactReadback(_ artifacts: [PlannerArtifact]) throws {
        for artifact in artifacts {
            _ = try PlannerArtifactStorage.content(for: artifact)
        }
    }

    private static func artifactRequirementHint(for node: PlanningNode, artifacts: [PlannerArtifact]) -> String? {
        let expectedOutputs = uniqueRequirementTokens(node.schema.outputs)
        let requiredRefs = uniqueRequirementTokens(node.gate?.requiredArtifactRefs ?? [])
        let missingOutputs = expectedOutputs.filter { expected in
            !artifacts.contains { artifactSatisfiesExpectation($0, expected) }
        }
        let missingRefs = requiredRefs.filter { required in
            !artifacts.contains { artifactSatisfiesRequiredRef($0, required) }
        }
        let missing = missingOutputs + missingRefs
        guard !missing.isEmpty else { return nil }
        return "Artifact requirements still missing for \(node.title): \(missing.prefix(6).joined(separator: ", "))\(missing.count > 6 ? " and \(missing.count - 6) more" : "")."
    }

    private static func artifactSatisfiesExpectation(_ artifact: PlannerArtifact, _ expectation: String) -> Bool {
        let expected = normalizeRequirementToken(expectation)
        guard !expected.isEmpty else { return false }
        return artifactRequirementCandidates(artifact).contains { candidate in
            let normalized = normalizeRequirementToken(candidate)
            guard !normalized.isEmpty else { return false }
            return normalized == expected || normalized.contains(expected) || expected.contains(normalized)
        }
    }

    private static func artifactSatisfiesRequiredRef(_ artifact: PlannerArtifact, _ requiredRef: String) -> Bool {
        sameRequirement(artifact.reference, requiredRef)
            || sameRequirement(artifact.title, requiredRef)
            || artifactSatisfiesExpectation(artifact, requiredRef)
    }

    private static func artifactRequirementCandidates(_ artifact: PlannerArtifact) -> [String] {
        uniqueRequirementTokens([
            artifact.kind.rawValue,
            artifact.reference,
            artifact.title,
            artifact.status
        ] + artifactPayloadTextCandidates(artifact.payload))
    }

    private static func artifactPayloadTextCandidates(_ payload: BoardJSONValue?) -> [String] {
        guard let payload else { return [] }
        switch payload {
        case .string(let value):
            return [value]
        case .array(let values):
            return values.flatMap { artifactPayloadTextCandidates($0) }
        case .object(let object):
            let directKeys = ["summary", "description", "content", "text", "markdown", "html", "json"]
            let nestedKeys = ["result", "output", "evidence", "payload"]
            let direct = directKeys.compactMap { object[$0]?.stringValue }
            let nested = nestedKeys.flatMap { artifactPayloadTextCandidates(object[$0]) }
            return direct + nested
        case .null, .bool, .number:
            return []
        }
    }

    private static func sameRequirement(_ left: String, _ right: String) -> Bool {
        normalizeRequirementToken(left) == normalizeRequirementToken(right)
    }

    private static func normalizeRequirementToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[\s_-]+"#, with: "-", options: .regularExpression)
    }

    private static func uniqueRequirementTokens(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeRequirementToken(trimmed)
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
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
        _ = try store.patchRenderValues(
            canvasId: canvasId,
            objectValues: [
                "node:\(nodeId)": CanvasRenderObjectValues(
                    x: layout.x,
                    y: layout.y,
                    width: layout.width,
                    height: layout.height,
                    zIndex: nil,
                    hidden: nil,
                    collapsed: nil,
                    pinned: nil,
                    rendererVariant: nil,
                    density: nil,
                    icon: nil,
                    designToken: nil
                )
            ],
            relationValues: [:],
            renderOnlyObjects: nil
        )
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
            summary: "Meee2 AI detected drift for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs attention)", status: .ready)
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
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], states: [NodeStateSnapshot], edges: [PlannerGraphEdge], artifacts: [PlannerArtifact]) {
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
        return (approved, nodes, service.readNodeState(nodes: nodes), graphEdges(for: nodes), preview.artifacts)
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
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], states: [NodeStateSnapshot], edges: [PlannerGraphEdge], artifacts: [PlannerArtifact], canvas: PlanningCanvas) {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.applyProposal, access: state.access)
        let record = try store.applyProposal(proposalId: proposalId, canvasId: canvasId, service: service)
        guard let proposal = record.proposals.first(where: { $0.id == proposalId }) else {
            throw PlannerCoreError.proposalNotFound(proposalId)
        }
        // `canvas` carries the post-apply 5-atom collections (dataSources /
        // edges / monitorSpec) so callers can read the governance result
        // directly without a second canvasState round-trip.
        return (proposal, record.nodes, service.readNodeState(nodes: record.nodes), graphEdges(for: record.nodes), record.artifacts, record.canvas)
    }

    static func workspaceMonitor(
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil,
        sessions: [SessionDTO]? = nil
    ) throws -> PlannerMonitorState {
        var items: [PlannerMonitorItem] = []
        for boardCanvas in snapshot.canvases {
            guard boardCanvas.kind != .monitor else { continue }
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
            let eventDateIndex = PlannerEventDateIndex(events: state.events)

            // Pluck the live attempt's awaitingInputSince from the active run
            // (if any) so the monitor can boost stale-awaiting items and the
            // UI can render "等了 X 小时". Only the last attempt of the
            // active run's per-node state carries the clock; older attempts
            // are immutable.
            let activeRun = runs.first(where: { $0.status == .active })
            if let canvasItem = monitorCanvasItem(
                canvas: state.canvas,
                nodes: visibleNodes,
                statesByNodeId: statesByNodeId,
                runs: runs,
                artifactsByNodeId: artifactsByNodeId,
                eventDateIndex: eventDateIndex,
                actorId: actorId,
                role: state.access.role,
                sessions: sessions,
                activeRun: activeRun
            ) {
                items.append(canvasItem)
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
                        updatedAt: eventDateIndex.latest(proposalId: proposal.id)
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

    private static func monitorCanvasItem(
        canvas: PlanningCanvas,
        nodes: [PlanningNode],
        statesByNodeId: [String: NodeStateSnapshot],
        runs: [WorkflowRun],
        artifactsByNodeId: [String: [PlannerArtifact]],
        eventDateIndex: PlannerEventDateIndex,
        actorId: String,
        role: PlannerCanvasRole,
        sessions: [SessionDTO]?,
        activeRun: WorkflowRun?
    ) -> PlannerMonitorItem? {
        let visibleStates = nodes.compactMap { node -> (node: PlanningNode, state: NodeStateSnapshot)? in
            guard let state = statesByNodeId[node.id] else { return nil }
            return (node, state)
        }
        let visibleRuns = runs.filter { run in
            role != .doer || run.nodeStates.values.contains { $0.assigneeId == actorId }
        }
        guard !nodes.isEmpty || !visibleRuns.isEmpty else { return nil }

        let unfinishedStates = visibleStates.filter { $0.state.runState != NodeRunState.done }
        let candidateStates = unfinishedStates.isEmpty ? visibleStates : unfinishedStates
        let nodeRank = candidateStates.map { monitorRank(for: $0.state) }.min() ?? 5
        let runRank = visibleRuns.map { run -> Int in
            let hasAttention = run.nodeStates.values.contains { state in
                state.runState == PlannerWorkflowRunState.failed
                    || state.runState == PlannerWorkflowRunState.gateWait
                    || state.runState == PlannerWorkflowRunState.awaitingInput
            }
            if hasAttention {
                return 1
            }
            return run.status == .active ? 3 : 5
        }.min() ?? 5
        let rank = min(nodeRank, runRank)
        let candidateNodeStates = candidateStates.map { $0.state }
        let runState = canvasRunState(for: candidateNodeStates, fallbackRank: rank)
        let blockers = Array(visibleStates.flatMap { $0.state.blockers }.prefix(3))
        let nodeNeedsOwnerReview = visibleStates.contains { $0.state.needsOwnerReview }
        let runNeedsOwnerReview = visibleRuns.contains { run in
            run.nodeStates.values.contains { state in
                state.runState == PlannerWorkflowRunState.failed
                    || state.runState == PlannerWorkflowRunState.gateWait
                    || state.runState == PlannerWorkflowRunState.awaitingInput
                }
        }
        let needsOwnerReview = nodeNeedsOwnerReview || runNeedsOwnerReview
        let nodeEvidenceCount = visibleStates.reduce(0) { total, pair in
            total + (pair.node.artifactRefs ?? []).count + (artifactsByNodeId[pair.node.id]?.count ?? 0)
        }
        let runEvidenceCount = visibleRuns.reduce(0) { total, run in
            let runArtifacts = run.nodeStates.values.reduce(0) { subtotal, state in
                subtotal + state.artifactIds.count
            }
            return total + runArtifacts
        }
        let evidenceCount = nodeEvidenceCount + runEvidenceCount
        let latestRunUpdate = visibleRuns.map { $0.updatedAt }.max()
        let latestNodeUpdate = visibleStates.compactMap { pair in
            eventDateIndex.latest(nodeId: pair.node.id) ?? pair.node.outputSubmittedAt
        }.max()
        let updatedAt = [
            latestRunUpdate,
            latestNodeUpdate
        ].compactMap { $0 }.max()
        let doneCount = visibleStates.filter { $0.state.runState == NodeRunState.done }.count
        let totalCount = max(visibleStates.count, nodes.count)
        return PlannerMonitorItem(
            id: "canvas-\(canvas.id)",
            kind: .delivery,
            canvasId: canvas.id,
            canvasTitle: canvas.title,
            nodeId: nil,
            nodeTitle: nil,
            sessionId: nil,
            deliveryId: canvas.id,
            proposalId: nil,
            proposalStatus: nil,
            summary: canvas.title,
            runState: runState,
            blockers: blockers,
            needsOwnerReview: needsOwnerReview,
            doerId: role == .doer ? actorId : nil,
            riskRank: rank,
            evidenceCount: evidenceCount,
            updatedAt: updatedAt,
            nextAction: "\(doneCount)/\(totalCount) nodes",
            awaitingInputSince: canvasAwaitingInputSince(nodes: nodes, activeRun: activeRun)
        )
    }

    private static func canvasRunState(for states: [NodeStateSnapshot], fallbackRank: Int) -> NodeRunState? {
        if states.contains(where: { $0.runState == .blocked }) { return .blocked }
        if states.contains(where: { $0.runState == .working }) { return .working }
        if states.contains(where: { $0.runState == .draft }) { return .draft }
        if states.contains(where: { $0.runState == .ready }) { return .ready }
        if states.contains(where: { $0.runState == .done }) { return .done }
        switch fallbackRank {
        case 0:
            return .blocked
        case 1...3:
            return .working
        case 4:
            return .ready
        default:
            return nil
        }
    }

    private static func canvasAwaitingInputSince(nodes: [PlanningNode], activeRun: WorkflowRun?) -> Date? {
        guard let activeRun else { return nil }
        return nodes
            .compactMap { activeRun.nodeStates[$0.id]?.attempts.last?.awaitingInputSince }
            .min()
    }

    private static func monitorSession(_ session: SessionDTO, matches sessionId: String) -> Bool {
        var candidates = [session.id]
        let prefix = "\(session.pluginId)-"
        if session.id.hasPrefix(prefix) {
            candidates.append(String(session.id.dropFirst(prefix.count)))
        }
        if let surfaceId = session.surfaceId,
           !surfaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(surfaceId)
        }
        return candidates.contains { candidate in
            candidate == sessionId
                || candidate.hasSuffix("-\(sessionId)")
                || sessionId.hasSuffix("-\(candidate)")
        }
    }

    private struct PlannerEventDateIndex {
        private var latestByNodeId: [String: Date] = [:]
        private var latestByProposalId: [String: Date] = [:]

        init(events: [PlannerEvent]) {
            for event in events {
                if let nodeId = event.nodeId {
                    latestByNodeId[nodeId] = max(latestByNodeId[nodeId] ?? event.createdAt, event.createdAt)
                }
                if let proposalId = event.proposalId {
                    latestByProposalId[proposalId] = max(latestByProposalId[proposalId] ?? event.createdAt, event.createdAt)
                }
            }
        }

        func latest(nodeId: String) -> Date? {
            latestByNodeId[nodeId]
        }

        func latest(proposalId: String) -> Date? {
            latestByProposalId[proposalId]
        }
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
            plannerContext: "canvas:\(canvas.id)",
            visibility: canvas.scope == .team ? .public : .private
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
            node.doerId == actorId && (isLegacyWorkingStatus(node.status) || node.status == .blocked || isLegacyDraftStatus(node.status))
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
    /// - `dead` → `pending` sentinel; applySessionRunStateLocked treats this
    ///   as an ended bound session and keeps the session id so UI can resume.
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
            return .pending
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
            status: .ready,
            dependsOnNodeIds: [node.id]
        )
        return PlanProposal(
            id: "proposal-\(node.id)-refine\(suffix)",
            canvasId: node.canvasId,
            summary: "Refine \(node.title)",
            changes: [
                .updateNode(id: node.id, status: .ready),
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
            releaseAutomationStep(
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

    private static func releaseAutomationStep(
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
            doerId: "release-automation",
            status: .ready,
            dependsOnNodeIds: dependsOn.map { "\(canvas.id)-\($0)" },
            nodeKind: .step,
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
                    status: .ready,
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
            status: .ready,
            dependsOnNodeIds: [node.id]
        )
        let blockerSummary = state.blockers.isEmpty ? "blocked state" : state.blockers.joined(separator: "; ")
        return PlanProposal(
            id: "proposal-\(node.id)-split",
            canvasId: node.canvasId,
            summary: "Split \(node.title) because \(blockerSummary)",
            changes: [
                .updateNode(id: node.id, status: .ready),
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
            title: goal.isEmpty ? "Generated Meee2 AI node" : goal,
            schema: NodeSchema(
                inputs: ["owner goal"],
                outputs: ["first executable output"],
                goal: "complete the generated node"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "Meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .human,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .ready
        )
        return PlanProposal(
            id: "proposal-\(canvas.id)-generate",
            canvasId: canvas.id,
            summary: "Generate initial Meee2 AI graph for \(canvas.title)",
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
            summary: "Meee2 AI detected drift for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs attention)", status: .ready)
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
        var proposal = try PlannerProposalValidator.decodeProposal(from: output)
        try PlannerProposalValidator.validate(&proposal, canvas: canvas, nodes: [])
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
        var proposal = try PlannerProposalValidator.decodeProposal(from: output)
        try PlannerProposalValidator.validate(&proposal, canvas: canvas, nodes: [node])
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
        var proposal = try PlannerProposalValidator.decodeProposal(from: output)
        try PlannerProposalValidator.validate(&proposal, canvas: canvas, nodes: nodes)
        return proposal
    }
}

enum PlannerPromptFactory {
    static let systemPrompt = """
    You are Meee2 AI. Return only strict JSON for PlanProposal, or null when no proposal is needed.
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
