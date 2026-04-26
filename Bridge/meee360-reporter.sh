#!/bin/bash
# meee360-reporter.sh
# Read ~/.meee2/settings.json and POST heartbeat to Supabase when enabled && online
# Called by claude-hook-bridge.sh after sending data to meee2 Unix socket

set -e

SETTINGS_FILE="$HOME/.meee2/settings.json"

# Check if settings file exists
if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "$(date +%H:%M:%S) [meee360] No settings file at $SETTINGS_FILE" >> /tmp/meee360-reporter.log
    exit 0
fi

# Read meee360 config using jq
MEEE360_ENABLED=$(jq -r '.meee360.enabled // false' "$SETTINGS_FILE" 2>/dev/null)
MEEE360_ONLINE=$(jq -r '.meee360.online // false' "$SETTINGS_FILE" 2>/dev/null)

# Skip if not enabled or not online
if [[ "$MEEE360_ENABLED" != "true" || "$MEEE360_ONLINE" != "true" ]]; then
    echo "$(date +%H:%M:%S) [meee360] Skip: enabled=$MEEE360_ENABLED online=$MEEE360_ONLINE" >> /tmp/meee360-reporter.log
    exit 0
fi

# Read credentials
SUPABASE_URL=$(jq -r '.meee360.supabaseUrl // empty' "$SETTINGS_FILE" 2>/dev/null)
SUPABASE_KEY=$(jq -r '.meee360.supabaseKey // empty' "$SETTINGS_FILE" 2>/dev/null)
TEAM_ID=$(jq -r '.meee360.teamId // empty' "$SETTINGS_FILE" 2>/dev/null)
USER_ID=$(jq -r '.meee360.userId // empty' "$SETTINGS_FILE" 2>/dev/null)
MACHINE_ID=$(jq -r '.meee360.machineId // "unknown"' "$SETTINGS_FILE" 2>/dev/null)
SESSION_KEY=$(jq -r '.meee360.sessionKey // "default"' "$SETTINGS_FILE" 2>/dev/null)

# Validate required fields
if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_KEY" || -z "$TEAM_ID" || -z "$USER_ID" ]]; then
    echo "$(date +%H:%M:%S) [meee360] Missing required config fields" >> /tmp/meee360-reporter.log
    exit 0
fi

# Get hook event type and session info from stdin (passed by bridge)
INPUT=$(cat)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // .event // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // "unknown"' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // .project_directory // ""' 2>/dev/null)

# Determine status based on event
STATUS="active"
case "$HOOK_EVENT" in
    Stop)
        STATUS="idle"
        ;;
    SessionStart)
        STATUS="active"
        ;;
    Notification)
        STATUS="active"
        ;;
    SessionEnd)
        STATUS="idle"
        ;;
esac

# Build summary object
SUMMARY=$(cat <<EOF
{
  "task_summary": "$HOOK_EVENT",
  "session_id": "$SESSION_ID",
  "cwd": "$CWD"
}
EOF
)

# Call Supabase RPC function (safer than direct REST API)
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$SUPABASE_URL/rest/v1/rpc/meee360_upsert_session" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H "Content-Type: application/json" \
    -d @- <<REQUEST_BODY
{
  "p_team_id": "$TEAM_ID",
  "p_user_id": "$USER_ID",
  "p_machine_id": "$MACHINE_ID",
  "p_session_key": "$SESSION_KEY",
  "p_session_type": "claude",
  "p_status": "$STATUS",
  "p_summary": $SUMMARY
}
REQUEST_BODY
)

HTTP_CODE=$(echo "$RESPONSE" | tail -1 | grep -oE '[0-9]{3}' || echo "000")
BODY=$(echo "$RESPONSE" | sed '$ d')

if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
    echo "$(date +%H:%M:%S) [meee360] OK: event=$HOOK_EVENT status=$STATUS http=$HTTP_CODE" >> /tmp/meee360-reporter.log
else
    echo "$(date +%H:%M:%S) [meee360] FAIL: event=$HOOK_EVENT status=$STATUS http=$HTTP_CODE body=$BODY" >> /tmp/meee360-reporter.log
fi

exit 0