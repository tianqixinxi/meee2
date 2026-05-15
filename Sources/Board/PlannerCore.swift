import Foundation

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

    static func addNode(_ node: PlanningNode) -> PlanChange {
        PlanChange(kind: .addNode, node: node, nodeId: nil, title: nil, status: nil)
    }

    static func updateNode(
        id: String,
        title: String? = nil,
        status: PlanningNodeStatus? = nil
    ) -> PlanChange {
        PlanChange(kind: .updateNode, node: nil, nodeId: id, title: title, status: status)
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

enum PlannerCoreError: LocalizedError, Equatable {
    case proposalNotApproved
    case canvasMismatch(expected: String, actual: String)
    case missingNodeForAdd
    case missingNodeId
    case nodeNotFound(String)
    case canvasNotFound(String)

    var errorDescription: String? {
        switch self {
        case .proposalNotApproved:
            return "plan proposal must be approved before apply"
        case .canvasMismatch(let expected, let actual):
            return "proposal canvas mismatch: expected \(expected), got \(actual)"
        case .missingNodeForAdd:
            return "addNode change is missing node"
        case .missingNodeId:
            return "updateNode change is missing nodeId"
        case .nodeNotFound(let id):
            return "planning node not found: \(id)"
        case .canvasNotFound(let id):
            return "planning canvas not found: \(id)"
        }
    }
}

final class PlannerCoreService {
    func nodeMock(canvasId: String) -> [PlanningNode] {
        [
            PlanningNode(
                id: "\(canvasId)-node-1",
                canvasId: canvasId,
                title: "Planner LLM Spike",
                ioSchema: IOSchema(
                    consumes: ["owner goal", "canvas context"],
                    produces: ["initial plan proposal"],
                    completionSignal: "proposal created"
                ),
                contextSources: [
                    ContextSource(kind: .document, title: "Feature list", reference: "doc/meee2-feature-list-wjk-codex.md")
                ],
                executionMode: .signOff,
                executorType: .codex,
                doerId: "A",
                status: .running
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
                status: .waiting
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
                status: .blocked
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
                status: .done
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
                if let status = change.status {
                    updatedNodes[index].status = status
                }
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
                blockers: node.status == .blocked ? ["Node is blocked and needs planner attention"] : [],
                artifactRefs: node.status == .done ? ["artifact://\(node.id)/output"] : [],
                needsOwnerReview: node.status == .blocked || node.executionMode == .signOff
            )
        }
    }
}

enum PlannerBoardBridge {
    private static let service = PlannerCoreService()

    static func canvasState(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> (canvas: PlanningCanvas, nodes: [PlanningNode], states: [NodeStateSnapshot]) {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas)
        let nodes = service.nodeMock(canvasId: canvas.id)
        return (canvas, nodes, service.readNodeState(nodes: nodes))
    }

    static func generateProposal(
        goal: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> PlanProposal {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas)
        let title = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = PlanningNode(
            id: "\(canvas.id)-proposal-node-1",
            canvasId: canvas.id,
            title: title.isEmpty ? "Generated planner node" : title,
            ioSchema: IOSchema(
                consumes: ["owner goal", "planner context"],
                produces: ["executable node output"],
                completionSignal: "owner approves generated proposal"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "Planner context", reference: canvas.plannerContext)
            ],
            executionMode: .signOff,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .waiting
        )
        return PlanProposal(
            id: "proposal-\(canvas.id)-generate",
            canvasId: canvas.id,
            summary: "Generate planner graph for \(canvas.title)",
            changes: [.addNode(node)],
            status: .pending
        )
    }

    static func driftProposal(
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> PlanProposal? {
        let state = try canvasState(for: canvasId, snapshot: snapshot)
        guard let blocked = state.states.first(where: { $0.runState == .blocked || $0.needsOwnerReview }),
              let node = state.nodes.first(where: { $0.id == blocked.nodeId }) else {
            return nil
        }
        return PlanProposal(
            id: "proposal-\(node.id)-drift",
            canvasId: node.canvasId,
            summary: "Planner detected drift or review need for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs owner review)", status: .planning)
            ],
            status: .pending
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
        let currentNodes = service.nodeMock(canvasId: canvasId)
        let approved = service.approve(proposal)
        let nodes = try service.applyNodeChange(nodes: currentNodes, proposal: approved)
        return (approved, nodes, service.readNodeState(nodes: nodes))
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

    private static func planningCanvas(from canvas: BoardLayoutStore.Canvas) -> PlanningCanvas {
        PlanningCanvas(
            id: canvas.id,
            ownerId: canvas.ownerUserId ?? canvas.createdBy ?? "local-owner",
            title: canvas.name,
            plannerContext: "canvas:\(canvas.id)"
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
            title: goal.isEmpty ? "Generated planner node" : goal,
            ioSchema: IOSchema(
                consumes: ["owner goal"],
                produces: ["first executable output"],
                completionSignal: "owner reviews generated proposal"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "Planner context", reference: canvas.plannerContext)
            ],
            executionMode: .signOff,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .waiting
        )
        return PlanProposal(
            id: "proposal-\(canvas.id)-generate",
            canvasId: canvas.id,
            summary: "Generate initial planner graph for \(canvas.title)",
            changes: [.addNode(node)],
            status: .pending
        )
    }

    func refineNode(node: PlanningNode, reason: String) async throws -> PlanProposal {
        let followUp = PlanningNode(
            id: "\(node.id)-refine-1",
            canvasId: node.canvasId,
            title: reason.isEmpty ? "\(node.title) refinement" : reason,
            ioSchema: IOSchema(
                consumes: [node.ioSchema.produces.joined(separator: ", ")],
                produces: ["refined output"],
                completionSignal: "refinement reviewed"
            ),
            contextSources: node.contextSources,
            executionMode: .signOff,
            executorType: node.executorType,
            doerId: node.doerId,
            status: .planning
        )
        return PlanProposal(
            id: "proposal-\(node.id)-refine",
            canvasId: node.canvasId,
            summary: "Refine \(node.title)",
            changes: [
                .updateNode(id: node.id, status: .planning),
                .addNode(followUp)
            ],
            status: .pending
        )
    }

    func inspectDrift(nodes: [PlanningNode], states: [NodeStateSnapshot]) async throws -> PlanProposal? {
        guard let state = states.first(where: { $0.runState == .blocked || $0.needsOwnerReview }),
              let node = nodes.first(where: { $0.id == state.nodeId }) else {
            return nil
        }
        return PlanProposal(
            id: "proposal-\(node.id)-drift",
            canvasId: node.canvasId,
            summary: "Planner detected drift or review need for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs owner review)", status: .planning)
            ],
            status: .pending
        )
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
