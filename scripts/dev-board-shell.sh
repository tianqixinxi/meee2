#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

choose_board_port() {
  if [[ -n "${MEEE2_BOARD_PORT:-}" ]]; then
    echo "$MEEE2_BOARD_PORT"
    return
  fi

  local port=9876
  while lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
    port=$((port + 1))
    if [[ "$port" -gt 9976 ]]; then
      echo "No available BoardServer port found in 9876-9976" >&2
      exit 1
    fi
  done
  echo "$port"
}

BOARD_PORT="$(choose_board_port)"
export MEEE2_BOARD_PORT="$BOARD_PORT"

echo "Building desktop Board WebDist."
pnpm run build:web

echo "Starting desktop Board shell at http://127.0.0.1:${BOARD_PORT}."
echo "Vite dev server is not started; http://127.0.0.1:5002 should remain inaccessible."
swift run meee2 board
