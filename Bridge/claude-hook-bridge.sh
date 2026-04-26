#!/bin/bash
# claude-hook-bridge.sh
# Claude CLI Hook Bridge Script
# 将 Claude CLI hooks 数据转发到 meee2 Unix Socket Server

# meee2 Unix Socket 路径
PEER_ISLAND_SOCKET="/tmp/meee2.sock"

# 获取事件类型 (从环境变量或 stdin)
HOOK_EVENT="${CLAUDE_HOOK_EVENT_NAME:-}"

# 读取 stdin 数据
INPUT=$(cat)

# 无条件 debug：确认 bridge 被调用 + 看到的 event 是啥
echo "$(date +%H:%M:%S) ENTER pid=$$ env_event=${CLAUDE_HOOK_EVENT_NAME:-none} claude_sid=${CLAUDE_SESSION_ID:-none} stdin_len=${#INPUT}" >> /tmp/meee2-bridge-debug.log
if [ -n "$INPUT" ] && command -v jq &> /dev/null; then
    _peek=$(echo "$INPUT" | jq -r '.hook_event_name // "MISSING"' 2>/dev/null)
    echo "  json.hook_event_name=$_peek" >> /tmp/meee2-bridge-debug.log
fi

# 读取终端环境变量
# 注意：hook 脚本运行在管道上下文中，tty 命令会返回 "not a tty"
# 沿进程树向上查找，直到找到有真实 TTY 的祖先进程
TTY_VAL="${TTY:-}"
if [ -z "$TTY_VAL" ] || [ "$TTY_VAL" = "not a tty" ]; then
    _PID=$$
    for _i in 1 2 3 4 5; do
        _PID=$(ps -o ppid= -p $_PID 2>/dev/null | tr -d ' ')
        [ -z "$_PID" ] || [ "$_PID" = "1" ] && break
        _TTY=$(ps -o tty= -p $_PID 2>/dev/null | tr -d ' ')
        if [ -n "$_TTY" ] && [ "$_TTY" != "??" ]; then
            TTY_VAL="$_TTY"
            break
        fi
    done
fi
if [ "$TTY_VAL" = "??" ] || [ "$TTY_VAL" = "not a tty" ]; then
    TTY_VAL=""
fi

TERM_PROGRAM_VAL="${TERM_PROGRAM:-}"
TERM_BUNDLE_VAL="${TERM_PROGRAM_BUNDLE_ID:-}"

# cmux 检测：如果 CMUX_SOCKET_PATH 存在，则是在 cmux 中运行
# cmux 基于 ghostty，所以 TERM_PROGRAM 可能显示 ghostty，但实际是 cmux
CMUX_SOCKET_VAL="${CMUX_SOCKET_PATH:-}"
CMUX_SURFACE_VAL="${CMUX_SURFACE_ID:-}"

# 如果在 cmux 中，修正 termProgram
if [ -n "$CMUX_SOCKET_VAL" ]; then
    TERM_PROGRAM_VAL="cmux"
    TERM_BUNDLE_VAL="cmux"
fi

# Ghostty 原生终端 ID。
#
# 优先策略：tty 反查（Ghostty PR #11922, merged 2026-04-20，进入 tip nightly）。
# AppleScript `tty of (terminal id "X")` 现在返回 `/dev/ttysNNN`，用我们 hook
# 子进程持有的 tty 直接匹配，**完全 deterministic** —— 不依赖 user focus、
# 不依赖事件类型、不会撞 id。需要 Ghostty >= tip。
#
# Fallback：旧版 Ghostty（如 1.3.1 stable）AppleScript terminal class 没有
# tty 字段，反查会全部空串。这时退到老的"focused terminal of front window"
# 启发式（只在 SessionStart/UserPromptSubmit 触发，因为这两个事件 user 焦点
# 大概率还在对的 tab）。装上 tip 后 deterministic 路径自动生效。
GHOSTTY_TERMINAL_ID_VAL=""
# 从 JSON stdin 里回落取 event 名（新版 Claude 不再塞 env）
_HOOK_EVENT_FOR_CAPTURE="$HOOK_EVENT"
if [ -z "$_HOOK_EVENT_FOR_CAPTURE" ] && command -v jq &> /dev/null && [ -n "$INPUT" ]; then
    _HOOK_EVENT_FOR_CAPTURE=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
fi

if [ -z "$CMUX_SOCKET_VAL" ] && [ -n "$TTY_VAL" ]; then
    # Step 1：tty 反查（需要 Ghostty tip 的 tty 属性）
    # tty 属性来自 PR #11922；老版本会让 osascript 整段抛错回空串。
    # 注意：TTY_VAL 是 "ttys003"（无 /dev/ 前缀），Ghostty 返回 "/dev/ttys003"。
    _MY_TTY_PATH="/dev/$TTY_VAL"
    GHOSTTY_TERMINAL_ID_VAL=$(/usr/bin/osascript <<EOF 2>/dev/null
tell application "Ghostty"
  try
    repeat with t in terminals
      try
        if (tty of t as string) is "$_MY_TTY_PATH" then return id of t
      end try
    end repeat
  end try
  return ""
end tell
EOF
)
    _GHOSTTY_STRATEGY="tty"
    # Step 2：tty 路径没拿到 → 退回 focused-terminal 启发式（只对启动级事件）
    # + cwd validation 兜底，防 focus race。
    if [ -z "$GHOSTTY_TERMINAL_ID_VAL" ]; then
        case "$_HOOK_EVENT_FOR_CAPTURE" in
            SessionStart|UserPromptSubmit)
                _CANDIDATE=$(/usr/bin/osascript -e '
tell application "Ghostty"
  try
    set t to focused terminal of (selected tab of (front window))
    return id of t
  on error
    return ""
  end try
end tell' 2>/dev/null)
                if [ -n "$_CANDIDATE" ]; then
                    # cwd validation：拿候选 terminal 的 working directory，跟
                    # 我们 hook 进程的 $PWD 比对。一致才采纳——focus race 抓到
                    # 的是别的 tab，cwd 大概率不一样，就会被拒掉。
                    _MY_CWD="${CLAUDE_CWD:-$PWD}"
                    _CAND_CWD=$(/usr/bin/osascript <<EOF 2>/dev/null
tell application "Ghostty"
  try
    return working directory of (terminal id "$_CANDIDATE")
  on error
    return ""
  end try
end tell
EOF
)
                    # 路径规范化：去掉尾部 / 再比
                    _MY_CWD="${_MY_CWD%/}"
                    _CAND_CWD="${_CAND_CWD%/}"
                    if [ -n "$_CAND_CWD" ] && [ "$_CAND_CWD" = "$_MY_CWD" ]; then
                        GHOSTTY_TERMINAL_ID_VAL="$_CANDIDATE"
                        _GHOSTTY_STRATEGY="focused+cwd"
                    else
                        echo "$(date +%H:%M:%S) GHOSTTY_REJECT sid=${CLAUDE_SESSION_ID:-?} candidate=$_CANDIDATE cwd_mine='$_MY_CWD' cwd_cand='$_CAND_CWD' (focus race)" >> /tmp/meee2-bridge-debug.log
                    fi
                fi
                ;;
        esac
    fi
    # 落一行调试日志（带 strategy 标签便于看哪条路径成功）
    if [ -n "$GHOSTTY_TERMINAL_ID_VAL" ]; then
        echo "$(date +%H:%M:%S) event=$_HOOK_EVENT_FOR_CAPTURE sid=${CLAUDE_SESSION_ID:-?} tty=$TTY_VAL ghosttyId=$GHOSTTY_TERMINAL_ID_VAL strategy=$_GHOSTTY_STRATEGY" >> /tmp/meee2-bridge-debug.log
    fi
fi

# iTerm2：每 tab 自带 ITERM_SESSION_ID 环境变量（UUID），native deterministic。
# AppleScript 端可用 `tell session id "X" to write text "..."` 直推，不需要焦点。
ITERM_SESSION_ID_VAL="${ITERM_SESSION_ID:-}"

# Apple Terminal：每 tab 自带 TERM_SESSION_ID。Apple Terminal 的 AppleScript
# 模型按 tty 寻址 tab 更稳，所以这里只把 session id 作为辅助 capture。
APPLE_TERM_SESSION_ID_VAL="${TERM_SESSION_ID:-}"

# 构建 JSON 数据
if [ -z "$INPUT" ] || [ "$INPUT" = "" ]; then
    # 没有 stdin 数据，构造基本事件
    INPUT=$(cat <<EOF
{
  "event": "$HOOK_EVENT",
  "sessionId": "${CLAUDE_SESSION_ID:-unknown}",
  "cwd": "${CLAUDE_CWD:-$PWD}",
  "tty": "$TTY_VAL",
  "termProgram": "$TERM_PROGRAM_VAL",
  "termBundleId": "$TERM_BUNDLE_VAL",
  "cmuxSocketPath": "$CMUX_SOCKET_VAL",
  "cmuxSurfaceId": "$CMUX_SURFACE_VAL",
  "ghosttyTerminalId": "$GHOSTTY_TERMINAL_ID_VAL",
  "iTermSessionId": "$ITERM_SESSION_ID_VAL",
  "appleTerminalSessionId": "$APPLE_TERM_SESSION_ID_VAL",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)
else
    # 有 stdin 数据，添加终端信息
    if command -v jq &> /dev/null; then
        INPUT=$(echo "$INPUT" | jq \
            --arg tty "$TTY_VAL" \
            --arg term "$TERM_PROGRAM_VAL" \
            --arg bundle "$TERM_BUNDLE_VAL" \
            --arg cmuxSocket "$CMUX_SOCKET_VAL" \
            --arg cmuxSurface "$CMUX_SURFACE_VAL" \
            --arg ghosttyId "$GHOSTTY_TERMINAL_ID_VAL" \
            --arg iTermId "$ITERM_SESSION_ID_VAL" \
            --arg appleTermId "$APPLE_TERM_SESSION_ID_VAL" \
            '. + {
                tty: (if .tty then .tty else $tty end),
                termProgram: (if .termProgram then .termProgram else $term end),
                termBundleId: (if .termBundleId then .termBundleId else $bundle end),
                cmuxSocketPath: (if .cmuxSocketPath then .cmuxSocketPath else $cmuxSocket end),
                cmuxSurfaceId: (if .cmuxSurfaceId then .cmuxSurfaceId else $cmuxSurface end)
            }
            + (if $ghosttyId != "" then {ghosttyTerminalId: $ghosttyId} else {} end)
            + (if $iTermId != "" then {iTermSessionId: $iTermId} else {} end)
            + (if $appleTermId != "" then {appleTerminalSessionId: $appleTermId} else {} end)')
    else
        # 无 jq 时，在 JSON 结尾添加字段
        if [ -n "$TTY_VAL" ] || [ -n "$TERM_PROGRAM_VAL" ] || [ -n "$CMUX_SOCKET_VAL" ]; then
            # 移除最后的 }，添加新字段
            INPUT=$(echo "$INPUT" | sed 's/}$/,"tty":"'"$TTY_VAL"'","termProgram":"'"$TERM_PROGRAM_VAL"'","termBundleId":"'"$TERM_BUNDLE_VAL"'","cmuxSocketPath":"'"$CMUX_SOCKET_VAL"'","cmuxSurfaceId":"'"$CMUX_SURFACE_VAL"'"}/')
        fi
    fi
fi

# 发送数据到 meee2 Unix Socket
# 使用 nc (netcat) 发送数据到 Unix socket
if [ -S "$PEER_ISLAND_SOCKET" ]; then
    # 等待短暂时间让 socket 准备好
    sleep 0.1

    # 新版 Claude CLI 不再设置 $CLAUDE_HOOK_EVENT_NAME，改为通过 stdin JSON 的
    # hook_event_name 字段传。若 env 为空，从 JSON 回落解析。
    if [ -z "$HOOK_EVENT" ] && command -v jq &> /dev/null; then
        HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
    fi

    # 发送 JSON 数据并根据事件类型决定是否等待响应
    # PermissionRequest: 长超时，等待用户决定
    # Stop: 短超时，等待 A2A inbox drain 响应 (可能返回 {decision:"block",reason:...})
    # 其他: 不等待响应
    case "$HOOK_EVENT" in
        PermissionRequest)
            RESPONSE=$(echo "$INPUT" | nc -U -w 60 "$PEER_ISLAND_SOCKET" 2>/dev/null)
            [ -n "$RESPONSE" ] && echo "$RESPONSE"
            ;;
        Stop)
            RESPONSE=$(echo "$INPUT" | nc -U -w 5 "$PEER_ISLAND_SOCKET" 2>/dev/null)
            [ -n "$RESPONSE" ] && echo "$RESPONSE"
            ;;
        *)
            echo "$INPUT" | nc -U -w 2 "$PEER_ISLAND_SOCKET" > /dev/null 2>&1
            ;;
    esac
fi

# ─── meee360 上报 ─────────────────────────────────────────────────────────
# 找到 meee360-reporter.sh 脚本路径（和本脚本同目录）
BRIDGE_DIR="$(dirname "$0")"
MEEE360_REPORTER="$BRIDGE_DIR/meee360-reporter.sh"

# 如果脚本存在，异步调用（不阻塞 Claude hook）
# 通过 stdin 传递事件数据给 reporter
if [[ -x "$MEEE360_REPORTER" ]]; then
    echo "$INPUT" | "$MEEE360_REPORTER" &
fi

# 返回成功 (不影响 Claude CLI 执行)
exit 0