---
name: meee2
description: Use this skill when turning natural-language business processes into Meee2 workflow canvases, proposing or changing workflows, managing recurring jobs, executing planner nodes, or writing structured canvas artifacts through MCP.
metadata:
  short-description: Create and run Meee2 workflows
---

# Meee2 Skill

Meee2 Runtime is the source of truth for planner canvases, nodes, runs, routes, orchestration profiles, and artifacts. Terminal text is not enough to update the product UI. Use the Meee2 MCP tools whenever a task says you are executing a Meee2 planner node, working on a canvas, or gives you a `canvasId` and `nodeId`.

Canvas Orchestration Profile is the runtime model truth for a canvas: workflow, monitor, or rules engine kind plus semantic role slots, state slots, and action capabilities. It is owned by Meee2. Read it through `read_canvas_context`; do not read or edit `orchestration-profile.json` from the session cwd.

## Workflow Creation Flow

When the user describes a business process instead of an existing node:

1. Translate it into one complete blueprint: business steps, dependencies, tracker tabs, per-field write policy, required integrations, and recurring schedules.
2. Call `propose_workflow`. By default it stores the draft and immediately opens the single required approval in the meee2 Board. It must not create external resources or a Canvas before that Board approval. Do not ask for another confirmation in chat and do not call `apply_workflow_proposal` again.
3. Explain the result in business language and tell the user that it is waiting in the Board. Keep Canvas ids, node ids, routing, and runtime internals out of the primary explanation unless the user asks.
4. Use `draftOnly=true` only when the user explicitly asks to save a draft without opening approval. `apply_workflow_proposal` is only for submitting one of those draft-only proposals later or retrying a missing approval request.
5. After the Board approval creates or updates the Canvas, call `dry_run_workflow` to validate the structure without dispatching agents or writing external systems.
6. Call `enable_workflow` only to request a separate Board approval, because enabling creates future side effects. `pause_workflow` also creates a human approval request.

For an existing Canvas, call `propose_workflow_change` with the full desired blueprint. It also opens Board approval by default. Do not mutate the graph directly. Use `read_workflow_proposal` and `revise_workflow_proposal` while refining a draft; a revision opens a fresh approval and supersedes the older pending version unless `draftOnly=true`. Use `get_workflow_status` for a business-level status summary.

Tracker field policies are safety boundaries:

- `human_only`: AI may read but never overwrite the field.
- `ai_suggest`: AI may propose a value; a human approves the update.
- `ai_write`: AI may update the external object through its real connector.

Every integration also has a policy: `read_only`, `draft_only`, or `write`. If the user asks to read email and draft outreach, use `read_only` for the mailbox integration and `draft_only` for the outreach path. Omitted integration policies default to `read_only`.

Never treat `apply_workflow_proposal` as approval to create a Google Sheet, send outreach, modify email, or enable schedules. Those remain separate connector actions or approvals.

## Required Flow

1. Call `read_node_contract` first with the provided `canvasId` and `nodeId`.
2. Use the returned contract as the authority for inputs, outputs, allowed route targets, artifact schemas, and completion criteria.
3. Do the work using any relevant local tools or external MCP servers.
4. Finish by calling `submit_node_output` for the same `canvasId` and `nodeId`.
5. If you are blocked, still call `submit_node_output` with `status: "blocked"` and put the concrete blocker in `message.summary`.

If the task is canvas-level, rules-driven, or needs role/action/state semantics, call `read_canvas_context` with the `canvasId` before acting.

If tool names are namespaced, use `mcp__meee2__read_canvas_context`, `mcp__meee2__read_node_contract`, `mcp__meee2__submit_node_output`, `mcp__meee2__attach_artifact_to_node`, `mcp__meee2__update_artifact`, and `mcp__meee2__update_artifact_views`.

## Canvas Context

Use `read_canvas_context` when you need:

- the canvas orchestration kind, such as `workflow-graph-v1`, `monitor-observer-v1`, or `poker-rules-v1`;
- semantic `roleSlots`, `stateSlots`, or action `capability` bindings;
- graph-level context such as nodes, edges, artifacts, proposals, and render/orchestration profile status.

Treat `orchestrationProfile` as read-only context. To change the runtime model, ask Meee2 for an owner-approved orchestration profile replacement proposal instead of editing files directly.

## Output Rules

Use `submit_node_output` for final node state:

```json
{
  "canvasId": "canvas-id",
  "nodeId": "node-id",
  "status": "done",
  "message": {
    "summary": "Short result summary",
    "routeTo": ["owner"]
  },
  "artifacts": [
    {
      "kind": "kanban",
      "title": "Idea List",
      "reference": "idea_list_kanban",
      "payload": {
        "type": "kanban",
        "version": 1,
        "columns": [{ "id": "backlog", "title": "Backlog" }],
        "items": []
      },
      "routeTo": ["owner"]
    }
  ],
  "next": "complete"
}
```

Allowed final statuses are `done`, `blocked`, and `needs_review`. Allowed `next` values are `complete`, `blocked`, and `needs_owner_review`.

## Artifact Payloads

Supported `payload.type` values are `text`, `html`, `kanban`, `integration`, `json`, and `file`.

Small payloads can be inline. Large text, HTML, JSON, reports, and generic files should be written inside the current workspace, then submitted with a file reference:

```json
{
  "type": "html",
  "file": {
    "path": "report.html",
    "mimeType": "text/html",
    "name": "report.html"
  }
}
```

Meee2 copies file-backed artifacts into its own artifact store. Do not rely on the original session workspace path as the long-term artifact location.

For integrations, do not copy entire external systems into Meee2 by default. Submit a reference envelope with provider, URL or external id, summary, and status.

Write rules for external objects — the canvas never fetches from external systems, so a mirror only stays truthful if the writer keeps it so:

- **Declared output target.** If your node contract has `output.external_write_target` (`{connector, ref}`), that ref IS your output. Write the result directly to the real external object using that connector's tools (e.g. the Google Sheets MCP), then `submit_node_output` with `status: "done"` and the same ref as `artifact.reference`. Do NOT call `update_artifact` to fake the mirror — meee2 dispatches a reconcile sync automatically after a done submit and pulls the authoritative snapshot back. If the connector is not connected or the write fails, `submit_node_output` with `status: "blocked"` and the concrete reason; never degrade to writing only the mirror.
- **Incidental external mutation.** If you mutate some OTHER external object an artifact mirrors mid-work (not your declared output target — e.g. closing an issue, merging a PR), call `update_artifact` for that reference in the same working step to refresh its snapshot facts (`fields.rows`, `fields.updated`, summary) to match what you just did.

Before working on a shared external object, pull its current snapshot with `get_artifact` instead of trusting your memory of it.

Artifact Views are named projections over artifact data, such as `table`, `list`, `kanban`, `raw`, or `json`. Do not put `views` inside `submit_node_output`, `attach_artifact_to_node`, or `update_artifact` payloads. Use `update_artifact_views` when you need to add, update, or delete view tabs without changing artifact data versions.

## Common Mistakes

- Do not finish by only saying that an artifact was attached.
- Do not paste large HTML or reports directly into `payload`.
- Do not duplicate one data artifact just to create multiple display tabs; write Artifact Views with `update_artifact_views`.
- Do not submit route targets that are not allowed by `read_node_contract`.
- Do not read or edit `orchestration-profile.json` directly from the workspace; use `read_canvas_context`.
- Do not invent missing input. If required input is absent, submit a blocked result with a specific reason.
- Do not show tool traces or command output as user-facing artifact content unless the node explicitly asks for logs.
