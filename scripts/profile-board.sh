#!/usr/bin/env bash
set -euo pipefail

PORT="${MEEE2_BOARD_PORT:-9876}"
HOST="${MEEE2_BOARD_HOST:-127.0.0.1}"
BASE_URL="http://${HOST}:${PORT}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${TMPDIR:-/tmp}/meee2-board-profile-${STAMP}"
ARCHIVE="${OUT_DIR}.tar.gz"
RUNTIME_INFO="${HOME}/Library/Application Support/meee2/board-server.json"

mkdir -p "${OUT_DIR}"

extract_json_field() {
  local file="$1"
  local field="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$field" <<'PY'
import json
import sys
path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        value = json.load(handle).get(field)
    if value is not None:
        print(value)
except Exception:
    pass
PY
  fi
}

if [[ -f "${RUNTIME_INFO}" ]]; then
  runtime_port="$(extract_json_field "${RUNTIME_INFO}" port || true)"
  runtime_pid="$(extract_json_field "${RUNTIME_INFO}" pid || true)"
  if [[ -n "${runtime_port:-}" ]]; then
    PORT="${runtime_port}"
    BASE_URL="http://${HOST}:${PORT}"
  fi
fi

PID="${runtime_pid:-}"
if [[ -z "${PID}" ]]; then
  PID="$(pgrep -f 'meee2(.app/Contents/MacOS/meee2)? board' | head -1 || true)"
fi
if [[ -z "${PID}" ]]; then
  PID="$(lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
fi

{
  echo "meee2 board profile"
  echo "captured_at=$(date -Iseconds)"
  echo "base_url=${BASE_URL}"
  echo "pid=${PID:-unknown}"
  echo "runtime_info=${RUNTIME_INFO}"
  uname -a
} > "${OUT_DIR}/summary.txt"

{
  echo "== ps meee2 =="
  ps -axo pid,ppid,pcpu,pmem,rss,etime,comm,args | grep -E '[m]eee2|[C]odex|[G]hostty' || true
  echo
  echo "== top meee2 pid =="
  if [[ -n "${PID}" ]]; then
    ps -p "${PID}" -o pid,ppid,pcpu,pmem,rss,etime,comm,args || true
  fi
  echo
  echo "== port =="
  lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN || true
  echo
  echo "== vm_stat =="
  vm_stat || true
} > "${OUT_DIR}/process.txt"

if [[ -n "${PID}" ]] && command -v sample >/dev/null 2>&1; then
  sample "${PID}" 5 -file "${OUT_DIR}/sample.txt" >/dev/null 2>&1 || true
fi

if command -v curl >/dev/null 2>&1; then
  curl -s "${BASE_URL}/api/health" -o "${OUT_DIR}/health.json" || true
  curl -s "${BASE_URL}/api/_dev/perf" -o "${OUT_DIR}/perf.json" || true
  {
    echo "endpoint http_code bytes time_total"
    for endpoint in /api/state /api/canvases /api/planner/monitor /api/_dev/perf; do
      printf "%s " "${endpoint}"
      curl -s -o /dev/null -w "%{http_code} %{size_download} %{time_total}\n" "${BASE_URL}${endpoint}" || true
    done
  } > "${OUT_DIR}/http-timings.txt"
fi

if [[ -f /tmp/meee2.log ]]; then
  grep -a -E 'Perf|StateTrace|BoardAPI|PlannerStore|render profile|events\.jsonl|plannerCanvasChanged' /tmp/meee2.log \
    | tail -400 > "${OUT_DIR}/meee2-log-tail.txt" || true
fi

tar -czf "${ARCHIVE}" -C "$(dirname "${OUT_DIR}")" "$(basename "${OUT_DIR}")"
echo "${ARCHIVE}"
