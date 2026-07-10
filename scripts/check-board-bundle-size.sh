#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/Sources/Board/WebDist"
INDEX="$DIST/index.html"
MAX_INITIAL_GZIP=$((200 * 1024))
MAX_CHUNK_BYTES=$((500 * 1024))

if [[ ! -f "$INDEX" ]]; then
    echo "error: Board WebDist is missing; run pnpm build first" >&2
    exit 66
fi

INITIAL_BYTES=0
while IFS= read -r asset; do
    path="$DIST/${asset#./}"
    if [[ ! -f "$path" ]]; then
        echo "error: initial Board asset is missing: $asset" >&2
        exit 66
    fi
    bytes="$(gzip -c "$path" | wc -c | tr -d ' ')"
    INITIAL_BYTES=$((INITIAL_BYTES + bytes))
done < <(sed -nE 's/.*(src|href)="(\.\/assets\/[^"]+\.js)".*/\2/p' "$INDEX")

if (( INITIAL_BYTES >= MAX_INITIAL_GZIP )); then
    echo "error: initial Board JS gzip is ${INITIAL_BYTES}B (limit < ${MAX_INITIAL_GZIP}B)" >&2
    exit 1
fi

OVERSIZED="$(find "$DIST/assets" -type f -name '*.js' -size +${MAX_CHUNK_BYTES}c -print)"
if [[ -n "$OVERSIZED" ]]; then
    echo "error: Board JS chunks exceed 500KiB:" >&2
    echo "$OVERSIZED" >&2
    exit 1
fi

echo "✓ Board initial JS gzip ${INITIAL_BYTES}B; every JS chunk ≤500KiB"
