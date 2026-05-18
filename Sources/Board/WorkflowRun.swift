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
    /// Artifacts produced by this node *in this run*.
    var artifactIds: [String]
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
        artifactIds: [String] = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        nextAction: RunNextAction? = nil
    ) {
        self.nodeId = nodeId
        self.runState = runState
        self.attempts = attempts
        self.sessionId = sessionId
        self.chatThreadId = chatThreadId
        self.artifactIds = artifactIds
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.nextAction = nextAction
    }
}

// MARK: - WorkflowRun

/// One execution of a planner canvas's blueprint.
struct WorkflowRun: Codable, Equatable {
    var id: String
    var canvasId: String
    /// 1-based, auto-incrementing within the canvas. Run #1, #2, …
    var runIndex: Int
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
        self.status = status
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.nodeStates = nodeStates
        self.events = events
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
        now: Date = Date()
    ) -> WorkflowRun {
        var states: [String: RunNodeState] = [:]
        for node in nodes {
            states[node.id] = RunNodeState(nodeId: node.id, runState: .pending)
        }
        return WorkflowRun(
            id: "run-\(canvasId)-\(runIndex)-\(UUID().uuidString.lowercased().prefix(8))",
            canvasId: canvasId,
            runIndex: runIndex,
            status: .active,
            trigger: trigger,
            startedAt: now,
            nodeStates: states
        )
    }

    /// Migration path: pack a canvas's *current* per-node execution state into
    /// a synthetic Run #1. Used once, at load time, for canvases persisted
    /// before the Run layer existed (workflow-run-spec.md §9).
    static func migratedRunOne(
        canvasId: String,
        nodes: [PlanningNode],
        artifacts: [PlannerArtifact],
        now: Date = Date()
    ) -> WorkflowRun {
        var states: [String: RunNodeState] = [:]
        for node in nodes {
            let runState = node.workflowRunState ?? .pending
            let artifactIds = artifacts
                .filter { $0.nodeId == node.id }
                .map { $0.id }
            states[node.id] = RunNodeState(
                nodeId: node.id,
                runState: runState,
                attempts: [],
                sessionId: node.sessionId,
                artifactIds: artifactIds
            )
        }
        let inferredStatus = inferStatus(from: nodes.map { $0.workflowRunState ?? .pending })
        return WorkflowRun(
            id: "run-\(canvasId)-1-migrated",
            canvasId: canvasId,
            runIndex: 1,
            status: inferredStatus,
            trigger: "migration",
            startedAt: now,
            finishedAt: inferredStatus == .active ? nil : now,
            nodeStates: states
        )
    }

    /// Best-effort run status from a snapshot of node run-states.
    static func inferStatus(from runStates: [PlannerWorkflowRunState]) -> WorkflowRunStatus {
        guard !runStates.isEmpty else { return .active }
        if runStates.contains(.failed) { return .failed }
        if runStates.allSatisfy({ $0 == .done }) { return .completed }
        return .active
    }
}
