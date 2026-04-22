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

# Ghostty 原生终端 ID（只在 Ghostty 且 hook 时我们的 tab 大概率仍 focus 时捕获）。
# 参考 csm 的做法：在 SessionStart/UserPromptSubmit 等"用户刚触发"事件时调用
# osascript 抓一次 `id of (focused terminal of (selected tab of (front window)))`。
# 这个 ID 后续可用 `tell application "Ghostty" to focus (terminal id "X")` 精确跳转。
GHOSTTY_TERMINAL_ID_VAL=""
# 从 JSON stdin 里回落取 event 名（新版 Claude 不再塞 env）
_HOOK_EVENT_FOR_CAPTURE="$HOOK_EVENT"
if [ -z "$_HOOK_EVENT_FOR_CAPTURE" ] && command -v jq &> /dev/null && [ -n "$INPUT" ]; then
    _HOOK_EVENT_FOR_CAPTURE=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
fi
case "$_HOOK_EVENT_FOR_CAPTURE" in
    SessionStart|UserPromptSubmit)
        # 不做 TERM_PROGRAM 门禁：hook 子进程 env 里 $TERM_PROGRAM 经常丢，
        # 卡在这里会让 Ghostty 的 session 永远拿不到 terminal id。
        # 只跳过 cmux（cmux 用自己的 surface id 路径）。osascript 在 Ghostty
        # 不运行/不在前台时返回空串，bridge 会把空值当 no-op。
        if [ -z "$CMUX_SOCKET_VAL" ]; then
            GHOSTTY_TERMINAL_ID_VAL=$(/usr/bin/osascript -e '
tell application "Ghostty"
  try
    set t to focused terminal of (selected tab of (front window))
    return id of t
  on error
    return ""
  end try
end tell' 2>/dev/null)
            # 落一行调试日志到 /tmp，方便验证 bridge 是否确实抓到
            echo "$(date +%H:%M:%S) event=$_HOOK_EVENT_FOR_CAPTURE sid=${CLAUDE_SESSION_ID:-?} term=${TERM_PROGRAM:-?} ghosttyId=$GHOSTTY_TERMINAL_ID_VAL" >> /tmp/meee2-bridge-debug.log
        fi
        ;;
esac

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
            '. + {
                tty: (if .tty then .tty else $tty end),
                termProgram: (if .termProgram then .termProgram else $term end),
                termBundleId: (if .termBundleId then .termBundleId else $bundle end),
                cmuxSocketPath: (if .cmuxSocketPath then .cmuxSocketPath else $cmuxSocket end),
                cmuxSurfaceId: (if .cmuxSurfaceId then .cmuxSurfaceId else $cmuxSurface end)
            } + (if $ghosttyId != "" then {ghosttyTerminalId: $ghosttyId} else {} end)')
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

# 返回成功 (不影响 Claude CLI 执行)
exit 0