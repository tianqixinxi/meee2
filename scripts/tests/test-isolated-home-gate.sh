#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/test-isolated-home.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meee2-home-gate-self-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REAL_HOME="$ROOT/real-home"
mkdir -p "$REAL_HOME/.meee2"
printf 'baseline\n' > "$REAL_HOME/.meee2/session.json"

MEEE2_REAL_HOME="$REAL_HOME" "$GATE" -- sh -c '
    test "$HOME" = "$CFFIXED_USER_HOME"
    test "$MEEE2_STORAGE_ROOT" = "$MEEE2_COMM_KIT_STORAGE_ROOT"
    case "$MEEE2_STORAGE_ROOT" in "$TMPDIR"/*) ;; *) exit 64 ;; esac
    mkdir -p "$MEEE2_STORAGE_ROOT/sessions"
    printf "isolated\n" > "$MEEE2_STORAGE_ROOT/sessions/test.json"
'

set +e
MEEE2_REAL_HOME="$REAL_HOME" \
    CONTAMINATE_ROOT="$REAL_HOME/.meee2" \
    "$GATE" -- sh -c 'printf "pollution\n" >> "$CONTAMINATE_ROOT/session.json"' \
    > "$ROOT/contamination.out" 2>&1
CONTAMINATION_STATUS=$?
set -e
if [[ $CONTAMINATION_STATUS -eq 0 ]]; then
    echo "expected real-storage contamination to fail the gate" >&2
    cat "$ROOT/contamination.out" >&2
    exit 1
fi
grep -q "changed the real storage tree" "$ROOT/contamination.out"

set +e
MEEE2_REAL_HOME="$REAL_HOME" "$GATE" -- sh -c 'exit 23' > "$ROOT/command-failure.out" 2>&1
COMMAND_STATUS=$?
set -e
if [[ $COMMAND_STATUS -ne 23 ]]; then
    echo "expected command exit 23, got $COMMAND_STATUS" >&2
    cat "$ROOT/command-failure.out" >&2
    exit 1
fi

echo "✓ isolated HOME gate self-test passed"
