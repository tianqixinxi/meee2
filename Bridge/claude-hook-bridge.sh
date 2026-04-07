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

# 读取终端环境变量
# 注意：TTY 环境变量可能为空，使用 tty 命令获取实际 tty
TTY_VAL="${TTY:-}"
if [ -z "$TTY_VAL" ]; then
    TTY_VAL=$(tty 2>/dev/null || echo "")
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
            '. + {
                tty: (if .tty then .tty else $tty end),
                termProgram: (if .termProgram then .termProgram else $term end),
                termBundleId: (if .termBundleId then .termBundleId else $bundle end),
                cmuxSocketPath: (if .cmuxSocketPath then .cmuxSocketPath else $cmuxSocket end),
                cmuxSurfaceId: (if .cmuxSurfaceId then .cmuxSurfaceId else $cmuxSurface end)
            }')
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

    # 发送 JSON 数据并等待响应 (对于 PermissionRequest 需要等待)
    # 使用超时避免无限等待
    if [ "$HOOK_EVENT" = "PermissionRequest" ]; then
        # PermissionRequest 需要等待响应，使用较长超时
        RESPONSE=$(echo "$INPUT" | nc -U -w 60 "$PEER_ISLAND_SOCKET" 2>/dev/null)

        # 如果收到响应，输出到 stdout 让 Claude CLI 处理
        if [ -n "$RESPONSE" ]; then
            echo "$RESPONSE"
        fi
    else
        # 其他事件不需要等待响应
        echo "$INPUT" | nc -U -w 2 "$PEER_ISLAND_SOCKET" > /dev/null 2>&1
    fi
fi

# 返回成功 (不影响 Claude CLI 执行)
exit 0