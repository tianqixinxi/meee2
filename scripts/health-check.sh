#!/bin/bash
# health-check.sh — Verify the development environment is ready.

cd "$(dirname "$0")/.."

echo "=== meee2 Development Environment Check ==="
echo ""

# Swift version
SWIFT_VER=$(swift --version 2>&1 | head -1)
echo "Swift: $SWIFT_VER"

# macOS version
echo "macOS: $(sw_vers -productVersion)"

# swiftlint
if command -v swiftlint &> /dev/null; then
    echo "swiftlint: $(swiftlint version)"
else
    echo "swiftlint: NOT INSTALLED (optional, run: brew install swiftlint)"
fi

# jq (used by bridge script)
if command -v jq &> /dev/null; then
    echo "jq: $(jq --version)"
else
    echo "jq: NOT INSTALLED (recommended, run: brew install jq)"
fi

# Git hooks
HOOKS_PATH=$(git config core.hooksPath 2>/dev/null)
if [ "$HOOKS_PATH" = ".githooks" ]; then
    echo "Git hooks: configured ✓"
else
    echo "Git hooks: NOT configured (run: bash .githooks/setup.sh)"
fi

# meee2 app running
if pgrep -x meee2 > /dev/null 2>&1; then
    echo "meee2 app: running ✓"
else
    echo "meee2 app: not running"
fi

# Unix socket
if [ -S /tmp/meee2.sock ]; then
    echo "Hook socket: /tmp/meee2.sock ✓"
else
    echo "Hook socket: not found (start meee2 app first)"
fi

echo ""
echo "Done."
