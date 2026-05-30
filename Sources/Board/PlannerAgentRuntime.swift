import Foundation

// Phase 8 planner-graph: a swappable **agent runtime** that sits *above* the
// Phase 1 `PlannerAdapter`.
//
// Where `PlannerAdapter` is a one-shot "graph context + goal → PlanProposal"
// translator, the `PlannerAgentRuntime` is the policy layer: it decides, given
// a planner *event* and the current graph state, *whether* to act and *what*
// proposals to produce. It never persists, never approves, never applies — it
// only ever returns pending `PlanProposal`s for the human approval gate.
//
// The seam is deliberately single-point: `PlannerAgentRuntimeRegistry.shared`.
// A user replacing meee2's planner with their own evolution engine swaps the
// whole runtime in one line; nothing else in the planner surface needs to
// change.

// MARK: - Events

/// The inputs a planner agent runtime reacts to.
///
/// Each case carries the `canvasId` it pertains to so a replacement runtime can
/// be canvas-aware without re-deriving it.
enum PlannerAgentEvent: Equatable {
    /// The owner asked the planner to (re)generate a plan from a goal.
    case userGoal(canvasId: String, goal: String, context: String?)
    /// A drift inspection was requested for a canvas (manual or scheduled).
    case driftInspection(canvasId: String)
    /// A planner node's workflow run-state changed (e.g. a bound session moved
    /// `running → failed`). Emitted from the Phase 2 run-state feedback path.
    case nodeRunStateChanged(canvasId: String, nodeId: String, runState: PlannerWorkflowRunState)
    /// A milestone node completed — the hook for rolling-milestone expansion.
    case milestoneCompleted(canvasId: String, nodeId: String)

    /// The canvas this event pertains to.
    var canvasId: String {
        switch self {
        case .userGoal(let canvasId, _, _):
            return canvasId
        case .driftInspection(let canvasId):
            return canvasId
        case .nodeRunStateChanged(let canvasId, _, _):
            return canvasId
        case .milestoneCompleted(let canvasId, _):
            return canvasId
        }
    }
}

// MARK: - Outcome

/// The result of a runtime handling one `PlannerAgentEvent`.
///
/// Every proposal in `proposals` is `pending` — the runtime never approves or
/// applies. When the runtime decides nothing is needed it returns an *empty*
/// `proposals` list and sets `noActionReason` to a human-readable explanation.
struct PlannerAgentOutcome: Equatable {
    /// Pending proposals produced by the runtime (may be empty).
    var proposals: [PlanProposal]
    /// Why the runtime produced these proposals (for logs / UI).
    var rationale: String?
    /// Risks the runtime wants a human to weigh before approving.
    var risks: [String]
    /// Set (with empty `proposals`) when the runtime decided no action is
    /// needed — e.g. a healthy graph or a non-failure run-state change.
    var noActionReason: String?

    init(
        proposals: [PlanProposal] = [],
        rationale: String? = nil,
        risks: [String] = [],
        noActionReason: String? = nil
    ) {
        self.proposals = proposals
        self.rationale = rationale
        self.risks = risks
        self.noActionReason = noActionReason
    }

    /// Convenience: a "did nothing, here's why" outcome.
    static func noAction(_ reason: String) -> PlannerAgentOutcome {
        PlannerAgentOutcome(proposals: [], noActionReason: reason)
    }
}

// MARK: - Runtime protocol

/// The swappable planner agent runtime.
///
/// One async entry point: react to a `PlannerAgentEvent` against a
/// `PlannerGraphState`, using the same `AssistantSettings` the Phase 1 adapter
/// consumes. Implementations MUST only ever produce `pending` proposals — the
/// human approval gate is not optional.
protocol PlannerAgentRuntime {
    func handle(
        _ event: PlannerAgentEvent,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome
}

// MARK: - Default implementation

/// The DEFAULT planner agent runtime.
///
/// Design contract — read before replacing:
/// - **No autonomous loop.** This runtime is purely *event-triggered*: it acts
///   only when `handle(_:state:settings:)` is called. It never schedules
///   itself, never polls, never runs in the background.
/// - **Proposals only, never applies.** Every outcome contains `pending`
///   proposals (or `noActionReason`). The runtime never approves or applies a
///   proposal — the human approval gate stays in full force.
/// - **Conservative on run-state.** A `.nodeRunStateChanged` event only yields
///   a proposal for an outright failure/blocked state; everything else is a
///   `noActionReason`.
/// - **Expected to be replaced.** This implementation is intentionally minimal.
///   A user bringing their own evolution engine swaps it in via
///   `PlannerAgentRuntimeRegistry.shared`; `.milestoneCompleted` in particular
///   is a no-op here precisely so a replacement runtime can own rolling
///   milestone expansion.
final class DefaultPlannerAgentRuntime: PlannerAgentRuntime {
    /// Builds the Phase 1 adapter for a given settings object. Injectable so
    /// tests can substitute a `FakeAssistantProvider`-backed adapter.
    private let adapterFactory: (AssistantSettings) -> PlannerAdapter

    /// Default: a real `BYOAPlannerAdapter`.
    init() {
        self.adapterFactory = { settings in BYOAPlannerAdapter(settings: settings) }
    }

    /// Test / advanced seam: inject an adapter factory.
    init(adapterFactory: @escaping (AssistantSettings) -> PlannerAdapter) {
        self.adapterFactory = adapterFactory
    }

    func handle(
        _ event: PlannerAgentEvent,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        switch event {
        case .userGoal(_, let goal, let context):
            return try await handleUserGoal(goal: goal, context: context, state: state, settings: settings)
        case .driftInspection:
            return try await handleDriftInspection(state: state, settings: settings)
        case .nodeRunStateChanged(_, let nodeId, let runState):
            return try await handleNodeRunStateChanged(
                nodeId: nodeId,
                runState: runState,
                state: state,
                settings: settings
            )
        case .milestoneCompleted:
            // Deliberately minimal: rolling-milestone expansion is left for a
            // replacement runtime. The event exists so that replacement can
            // implement it without changing this protocol.
            return .noAction("milestone evolution not yet implemented in DefaultPlannerAgentRuntime")
        }
    }

    // MARK: .userGoal

    /// Delegate to the Phase 1 adapter. If the adapter/provider fails, surface
    /// the error instead of fabricating a local proposal.
    private func handleUserGoal(
        goal: String,
        context: String?,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        let adapter = adapterFactory(settings)
        // Fold any extra context into the goal so the adapter prompt sees it
        // without widening the Phase 1 adapter signature.
        let effectiveGoal: String = {
            guard let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return goal
            }
            return goal.isEmpty ? context : "\(goal)\n\nContext:\n\(context)"
        }()
        let proposal = try await adapter.generateProposal(for: state, goal: effectiveGoal)
        return PlannerAgentOutcome(
            proposals: [proposal],
            rationale: "Generated a plan from the owner goal via the planner adapter."
        )
    }

    // MARK: .driftInspection

    /// Ask the adapter for a corrective proposal for the first blocked node,
    /// or return `noActionReason` if the graph is healthy.
    private func handleDriftInspection(
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        guard let blocked = state.states.first(where: { $0.runState == .blocked }),
              let node = state.nodes.first(where: { $0.id == blocked.nodeId }) else {
            return .noAction("planner graph is healthy — no blocked nodes")
        }
        let correctiveGoal = """
        Node "\(node.title)" (id: \(node.id)) is blocked.
        Current blockers: \(blocked.blockers.joined(separator: ", ")).
        Propose ONE small corrective change to recover this node. Keep the proposal pending.
        """
        let adapter = adapterFactory(settings)
        let proposal = try await adapter.generateProposal(for: state, goal: correctiveGoal)
        return PlannerAgentOutcome(
            proposals: [proposal],
            rationale: "Node \(node.id) is blocked; proposed a corrective change via the planner adapter.",
            risks: ["Corrective proposal — review before approving; the blocker may need human diagnosis."]
        )
    }

    // MARK: .nodeRunStateChanged

    /// CONSERVATIVE: only act on an outright failure/blocked run-state. For any
    /// other state, return a `noActionReason` — the runtime never reacts to
    /// healthy progress. When it does act, it produces exactly ONE pending
    /// corrective proposal via the adapter, prompted with the failed node.
    private func handleNodeRunStateChanged(
        nodeId: String,
        runState: PlannerWorkflowRunState,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        guard runState == .failed else {
            return .noAction("run-state \(runState.rawValue) is not a failure — no corrective action needed")
        }
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            return .noAction("run-state change references unknown node \(nodeId)")
        }
        let correctiveGoal = """
        Node "\(node.title)" (id: \(node.id)) reported run-state "failed".
        Propose ONE small corrective change to recover this node — e.g. retry, \
        rescope, or flag it for human diagnosis. Keep the proposal pending.
        """
        let adapter = adapterFactory(settings)
        let proposal = try await adapter.generateProposal(for: state, goal: correctiveGoal)
        return PlannerAgentOutcome(
            proposals: [proposal],
            rationale: "Node \(node.id) failed; proposed a corrective change via the planner adapter.",
            risks: ["Corrective proposal — review before approving; the failure may need a human diagnosis."]
        )
    }

}

// MARK: - Registry (the single injection seam)

/// THE seam.
///
/// Every planner entry point routes through `PlannerAgentRuntimeRegistry.shared`
/// instead of touching a `PlannerAdapter` directly. To replace
/// meee2's planner brain with your own evolution engine, do exactly one thing:
///
/// ```swift
/// PlannerAgentRuntimeRegistry.shared = MyEvolutionRuntime()
/// ```
///
/// Nothing else in the planner HTTP surface or board bridge needs to change.
enum PlannerAgentRuntimeRegistry {
    /// The active planner agent runtime. Defaults to the no-autonomous-loop
    /// `DefaultPlannerAgentRuntime`; assign to swap the whole runtime.
    static var shared: PlannerAgentRuntime = DefaultPlannerAgentRuntime()
}
