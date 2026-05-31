#!/usr/bin/env python3
"""E2E: 「开干」 auto-starts a session AND delivers the initial prompt.

Replicates a node dispatch against the LIVE board (localhost:9876) and checks:

  (A) AUTO-START — dispatch auto-creates a session and BINDS it to the node
      (node.sessionId set + a surface session whose currentTask is this node).
      Headless-verifiable → hard assertion.

  (B) PROMPT DELIVERY — the bound session's claude actually received the initial
      prompt: a transcript with real content appears in the node's managed
      workspace within the timeout (the ready-gated delivery in
      GhosttySurfaceBackend, sequenced after the workspace-trust auto-accept).
      ⚠️ Requires a REAL GUI app: a nohup/headless dev binary can't run a Ghostty
      exec surface (tty=nil → claude never launches), so (B) reports
      "NOT delivered — needs GUI" instead of failing. Pass --require-prompt to
      make (B) a hard assertion (run this from the actual meee2.app).

Side effect: dispatch launches a real claude ghostty surface. Self-cleaning
(detaches + deletes the temp canvas on exit); the spawned surface lingers as a
dead session (no clean-kill endpoint). Per-run unique ids avoid stale-count
pollution.

Run:  python3 scripts/e2e/planner-dispatch-prompt-delivery.py [--require-prompt]
Exit: 0 if (A) holds (and (B) when --require-prompt); 1 otherwise.
"""
import json
import os
import sys
import time
import urllib.request

BASE = "http://localhost:9876"
RUN = str(int(time.time()))
CANVAS_NAME = f"e2e-dispatch-prompt-{RUN}"
NODE_ID = f"n_prompt_{RUN}"
# Run-unique token baked into the node goal. The dispatch prompt carries the
# goal, so finding this exact token in the transcript proves the ACTUAL
# initial prompt reached claude — not just that *some* transcript exists
# (a regression that launches claude but drops/garbles the prompt would still
# write a transcript, so line-count alone is insufficient).
MARKER = f"PONGPROOF{RUN}"
PROMPT_TIMEOUT_S = 45  # claude boot + workspace-trust accept + prompt submit


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        r = urllib.request.urlopen(req, timeout=30)
        return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:200]}


def bound_session(node):
    return (node.get("sessionId") or "").strip()


def session_for_node(node_id):
    _, st = api("GET", "/api/state")
    return next((s for s in st.get("sessions", [])
                 if s.get("currentTask") == f"Node {node_id}"), None)


def transcript_has_marker(ws, marker):
    """True iff a transcript in the node's workspace contains `marker` — i.e.
    the dispatched initial prompt (which carries the goal token) reached claude.
    Also returns the max line count seen (for diagnostics)."""
    enc = "".join(c if c.isalnum() else "-" for c in ws)
    d = os.path.expanduser(f"~/.claude/projects/{enc}")
    if not os.path.isdir(d):
        return False, 0
    found, lines = False, 0
    for f in os.listdir(d):
        if not f.endswith(".jsonl"):
            continue
        with open(os.path.join(d, f), encoding="utf-8", errors="ignore") as fh:
            n = 0
            for line in fh:
                n += 1
                if marker in line:
                    found = True
        lines = max(lines, n)
    return found, lines


def main():
    require_prompt = "--require-prompt" in sys.argv

    _, env = api("POST", "/api/canvases",
                 {"name": CANVAS_NAME, "scope": "personal", "kind": "board"})
    cid = next((c["id"] for c in env.get("canvases", [])
                if c.get("name") == CANVAS_NAME), env.get("activeCanvasId"))
    if not cid:
        print("✗ could not create test canvas")
        return 1
    ws = os.path.expanduser(f"~/.meee2/workspaces/global/{cid}")
    changes = [{"kind": "addNode", "node": {
        "id": NODE_ID, "canvasId": cid, "title": "prompt-delivery node",
        "schema": {"inputs": [], "outputs": ["out"],
                   "goal": f"Reply with exactly the token {MARKER} and nothing else."},
        "contextSources": [], "executionMode": "auto", "executorType": "claude",
        "doerId": "owner", "nodeKind": "step", "status": "ready",
        "dependsOnNodeIds": []}}]
    _, prop = api("POST", f"/api/planner/canvases/{cid}/proposals/graph-change",
                  {"summary": "prompt delivery", "changes": changes})
    pid = prop.get("proposal", {}).get("id")
    api("POST", f"/api/planner/canvases/{cid}/proposals/{pid}/approve")
    api("POST", f"/api/planner/canvases/{cid}/proposals/{pid}/apply")

    rc = 0
    try:
        st, _ = api("POST", f"/api/planner/canvases/{cid}/nodes/{NODE_ID}/dispatch",
                    {"runner": "claude", "cwd": ws})
        print(f"dispatch: HTTP {st}")
        time.sleep(2)

        # (A) AUTO-START — node bound + a surface session for this node.
        _, g = api("GET", f"/api/planner/canvases/{cid}/graph")
        node = next((n for n in g.get("nodes", []) if n["id"] == NODE_ID), {})
        sid = bound_session(node)
        sess = session_for_node(NODE_ID)
        auto_started = bool(sid) and sess is not None
        print(f"\n(A) auto-start: nodeBound={bool(sid)} sessionId={sid[:26]} "
              f"runState={node.get('workflowRunState')} surfaceInState={sess is not None}")
        if auto_started:
            print("    ✓ dispatch auto-started and bound a session")
        else:
            print("    ✗ no session auto-started/bound for the node")
            rc = 1

        # (B) PROMPT DELIVERY — the dispatched prompt (carrying MARKER) reached
        # claude: the workspace transcript must CONTAIN the run-unique token,
        # not merely exist (a dropped/garbled prompt would still write a file).
        print(f"\n(B) prompt delivery: polling for token {MARKER} in transcript (≤{PROMPT_TIMEOUT_S}s)…")
        found, lines = False, 0
        waited = 0
        while waited < PROMPT_TIMEOUT_S:
            time.sleep(3)
            waited += 3
            found, lines = transcript_has_marker(ws, MARKER)
            if found:
                break
        if found:
            print(f"    ✓ prompt delivered — transcript contains the dispatched token ({lines} lines)")
        elif lines > 1:
            # Real regression even headless: claude launched and wrote a
            # transcript, but the dispatched prompt's token is absent.
            print(f"    ✗ claude launched ({lines}-line transcript) but the initial prompt was"
                  " DROPPED/garbled — the dispatched token never reached it")
            rc = 1
        else:
            msg = "    ✗ prompt NOT delivered — no transcript at all"
            if not require_prompt:
                msg += "\n      (expected on a headless/nohup binary — the Ghostty exec surface\n" \
                       "       can't run claude without a GUI; run this from the real meee2.app)"
            print(msg)
            if require_prompt:
                rc = 1
    finally:
        api("POST", f"/api/planner/canvases/{cid}/nodes/{NODE_ID}/detach-session")
        api("DELETE", f"/api/canvases/{cid}")
        print(f"\ncleaned up canvas {cid}")

    print("\n" + ("✓ PASS" if rc == 0 else "✗ FAIL"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
