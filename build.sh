#!/bin/bash

# Build meee2 with proper entitlements and dynamic library setup

cd "$(dirname "$0")"

# Build the app
echo "Building meee2..."

# Build web frontend if npm is available
if command -v npm &>/dev/null && [ -d "web" ]; then
    echo "Building web frontend..."
    (cd web && npm ci && npm run build)
fi

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

# Install OpenClaw plugin
BUILTIN_OPENCLAW=".build/release/libOpenClawPlugin.dylib"
if [ -f "$BUILTIN_OPENCLAW" ]; then
    PLUGIN_DIR="$HOME/.meee2/plugins/openclaw"
    mkdir -p "$PLUGIN_DIR"
    cp "$BUILTIN_OPENCLAW" "$PLUGIN_DIR/OpenClawPlugin.dylib"
    if [ ! -f "$PLUGIN_DIR/plugin.json" ]; then
        cat > "$PLUGIN_DIR/plugin.json" << 'EOF'
{
    "id": "com.meee2.plugin.openclaw",
    "name": "OpenClaw",
    "version": "0.2.0",
    "dylib": "OpenClawPlugin.dylib"
}
EOF
    fi
    echo "Installed OpenClawPlugin to $PLUGIN_DIR/"
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
