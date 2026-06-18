---
name: meee2
description: Use this skill when you are executing a Meee2 planner node, working on a Meee2 canvas, reading canvas orchestration/runtime context, submitting planner output, attaching artifacts, routing outputs, or keeping the Meee2 UI in sync through MCP.
metadata:
  short-description: Execute Meee2 planner nodes
---

# Meee2 Skill

Meee2 Runtime is the source of truth for planner canvases, nodes, runs, routes, orchestration profiles, and artifacts. Terminal text is not enough to update the product UI. Use the Meee2 MCP tools whenever a task says you are executing a Meee2 planner node, working on a canvas, or gives you a `canvasId` and `nodeId`.

Canvas Orchestration Profile is the runtime model truth for a canvas: workflow, monitor, or rules engine kind plus semantic role slots, state slots, and action capabilities. It is owned by Meee2. Read it through `read_canvas_context`; do not read or edit `orchestration-profile.json` from the session cwd.

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
