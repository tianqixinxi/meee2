#!/bin/bash

# Build PeerIsland with proper entitlements to disable sandbox

cd "$(dirname "$0")"

# Build the app
echo "Building PeerIsland..."
swift build -c release

# Find the built executable
EXECUTABLE=".build/release/PeerIsland"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Build failed, executable not found"
    exit 1
fi

# Apply entitlements to disable sandbox
echo "Applying entitlements..."
codesign --force --sign - --entitlements PeerIsland.entitlements "$EXECUTABLE"

echo "Build complete. Run with: .build/release/PeerIsland"