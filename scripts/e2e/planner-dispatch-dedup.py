#!/usr/bin/env python3
"""E2E regression: 「开干」 must spawn exactly ONE internal session per node.

Reported bug: clicking 开干 produced TWO `内置 / running` cards for one node
(two distinct ghostty-surface sessions). Root cause: dispatch already creates
the surface (`createInternalSessionSurface createIfMissing:true`), and the
frontend's post-dispatch "open the session window" step then called the
`internal-session` (ensure) endpoint WITHOUT `openOnly`, so for a freshly
dispatched surface (not a reusable *internal* surface) the endpoint took the
`recreate` branch and spawned a SECOND surface. Fix: the open step passes
`openOnly:true` → ensure focuses the live bound session (`focus-external`)
instead of recreating.

This script replicates the frontend「开干」flow against the LIVE board server
(localhost:9876) and asserts the node ends up with exactly one bound surface.

⚠️ Side effect: dispatch launches a real `claude` ghostty surface. The script
deletes its temp canvas and detaches the session on exit, but the spawned
surface lingers as a dead session (no clean kill endpoint) — same as other
dispatch e2es. Run sparingly.

Optional `--prove-control` also runs the buggy path (ensure WITHOUT openOnly)
to demonstrate it recreates → 2 surfaces, proving the assertion discriminates.
Off by default because it spawns an extra surface.

Run:  python3 scripts/e2e/planner-dispatch-dedup.py [--prove-control]
Exit:  0 if exactly one surface after the fixed flow, 1 otherwise.
"""
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from board_control import HEADER_NAME, control_token  # noqa: E402

BASE = "http://localhost:9876"
# Per-run unique ids. Cleanup deliberately leaves the spawned (dead) surface
# behind, so a CONSTANT node id would make the next run count THIS run's stale
# `Node <id>` session and falsely report a double-spawn. A fresh id per run
# scopes the surface count to this run only.
RUN = str(int(time.time()))
CANVAS_NAME = f"e2e-dispatch-dedup-{RUN}"
NODE_ID = f"n_dedup_{RUN}"
CONTROL_TOKEN = None


def api(method, path, body=None):
    global CONTROL_TOKEN
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if method.upper() in {"POST", "PUT", "PATCH", "DELETE"}:
        CONTROL_TOKEN = CONTROL_TOKEN or control_token(BASE)
        headers[HEADER_NAME] = CONTROL_TOKEN
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers=headers,
    )
    try:
        r = urllib.request.urlopen(req, timeout=30)
        return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:200]}


def surfaces_for_node():
    _, st = api("GET", "/api/state")
    return [s["id"] for s in st.get("sessions", [])
            if s.get("currentTask") == f"Node {NODE_ID}"]


def main():
    prove_control = "--prove-control" in sys.argv

    # Fresh temp canvas + one step node.
    _, env = api("POST", "/api/canvases",
                 {"name": CANVAS_NAME, "scope": "personal", "kind": "board"})
    cid = next((c["id"] for c in env.get("canvases", [])
                if c.get("name") == CANVAS_NAME), env.get("activeCanvasId"))
    if not cid:
        print("✗ could not create test canvas")
        return 1
    ws = os.path.expanduser(f"~/.meee2/workspaces/global/{cid}")
    changes = [{"kind": "addNode", "node": {
        "id": NODE_ID, "canvasId": cid, "title": "dispatch dedup node",
        "schema": {"inputs": [], "outputs": ["out"], "goal": "x"},
        "contextSources": [], "executionMode": "auto", "executorType": "claude",
        "doerId": "owner", "nodeKind": "step", "status": "ready",
        "dependsOnNodeIds": []}}]
    _, prop = api("POST", f"/api/planner/canvases/{cid}/proposals/graph-change",
                  {"summary": "dedup test", "changes": changes})
    pid = prop.get("proposal", {}).get("id")
    api("POST", f"/api/planner/canvases/{cid}/proposals/{pid}/approve")
    api("POST", f"/api/planner/canvases/{cid}/proposals/{pid}/apply")

    rc = 0
    try:
        # --- the frontend「开干」flow ---
        st, _ = api("POST", f"/api/planner/canvases/{cid}/nodes/{NODE_ID}/dispatch",
                    {"runner": "claude", "cwd": ws})
        print(f"dispatch: HTTP {st}")
        time.sleep(2)
        after_dispatch = len(surfaces_for_node())
        print(f"  after dispatch: {after_dispatch} surface(s)")

        # post-dispatch open — the FIX passes openOnly:true (focus, never recreate).
        st, r = api("POST", f"/api/planner/canvases/{cid}/nodes/{NODE_ID}/internal-session",
                    {"runner": "claude", "cwd": ws, "openOnly": True})
        print(f"ensure(openOnly=true): HTTP {st} action={r.get('action')}")
        time.sleep(2)
        final = len(surfaces_for_node())
        print(f"  after open(openOnly): {final} surface(s)")

        if final == 1 and after_dispatch == 1:
            print("✓ exactly one internal session after 「开干」 (fix holds)")
        else:
            print(f"❌ expected 1 surface, got {final} — double-dispatch regressed")
            rc = 1

        if prove_control:
            st, r = api("POST", f"/api/planner/canvases/{cid}/nodes/{NODE_ID}/internal-session",
                        {"runner": "claude", "cwd": ws})  # NO openOnly = old buggy path
            time.sleep(2)
            ctrl = len(surfaces_for_node())
            print(f"\n[control] ensure WITHOUT openOnly: action={r.get('action')} → {ctrl} surface(s)")
            print("   (recreate → 2 confirms the assertion would catch the regression)")
    finally:
        # Cleanup: detach + delete the temp canvas. The spawned surface lingers
        # as a dead session (no clean-kill endpoint).
        api("POST", f"/api/planner/canvases/{cid}/nodes/{NODE_ID}/detach-session")
        api("DELETE", f"/api/canvases/{cid}")
        print(f"\ncleaned up canvas {cid}")

    return rc


if __name__ == "__main__":
    sys.exit(main())
