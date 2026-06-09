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

# 项目级 env:加载仓库根的 .env(若存在),变量自动 export(set -a)。把
# MEEE2_ONLINE_APP_BASE_URL 等放进 .env 即可,不必每次命令带 env / 改全局 shell。
# .env 本地忽略(.git/info/exclude),不进版本库 —— 可放凭证。
set -a
[ -f .env ] && . ./.env
set +a

BINARY=".build/arm64-apple-macosx/debug/meee2"
if [[ ! -x "$BINARY" ]]; then
  echo "meee2 debug binary not found at $BINARY — did you run 'swift build'?" >&2
  exit 1
fi

# pkill 在没有匹配进程时返回 1，set -e 会炸；显式吞掉。
pkill -f '\.build/.*meee2( board)?$' 2>/dev/null || true
sleep 1

BACKEND="${MEEE2_ONLINE_APP_BASE_URL:-https://meee2-online-meee1.vercel.app}"
echo "Starting meee2 (debug) with MEEE2_ONLINE_APP_BASE_URL=$BACKEND"
echo "Logs: tail -F /tmp/meee2.log"

MEEE2_ONLINE_APP_BASE_URL="$BACKEND" \
  nohup "$BINARY" >/tmp/meee2.log 2>&1 &

# 简单确认进程起来（pgrep 在 nohup detach 后约 0.5s 内可见）
sleep 1
if pgrep -f '\.build/.*meee2( board)?$' >/dev/null; then
  echo "meee2 PID: $(pgrep -f '\.build/.*meee2( board)?$')"
else
  echo "meee2 failed to start; check /tmp/meee2.log" >&2
  exit 1
fi
