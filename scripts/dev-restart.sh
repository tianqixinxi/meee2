#!/usr/bin/env bash
# Restart the dev meee2 binary in background (nohup), pointing the meee2-online
# backend at MEEE2_ONLINE_APP_BASE_URL (defaults to the Vercel deployment so
# that "Login" works out of the box without running meee2-online locally).
#
# Designed to be called after `pnpm build:dev` so WebDist + Swift resource
# bundle are fresh; the script itself does NOT rebuild — that's the caller's
# job (so `pnpm restart:dev` chains the two without re-running build here).
#
# Override the backend by exporting MEEE2_ONLINE_APP_BASE_URL before invoking,
# e.g. `MEEE2_ONLINE_APP_BASE_URL=http://localhost:3000 pnpm restart:dev` for
# the dual-local scenario.
set -euo pipefail

cd "$(dirname "$0")/.."

BINARY=".build/arm64-apple-macosx/debug/meee2"
if [[ ! -x "$BINARY" ]]; then
  echo "meee2 debug binary not found at $BINARY — did you run 'swift build'?" >&2
  exit 1
fi

# pkill 在没有匹配进程时返回 1，set -e 会炸；显式吞掉。
pkill -f '\.build/.*meee2$' 2>/dev/null || true
sleep 1

BACKEND="${MEEE2_ONLINE_APP_BASE_URL:-https://meee2-online-meee1.vercel.app}"

# stdout/stderr 落盘位置 —— 这里只接 NSLog 直写 + 早期 print（[StateTrace] 在 NSLog 里）。
# MLog 家族自己落 ~/Library/Logs/meee2.log（或 MEEE2_HOME/logs/meee2.log）。
#
# 旧默认 `/tmp/meee2.log` 在多 workspace 同时跑 dev 时会互相盖。规则：
#   1. MEEE2_LOG_DIR 显式指定 → 用 `${MEEE2_LOG_DIR}/state-trace.log`
#   2. MEEE2_HOME 指定 → 用 `${MEEE2_HOME}/logs/state-trace.log`
#   3. 都没指定 → 保留 /tmp 但用当前 workspace 路径的 sha 前 8 位做前缀防互覆
if [[ -n "${MEEE2_LOG_DIR:-}" ]]; then
  STATE_TRACE_LOG="${MEEE2_LOG_DIR%/}/state-trace.log"
elif [[ -n "${MEEE2_HOME:-}" ]]; then
  STATE_TRACE_LOG="${MEEE2_HOME%/}/logs/state-trace.log"
else
  WS_HASH="$(printf %s "$PWD" | shasum -a 256 | cut -c1-8)"
  STATE_TRACE_LOG="/tmp/meee2-${WS_HASH}.log"
fi
mkdir -p "$(dirname "$STATE_TRACE_LOG")"

echo "Starting meee2 (debug) with MEEE2_ONLINE_APP_BASE_URL=$BACKEND"
echo "Logs: tail -F $STATE_TRACE_LOG"

MEEE2_ONLINE_APP_BASE_URL="$BACKEND" \
  nohup "$BINARY" >"$STATE_TRACE_LOG" 2>&1 &

# 简单确认进程起来（pgrep 在 nohup detach 后约 0.5s 内可见）
sleep 1
if pgrep -f '\.build/.*meee2$' >/dev/null; then
  echo "meee2 PID: $(pgrep -f '\.build/.*meee2$')"
else
  echo "meee2 failed to start; check $STATE_TRACE_LOG" >&2
  exit 1
fi
