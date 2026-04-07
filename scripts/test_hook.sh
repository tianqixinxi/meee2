#!/bin/bash
# 模拟发送 Hook 事件到 meee2

SOCKET_PATH="/tmp/meee2.sock"

send_event() {
    echo "$1" | nc -U "$SOCKET_PATH"
    echo "Sent: $1"
}

# 测试 PermissionRequest
test_permission() {
    local session_id="test-session-$(date +%s)"
    local tool_use_id="toolu_$(date +%s)"

    echo "=== Testing PermissionRequest ==="
    echo "Session ID: $session_id"
    echo "Tool Use ID: $tool_use_id"

    send_event '{
        "hook_event_name": "PermissionRequest",
        "session_id": "'$session_id'",
        "cwd": "/Users/test/project",
        "status": "waiting_for_approval",
        "tool_name": "Bash",
        "tool_use_id": "'$tool_use_id'",
        "tool_input": {"command": "ls -la"},
        "permission": "Execute bash command",
        "tty": "/dev/ttys000",
        "term_program": "Ghostty"
    }'
}

# 测试 AskUserQuestion with options
test_ask_user_question() {
    local session_id="test-session-$(date +%s)"
    local tool_use_id="toolu_$(date +%s)"

    echo "=== Testing AskUserQuestion ==="
    echo "Session ID: $session_id"
    echo "Tool Use ID: $tool_use_id"

    send_event '{
        "hook_event_name": "PermissionRequest",
        "session_id": "'$session_id'",
        "cwd": "/Users/test/project",
        "status": "waiting_for_approval",
        "tool_name": "AskUserQuestion",
        "tool_use_id": "'$tool_use_id'",
        "tool_input": {
            "questions": [{
                "header": "Auth",
                "question": "Which auth method?",
                "options": [
                    {"label": "OAuth", "description": "Use OAuth 2.0"},
                    {"label": "API Key", "description": "Use API key"},
                    {"label": "None", "description": "Skip authentication"}
                ]
            }]
        },
        "permission": "AskUserQuestion",
        "tty": "/dev/ttys000",
        "term_program": "Ghostty"
    }'
}

# 测试 Stop
test_stop() {
    local session_id="test-session-$(date +%s)"

    echo "=== Testing Stop ==="
    echo "Session ID: $session_id"

    send_event '{
        "hook_event_name": "Stop",
        "session_id": "'$session_id'",
        "cwd": "/Users/test/project",
        "status": "waiting_for_input",
        "last_assistant_message": "Task completed successfully!"
    }'
}

case "$1" in
    permission)
        test_permission
        ;;
    ask)
        test_ask_user_question
        ;;
    stop)
        test_stop
        ;;
    *)
        echo "Usage: $0 {permission|ask|stop}"
        echo ""
        echo "Examples:"
        echo "  $0 permission  - Test basic permission request"
        echo "  $0 ask         - Test AskUserQuestion with options"
        echo "  $0 stop        - Test Stop event"
        ;;
esac