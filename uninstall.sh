#!/bin/bash
# uninstall.sh — clean removal of meee2 from a Mac.
#
# Default is DRY-RUN: prints what would happen without touching anything.
# Pass --apply to actually do it. Pass --keep-state to preserve ~/.meee2/
# (sessions / channels / plugins / templates / queue / unread state).
#
# What gets cleaned up:
#   1. Running processes:  /Applications/meee2.app + mcp-meee2/server.js
#   2. App bundle:         /Applications/meee2.app
#   3. CLI symlink:        /usr/local/bin/meee2 (if it points to meee2.app)
#   4. Claude hooks:       ~/.claude/settings.json — only the hooks pointing
#                          at claude-hook-bridge.sh, plus permissions.allow
#                          entries that match `mcp__meee2__*`. Other hooks /
#                          permissions are left alone.
#   5. Claude MCP:         ~/.claude.json — only the `mcpServers.meee2` key.
#                          The 200+KB rest of the file is preserved.
#   6. Codex MCP:          ~/.codex/config.toml — only the
#                          `[mcp_servers.meee2]` table block.
#   7. State dir:          ~/.meee2/  (unless --keep-state)
#   8. Runtime info:       ~/Library/Application Support/meee2/board-server.json
#   9. Logs:               ~/Library/Logs/meee2.log, /tmp/meee2*.log
#  10. Sockets:            /tmp/meee2.sock
#  11. LAN env:            launchctl unsetenv MEEE2_BOARD_BIND (if set)
#
# Usage:
#   ./uninstall.sh                # dry-run, prints plan
#   ./uninstall.sh --apply        # actually remove
#   ./uninstall.sh --apply --keep-state
#
# Notes:
#  - Surgical JSON edits use python3 (system Python on macOS 13+).
#  - Codex TOML edit is a block-level regex (matches what
#    MCPConfigManager.upsertTomlTableBlock writes).
#  - Anything ambiguous (file already gone / not ours) is logged and skipped,
#    never errored. The script is idempotent — safe to re-run.

set -u

APPLY=0
KEEP_STATE=0
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --keep-state) KEEP_STATE=1 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 1
            ;;
    esac
done

if [ "$APPLY" = "0" ]; then
    echo "==> DRY RUN (pass --apply to actually remove)"
else
    echo "==> APPLY mode — will modify your system"
fi
echo

# --- helpers --------------------------------------------------------------

run() {
    # Echo + execute when in apply mode; just echo when dry-run
    echo "  $ $*"
    if [ "$APPLY" = "1" ]; then
        eval "$@"
    fi
}

# Surgically delete a top-level JSON key. Preserves the rest of the file.
# Uses python3's json (preserves nothing about formatting, but Claude's
# settings/claude.json don't expect fancy formatting).
json_delete_keypath() {
    local file="$1"
    shift
    if [ ! -f "$file" ]; then
        echo "  (skip — $file does not exist)"
        return 0
    fi
    if [ "$APPLY" = "0" ]; then
        echo "  $ python3 -c 'edit $file: delete $*'"
        return 0
    fi
    python3 - "$file" "$@" <<'PY'
import json, sys, os
path = sys.argv[1]
keys = sys.argv[2:]
with open(path, 'r') as f:
    data = json.load(f)

def walk_delete(obj, keypath):
    if not keypath:
        return
    head, *rest = keypath
    if not isinstance(obj, dict):
        return
    if not rest:
        obj.pop(head, None)
        return
    if head in obj:
        walk_delete(obj[head], rest)

# keys are passed as one keypath per arg group, separated by "."
for kp in keys:
    walk_delete(data, kp.split('.'))

# Atomic write
tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
}

# Filter ~/.claude/settings.json: drop hooks pointing to claude-hook-bridge.sh
# and remove `mcp__meee2__*` from permissions.allow.
prune_claude_settings() {
    local file="$HOME/.claude/settings.json"
    if [ ! -f "$file" ]; then
        echo "  (skip — $file does not exist)"
        return 0
    fi
    if [ "$APPLY" = "0" ]; then
        echo "  $ python3 -c 'edit $file: drop meee2 hooks + permissions.allow'"
        return 0
    fi
    python3 - "$file" <<'PY'
import json, sys, os, re
path = sys.argv[1]
with open(path, 'r') as f:
    data = json.load(f)

# 1. hooks: each event ("Stop", "PostToolUse", ...) maps to a list of
#    matchers. Drop any matcher whose hooks[].command references our bridge.
BRIDGE_RE = re.compile(r'claude-hook-bridge\.sh')
hooks = data.get('hooks')
if isinstance(hooks, dict):
    for event, matchers in list(hooks.items()):
        if not isinstance(matchers, list):
            continue
        kept = []
        for m in matchers:
            inner = m.get('hooks') if isinstance(m, dict) else None
            if isinstance(inner, list):
                inner_kept = [
                    h for h in inner
                    if not (isinstance(h, dict)
                            and isinstance(h.get('command'), str)
                            and BRIDGE_RE.search(h['command']))
                ]
                if inner_kept:
                    nm = dict(m)
                    nm['hooks'] = inner_kept
                    kept.append(nm)
            else:
                kept.append(m)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if not hooks:
        data.pop('hooks', None)

# 2. permissions.allow: drop entries starting with "mcp__meee2__"
perms = data.get('permissions')
if isinstance(perms, dict):
    allow = perms.get('allow')
    if isinstance(allow, list):
        kept = [a for a in allow if not (isinstance(a, str) and a.startswith('mcp__meee2__'))]
        if kept:
            perms['allow'] = kept
        else:
            perms.pop('allow', None)
    if not perms:
        data.pop('permissions', None)

tmp = path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
}

# Remove `[mcp_servers.meee2] ... ` block from Codex config.toml.
# Mirrors MCPConfigManager.upsertTomlTableBlock's write format.
prune_codex_config() {
    local file="$HOME/.codex/config.toml"
    if [ ! -f "$file" ]; then
        echo "  (skip — $file does not exist)"
        return 0
    fi
    if [ "$APPLY" = "0" ]; then
        echo "  $ python3 -c 'edit $file: drop [mcp_servers.meee2] block'"
        return 0
    fi
    python3 - "$file" <<'PY'
import sys, re, os
path = sys.argv[1]
with open(path, 'r') as f:
    text = f.read()

# Remove the block from "[mcp_servers.meee2]" line up to (but not including)
# the next "[" header or EOF. Strip surrounding blank lines.
pattern = re.compile(
    r'(?:\n+)?\[mcp_servers\.meee2\][^\n]*\n(?:[^\[\n][^\n]*\n?)*',
    re.MULTILINE,
)
new = pattern.sub('\n', text)
new = re.sub(r'\n{3,}', '\n\n', new).lstrip('\n')

if new != text:
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        f.write(new)
    os.replace(tmp, path)
PY
}

# --- 1. stop running processes -------------------------------------------

echo "==> 1. Stopping running processes"
if pgrep -f 'meee2.app/Contents/MacOS/meee2' >/dev/null 2>&1; then
    run "pkill -f 'meee2.app/Contents/MacOS/meee2' || true"
else
    echo "  (no /Applications/meee2.app process running)"
fi
if pgrep -f '\.build/.*meee2\$' >/dev/null 2>&1; then
    run "pkill -f '\\.build/.*meee2\$' || true"
else
    echo "  (no dev meee2 process running)"
fi
if pgrep -f 'mcp-meee2/server\.js' >/dev/null 2>&1; then
    run "pkill -f 'mcp-meee2/server\\.js' || true"
else
    echo "  (no mcp-meee2/server.js process running)"
fi
echo

# --- 2. remove app bundle -------------------------------------------------

echo "==> 2. Removing app bundle"
if [ -d /Applications/meee2.app ]; then
    run "rm -rf /Applications/meee2.app"
else
    echo "  (skip — /Applications/meee2.app not present)"
fi
echo

# --- 3. CLI symlink -------------------------------------------------------

echo "==> 3. CLI symlink at /usr/local/bin/meee2"
if [ -L /usr/local/bin/meee2 ]; then
    target=$(readlink /usr/local/bin/meee2 || true)
    case "$target" in
        */meee2.app/*)
            # Owned by us — needs sudo since /usr/local/bin is root-owned
            run "sudo rm -f /usr/local/bin/meee2"
            ;;
        *)
            echo "  (skip — /usr/local/bin/meee2 → $target, not a meee2.app link)"
            ;;
    esac
else
    echo "  (skip — /usr/local/bin/meee2 not present)"
fi
echo

# --- 4. claude hooks + permissions ---------------------------------------

echo "==> 4. ~/.claude/settings.json — drop hooks + permissions for meee2"
prune_claude_settings
echo

# --- 5. claude MCP server -------------------------------------------------

echo "==> 5. ~/.claude.json — drop mcpServers.meee2"
json_delete_keypath "$HOME/.claude.json" "mcpServers.meee2"
echo

# --- 6. codex MCP server --------------------------------------------------

echo "==> 6. ~/.codex/config.toml — drop [mcp_servers.meee2] block"
prune_codex_config
echo

# --- 7. state dir ---------------------------------------------------------

echo "==> 7. ~/.meee2/  (sessions, channels, plugins, queue, settings, …)"
if [ "$KEEP_STATE" = "1" ]; then
    echo "  (skip — --keep-state)"
elif [ -d "$HOME/.meee2" ]; then
    run "rm -rf '$HOME/.meee2'"
else
    echo "  (skip — directory not present)"
fi
echo

# --- 8. runtime info / 9. logs / 10. socket ------------------------------

echo "==> 8-10. Runtime info, logs, socket"
for f in \
    "$HOME/Library/Application Support/meee2/board-server.json" \
    "$HOME/Library/Logs/meee2.log" \
    /tmp/meee2.log /tmp/meee2.log.test \
    /tmp/meee2-app.log /tmp/meee2-bridge-debug.log /tmp/meee2-web.log \
    /tmp/meee2.sock; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        run "rm -f '$f'"
    fi
done
# Application Support/meee2 may now be empty
if [ -d "$HOME/Library/Application Support/meee2" ]; then
    run "rmdir '$HOME/Library/Application Support/meee2' 2>/dev/null || true"
fi
echo

# --- 11. LAN env var ------------------------------------------------------

echo "==> 11. LAN bind env var"
if launchctl getenv MEEE2_BOARD_BIND >/dev/null 2>&1; then
    run "launchctl unsetenv MEEE2_BOARD_BIND"
else
    echo "  (skip — MEEE2_BOARD_BIND not set in launchctl env)"
fi
echo

# --- summary --------------------------------------------------------------

if [ "$APPLY" = "0" ]; then
    echo "==> Dry run finished. Re-run with --apply to actually remove."
else
    echo "==> Uninstall complete."
    echo "    State preserved in ~/.meee2/ (--keep-state was set)" \
        | { [ "$KEEP_STATE" = "1" ] && cat || true; }
    echo "    Restart any open Claude / Codex CLI sessions so the hook +"
    echo "    MCP changes take effect."
fi
