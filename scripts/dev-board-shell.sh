#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DEV_URL="${MEEE2_BOARD_VITE_URL:-http://127.0.0.1:5002}"
WEB_LOG="${MEEE2_WEB_LOG:-/tmp/meee2-web.log}"

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
export MEEE2_BOARD_API_URL="${MEEE2_BOARD_API_URL:-http://127.0.0.1:${BOARD_PORT}}"

cleanup() {
  if [[ -n "${WEB_PID:-}" ]]; then
    kill "$WEB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting board Vite dev server at ${DEV_URL}"
: > "$WEB_LOG"
pnpm -F @meee1/board-app exec vite --host 127.0.0.1 >>"$WEB_LOG" 2>&1 &
WEB_PID=$!

echo "Vite log: ${WEB_LOG}"
echo "Open Board uses built WebDist at ${MEEE2_BOARD_API_URL}."
echo "Dev WebUI is available at ${DEV_URL}."
open "$DEV_URL" >/dev/null 2>&1 || true
swift run meee2 board
