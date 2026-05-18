import Foundation

// P3 of the planner Run layer — the EXECUTION-layer policy.
//
// `WorkflowRunEngine` is deliberately separate from `PlannerAgentRuntime`:
//   · PlannerAgentRuntime = governance — produces graph-change *proposals*.
//   · WorkflowRunEngine   = execution — advances a *run* over a fixed graph.
//
// Decision B (semi-automatic): when a node finishes, the engine surfaces every
// now-unblocked downstream node as `readyToDispatch` — but it NEVER dispatches
// or binds a session itself. A human still pulls the trigger. The engine only
// recomputes run status + per-node `nextAction`; it has no autonomous loop.

/// What the user should do next for a node, in the context of a run. Derived
/// from the node's run-state plus whether its upstream dependencies are done.
enum RunNextAction: String, Codable, Equatable {
    /// Upstream dependencies are not all done — nothing to do yet.
    case waitingOnUpstream = "waiting-on-upstream"
    /// Dependencies satisfied, no session yet — dispatch or bind one.
    case readyToDispatch = "ready-to-dispatch"
    /// A session is executing this node — open it to follow progress.
    case inProgress = "in-progress"
    /// Parked at a human gate — review and resolve it.
    case gateReview = "gate-review"
    /// Done — confirm the produced artifacts are attached.
    case confirmArtifacts = "confirm-artifacts"
    /// Failed — needs human diagnosis before the run can move on.
    case needsAttention = "needs-attention"
}

enum WorkflowRunEngine {
    /// Recompute a run after an execution-layer mutation.
    ///
    /// - Refreshes every node's `nextAction` (decision B — downstream nodes
    ///   become `readyToDispatch` once their deps are done).
    /// - Rolls the run `status` up: `failed` if any node failed, `completed`
    ///   when every node is done, otherwise unchanged.
    /// - Aborted runs are returned untouched — a human end-state is terminal.
    static func advance(_ run: WorkflowRun, nodes: [PlanningNode]) -> WorkflowRun {
        guard run.status == .active else { return run }
        var updated = run
        let depsByNode = dependencies(of: nodes)

        for nodeId in updated.nodeStates.keys {
            var state = updated.nodeStates[nodeId]!
            state.nextAction = nextAction(
                for: state,
                deps: depsByNode[nodeId] ?? [],
                states: updated.nodeStates
            )
            updated.nodeStates[nodeId] = state
        }

        let runStates = updated.nodeStates.values.map { $0.runState }
        if !runStates.isEmpty {
            if runStates.contains(.failed) {
                updated.status = .failed
                updated.finishedAt = updated.finishedAt ?? Date()
            } else if runStates.allSatisfy({ $0 == .done }) {
                updated.status = .completed
                updated.finishedAt = updated.finishedAt ?? Date()
            }
        }
        return updated
    }

    /// The next-action for a single node given its run-state and the run-state
    /// of its upstream dependencies.
    static func nextAction(
        for state: RunNodeState,
        deps: [String],
        states: [String: RunNodeState]
    ) -> RunNextAction {
        switch state.runState {
        case .failed:
            return .needsAttention
        case .done:
            return .confirmArtifacts
        case .gateWait:
            return .gateReview
        case .dispatched, .running:
            return .inProgress
        case .pending:
            let upstreamAllDone = deps.allSatisfy { depId in
                states[depId]?.runState == .done
            }
            return upstreamAllDone ? .readyToDispatch : .waitingOnUpstream
        }
    }

    /// nodeId → its `dependsOnNodeIds` (empty when the node has none).
    private static func dependencies(of nodes: [PlanningNode]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for node in nodes {
            map[node.id] = node.dependsOnNodeIds ?? []
        }
        return map
    }
}
