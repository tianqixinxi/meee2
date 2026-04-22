#!/bin/bash
# Configure git to use project hooks
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
echo "Git hooks configured. Pre-commit hook is now active."
