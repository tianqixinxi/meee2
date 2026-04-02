#!/bin/bash

# Build PeerIsland with proper entitlements and dynamic library setup

cd "$(dirname "$0")"

# Build the app
echo "Building PeerIsland..."
swift build -c release

# Find the built executable
EXECUTABLE=".build/release/PeerIsland"
DYLIB=".build/release/libPeerPluginKit.dylib"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Build failed, executable not found"
    exit 1
fi

if [ ! -f "$DYLIB" ]; then
    echo "Error: libPeerPluginKit.dylib not found at $DYLIB"
    exit 1
fi

# Install PeerPluginKit.dylib to ~/.peer-island/lib/
INSTALL_DIR="$HOME/.peer-island/lib"
mkdir -p "$INSTALL_DIR"
cp "$DYLIB" "$INSTALL_DIR/libPeerPluginKit.dylib"
echo "Installed libPeerPluginKit.dylib to $INSTALL_DIR/"

# Apply entitlements to disable sandbox
echo "Applying entitlements..."
codesign --force --sign - --entitlements PeerIsland.entitlements "$EXECUTABLE"

# Sign the dylib as well
codesign --force --sign - "$INSTALL_DIR/libPeerPluginKit.dylib"

# Set rpath on the executable to find the dylib at runtime
echo "Setting rpath on executable..."
install_name_tool -add_rpath "@executable_path/../.build/release" "$EXECUTABLE" 2>/dev/null || true

echo ""
echo "Build complete!"
echo "  Executable: $EXECUTABLE"
echo "  PluginKit:  $INSTALL_DIR/libPeerPluginKit.dylib"
echo "  Run with:   $EXECUTABLE"
