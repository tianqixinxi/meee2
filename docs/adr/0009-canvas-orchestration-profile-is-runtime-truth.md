# Canvas Orchestration Profile Defines Runtime Model Without Duplicating Graph Truth

Canvas runtime orchestration is modeled through a canvas-owned Orchestration Profile stored in `orchestration-profile.json`, alongside `render-profile.json`. Render Profile remains the presentation truth; Orchestration Profile is the runtime model truth; Artifacts and `canvasRuntime` remain the live state truth.

Workflow is an orchestration kind, not an implicit default hidden in the graph. v1 supports the built-in kinds `workflow-graph-v1`, `monitor-observer-v1`, and `poker-rules-v1`. The profile may carry global policy and semantic bindings, but it must not copy nodes, edges, statuses, gates, or current scene state.

For rules-assisted scenes such as Poker Table, the Rules Orchestrator remains deterministic canvas runtime behavior. It is not a node, GM, Dealer, renderer, or AI session. Dealer / Table State is only the node-scoped home for authoritative `game-state.json` and `action-log.json`; phase, pot, hand state, next actor, and auto-run state continue to come from artifacts and runtime snapshots.

Template Intake Policy belongs to template metadata. It helps natural-language creation choose and adapt templates, but it is not an Assistant Profile and does not create `assistant-profile.json`. If future canvases need durable AI behavior policy, that should be evaluated as a separate decision.

Legacy `sceneSpec.orchestration` is retained only as a migration source. New runtime model writes go through `orchestration-profile.json`, and profile replacement requires the same owner-approved proposal governance used for render-logic changes.
