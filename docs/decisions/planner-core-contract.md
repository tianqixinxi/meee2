# Planner Core Contract

Status: wjk + Codex contract freeze for the first planner-core spike.

This document freezes the minimum contracts needed for the first owner-controlled
Planner loop. It intentionally avoids UI, realtime presence, and real executor
integration.

## Product Rules

- A canvas is a planning boundary.
- Each canvas has one owner who can edit plan topology.
- Other members can view, suggest, and execute assigned nodes, but cannot edit
  topology directly.
- Planner can propose topology changes, but cannot apply them without owner
  approval.
- Nodes represent executable sessions, not static task cards.

## Contracts

| Contract | Meaning | First consumer |
|---|---|---|
| `PlanningCanvas` | Planning boundary with owner-only edit authority and planner context. | Canvas + permission shell |
| `PlanningNode` | Executable session node with IO, context, mode, executor, doer, and status. | Canvas, Proposal Shell, States Panel |
| `PlanProposal` | Planner-authored change set that must be approved before it mutates nodes. | Proposal Shell |
| `NodeStateSnapshot` | Runtime reality from executor/session state for Planner observation. | Real Planner, Monitor, States Panel |

## Dependency Conclusions

- `NodeMock feeds Canvas + Permission`
  - UI can render a multi-canvas / owner-permission shell from deterministic
    mocked nodes before real executor integration.
- `applyNodeChange feeds Proposal Shell`
  - Proposal UI should preview and apply approved `PlanProposal` changes through
    one core function, instead of mutating nodes directly.
- `NodeState read feeds Real Planner`
  - Planner should observe `NodeStateSnapshot` instead of reading UI state.
- `realtime + presence feeds Multi-user View`
  - Presence and realtime visibility are downstream of this contract and are not
    part of tonight's implementation.

## Tonight's Interface Boundary

The first implementation provides deterministic local behavior only:

- `nodeMock(canvasId:)` returns nodes covering waiting, running, blocked, and
  done states.
- `applyNodeChange(nodes:proposal:)` applies only approved add/update changes.
- `readNodeState(nodes:)` derives runtime snapshots from node status.
- `PlannerAgent` defines the LLM planner seam, with `MockPlannerAgent` producing
  pending proposals for generate, refine, and drift inspection.

## Mock-backed Planner API

The first HTTP surface is intentionally mock-backed:

| Endpoint | Purpose |
|---|---|
| `GET /api/planner/canvases/:id/state` | Return the planning canvas, deterministic mock nodes, and node state snapshots. |
| `POST /api/planner/canvases/:id/proposals/generate` | Generate a pending proposal from an owner goal without mutating topology. |
| `POST /api/planner/canvases/:id/proposals/inspect-drift` | Inspect current mock state and return a pending drift proposal when a node needs attention. |
| `POST /api/planner/canvases/:id/proposals/apply-preview` | Preview an approved application of a proposal without persisting planner topology. |

Future real session integration should replace the mock data source while
keeping these contracts stable.
