import Foundation
import Meee2PluginKit

struct PlanningCanvas: Codable, Equatable {
    var id: String
    var ownerId: String
    var title: String
    var plannerContext: String
}

struct IOSchema: Codable, Equatable {
    var consumes: [String]
    var produces: [String]
    var completionSignal: String
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

enum ExecutionMode: String, Codable, Equatable {
    case auto
    case signOff = "sign-off"
    case human
}

enum ExecutorType: String, Codable, Equatable {
    case claude
    case codex
    case cursor
    case openClaw
    case devin
    case human
    case mock
}

enum PlanningNodeStatus: String, Codable, Equatable {
    case waiting
    case running
    case blocked
    case done
    case planning
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
    case dispatched
    case running
    case gateWait = "gate-wait"
    case done
    case failed
}

struct PlannerNodeTrigger: Codable, Equatable {
    var type: String
    var label: String
    var eventSource: String?
}

struct PlannerNodeGate: Codable, Equatable {
    var type: String
    var label: String
    var requiredArtifactRefs: [String]
    var approvers: [String]
    var onFailGotoNodeId: String?
}

enum PlannerDispatchRunner: String, Codable, Equatable {
    case byoaLocal = "byoa-local"
    case ciAgent = "ci-agent"
    case human
}

struct PlannerNodeDispatch: Codable, Equatable {
    var runner: PlannerDispatchRunner
    var skill: String?
    var actor: String
    var command: String?
    var fallbackRunner: PlannerDispatchRunner?
}

enum PlannerArtifactKind: String, Codable, Equatable {
    case ideaDraft = "idea-draft"
    case prd
    case implPR = "impl-pr"
    case prereleaseVerdict = "prerelease-verdict"
    case mainMerge = "main-merge"
    case larkDoc = "lark-doc"
    case checkResult = "check-result"
    case generic
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
    var ioSchema: IOSchema
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
    var gate: PlannerNodeGate?
    var dispatch: PlannerNodeDispatch?
    var approvers: [String]?
    var artifactRefs: [String]?
    var eventRefs: [String]?
    var workflowRunState: PlannerWorkflowRunState?

    init(
        id: String,
        canvasId: String,
        title: String,
        ioSchema: IOSchema,
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
        gate: PlannerNodeGate? = nil,
        dispatch: PlannerNodeDispatch? = nil,
        approvers: [String]? = nil,
        artifactRefs: [String]? = nil,
        eventRefs: [String]? = nil,
        workflowRunState: PlannerWorkflowRunState? = nil
    ) {
        self.id = id
        self.canvasId = canvasId
        self.title = title
        self.ioSchema = ioSchema
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
        self.gate = gate
        self.dispatch = dispatch
        self.approvers = approvers
        self.artifactRefs = artifactRefs
        self.eventRefs = eventRefs
        self.workflowRunState = workflowRunState
    }
}

enum PlanProposalStatus: String, Codable, Equatable {
    case pending
    case approved
    case applied
    case rejected
}

struct PlanChange: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case addNode
        case updateNode
    }

    var kind: Kind
    var node: PlanningNode?
    var nodeId: String?
    var title: String?
    var status: PlanningNodeStatus?
    var ioSchema: IOSchema?
    var contextSources: [ContextSource]?
    var dependsOnNodeIds: [String]?
    var subCanvasId: String?
    var nodeKind: PlanningNodeKind?
    var layout: PlannerNodeLayout?
    var trigger: PlannerNodeTrigger?
    var gate: PlannerNodeGate?
    var dispatch: PlannerNodeDispatch?
    var approvers: [String]?
    var artifactRefs: [String]?
    var eventRefs: [String]?
    var workflowRunState: PlannerWorkflowRunState?
    var sessionId: String?
    var chatThreadId: String?
    var source: PlanningNodeSource?

    init(
        kind: Kind,
        node: PlanningNode?,
        nodeId: String?,
        title: String?,
        status: PlanningNodeStatus?,
        ioSchema: IOSchema? = nil,
        contextSources: [ContextSource]? = nil,
        dependsOnNodeIds: [String]? = nil,
        subCanvasId: String? = nil,
        nodeKind: PlanningNodeKind? = nil,
        layout: PlannerNodeLayout? = nil,
        trigger: PlannerNodeTrigger? = nil,
        gate: PlannerNodeGate? = nil,
        dispatch: PlannerNodeDispatch? = nil,
        approvers: [String]? = nil,
        artifactRefs: [String]? = nil,
        eventRefs: [String]? = nil,
        workflowRunState: PlannerWorkflowRunState? = nil,
        sessionId: String? = nil,
        chatThreadId: String? = nil,
        source: PlanningNodeSource? = nil
    ) {
        self.kind = kind
        self.node = node
        self.nodeId = nodeId
        self.title = title
        self.status = status
        self.ioSchema = ioSchema
        self.contextSources = contextSources
        self.dependsOnNodeIds = dependsOnNodeIds
        self.subCanvasId = subCanvasId
        self.nodeKind = nodeKind
        self.layout = layout
        self.trigger = trigger
        self.gate = gate
        self.dispatch = dispatch
        self.approvers = approvers
        self.artifactRefs = artifactRefs
        self.eventRefs = eventRefs
        self.workflowRunState = workflowRunState
        self.sessionId = sessionId
        self.chatThreadId = chatThreadId
        self.source = source
    }

    static func addNode(_ node: PlanningNode) -> PlanChange {
        PlanChange(kind: .addNode, node: node, nodeId: nil, title: nil, status: nil)
    }

    static func updateNode(
        id: String,
        title: String? = nil,
        status: PlanningNodeStatus? = nil,
        ioSchema: IOSchema? = nil,
        contextSources: [ContextSource]? = nil,
        dependsOnNodeIds: [String]? = nil,
        subCanvasId: String? = nil,
        nodeKind: PlanningNodeKind? = nil,
        layout: PlannerNodeLayout? = nil,
        trigger: PlannerNodeTrigger? = nil,
        gate: PlannerNodeGate? = nil,
        dispatch: PlannerNodeDispatch? = nil,
        approvers: [String]? = nil,
        artifactRefs: [String]? = nil,
        eventRefs: [String]? = nil,
        workflowRunState: PlannerWorkflowRunState? = nil,
        sessionId: String? = nil,
        chatThreadId: String? = nil,
        source: PlanningNodeSource? = nil
    ) -> PlanChange {
        PlanChange(
            kind: .updateNode,
            node: nil,
            nodeId: id,
            title: title,
            status: status,
            ioSchema: ioSchema,
            contextSources: contextSources,
            dependsOnNodeIds: dependsOnNodeIds,
            subCanvasId: subCanvasId,
            nodeKind: nodeKind,
            layout: layout,
            trigger: trigger,
            gate: gate,
            dispatch: dispatch,
            approvers: approvers,
            artifactRefs: artifactRefs,
            eventRefs: eventRefs,
            workflowRunState: workflowRunState,
            sessionId: sessionId,
            chatThreadId: chatThreadId,
            source: source
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
    case waiting
    case running
    case blocked
    case done
    case planning
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
    case proposalCreated = "proposal.created"
    case proposalApproved = "proposal.approved"
    case proposalApplied = "proposal.applied"
    case proposalRejected = "proposal.rejected"
    case artifactAttached = "artifact.attached"
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
}

struct PlannerMonitorItem: Codable, Equatable {
    var id: String
    var kind: PlannerMonitorItemKind
    var canvasId: String
    var canvasTitle: String
    var nodeId: String?
    var nodeTitle: String?
    var proposalId: String?
    var proposalStatus: PlanProposalStatus?
    var summary: String
    var runState: NodeRunState?
    var blockers: [String]
    var needsOwnerReview: Bool
    var doerId: String?
    var riskRank: Int
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
    case permissionDenied(action: String, role: PlannerCanvasRole)

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
        case .permissionDenied(let action, let role):
            return "meee2 AI \(action) is not allowed for \(role.rawValue)"
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
}

enum PlannerProposalValidator {
    static func decodeProposal(from rawOutput: String) throws -> PlanProposal {
        let decoder = JSONDecoder()
        for candidate in jsonCandidates(from: rawOutput) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let proposal = try? decoder.decode(PlanProposal.self, from: data) {
                return proposal
            }
        }
        throw PlannerCoreError.invalidPlannerProposalJSON
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

        let nodeIds = Set(nodes.map(\.id))
        for change in proposal.changes {
            switch change.kind {
            case .addNode:
                guard let node = change.node else { throw PlannerCoreError.missingNodeForAdd }
                guard node.canvasId == canvas.id else {
                    throw PlannerCoreError.canvasMismatch(expected: canvas.id, actual: node.canvasId)
                }
            case .updateNode:
                guard let nodeId = change.nodeId else { throw PlannerCoreError.missingNodeId }
                guard nodeIds.contains(nodeId) else { throw PlannerCoreError.nodeNotFound(nodeId) }
                guard change.title != nil ||
                    change.status != nil ||
                    change.ioSchema != nil ||
                    change.contextSources != nil ||
                    change.dependsOnNodeIds != nil ||
                    change.subCanvasId != nil ||
                    change.nodeKind != nil ||
                    change.layout != nil ||
                    change.trigger != nil ||
                    change.gate != nil ||
                    change.dispatch != nil ||
                    change.approvers != nil ||
                    change.artifactRefs != nil ||
                    change.eventRefs != nil ||
                    change.workflowRunState != nil ||
                    change.sessionId != nil ||
                    change.chatThreadId != nil ||
                    change.source != nil else {
                    throw PlannerCoreError.updateNodeNoFields(nodeId)
                }
            }
        }
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
                ioSchema: IOSchema(
                    consumes: ["owner goal", "canvas context"],
                    produces: ["initial meee2 AI proposal"],
                    completionSignal: "proposal created"
                ),
                contextSources: [
                    ContextSource(kind: .document, title: "Feature list", reference: "doc/meee2-feature-list-wjk-codex.md")
                ],
                executionMode: .signOff,
                executorType: .codex,
                doerId: "A",
                status: .running,
                dependsOnNodeIds: []
            ),
            PlanningNode(
                id: "\(canvasId)-node-2",
                canvasId: canvasId,
                title: "Canvas + Permission Shell",
                ioSchema: IOSchema(
                    consumes: ["node mock", "owner policy"],
                    produces: ["owner-only canvas shell"],
                    completionSignal: "shell renders mocked nodes"
                ),
                contextSources: [
                    ContextSource(kind: .repository, title: "Board module", reference: "Sources/Board")
                ],
                executionMode: .human,
                executorType: .human,
                doerId: "B",
                status: .waiting,
                dependsOnNodeIds: ["\(canvasId)-node-1"]
            ),
            PlanningNode(
                id: "\(canvasId)-node-3",
                canvasId: canvasId,
                title: "Proposal Apply Contract",
                ioSchema: IOSchema(
                    consumes: ["approved plan proposal"],
                    produces: ["updated planning nodes"],
                    completionSignal: "approved proposal applied"
                ),
                contextSources: [
                    ContextSource(kind: .artifact, title: "PlanProposal", reference: "PlannerCore.PlanProposal")
                ],
                executionMode: .signOff,
                executorType: .mock,
                doerId: "A",
                status: .blocked,
                dependsOnNodeIds: ["\(canvasId)-node-2"]
            ),
            PlanningNode(
                id: "\(canvasId)-node-4",
                canvasId: canvasId,
                title: "NodeState Read",
                ioSchema: IOSchema(
                    consumes: ["planning nodes"],
                    produces: ["node state snapshots"],
                    completionSignal: "blocked/running/done states visible"
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
                if let ioSchema = change.ioSchema {
                    updatedNodes[index].ioSchema = ioSchema
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
                if let status = change.status {
                    updatedNodes[index].status = status
                }
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
                updatedNodes[index].status = .planning
            }
        }
        return updatedNodes
    }

    func readNodeState(nodes: [PlanningNode]) -> [NodeStateSnapshot] {
        nodes.map { node in
            let runState = NodeRunState(status: node.status)
            return NodeStateSnapshot(
                nodeId: node.id,
                runState: runState,
                blockers: blockers(for: node),
                artifactRefs: artifactRefs(for: node),
                needsOwnerReview: node.status == .blocked || (node.status != .planning && node.executionMode == .signOff)
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
            runState = .planning
        } else if !scopedStates.isEmpty && scopedStates.allSatisfy({ $0.runState == .done }) {
            runState = .done
        } else if scopedStates.contains(where: { $0.runState == .running }) {
            runState = .running
        } else if scopedStates.contains(where: { $0.runState == .planning }) {
            runState = .planning
        } else {
            runState = .waiting
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
        if node.status == .done {
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
            return ["Node is blocked and needs meee2 AI attention"]
        case .planning:
            return ["Node is replanning after dependency or schema change"]
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
            ioSchema: IOSchema(
                consumes: sessionInputHints(session),
                produces: ["session output"],
                completionSignal: completionSignal(for: session.status)
            ),
            contextSources: contextSources(session),
            executionMode: session.status == .permissionRequired ? .signOff : .auto,
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
            return .running
        case .permissionRequired, .dead:
            return .blocked
        case .completed:
            return .done
        case .idle, .waitingForUser:
            return .waiting
        }
    }

    private static func completionSignal(for status: SessionStatus) -> String {
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
    struct CanvasRecord: Codable, Equatable {
        var canvas: PlanningCanvas
        var nodes: [PlanningNode]
        var proposals: [PlanProposal]
        var events: [PlannerEvent]
        var artifacts: [PlannerArtifact]

        init(
            canvas: PlanningCanvas,
            nodes: [PlanningNode],
            proposals: [PlanProposal],
            events: [PlannerEvent] = [],
            artifacts: [PlannerArtifact] = []
        ) {
            self.canvas = canvas
            self.nodes = nodes
            self.proposals = proposals
            self.events = events
            self.artifacts = artifacts
        }

        enum CodingKeys: String, CodingKey {
            case canvas, nodes, proposals, events, artifacts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.canvas = try container.decode(PlanningCanvas.self, forKey: .canvas)
            self.nodes = try container.decode([PlanningNode].self, forKey: .nodes)
            self.proposals = try container.decode([PlanProposal].self, forKey: .proposals)
            self.events = try container.decodeIfPresent([PlannerEvent].self, forKey: .events) ?? []
            self.artifacts = try container.decodeIfPresent([PlannerArtifact].self, forKey: .artifacts) ?? []
        }
    }

    private struct StoreDocument: Codable {
        var canvases: [String: CanvasRecord]
    }

    static let shared = PlannerStore(
        fileURL: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
            .appendingPathComponent("planner-canvases.json")
    )

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()
    private var document: StoreDocument

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.document = Self.loadDocument(fileURL: fileURL, fileManager: fileManager, decoder: decoder)
    }

    func record(
        for canvas: PlanningCanvas,
        seedNodes: [PlanningNode]
    ) throws -> CanvasRecord {
        try withLock {
            if let existing = document.canvases[canvas.id] {
                if existing.canvas == canvas {
                    return existing
                }
                var updated = existing
                updated.canvas = canvas
                document.canvases[canvas.id] = updated
                try save()
                return updated
            }

            let record = CanvasRecord(canvas: canvas, nodes: seedNodes, proposals: [])
            document.canvases[canvas.id] = record
            try save()
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
            try save()
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
            try save()
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
            try save()
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
            try save()
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
                derivedArtifacts(from: nodes, canvasId: canvasId)
            )
            record.events.append(event(
                canvasId: canvasId,
                type: .proposalApplied,
                proposalId: proposalId,
                summary: proposal.summary
            ))
            document.canvases[canvasId] = record
            try save()
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

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func requireRecord(canvasId: String) throws -> CanvasRecord {
        guard let record = document.canvases[canvasId] else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        return record
    }

    private func save() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
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
            record.artifacts = mergeArtifacts(record.artifacts, [artifact])
            var refs = record.nodes[nodeIndex].artifactRefs ?? []
            if !refs.contains(artifact.reference) {
                refs.append(artifact.reference)
            }
            record.nodes[nodeIndex].artifactRefs = refs
            record.events.append(event(
                canvasId: canvasId,
                type: .artifactAttached,
                nodeId: artifact.nodeId,
                summary: artifact.title,
                artifactRefs: [artifact.reference]
            ))
            document.canvases[canvasId] = record
            try save()
            return record
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
            try save()
            return record
        }
    }

    private func mergeArtifacts(
        _ existing: [PlannerArtifact],
        _ incoming: [PlannerArtifact]
    ) -> [PlannerArtifact] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for artifact in incoming {
            byId[artifact.id] = artifact
        }
        return byId.values.sorted { $0.createdAt < $1.createdAt }
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

    private func serviceArtifactRefs(node: PlanningNode) -> [String] {
        var refs = node.artifactRefs ?? []
        if node.status == .done {
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
        fileURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> StoreDocument {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(StoreDocument.self, from: data) else {
            return StoreDocument(canvases: [:])
        }
        return decoded
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
        var record = try store.record(for: canvas, seedNodes: [])
        record = try store.replaceNodesIfUnmodified(
            canvasId: canvas.id,
            matching: service.nodeMock(canvasId: canvas.id),
            with: []
        )
        let nodes = record.nodes
        let access = PlannerPermission.access(for: record.canvas, nodes: nodes, actorId: actorUserId)
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
            ioSchema: IOSchema(
                consumes: ["owner goal", "meee2 AI context"],
                produces: ["executable node output"],
                completionSignal: "owner approves generated proposal"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .signOff,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .waiting
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

    static func bindSessionProposal(
        nodeId: String,
        sessionId: String,
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
            id: "proposal-\(nodeId)-bind-session-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            summary: "Bind session to \(node.title)",
            changes: [
                .updateNode(
                    id: nodeId,
                    nodeKind: .session,
                    workflowRunState: .running,
                    sessionId: sessionId,
                    chatThreadId: sessionId,
                    source: .session
                )
            ],
            status: .pending
        )
        .saved(in: store, canvas: state.canvas, seedNodes: [], validationNodes: state.nodes)
    }

    static func dispatchNodeProposal(
        nodeId: String,
        runner: PlannerDispatchRunner,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.createProposal, access: state.access)
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        let dispatch = PlannerNodeDispatch(
            runner: runner,
            skill: node.dispatch?.skill ?? "m3-coding",
            actor: node.doerId,
            command: runner == .byoaLocal ? "claude" : nil,
            fallbackRunner: runner == .ciAgent ? .byoaLocal : nil
        )
        return try PlanProposal(
            id: "proposal-\(nodeId)-dispatch-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            summary: "Dispatch \(node.title) via \(runner.rawValue)",
            changes: [
                .updateNode(
                    id: nodeId,
                    status: runner == .human ? .blocked : .running,
                    dispatch: dispatch,
                    workflowRunState: runner == .human ? .gateWait : .dispatched
                )
            ],
            status: .pending
        )
        .saved(in: store, canvas: state.canvas, seedNodes: [], validationNodes: state.nodes)
    }

    static func attachArtifact(
        nodeId: String,
        kind: PlannerArtifactKind,
        title: String,
        reference: String,
        status: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.updateAssignedNode, access: state.access)
        guard state.nodes.contains(where: { $0.id == nodeId }) else {
            throw PlannerCoreError.nodeNotFound(nodeId)
        }
        let artifact = PlannerArtifact(
            id: "artifact-\(canvasId)-\(nodeId)-\(UUID().uuidString.lowercased())",
            canvasId: canvasId,
            nodeId: nodeId,
            kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? reference : title,
            reference: reference,
            status: status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "attached" : status,
            createdAt: Date()
        )
        _ = try store.attachArtifact(artifact, canvasId: canvasId)
        return try graphState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
    }

    static func updateNodeLayout(
        nodeId: String,
        layout: PlannerNodeLayout,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot,
        actorUserId: String? = nil
    ) throws -> PlannerGraphState {
        let state = try canvasState(for: canvasId, snapshot: snapshot, actorUserId: actorUserId)
        try PlannerPermission.require(.updateAssignedNode, access: state.access)
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
        guard let blocked = state.states.first(where: { $0.runState == .blocked || $0.needsOwnerReview }),
              let node = state.nodes.first(where: { $0.id == blocked.nodeId }) else {
            return nil
        }
        return try PlanProposal(
            id: "proposal-\(node.id)-drift-\(UUID().uuidString.lowercased())",
            canvasId: node.canvasId,
            summary: "meee2 AI detected drift or review need for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs owner review)", status: .planning)
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

    static func applyPreview(
        proposal: PlanProposal,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], states: [NodeStateSnapshot]) {
        _ = try requireCanvas(canvasId, in: snapshot)
        guard proposal.canvasId == canvasId else {
            throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: proposal.canvasId)
        }
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas, actorUserId: nil)
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
            let state = try canvasState(
                for: boardCanvas.id,
                snapshot: snapshot,
                actorUserId: actorUserId
            )
            let actorId = state.access.actorId
            let statesByNodeId = Dictionary(uniqueKeysWithValues: state.states.map { ($0.nodeId, $0) })
            let visibleNodes = state.access.role == .doer
                ? state.nodes.filter { $0.doerId == actorId }
                : state.nodes

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
                    proposalId: nil,
                    proposalStatus: nil,
                    summary: node.title,
                    runState: snapshot.runState,
                    blockers: snapshot.blockers,
                    needsOwnerReview: snapshot.needsOwnerReview,
                    doerId: node.doerId,
                    riskRank: rank
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
                        riskRank: proposal.status == .pending ? 1 : 2
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

    private static func requireCanvas(
        _ canvasId: String,
        in snapshot: BoardLayoutStore.Snapshot
    ) throws -> BoardLayoutStore.Canvas {
        guard let canvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        return canvas
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
        case .running:
            return 2
        case .planning:
            return 3
        case .waiting:
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
            node.doerId == actorId && (node.status == .running || node.status == .blocked || node.status == .planning)
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
            ioSchema: IOSchema(
                consumes: [node.ioSchema.produces.joined(separator: ", ")],
                produces: ["refined output"],
                completionSignal: "refinement reviewed"
            ),
            contextSources: node.contextSources,
            executionMode: .signOff,
            executorType: node.executorType,
            doerId: node.doerId,
            status: .planning,
            dependsOnNodeIds: [node.id]
        )
        return PlanProposal(
            id: "proposal-\(node.id)-refine\(suffix)",
            canvasId: node.canvasId,
            summary: "Refine \(node.title)",
            changes: [
                .updateNode(id: node.id, status: .planning),
                .addNode(followUp)
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
            ioSchema: IOSchema(
                consumes: dependsOn.isEmpty ? ["owner intent"] : dependsOn,
                produces: artifactRefs,
                completionSignal: gate.label
            ),
            contextSources: artifactRefs.map {
                ContextSource(kind: .artifact, title: $0, reference: $0)
            },
            executionMode: dispatch.runner == .human ? .human : .signOff,
            executorType: executorType(for: dispatch.runner),
            doerId: dispatch.actor,
            status: .waiting,
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
            ioSchema: IOSchema(
                consumes: ["main branch update"],
                produces: ["external release automation"],
                completionSignal: "external:N6"
            ),
            contextSources: [
                ContextSource(kind: .artifact, title: "external automation", reference: "external:N6")
            ],
            executionMode: .auto,
            executorType: .mock,
            doerId: "external",
            status: .waiting,
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
        case .byoaLocal:
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
                    status: .planning,
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
            ioSchema: IOSchema(
                consumes: node.ioSchema.consumes,
                produces: ["split node output"],
                completionSignal: "split output reviewed"
            ),
            contextSources: node.contextSources,
            executionMode: .signOff,
            executorType: node.executorType,
            doerId: node.doerId,
            status: .planning,
            dependsOnNodeIds: [node.id]
        )
        let blockerSummary = state.blockers.isEmpty ? "blocked state" : state.blockers.joined(separator: "; ")
        return PlanProposal(
            id: "proposal-\(node.id)-split",
            canvasId: node.canvasId,
            summary: "Split \(node.title) because \(blockerSummary)",
            changes: [
                .updateNode(id: node.id, status: .planning),
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
            ioSchema: IOSchema(
                consumes: ["owner goal"],
                produces: ["first executable output"],
                completionSignal: "owner reviews generated proposal"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .signOff,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .waiting
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
        guard let state = states.first(where: { $0.runState == .blocked || $0.needsOwnerReview }),
              let node = nodes.first(where: { $0.id == state.nodeId }) else {
            if let planningState = states.first(where: { $0.runState == .planning }),
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
            summary: "meee2 AI detected drift or review need for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs owner review)", status: .planning)
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
        case .waiting:
            self = .waiting
        case .running:
            self = .running
        case .blocked:
            self = .blocked
        case .done:
            self = .done
        case .planning:
            self = .planning
        }
    }
}
