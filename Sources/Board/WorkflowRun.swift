import Foundation

// Phase 1 of the planner Run layer (see meee2-workspace/doc/workflow-run-spec.md).
//
// A planner *canvas* is a single, mutable graph — the **design / blueprint**.
// Executing that blueprint produces a `WorkflowRun`: an immutable-per-attempt
// record of one pass over the graph. Execution state (run-state, bound session,
// produced artifacts) lives in the run's `nodeStates`, NOT on `PlanningNode` —
// so a blueprint can be run many times and each run keeps its own history.
//
// This file defines only the model + pure helpers. Persistence lives in
// `PlannerStore`; run-scoped mutation/endpoints are wired in `PlannerCore` /
// `BoardAPI`.

// MARK: - Run status

/// Lifecycle of one `WorkflowRun`.
enum WorkflowRunStatus: String, Codable, Equatable {
    /// The run is in progress — execution-layer actions land on it.
    case active
    /// Every terminal node reached `done`.
    case completed
    /// The run hit an unrecoverable failure.
    case failed
    /// A human terminated the run before it finished.
    case aborted
}

// MARK: - Per-node, per-run execution state

/// One attempt at executing a node within a run. A node that fails a gate and
/// is retried accumulates multiple attempts; the last one is the live attempt.
struct NodeAttempt: Codable, Equatable {
    /// 0-based attempt index within the node's `attempts` list.
    var index: Int
    /// Session bound to this attempt (a spawning runner) — `nil` for human/CI.
    var sessionId: String?
    /// Run-state this attempt ended in (or is currently in, if live).
    var runState: PlannerWorkflowRunState
    var startedAt: Date
    var finishedAt: Date?
    /// `done` / `failed` / a free-text rollback reason — `nil` while live.
    var outcome: String?

    init(
        index: Int,
        sessionId: String? = nil,
        runState: PlannerWorkflowRunState,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        outcome: String? = nil
    ) {
        self.index = index
        self.sessionId = sessionId
        self.runState = runState
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
    }
}

/// The execution state of one `PlanningNode` *within a specific run*.
///
/// Named `RunNodeState` (not the spec's `NodeRunState`) because `NodeRunState`
/// is already an enum elsewhere in the planner core.
struct RunNodeState: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case nodeId
        case runState
        case attempts
        case sessionId
        case chatThreadId
        case assigneeId
        case artifactIds
        case outputRefs
        case startedAt
        case finishedAt
        case nextAction
    }

    var nodeId: String
    /// Current run-state of the node in this run.
    var runState: PlannerWorkflowRunState
    /// Attempt history — gate retries / re-dispatches append here.
    var attempts: [NodeAttempt]
    /// The session bound / dispatched for the live attempt. Q3 decision:
    /// exactly one active session per `(run, node)` — parallel sessions are
    /// not modelled; re-dispatch starts a new attempt instead.
    var sessionId: String?
    var chatThreadId: String?
    /// Actual responsible person for this node in this delivery. Falls back to
    /// the blueprint node's default assignee when nil.
    var assigneeId: String?
    /// Artifacts produced by this node *in this run*.
    var artifactIds: [String]
    /// User-facing output references produced by this node in this run.
    var outputRefs: [String]
    var startedAt: Date?
    var finishedAt: Date?
    /// What the user should do next for this node, recomputed by
    /// `WorkflowRunEngine.advance`. Derived — never set by hand.
    var nextAction: RunNextAction?

    init(
        nodeId: String,
        runState: PlannerWorkflowRunState = .pending,
        attempts: [NodeAttempt] = [],
        sessionId: String? = nil,
        chatThreadId: String? = nil,
        assigneeId: String? = nil,
        artifactIds: [String] = [],
        outputRefs: [String] = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        nextAction: RunNextAction? = nil
    ) {
        self.nodeId = nodeId
        self.runState = runState
        self.attempts = attempts
        self.sessionId = sessionId
        self.chatThreadId = chatThreadId
        self.assigneeId = assigneeId
        self.artifactIds = artifactIds
        self.outputRefs = outputRefs
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.nextAction = nextAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.nodeId = try container.decode(String.self, forKey: .nodeId)
        self.runState = try container.decode(PlannerWorkflowRunState.self, forKey: .runState)
        self.attempts = try container.decodeIfPresent([NodeAttempt].self, forKey: .attempts) ?? []
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.chatThreadId = try container.decodeIfPresent(String.self, forKey: .chatThreadId)
        self.assigneeId = try container.decodeIfPresent(String.self, forKey: .assigneeId)
        self.artifactIds = try container.decodeIfPresent([String].self, forKey: .artifactIds) ?? []
        self.outputRefs = try container.decodeIfPresent([String].self, forKey: .outputRefs) ?? []
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.nextAction = try container.decodeIfPresent(RunNextAction.self, forKey: .nextAction)
    }
}

// MARK: - WorkflowRun

/// One execution of a planner canvas's blueprint.
struct WorkflowRun: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id
        case canvasId
        case runIndex
        case title
        case summary
        case responsibleUserId
        case linkedArtifactRefs
        case updatedAt
        case status
        case trigger
        case startedAt
        case finishedAt
        case nodeStates
        case events
    }

    var id: String
    var canvasId: String
    /// 1-based, auto-incrementing within the canvas. Run #1, #2, …
    var runIndex: Int
    /// User-facing delivery name. The internal run index remains only a
    /// secondary/debug identifier.
    var title: String
    var summary: String?
    var responsibleUserId: String?
    var linkedArtifactRefs: [String]
    var updatedAt: Date
    var status: WorkflowRunStatus
    /// Who/what started the run — an actor id, `"schedule"`, or
    /// `"template-instantiate"`.
    var trigger: String
    var startedAt: Date
    var finishedAt: Date?
    /// nodeId → execution state for that node in this run.
    var nodeStates: [String: RunNodeState]
    /// This run's timeline (scoped to the run, not a global flat log).
    var events: [PlannerEvent]

    init(
        id: String,
        canvasId: String,
        runIndex: Int,
        title: String? = nil,
        summary: String? = nil,
        responsibleUserId: String? = nil,
        linkedArtifactRefs: [String] = [],
        updatedAt: Date? = nil,
        status: WorkflowRunStatus = .active,
        trigger: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        nodeStates: [String: RunNodeState] = [:],
        events: [PlannerEvent] = []
    ) {
        self.id = id
        self.canvasId = canvasId
        self.runIndex = runIndex
        self.title = WorkflowRun.normalizedTitle(title, runIndex: runIndex)
        self.summary = summary
        self.responsibleUserId = responsibleUserId
        self.linkedArtifactRefs = linkedArtifactRefs
        self.updatedAt = updatedAt ?? startedAt
        self.status = status
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.nodeStates = nodeStates
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.canvasId = try container.decode(String.self, forKey: .canvasId)
        self.runIndex = try container.decode(Int.self, forKey: .runIndex)
        self.title = WorkflowRun.normalizedTitle(
            try container.decodeIfPresent(String.self, forKey: .title),
            runIndex: runIndex
        )
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.responsibleUserId = try container.decodeIfPresent(String.self, forKey: .responsibleUserId)
        self.linkedArtifactRefs = try container.decodeIfPresent([String].self, forKey: .linkedArtifactRefs) ?? []
        self.status = try container.decode(WorkflowRunStatus.self, forKey: .status)
        self.trigger = try container.decode(String.self, forKey: .trigger)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? finishedAt ?? startedAt
        self.nodeStates = try container.decodeIfPresent([String: RunNodeState].self, forKey: .nodeStates) ?? [:]
        self.events = try container.decodeIfPresent([PlannerEvent].self, forKey: .events) ?? []
    }

    private static func normalizedTitle(_ title: String?, runIndex: Int) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Delivery #\(runIndex)" : trimmed
    }
}

// MARK: - Construction helpers

extension WorkflowRun {
    /// Start a fresh run over `nodes`: every node initialised to `pending`,
    /// `runIndex` one past the canvas's previous highest run.
    static func start(
        canvasId: String,
        runIndex: Int,
        trigger: String,
        nodes: [PlanningNode],
        title: String? = nil,
        summary: String? = nil,
        responsibleUserId: String? = nil,
        linkedArtifactRefs: [String] = [],
        now: Date = Date()
    ) -> WorkflowRun {
        var states: [String: RunNodeState] = [:]
        for node in nodes {
            let defaultAssignee = node.doerId.trimmingCharacters(in: .whitespacesAndNewlines)
            states[node.id] = RunNodeState(
                nodeId: node.id,
                runState: .pending,
                assigneeId: defaultAssignee.isEmpty ? nil : defaultAssignee
            )
        }
        return WorkflowRun(
            id: "run-\(canvasId)-\(runIndex)-\(UUID().uuidString.lowercased().prefix(8))",
            canvasId: canvasId,
            runIndex: runIndex,
            title: title,
            summary: summary,
            responsibleUserId: responsibleUserId,
            linkedArtifactRefs: linkedArtifactRefs,
            updatedAt: now,
            status: .active,
            trigger: trigger,
            startedAt: now,
            nodeStates: states
        )
    }

}
