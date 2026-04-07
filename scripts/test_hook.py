#!/usr/bin/env python3
"""
Test script for meee2 hook events.
Usage: python3 test_hook.py [command]

Commands:
  permission    - Send a basic PermissionRequest
  ask           - Send AskUserQuestion with options
  stop          - Send a Stop event
  raw <json>    - Send raw JSON
"""

import socket
import sys
import json
import time

SOCKET_PATH = "/tmp/meee2.sock"

def send_event(event_data):
    """Send event to meee2 socket"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)

        json_str = json.dumps(event_data)
        print(f"Sending: {json_str[:100]}...")

        sock.sendall(json_str.encode('utf-8'))

        # Wait for response (if any) - keep socket open longer for permission requests
        if event_data.get("hook_event_name") == "PermissionRequest" and event_data.get("status") == "waiting_for_approval":
            print("Permission request sent, waiting for response...")
            print("(Socket will stay open for 60 seconds - click Allow/Deny in meee2)")
            sock.settimeout(60)
            try:
                response = sock.recv(4096)
                if response:
                    print(f"Response received: {response.decode('utf-8')}")
            except socket.timeout:
                print("Timeout waiting for response")
        else:
            sock.settimeout(2)
            try:
                response = sock.recv(4096)
                if response:
                    print(f"Response: {response.decode('utf-8')}")
            except socket.timeout:
                print("No response (expected for non-permission events)")

        sock.close()
        print("✓ Event sent successfully")

    except Exception as e:
        print(f"Error: {e}")

def test_permission():
    """Test basic PermissionRequest"""
    session_id = f"test-session-{int(time.time())}"
    tool_use_id = f"toolu_{int(time.time())}"

    print(f"Session ID: {session_id}")
    print(f"Tool Use ID: {tool_use_id}")

    event = {
        "hook_event_name": "PermissionRequest",
        "session_id": session_id,
        "cwd": "/Users/test/project",
        "status": "waiting_for_approval",
        "tool_name": "Bash",
        "tool_use_id": tool_use_id,
        "tool_input": {"command": "ls -la"},
        "permission": "Execute bash command",
        "tty": "/dev/ttys000",
        "term_program": "Ghostty"
    }

    send_event(event)
    return session_id

def test_ask_user_question():
    """Test AskUserQuestion with options"""
    session_id = f"test-session-{int(time.time())}"
    tool_use_id = f"toolu_{int(time.time())}"

    print(f"Session ID: {session_id}")
    print(f"Tool Use ID: {tool_use_id}")

    event = {
        "hook_event_name": "PermissionRequest",
        "session_id": session_id,
        "cwd": "/Users/test/project",
        "status": "waiting_for_approval",
        "tool_name": "AskUserQuestion",
        "tool_use_id": tool_use_id,
        "tool_input": {
            "questions": [{
                "header": "Auth",
                "question": "Which authentication method would you like to use?",
                "options": [
                    {"label": "OAuth", "description": "Use OAuth 2.0 flow"},
                    {"label": "API Key", "description": "Use static API key"},
                    {"label": "None", "description": "Skip authentication"}
                ]
            }]
        },
        "permission": "AskUserQuestion",
        "tty": "/dev/ttys000",
        "term_program": "Ghostty"
    }

    send_event(event)
    return session_id

def test_stop():
    """Test Stop event"""
    session_id = f"test-session-{int(time.time())}"

    print(f"Session ID: {session_id}")

    event = {
        "hook_event_name": "Stop",
        "session_id": session_id,
        "cwd": "/Users/test/project",
        "status": "waiting_for_input",
        "last_assistant_message": "✓ Task completed successfully! All files have been processed."
    }

    send_event(event)
    return session_id

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "permission":
        test_permission()
    elif cmd == "ask":
        test_ask_user_question()
    elif cmd == "stop":
        test_stop()
    elif cmd == "raw" and len(sys.argv) > 2:
        send_event(json.loads(sys.argv[2]))
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)

if __name__ == "__main__":
    main()