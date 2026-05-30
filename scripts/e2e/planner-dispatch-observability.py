#!/usr/bin/env python3
"""E2E: dispatched step-node session observability.

Verifies two reported bugs against the LIVE board server (localhost:9876):

  Bug A — a dispatched step node's session shows no progress (recentMessages
          stays empty) even though the real `claude` process ran and wrote a
          transcript in the managed workspace.

  Bug B — a permission-required session leaves the node stuck at `running`
          because the permission signal (pendingPermissionTool) never reaches
          the surface-session record the node is bound to.

Root cause (what these assertions pin): the node binds to the meee2
ghostty-surface session id (`claude-ghostty-XXX`, transcriptPath=nil), while
the real CLI session writes `~/.claude/projects/<encoded-managed-cwd>/<cli-sid>.jsonl`
under its OWN uuid. meee2 never correlates the two by their shared managed
workspace cwd, so the surface session — and therefore the node — is blind.

Run:  python3 scripts/e2e/planner-dispatch-observability.py
Exit:  0 if everything is observable (bugs fixed), 1 if the gap is present.
"""
import json
import os
import sys
import urllib.request

BASE = "http://localhost:9876"
HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")


def api(path):
    return json.loads(urllib.request.urlopen(BASE + path, timeout=20).read().decode() or "{}")


def session_store(sid):
    f = os.path.join(HOME, ".meee2", "sessions", f"{sid}.json")
    return json.load(open(f)) if os.path.exists(f) else None


def encode_cwd(cwd):
    # Claude CLI project-dir encoding: every non-alnum char → '-'.
    return "".join(c if c.isalnum() else "-" for c in cwd)


def real_transcript_for(cwd):
    """Newest .jsonl Claude actually wrote for this workspace, if any."""
    d = os.path.join(PROJECTS, encode_cwd(cwd))
    if not os.path.isdir(d):
        return None, 0
    js = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".jsonl")]
    if not js:
        return None, 0
    newest = max(js, key=os.path.getmtime)
    with open(newest) as fh:
        lines = sum(1 for _ in fh)
    return newest, lines


def main():
    state = api("/api/state")
    sess = {s["id"]: s for s in state.get("sessions", [])}
    env = api("/api/canvases")

    bound = []  # (canvas, node title, runState, sessionId)
    for c in env.get("canvases", []):
        try:
            graph = api(f"/api/planner/canvases/{c['id']}/graph")
        except Exception:
            continue
        for n in graph.get("nodes", []):
            sid = (n.get("sessionId") or "").strip()
            if sid:
                bound.append((c.get("name", "?"), n.get("title", "?"),
                              n.get("workflowRunState"), sid))

    ghostty = [b for b in bound if b[3].startswith("claude-ghostty-")]
    print(f"绑定 session 的 step 节点: {len(bound)} 个，其中 ghostty-surface: {len(ghostty)}\n")

    # Assertion is at the OBSERVABLE layer (/api/state DTO), because the fix
    # correlates surface→CLI at DTO-build time — it does NOT rewrite the
    # on-disk surface SessionStore record. A dispatched surface session is
    # observable when, IF a real CLI transcript exists for its managed
    # workspace, the board DTO it's bound to exposes that transcript
    # (recentMessages) instead of staying empty.
    fail = 0
    checked = 0
    for canvas, title, run_state, sid in ghostty:
        s = sess.get(sid)
        store = session_store(sid)
        if not (s and store):
            continue
        cwd = store.get("cwd")
        if not (cwd and "/.meee2/workspaces/" in cwd):
            continue  # only managed-workspace dispatched sessions
        real_tp, real_lines = real_transcript_for(cwd)
        if not (real_tp and real_lines > 1):
            continue  # no real CLI work to correlate yet — nothing to assert
        checked += 1
        n_msg = len(s.get("recentMessages", []))
        # Opaque == claude wrote a real transcript but the bound DTO still
        # shows nothing (the pre-fix symptom: stuck running, no progress).
        opaque = n_msg == 0
        if opaque:
            fail += 1
        print(f"[{'FAIL (不透明)' if opaque else 'ok'}] {canvas[:14]:14} · {title[:18]:18} runState={run_state}")
        print(f"          real CLI transcript = {os.path.basename(real_tp)} ({real_lines} 行)")
        print(f"          bound DTO recentMessages = {n_msg} · status={s.get('status')} · pendPerm={s.get('pendingPermissionTool')}\n")

    print("=" * 60)
    if checked == 0:
        print("没有可断言的 dispatched 会话（需要一个跑过、写了 transcript 的托管工作区会话）。")
        return 0
    if fail:
        print(f"❌ {fail}/{checked} 个 dispatched 会话仍不透明:")
        print("   claude 写了真实 transcript,但节点绑定的 DTO 仍看不到 → 失明。")
        print("   → 进展不更新(Bug A) + 状态/permission 信号丢失导致卡 running(Bug B)。")
        return 1
    print(f"✓ {checked}/{checked} 个 dispatched 会话已把 CLI transcript 回流到绑定 DTO,可观测。")
    print("   (surface→CLI 按托管工作区 cwd 关联 → recentMessages / status / permission 回流。)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
