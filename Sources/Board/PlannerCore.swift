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
        source: PlanningNodeSource? = .planner
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

    var errorDescription: String? {
        switch self {
        case .invalidPlannerProposalJSON:
            return "planner proposal output is not valid JSON"
        case .proposalNotApproved:
            return "plan proposal must be approved before apply"
        case .proposalNotFound(let id):
            return "plan proposal not found: \(id)"
        case .canvasMismatch(let expected, let actual):
            return "proposal canvas mismatch: expected \(expected), got \(actual)"
        case .emptyProposalChanges:
            return "planner proposal must contain at least one change"
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
                guard change.title != nil || change.status != nil else {
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
            source: .session
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

    func saveProposal(
        _ proposal: PlanProposal,
        canvas: PlanningCanvas,
        seedNodes: [PlanningNode],
        validationNodes: [PlanningNode]? = nil
    ) throws -> PlanProposal {
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
        }
        document.canvases[canvas.id] = record
        try save()
        return proposal
    }

    func approveProposal(
        proposalId: String,
        canvasId: String
    ) throws -> PlanProposal {
        var record = try requireRecord(canvasId: canvasId)
        guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
            throw PlannerCoreError.proposalNotFound(proposalId)
        }
        guard record.proposals[index].canvasId == canvasId else {
            throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: record.proposals[index].canvasId)
        }
        record.proposals[index].status = .approved
        document.canvases[canvasId] = record
        try save()
        return record.proposals[index]
    }

    func rejectProposal(
        proposalId: String,
        canvasId: String
    ) throws -> PlanProposal {
        var record = try requireRecord(canvasId: canvasId)
        guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
            throw PlannerCoreError.proposalNotFound(proposalId)
        }
        guard record.proposals[index].canvasId == canvasId else {
            throw PlannerCoreError.canvasMismatch(expected: canvasId, actual: record.proposals[index].canvasId)
        }
        record.proposals[index].status = .rejected
        document.canvases[canvasId] = record
        try save()
        return record.proposals[index]
    }

    func applyProposal(
        proposalId: String,
        canvasId: String,
        service: PlannerCoreService
    ) throws -> CanvasRecord {
        var record = try requireRecord(canvasId: canvasId)
        guard let index = record.proposals.firstIndex(where: { $0.id == proposalId }) else {
            throw PlannerCoreError.proposalNotFound(proposalId)
        }
        let proposal = record.proposals[index]
        try PlannerProposalValidator.validate(proposal, canvas: record.canvas, nodes: record.nodes)
        let nodes = try service.applyNodeChange(nodes: record.nodes, proposal: proposal)
        record.nodes = nodes
        record.proposals[index].status = .applied
        document.canvases[canvasId] = record
        try save()
        return record
    }

    func preview(
        proposal: PlanProposal,
        canvas: PlanningCanvas,
        seedNodes: [PlanningNode],
        service: PlannerCoreService
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode]) {
        let record = try record(for: canvas, seedNodes: seedNodes)
        try PlannerProposalValidator.validate(proposal, canvas: canvas, nodes: record.nodes)
        let approved = service.approve(proposal)
        let nodes = try service.applyNodeChange(nodes: record.nodes, proposal: approved)
        return (approved, nodes)
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
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> (canvas: PlanningCanvas, nodes: [PlanningNode], states: [NodeStateSnapshot], proposals: [PlanProposal]) {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas)
        let record = try store.record(for: canvas, seedNodes: service.nodeMock(canvasId: canvas.id))
        let nodes = record.nodes + sessionBackedNodes(for: record.canvas, snapshot: snapshot)
        return (record.canvas, nodes, service.readNodeState(nodes: nodes), record.proposals)
    }

    static func generateProposal(
        goal: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> PlanProposal {
        let boardCanvas = try requireCanvas(canvasId, in: snapshot)
        let canvas = planningCanvas(from: boardCanvas)
        let title = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposalUUID = UUID().uuidString.lowercased()
        let node = PlanningNode(
            id: "\(canvas.id)-proposal-node-\(proposalUUID)",
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
        return try PlanProposal(
            id: "proposal-\(canvas.id)-generate-\(proposalUUID)",
            canvasId: canvas.id,
            summary: "Generate planner graph for \(canvas.title)",
            changes: [.addNode(node)],
            status: .pending
        )
        .saved(in: store, canvas: canvas, seedNodes: service.nodeMock(canvasId: canvas.id))
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
        return try PlanProposal(
            id: "proposal-\(node.id)-drift-\(UUID().uuidString.lowercased())",
            canvasId: node.canvasId,
            summary: "Planner detected drift or review need for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs owner review)", status: .planning)
            ],
            status: .pending
        )
        .saved(
            in: store,
            canvas: state.canvas,
            seedNodes: service.nodeMock(canvasId: state.canvas.id),
            validationNodes: state.nodes
        )
    }

    static func refineProposal(
        nodeId: String,
        reason: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> PlanProposal {
        let state = try canvasState(for: canvasId, snapshot: snapshot)
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
            seedNodes: service.nodeMock(canvasId: state.canvas.id),
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
        let canvas = planningCanvas(from: boardCanvas)
        let preview = try store.preview(
            proposal: proposal,
            canvas: canvas,
            seedNodes: service.nodeMock(canvasId: canvasId),
            service: service
        )
        let approved = preview.proposal
        let nodes = preview.nodes
        return (approved, nodes, service.readNodeState(nodes: nodes))
    }

    static func approveProposal(
        proposalId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> PlanProposal {
        _ = try requireCanvas(canvasId, in: snapshot)
        return try store.approveProposal(proposalId: proposalId, canvasId: canvasId)
    }

    static func rejectProposal(
        proposalId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> PlanProposal {
        _ = try requireCanvas(canvasId, in: snapshot)
        return try store.rejectProposal(proposalId: proposalId, canvasId: canvasId)
    }

    static func applyProposal(
        proposalId: String,
        for canvasId: String,
        snapshot: BoardLayoutStore.Snapshot
    ) throws -> (proposal: PlanProposal, nodes: [PlanningNode], states: [NodeStateSnapshot]) {
        _ = try requireCanvas(canvasId, in: snapshot)
        let record = try store.applyProposal(proposalId: proposalId, canvasId: canvasId, service: service)
        guard let proposal = record.proposals.first(where: { $0.id == proposalId }) else {
            throw PlannerCoreError.proposalNotFound(proposalId)
        }
        return (proposal, record.nodes, service.readNodeState(nodes: record.nodes))
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

    private static func sessionBackedNodes(
        for canvas: PlanningCanvas,
        snapshot: BoardLayoutStore.Snapshot
    ) -> [PlanningNode] {
        let visibleSessionIds = Set(snapshot.memberships
            .filter { $0.canvasId == canvas.id && $0.visible }
            .map(\.sessionId))
        guard !visibleSessionIds.isEmpty else { return [] }

        return PluginManager.shared.sessions
            .filter { visibleSessionIds.contains($0.id) }
            .filter { PluginManager.shared.isPluginEnabled($0.pluginId) }
            .map {
                SessionToPlanningNodeMapper.map(
                    session: $0,
                    canvasId: canvas.id,
                    doerId: canvas.ownerId
                )
            }
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
            status: .planning
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

enum PlannerDriftAdvisor {
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
            status: .planning
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
        PlannerProposalFactory.refineNode(node: node, reason: reason)
    }

    func inspectDrift(nodes: [PlanningNode], states: [NodeStateSnapshot]) async throws -> PlanProposal? {
        guard let state = states.first(where: { $0.runState == .blocked || $0.needsOwnerReview }),
              let node = nodes.first(where: { $0.id == state.nodeId }) else {
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
