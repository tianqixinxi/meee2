#!/bin/bash
# validate.sh — Pre-commit validation gate for AI agents and developers.
# Run this before committing. Exit code 0 = safe to commit.

set -e
cd "$(dirname "$0")/.."

FAILED=0

echo "=== 1/5 Build ==="
if swift build 2>&1 | tail -3; then
    echo "✓ Build passed"
else
    echo "✗ Build failed"
    FAILED=1
fi

echo ""
echo "=== 2/5 Tests ==="
if swift test 2>&1 | tail -5; then
    echo "✓ Tests passed"
else
    echo "✗ Tests failed"
    FAILED=1
fi

echo ""
echo "=== 3/5 Lint ==="
if command -v swiftlint &> /dev/null; then
    if swiftlint lint --strict --quiet 2>&1; then
        echo "✓ Lint passed"
    else
        echo "✗ Lint violations found"
        FAILED=1
    fi
else
    echo "⚠ swiftlint not installed, skipping (brew install swiftlint)"
fi

echo ""
echo "=== 4/5 Hardcoded paths ==="
HARDCODED=$(grep -rn '"/Users/[a-zA-Z]' Sources/ App/ plugins-builtin/ 2>/dev/null | grep -v '\.build/' | grep -v 'CLAUDE.md' | grep -v 'Preview' | grep -v '/// ' | grep -v '// ' | grep -v '/Users/test/' || true)
if [ -n "$HARDCODED" ]; then
    echo "✗ Hardcoded user paths found:"
    echo "$HARDCODED"
    FAILED=1
else
    echo "✓ No hardcoded paths"
fi

echo ""
echo "=== 5/5 No print() in Services ==="
PRINTS=$(grep -rn '^\s*print(' Sources/Services/ 2>/dev/null | grep -v 'HookReceiver.swift' || true)
if [ -n "$PRINTS" ]; then
    echo "✗ Bare print() in Services (use MLog):"
    echo "$PRINTS"
    FAILED=1
else
    echo "✓ No bare print() in Services"
fi

echo ""
if [ $FAILED -ne 0 ]; then
    echo "=== VALIDATION FAILED ==="
    exit 1
else
    echo "=== ALL CHECKS PASSED ==="
    exit 0
fi
