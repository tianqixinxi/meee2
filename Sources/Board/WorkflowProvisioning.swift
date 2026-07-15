import Foundation
import Meee2CommKit

enum WorkflowProposalStatus: String, Codable, Equatable {
    case draft
    case applied
}

struct WorkflowBlueprintStep: Codable, Equatable {
    var id: String
    var title: String
    var goal: String
    var dependsOn: [String]
    var inputs: [String]
    var outputs: [String]
    var runtime: String
    var ownerId: String?
    var reviewerIds: [String]
    var approverIds: [String]
    var requiresApproval: Bool
}

struct WorkflowBlueprintTrackerTab: Codable, Equatable {
    var id: String
    var title: String
    var columns: [String]
}

struct WorkflowBlueprintTracker: Codable, Equatable {
    var id: String
    var title: String
    var connector: String
    var reference: String
    var tabs: [WorkflowBlueprintTrackerTab]
    var readerStepIds: [String]
    var writerStepIds: [String]
    /// column -> human_only | ai_suggest | ai_write
    var fieldPolicies: [String: String]
}

struct WorkflowBlueprintSchedule: Codable, Equatable {
    var id: String
    var nodeId: String
    var cadence: String
    var intervalMinutes: Int?
    var timeZone: String?
    var hour: Int?
    var minute: Int?
    var dayOfMonth: Int?
    var prompt: String
}

struct WorkflowBlueprint: Codable, Equatable {
    var name: String
    var summary: String
    var scope: String
    var steps: [WorkflowBlueprintStep]
    var trackers: [WorkflowBlueprintTracker]
    var schedules: [WorkflowBlueprintSchedule]
    var integrations: [String]
    /// connector id -> read_only | draft_only | write
    var integrationPolicies: [String: String]?
}

struct WorkflowProposal: Codable, Equatable {
    var id: String
    var idempotencyKey: String?
    var requirement: String
    var blueprint: WorkflowBlueprint
    var targetCanvasId: String?
    var status: WorkflowProposalStatus
    var version: Int
    var appliedCanvasId: String?
    var createdAt: Date
    var updatedAt: Date
}

struct WorkflowProposalEnvelope: Encodable {
    let proposal: WorkflowProposal
}

struct WorkflowApplyEnvelope: Encodable {
    let proposal: WorkflowProposal
    let canvasId: String
    let created: Bool
}

struct WorkflowStatusEnvelope: Encodable {
    let canvasId: String
    let title: String
    let enabled: Bool
    let nodeCounts: [String: Int]
    let scheduledNodeCount: Int
    let nextRunAt: Date?
    let pendingApprovalCount: Int
    let missingIntegrations: [String]
    let latestRun: WorkflowRun?
}

struct WorkflowDryRunEnvelope: Encodable, Equatable {
    let canvasId: String
    let nodeCount: Int
    let rootNodeIds: [String]
    let topologicalNodeIds: [String]
    let scheduledNodeCount: Int
    let allSchedulesDisabled: Bool
    let warnings: [String]
}

enum WorkflowProvisioningError: LocalizedError, Equatable {
    case notFound
    case validation(String)
    case immutableProposal
    case approvalRequired

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "workflow proposal not found"
        case .validation(let message):
            return message
        case .immutableProposal:
            return "applied workflow proposals are immutable; create a workflow change proposal"
        case .approvalRequired:
            return "explicit user approval is required before applying or enabling a workflow"
        }
    }
}

final class WorkflowProposalStore {
    static let shared = WorkflowProposalStore(
        fileURL: StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("workflow-proposals.json", isDirectory: false)
    )

    private struct StoreFile: Codable { var proposals: [WorkflowProposal] }

    private let lock = NSLock()
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func create(
        requirement rawRequirement: String,
        blueprint rawBlueprint: WorkflowBlueprint,
        idempotencyKey rawIdempotencyKey: String?,
        targetCanvasId: String? = nil
    ) throws -> WorkflowProposal {
        lock.lock()
        defer { lock.unlock() }
        var file = loadUnlocked()
        let requirement = clean(rawRequirement)
        let idempotencyKey = rawIdempotencyKey.flatMap(cleanOptional)
        if let idempotencyKey,
           let existing = file.proposals.first(where: { $0.idempotencyKey == idempotencyKey }) {
            return existing
        }
        let blueprint = try Self.normalized(rawBlueprint)
        guard !requirement.isEmpty else {
            throw WorkflowProvisioningError.validation("requirement is required")
        }
        if let targetCanvasId {
            guard BoardLayoutStore.shared.snapshot().canvases.contains(where: { $0.id == targetCanvasId }) else {
                throw WorkflowProvisioningError.validation("target canvas not found: \(targetCanvasId)")
            }
        }
        let now = Date()
        let proposal = WorkflowProposal(
            id: UUID().uuidString.lowercased(),
            idempotencyKey: idempotencyKey,
            requirement: requirement,
            blueprint: blueprint,
            targetCanvasId: targetCanvasId,
            status: .draft,
            version: 1,
            appliedCanvasId: nil,
            createdAt: now,
            updatedAt: now
        )
        file.proposals.append(proposal)
        try saveUnlocked(file)
        return proposal
    }

    func get(id: String) -> WorkflowProposal? {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().proposals.first { $0.id == id }
    }

    func proposal(appliedTo canvasId: String) -> WorkflowProposal? {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().proposals
            .filter { $0.appliedCanvasId == canvasId }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func revise(id: String, requirement: String?, blueprint: WorkflowBlueprint?, expectedVersion: Int?) throws -> WorkflowProposal {
        lock.lock()
        defer { lock.unlock() }
        var file = loadUnlocked()
        guard let index = file.proposals.firstIndex(where: { $0.id == id }) else {
            throw WorkflowProvisioningError.notFound
        }
        guard file.proposals[index].status == .draft else {
            throw WorkflowProvisioningError.immutableProposal
        }
        if let expectedVersion, expectedVersion != file.proposals[index].version {
            throw WorkflowProvisioningError.validation(
                "proposal version conflict: expected \(expectedVersion), current \(file.proposals[index].version)"
            )
        }
        if let requirement {
            let value = clean(requirement)
            guard !value.isEmpty else { throw WorkflowProvisioningError.validation("requirement is required") }
            file.proposals[index].requirement = value
        }
        if let blueprint {
            file.proposals[index].blueprint = try Self.normalized(blueprint)
        }
        file.proposals[index].version += 1
        file.proposals[index].updatedAt = Date()
        try saveUnlocked(file)
        return file.proposals[index]
    }

    func markApplied(id: String, canvasId: String) throws -> WorkflowProposal {
        lock.lock()
        defer { lock.unlock() }
        var file = loadUnlocked()
        guard let index = file.proposals.firstIndex(where: { $0.id == id }) else {
            throw WorkflowProvisioningError.notFound
        }
        file.proposals[index].status = .applied
        file.proposals[index].appliedCanvasId = canvasId
        file.proposals[index].updatedAt = Date()
        try saveUnlocked(file)
        return file.proposals[index]
    }

    static func normalized(_ blueprint: WorkflowBlueprint) throws -> WorkflowBlueprint {
        var value = blueprint
        value.name = clean(value.name)
        value.summary = clean(value.summary)
        value.scope = clean(value.scope).lowercased()
        guard !value.name.isEmpty else { throw WorkflowProvisioningError.validation("workflow name is required") }
        guard value.scope == "personal" || value.scope == "team" else {
            throw WorkflowProvisioningError.validation("scope must be personal or team")
        }
        guard !value.steps.isEmpty else { throw WorkflowProvisioningError.validation("at least one workflow step is required") }

        var stepIds = Set<String>()
        for index in value.steps.indices {
            value.steps[index].id = clean(value.steps[index].id)
            value.steps[index].title = clean(value.steps[index].title)
            value.steps[index].goal = clean(value.steps[index].goal)
            let normalizedRuntime = clean(value.steps[index].runtime).lowercased()
            value.steps[index].runtime = ExecutorType.allCases.first {
                $0.rawValue.lowercased() == normalizedRuntime
            }?.rawValue ?? normalizedRuntime
            guard validIdentifier(value.steps[index].id) else {
                throw WorkflowProvisioningError.validation("invalid step id: \(value.steps[index].id)")
            }
            guard stepIds.insert(value.steps[index].id).inserted else {
                throw WorkflowProvisioningError.validation("duplicate step id: \(value.steps[index].id)")
            }
            guard !value.steps[index].title.isEmpty, !value.steps[index].goal.isEmpty else {
                throw WorkflowProvisioningError.validation("step title and goal are required")
            }
            guard ExecutorType(rawValue: value.steps[index].runtime) != nil else {
                throw WorkflowProvisioningError.validation("unsupported runtime: \(value.steps[index].runtime)")
            }
        }
        for step in value.steps {
            for dependency in step.dependsOn where !stepIds.contains(dependency) {
                throw WorkflowProvisioningError.validation("step \(step.id) depends on unknown step \(dependency)")
            }
        }
        try assertAcyclic(steps: value.steps)

        var trackerIds = Set<String>()
        for index in value.trackers.indices {
            value.trackers[index].id = clean(value.trackers[index].id)
            value.trackers[index].title = clean(value.trackers[index].title)
            value.trackers[index].connector = clean(value.trackers[index].connector).lowercased()
            value.trackers[index].reference = clean(value.trackers[index].reference)
            guard validIdentifier(value.trackers[index].id), trackerIds.insert(value.trackers[index].id).inserted else {
                throw WorkflowProvisioningError.validation("tracker ids must be unique identifiers")
            }
            guard !value.trackers[index].connector.isEmpty, !value.trackers[index].reference.isEmpty else {
                throw WorkflowProvisioningError.validation("tracker connector and reference are required")
            }
            var tabIds = Set<String>()
            var columns = Set<String>()
            for tabIndex in value.trackers[index].tabs.indices {
                value.trackers[index].tabs[tabIndex].id = clean(value.trackers[index].tabs[tabIndex].id)
                value.trackers[index].tabs[tabIndex].title = clean(value.trackers[index].tabs[tabIndex].title)
                value.trackers[index].tabs[tabIndex].columns = value.trackers[index].tabs[tabIndex].columns
                    .map(clean)
                    .filter { !$0.isEmpty }
                let tab = value.trackers[index].tabs[tabIndex]
                guard validIdentifier(tab.id), tabIds.insert(tab.id).inserted,
                      !tab.title.isEmpty, !tab.columns.isEmpty else {
                    throw WorkflowProvisioningError.validation(
                        "tracker tabs need unique ids, titles, and at least one column"
                    )
                }
                columns.formUnion(tab.columns)
            }
            guard !value.trackers[index].tabs.isEmpty else {
                throw WorkflowProvisioningError.validation("tracker must include at least one tab")
            }
            let referencedSteps = value.trackers[index].readerStepIds + value.trackers[index].writerStepIds
            for stepId in referencedSteps where !stepIds.contains(stepId) {
                throw WorkflowProvisioningError.validation("tracker \(value.trackers[index].id) references unknown step \(stepId)")
            }
            let validPolicies = Set(["human_only", "ai_suggest", "ai_write"])
            for (field, policy) in value.trackers[index].fieldPolicies {
                guard columns.contains(field) else {
                    throw WorkflowProvisioningError.validation(
                        "tracker field policy references unknown column: \(field)"
                    )
                }
                guard validPolicies.contains(policy) else {
                    throw WorkflowProvisioningError.validation("unsupported tracker field policy: \(policy)")
                }
            }
            for column in columns where value.trackers[index].fieldPolicies[column] == nil {
                value.trackers[index].fieldPolicies[column] = "ai_suggest"
            }
            for policy in value.trackers[index].fieldPolicies.values where !validPolicies.contains(policy) {
                throw WorkflowProvisioningError.validation("unsupported tracker field policy: \(policy)")
            }
        }

        let approvalStepIds = Set(value.trackers.flatMap { tracker in
            tracker.fieldPolicies.values.contains("ai_suggest") ? tracker.writerStepIds : []
        })
        for index in value.steps.indices where approvalStepIds.contains(value.steps[index].id) {
            value.steps[index].requiresApproval = true
        }

        var scheduleIds = Set<String>()
        var scheduledStepIds = Set<String>()
        for index in value.schedules.indices {
            value.schedules[index].id = clean(value.schedules[index].id)
            value.schedules[index].nodeId = clean(value.schedules[index].nodeId)
            value.schedules[index].cadence = clean(value.schedules[index].cadence).lowercased()
            value.schedules[index].prompt = clean(value.schedules[index].prompt)
            guard validIdentifier(value.schedules[index].id), scheduleIds.insert(value.schedules[index].id).inserted else {
                throw WorkflowProvisioningError.validation("schedule ids must be unique identifiers")
            }
            guard stepIds.contains(value.schedules[index].nodeId) else {
                throw WorkflowProvisioningError.validation("schedule references unknown step \(value.schedules[index].nodeId)")
            }
            guard let scheduledStep = value.steps.first(where: { $0.id == value.schedules[index].nodeId }),
                  scheduledStep.runtime == ExecutorType.claude.rawValue
                    || scheduledStep.runtime == ExecutorType.codex.rawValue else {
                throw WorkflowProvisioningError.validation(
                    "scheduled steps must use the claude or codex runtime"
                )
            }
            guard scheduledStepIds.insert(value.schedules[index].nodeId).inserted else {
                throw WorkflowProvisioningError.validation(
                    "a workflow step may have only one schedule: \(value.schedules[index].nodeId)"
                )
            }
            guard PlannerScheduleCadence(rawValue: value.schedules[index].cadence) != nil else {
                throw WorkflowProvisioningError.validation("schedule cadence must be interval, daily, or monthly")
            }
            guard !value.schedules[index].prompt.isEmpty else {
                throw WorkflowProvisioningError.validation("schedule prompt is required")
            }
            switch PlannerScheduleCadence(rawValue: value.schedules[index].cadence) {
            case .interval:
                value.schedules[index].intervalMinutes = value.schedules[index].intervalMinutes ?? 60
                guard (value.schedules[index].intervalMinutes ?? 0) >= 1 else {
                    throw WorkflowProvisioningError.validation("intervalMinutes must be at least 1")
                }
            case .daily, .monthly:
                let timeZone = clean(value.schedules[index].timeZone ?? TimeZone.current.identifier)
                guard TimeZone(identifier: timeZone) != nil else {
                    throw WorkflowProvisioningError.validation("invalid schedule time zone: \(timeZone)")
                }
                value.schedules[index].timeZone = timeZone
                value.schedules[index].hour = value.schedules[index].hour ?? 9
                value.schedules[index].minute = value.schedules[index].minute ?? 0
                guard (0...23).contains(value.schedules[index].hour ?? -1),
                      (0...59).contains(value.schedules[index].minute ?? -1) else {
                    throw WorkflowProvisioningError.validation("schedule hour/minute are outside their valid range")
                }
                if value.schedules[index].cadence == PlannerScheduleCadence.monthly.rawValue {
                    value.schedules[index].dayOfMonth = value.schedules[index].dayOfMonth ?? 1
                    guard (1...31).contains(value.schedules[index].dayOfMonth ?? 0) else {
                        throw WorkflowProvisioningError.validation("dayOfMonth must be between 1 and 31")
                    }
                }
            case nil:
                break
            }
        }
        value.integrations = Array(Set(value.integrations.map { clean($0).lowercased() }.filter { !$0.isEmpty })).sorted()
        let rawIntegrationPolicies = value.integrationPolicies ?? [:]
        var integrationPolicies: [String: String] = [:]
        let validIntegrationPolicies = Set(["read_only", "draft_only", "write"])
        for (rawConnector, rawPolicy) in rawIntegrationPolicies {
            let connector = clean(rawConnector).lowercased()
            let policy = clean(rawPolicy).lowercased()
            guard value.integrations.contains(connector) else {
                throw WorkflowProvisioningError.validation(
                    "integration policy references undeclared connector: \(connector)"
                )
            }
            guard validIntegrationPolicies.contains(policy) else {
                throw WorkflowProvisioningError.validation("unsupported integration policy: \(policy)")
            }
            integrationPolicies[connector] = policy
        }
        for connector in value.integrations where integrationPolicies[connector] == nil {
            integrationPolicies[connector] = "read_only"
        }
        value.integrationPolicies = integrationPolicies
        return value
    }

    private static func assertAcyclic(steps: [WorkflowBlueprintStep]) throws {
        let deps = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.dependsOn) })
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ id: String) throws {
            if visiting.contains(id) { throw WorkflowProvisioningError.validation("workflow dependency cycle includes \(id)") }
            if visited.contains(id) { return }
            visiting.insert(id)
            for dependency in deps[id] ?? [] { try visit(dependency) }
            visiting.remove(id)
            visited.insert(id)
        }
        for step in steps { try visit(step.id) }
    }

    private func loadUnlocked() -> StoreFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder.decode(StoreFile.self, from: data) else {
            return StoreFile(proposals: [])
        }
        return file
    }

    private func saveUnlocked(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    private static func clean(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
    }

    private func clean(_ value: String) -> String { Self.clean(value) }
    private func cleanOptional(_ value: String) -> String? {
        let normalized = clean(value)
        return normalized.isEmpty ? nil : normalized
    }
}

enum WorkflowProvisioner {
    static func apply(proposal: WorkflowProposal, explicitlyApproved: Bool) throws -> WorkflowApplyEnvelope {
        guard explicitlyApproved else { throw WorkflowProvisioningError.approvalRequired }
        if proposal.status == .applied, let canvasId = proposal.appliedCanvasId {
            return WorkflowApplyEnvelope(proposal: proposal, canvasId: canvasId, created: false)
        }
        if let targetCanvasId = proposal.targetCanvasId {
            return try applyChange(proposal: proposal, canvasId: targetCanvasId)
        }
        let scope = BoardLayoutStore.CanvasScope(rawValue: proposal.blueprint.scope) ?? .personal
        let snapshot = try BoardLayoutStore.shared.createCanvas(name: proposal.blueprint.name, scope: scope, kind: .board)
        let canvasId = snapshot.activeCanvasId
        do {
            guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
                throw WorkflowProvisioningError.validation("created canvas was not found")
            }
            let ownerId = boardCanvas.ownerUserId ?? boardCanvas.createdBy ?? "local-owner"
            let planning = PlanningCanvas(
                id: canvasId,
                ownerId: ownerId,
                title: boardCanvas.name,
                plannerContext: "workflow-proposal:\(proposal.id)\n\(proposal.requirement)",
                visibility: scope == .team ? .public : .private
            )
            let nodes = materializeNodes(blueprint: proposal.blueprint, canvasId: canvasId, ownerId: ownerId)
            _ = try PlannerBoardBridge.store.record(for: planning, seedNodes: [])
            _ = try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: nodes)
            let applied = try WorkflowProposalStore.shared.markApplied(id: proposal.id, canvasId: canvasId)
            BoardServer.shared.broadcastStateChanged()
            return WorkflowApplyEnvelope(proposal: applied, canvasId: canvasId, created: true)
        } catch {
            _ = try? BoardLayoutStore.shared.deleteCanvas(id: canvasId)
            throw error
        }
    }

    static func dryRun(canvasId: String) throws -> WorkflowDryRunEnvelope {
        let graph = try PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: BoardLayoutStore.shared.snapshot(),
            actorUserId: PlannerPermission.currentActorId()
        )
        var remaining = Dictionary(uniqueKeysWithValues: graph.nodes.map {
            ($0.id, Set($0.dependsOnNodeIds ?? []))
        })
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { $0.value.isSubset(of: Set(ordered)) }
                .map(\.key)
                .sorted()
            guard !ready.isEmpty else {
                throw WorkflowProvisioningError.validation("workflow graph contains a dependency cycle")
            }
            ordered.append(contentsOf: ready)
            ready.forEach { remaining.removeValue(forKey: $0) }
        }
        let schedules = graph.nodes.compactMap(\.schedule)
        var warnings: [String] = []
        if graph.nodes.contains(where: { $0.status == .blocked }) {
            warnings.append("One or more steps are currently blocked.")
        }
        if schedules.contains(where: { $0.enabled }) {
            warnings.append("One or more recurring jobs are already enabled.")
        }
        return WorkflowDryRunEnvelope(
            canvasId: canvasId,
            nodeCount: graph.nodes.count,
            rootNodeIds: graph.nodes.filter { ($0.dependsOnNodeIds ?? []).isEmpty }.map(\.id).sorted(),
            topologicalNodeIds: ordered,
            scheduledNodeCount: schedules.count,
            allSchedulesDisabled: schedules.allSatisfy { !$0.enabled },
            warnings: warnings
        )
    }

    static func setEnabled(canvasId: String, enabled: Bool, explicitlyApproved: Bool) throws -> WorkflowStatusEnvelope {
        guard explicitlyApproved else { throw WorkflowProvisioningError.approvalRequired }
        let snapshot = BoardLayoutStore.shared.snapshot()
        let state = try PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: snapshot,
            actorUserId: PlannerPermission.currentActorId()
        )
        for node in state.nodes {
            guard var schedule = node.schedule else { continue }
            schedule.enabled = enabled
            schedule.nextRunAt = enabled ? schedule.nextOccurrence(after: Date()) : nil
            _ = try PlannerBoardBridge.updateNodeSchedule(
                nodeId: node.id,
                schedule: schedule,
                for: canvasId,
                snapshot: snapshot,
                actorUserId: PlannerPermission.currentActorId()
            )
        }
        BoardServer.shared.broadcastStateChanged()
        return try status(canvasId: canvasId)
    }

    static func status(canvasId: String) throws -> WorkflowStatusEnvelope {
        let graph = try PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: BoardLayoutStore.shared.snapshot(),
            actorUserId: PlannerPermission.currentActorId()
        )
        let counts = Dictionary(grouping: graph.nodes, by: { $0.status.rawValue }).mapValues(\.count)
        let schedules = graph.nodes.compactMap(\.schedule)
        let proposal = WorkflowProposalStore.shared.proposal(appliedTo: canvasId)
        let connected = Set(
            IntegrationDetector.scan()
                .filter { $0.state == .connected }
                .map(\.integrationId)
        )
        let required = proposal?.blueprint.integrations ?? []
        let missing = required.filter { !connected.contains($0) }.sorted()
        let latestRun = try PlannerBoardBridge.store.runs(canvasId: canvasId).last
        return WorkflowStatusEnvelope(
            canvasId: canvasId,
            title: graph.canvas.title,
            enabled: schedules.contains(where: \.enabled),
            nodeCounts: counts,
            scheduledNodeCount: schedules.count,
            nextRunAt: schedules.compactMap(\.nextRunAt).min(),
            pendingApprovalCount: graph.proposals.filter { $0.status == .pending || $0.status == .approved }.count,
            missingIntegrations: missing,
            latestRun: latestRun
        )
    }

    static func materializeNodes(blueprint: WorkflowBlueprint, canvasId: String, ownerId: String) -> [PlanningNode] {
        let stepById = Dictionary(uniqueKeysWithValues: blueprint.steps.map { ($0.id, $0) })
        var depthCache: [String: Int] = [:]
        func depth(_ id: String) -> Int {
            if let cached = depthCache[id] { return cached }
            let value = (stepById[id]?.dependsOn.map(depth).max() ?? -1) + 1
            depthCache[id] = value
            return value
        }
        var rowsByDepth: [Int: Int] = [:]
        let scheduleByNode = Dictionary(uniqueKeysWithValues: blueprint.schedules.map { ($0.nodeId, $0) })
        return blueprint.steps.map { step in
            let nodeDepth = depth(step.id)
            let row = rowsByDepth[nodeDepth, default: 0]
            rowsByDepth[nodeDepth] = row + 1
            let trackerInputs = blueprint.trackers.filter { $0.readerStepIds.contains(step.id) }
            let trackerWriters = blueprint.trackers.filter { $0.writerStepIds.contains(step.id) }
            let trackerOutputs = trackerWriters.map(\.reference)
            let involvedTrackers = uniqueTrackers(trackerInputs + trackerWriters)
            let contextSources = involvedTrackers.map {
                ContextSource(kind: .artifact, title: trackerContract($0), reference: $0.reference)
            }
            let approvers = step.approverIds.isEmpty && step.requiresApproval ? [ownerId] : step.approverIds
            let handoff: HandoffPolicy = step.requiresApproval ? .anyApprover : .none
            let runtime = ExecutorType(rawValue: step.runtime) ?? .claude
            let schedule = scheduleByNode[step.id].map(scheduleValue)
            return PlanningNode(
                id: managedNodeId(canvasId: canvasId, stepId: step.id),
                canvasId: canvasId,
                title: step.title,
                schema: NodeSchema(
                    inputs: step.inputs,
                    outputs: unique(step.outputs + trackerOutputs),
                    goal: executionGoal(step.goal, trackers: involvedTrackers, blueprint: blueprint)
                ),
                contextSources: contextSources,
                executionMode: runtime == .human ? .human : .auto,
                executorType: runtime,
                doerId: step.ownerId ?? ownerId,
                status: .ready,
                reviewerIds: step.reviewerIds,
                approverIds: approvers,
                handoffPolicy: handoff,
                dependsOnNodeIds: step.dependsOn.map { managedNodeId(canvasId: canvasId, stepId: $0) },
                nodeKind: .step,
                layout: PlannerNodeLayout(x: Double(nodeDepth) * 380, y: Double(row) * 220, width: 320, height: 168),
                schedule: schedule,
                gate: step.requiresApproval ? PlannerNodeGate(
                    type: "owner-review",
                    label: "Owner approval required",
                    requiredArtifactRefs: [],
                    approvers: approvers,
                    onFailGotoNodeId: nil
                ) : nil,
                approvers: approvers
            )
        }
    }

    private static func applyChange(proposal: WorkflowProposal, canvasId: String) throws -> WorkflowApplyEnvelope {
        let snapshot = BoardLayoutStore.shared.snapshot()
        let graph = try PlannerBoardBridge.graphState(
            for: canvasId,
            snapshot: snapshot,
            actorUserId: PlannerPermission.currentActorId()
        )
        let desired = materializeNodes(blueprint: proposal.blueprint, canvasId: canvasId, ownerId: graph.canvas.ownerId)
        let desiredById = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        let managedCurrent = graph.nodes.filter { $0.id.hasPrefix("\(canvasId)-wf-") }
        let currentIds = Set(managedCurrent.map(\.id))
        let desiredIds = Set(desired.map(\.id))
        var changes: [PlanChange] = []
        for id in currentIds.subtracting(desiredIds).sorted() {
            changes.append(PlanChange(kind: .removeNode, node: nil, nodeId: id, title: nil, status: nil))
        }
        for node in desired where !currentIds.contains(node.id) {
            changes.append(.addNode(node))
        }
        for current in managedCurrent {
            guard let node = desiredById[current.id] else { continue }
            changes.append(PlanChange(
                kind: .updateNode,
                node: nil,
                nodeId: current.id,
                title: node.title,
                status: .ready,
                schema: node.schema,
                contextSources: node.contextSources,
                dependsOnNodeIds: node.dependsOnNodeIds,
                nodeKind: .step,
                layout: node.layout,
                schedule: node.schedule,
                executionMode: node.executionMode,
                clearGate: node.gate == nil,
                gate: node.gate,
                approvers: node.approvers,
                source: .planner,
                doerId: node.doerId,
                reviewerIds: node.reviewerIds,
                approverIds: node.approverIds,
                handoffPolicy: node.handoffPolicy
            ))
        }
        let graphProposal = try PlannerBoardBridge.graphChangeProposal(
            summary: proposal.blueprint.summary.isEmpty ? "Update workflow from proposal \(proposal.id)" : proposal.blueprint.summary,
            changes: changes,
            for: canvasId,
            snapshot: snapshot,
            actorUserId: graph.canvas.ownerId
        )
        _ = try PlannerBoardBridge.approveProposal(
            proposalId: graphProposal.id,
            for: canvasId,
            snapshot: snapshot,
            actorUserId: graph.canvas.ownerId
        )
        _ = try PlannerBoardBridge.applyProposal(
            proposalId: graphProposal.id,
            for: canvasId,
            snapshot: snapshot,
            actorUserId: graph.canvas.ownerId
        )
        let applied = try WorkflowProposalStore.shared.markApplied(id: proposal.id, canvasId: canvasId)
        BoardServer.shared.broadcastStateChanged()
        return WorkflowApplyEnvelope(proposal: applied, canvasId: canvasId, created: false)
    }

    private static func scheduleValue(_ spec: WorkflowBlueprintSchedule) -> PlannerNodeSchedule {
        let cadence = PlannerScheduleCadence(rawValue: spec.cadence) ?? .interval
        let seconds: Int
        switch cadence {
        case .interval: seconds = max(60, (spec.intervalMinutes ?? 60) * 60)
        case .daily: seconds = 86_400
        case .monthly: seconds = 2_678_400
        }
        return PlannerNodeSchedule(
            enabled: false,
            intervalSeconds: seconds,
            prompt: spec.prompt,
            cadence: cadence,
            timeZoneIdentifier: spec.timeZone,
            hour: spec.hour,
            minute: spec.minute,
            dayOfMonth: spec.dayOfMonth
        )
    }

    private static func managedNodeId(canvasId: String, stepId: String) -> String {
        "\(canvasId)-wf-\(stepId)"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueTrackers(_ trackers: [WorkflowBlueprintTracker]) -> [WorkflowBlueprintTracker] {
        var seen = Set<String>()
        return trackers.filter { seen.insert($0.id).inserted }
    }

    private static func trackerContract(_ tracker: WorkflowBlueprintTracker) -> String {
        let tabs = tracker.tabs.map { "\($0.title)(\($0.columns.joined(separator: ", ")))" }
            .joined(separator: "; ")
        let policies = tracker.fieldPolicies.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "\(tracker.title) via \(tracker.connector); tabs: \(tabs); field policies: \(policies)"
    }

    private static func executionGoal(
        _ goal: String,
        trackers: [WorkflowBlueprintTracker],
        blueprint: WorkflowBlueprint
    ) -> String {
        var clauses = [goal]
        if !trackers.isEmpty {
            clauses.append("Tracker contract: " + trackers.map(trackerContract).joined(separator: " | "))
        }
        let policies = (blueprint.integrationPolicies ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        if !policies.isEmpty {
            clauses.append("Integration policies: \(policies). Never exceed these permissions.")
        }
        return clauses.joined(separator: "\n")
    }
}
