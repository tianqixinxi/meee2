#!/usr/bin/env bash
# Run a test command with an isolated HOME and prove that the caller's real
# ~/.meee2 tree has unchanged contents and persistence-relevant metadata.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_TOOL="$SCRIPT_DIR/lib/storage-tree-manifest.py"

usage() {
    cat <<'EOF'
Usage: scripts/test-isolated-home.sh [--] [COMMAND [ARG...]]

Runs COMMAND (default: swift test) with a temporary HOME and storage roots.
The command fails if the real ~/.meee2 tree changes while it runs.

Environment overrides used by the shell self-test and advanced CI setups:
  MEEE2_REAL_HOME          home whose .meee2 tree must remain unchanged
  MEEE2_REAL_STORAGE_ROOT exact tree to guard instead of REAL_HOME/.meee2
  MEEE2_KEEP_TEST_HOME=1   preserve the temporary home for debugging
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
if [[ "${1:-}" == "--" ]]; then
    shift
fi
if [[ $# -eq 0 ]]; then
    set -- swift test
fi

if [[ ! -x "$MANIFEST_TOOL" ]]; then
    echo "error: missing executable manifest tool: $MANIFEST_TOOL" >&2
    exit 70
fi

# Capture the real home before exporting any isolation variables. Tests may
# use either HOME, NSHomeDirectory(), or homeDirectoryForCurrentUser.
REAL_HOME="${MEEE2_REAL_HOME:-${HOME:?HOME must be set}}"
REAL_STORAGE_ROOT="${MEEE2_REAL_STORAGE_ROOT:-$REAL_HOME/.meee2}"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meee2-isolated-tests.XXXXXX")"
ISOLATED_HOME="$RUN_ROOT/home"
ISOLATED_STORAGE_ROOT="$RUN_ROOT/tmp/.meee2"
BEFORE_MANIFEST="$RUN_ROOT/real-before.manifest"
AFTER_MANIFEST="$RUN_ROOT/real-after.manifest"

cleanup() {
    if [[ "${MEEE2_KEEP_TEST_HOME:-0}" == "1" ]]; then
        echo "Preserved isolated test root: $RUN_ROOT" >&2
    else
        rm -rf "$RUN_ROOT"
    fi
}
trap cleanup EXIT INT TERM

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
    fi
}

mkdir -p \
    "$ISOLATED_HOME/.cache" \
    "$ISOLATED_HOME/.config" \
    "$ISOLATED_HOME/.local/share" \
    "$ISOLATED_HOME/Library/Application Support" \
    "$ISOLATED_HOME/Library/Caches" \
    "$ISOLATED_HOME/Library/Logs" \
    "$ISOLATED_STORAGE_ROOT"

"$MANIFEST_TOOL" "$REAL_STORAGE_ROOT" > "$BEFORE_MANIFEST"
BEFORE_HASH="$(sha256_file "$BEFORE_MANIFEST")"

export HOME="$ISOLATED_HOME"
export CFFIXED_USER_HOME="$ISOLATED_HOME"
export XDG_CACHE_HOME="$ISOLATED_HOME/.cache"
export XDG_CONFIG_HOME="$ISOLATED_HOME/.config"
export XDG_DATA_HOME="$ISOLATED_HOME/.local/share"
export TMPDIR="$RUN_ROOT/tmp"
export MEEE2_STORAGE_ROOT="$ISOLATED_STORAGE_ROOT"
export MEEE2_COMM_KIT_STORAGE_ROOT="$ISOLATED_STORAGE_ROOT"

echo "Isolated test HOME: $ISOLATED_HOME"
echo "Guarded real storage hash (before): $BEFORE_HASH"

set +e
(cd "$REPO_ROOT" && "$@")
COMMAND_STATUS=$?
set -e

"$MANIFEST_TOOL" "$REAL_STORAGE_ROOT" > "$AFTER_MANIFEST"
AFTER_HASH="$(sha256_file "$AFTER_MANIFEST")"
echo "Guarded real storage hash (after):  $AFTER_HASH"

if [[ "$BEFORE_HASH" != "$AFTER_HASH" ]] || ! cmp -s "$BEFORE_MANIFEST" "$AFTER_MANIFEST"; then
    echo "error: test command changed the real storage tree: $REAL_STORAGE_ROOT" >&2
    echo "Changed paths/metadata (file contents are represented only by SHA-256):" >&2
    diff -u "$BEFORE_MANIFEST" "$AFTER_MANIFEST" >&2 || true
    exit 1
fi

echo "✓ Real ~/.meee2 storage remained unchanged"
exit "$COMMAND_STATUS"
