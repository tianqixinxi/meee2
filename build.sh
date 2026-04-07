#!/bin/bash

# Build meee2 with proper entitlements and dynamic library setup

cd "$(dirname "$0")"

# Build the app
echo "Building meee2..."
swift build -c release

# Find the built executable
EXECUTABLE=".build/release/meee2"
DYLIB=".build/release/libMeee2PluginKit.dylib"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Build failed, executable not found"
    exit 1
fi

if [ ! -f "$DYLIB" ]; then
    echo "Error: libMeee2PluginKit.dylib not found at $DYLIB"
    exit 1
fi

# Install Meee2PluginKit.dylib to ~/.meee2/lib/
INSTALL_DIR="$HOME/.meee2/lib"
mkdir -p "$INSTALL_DIR"
cp "$DYLIB" "$INSTALL_DIR/libMeee2PluginKit.dylib"
echo "Installed libMeee2PluginKit.dylib to $INSTALL_DIR/"

# Install builtin plugins
BUILTIN_CURSOR=".build/release/libCursorPlugin.dylib"
if [ -f "$BUILTIN_CURSOR" ]; then
    PLUGIN_DIR="$HOME/.meee2/plugins/cursor"
    mkdir -p "$PLUGIN_DIR"
    cp "$BUILTIN_CURSOR" "$PLUGIN_DIR/CursorPlugin.dylib"
    echo "Installed CursorPlugin to $PLUGIN_DIR/"
fi

# Apply entitlements to disable sandbox
echo "Applying entitlements..."
codesign --force --sign - --entitlements meee2.entitlements "$EXECUTABLE"

# Sign the dylib as well
codesign --force --sign - "$INSTALL_DIR/libMeee2PluginKit.dylib"

# Set rpath on the executable to find the dylib at runtime
echo "Setting rpath on executable..."
install_name_tool -add_rpath "@executable_path/../.build/release" "$EXECUTABLE" 2>/dev/null || true

echo ""
echo "Build complete!"
echo "  Executable: $EXECUTABLE"
echo "  PluginKit:  $INSTALL_DIR/libMeee2PluginKit.dylib"
echo "  Run with:   $EXECUTABLE"
