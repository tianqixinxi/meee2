#!/bin/bash

# Build meee2 with proper entitlements and dynamic library setup
#
# Env knobs:
#   IDENTITY         — Developer ID signing identity (e.g. "Developer ID
#                      Application: <Name> (<TEAMID>)"). Unset → ad-hoc.
#                      See scripts/lib-codesign.sh for details.
#   SKIP_WEB_BUILD=1 — skip pnpm board-app rebuild (CI already did it)
#   UNIVERSAL=1      — produce a fat arm64+x86_64 binary instead of host arch.
#                      Slower (~2x); only needed for distribution. Dev iteration
#                      should leave UNIVERSAL unset for fast incremental builds.

cd "$(dirname "$0")"

# Source shared signing helper —— centralizes ad-hoc-vs-Developer-ID logic
# so all three scripts (build/deploy/create-dmg) sign consistently.
. scripts/lib-codesign.sh

# Build the app
echo "Building meee2..."

# Build web frontend if pnpm is available
if [ "${SKIP_WEB_BUILD:-0}" != "1" ] && command -v pnpm &>/dev/null && [ -d "packages/board-app" ]; then
    echo "Building web frontend..."
    pnpm install --frozen-lockfile=false
    pnpm -r --filter @meee1/board-app... build
fi

# Universal binary path: pass --arch arm64 --arch x86_64 for SwiftPM's
# native fat-binary support (Swift 5.7+ on macOS). Without UNIVERSAL=1 we
# only build for the host arch — Intel Macs can't run an arm64-only build
# but dev iteration on Apple Silicon shouldn't pay the 2x build cost.
SWIFT_BUILD_ARGS=(-c release)
if [ "${UNIVERSAL:-0}" = "1" ]; then
    echo "Building universal arm64 + x86_64 (UNIVERSAL=1)…"
    SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${SWIFT_BUILD_ARGS[@]}"

# Resolve the SwiftPM output directory. Single-arch goes to
# `.build/release/`; universal multi-arch goes to
# `.build/apple/Products/Release/` (Xcode-style path used when
# multiple --arch flags are passed). Downstream code (deploy.sh,
# create-dmg.sh) reads from a stable BUILD_DIR variable.
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_DIR=".build/apple/Products/Release"
else
    BUILD_DIR=".build/release"
fi
echo "Build artifacts at: $BUILD_DIR"

EXECUTABLE="$BUILD_DIR/meee2"
DYLIB="$BUILD_DIR/libMeee2PluginKit.dylib"

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
BUILTIN_CURSOR="$BUILD_DIR/libCursorPlugin.dylib"
if [ -f "$BUILTIN_CURSOR" ]; then
    PLUGIN_DIR="$HOME/.meee2/plugins/cursor"
    mkdir -p "$PLUGIN_DIR"
    cp "$BUILTIN_CURSOR" "$PLUGIN_DIR/CursorPlugin.dylib"
    echo "Installed CursorPlugin to $PLUGIN_DIR/"
fi

# Install OpenClaw plugin
BUILTIN_OPENCLAW="$BUILD_DIR/libOpenClawPlugin.dylib"
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

# Install Codex plugin
BUILTIN_CODEX="$BUILD_DIR/libCodexPlugin.dylib"
if [ -f "$BUILTIN_CODEX" ]; then
    PLUGIN_DIR="$HOME/.meee2/plugins/codex"
    mkdir -p "$PLUGIN_DIR"
    cp "$BUILTIN_CODEX" "$PLUGIN_DIR/CodexPlugin.dylib"
    if [ ! -f "$PLUGIN_DIR/plugin.json" ]; then
        cat > "$PLUGIN_DIR/plugin.json" << 'EOF'
{
    "id": "com.meee2.plugin.codex",
    "name": "Codex",
    "version": "0.2.0",
    "dylib": "CodexPlugin.dylib"
}
EOF
    fi
    echo "Installed CodexPlugin to $PLUGIN_DIR/"
fi

# Set rpath on the executable to find the dylib at runtime
echo "Setting rpath on executable..."
install_name_tool -add_rpath "@executable_path/../$BUILD_DIR" "$EXECUTABLE" 2>/dev/null || true

# Apply entitlements to disable sandbox. This must run after install_name_tool
# because changing load commands invalidates the Mach-O code signature.
# Helper picks up IDENTITY env (real Developer ID + hardened runtime +
# secure timestamp) or falls back to ad-hoc with a warning.
echo "Applying entitlements + signing executable..."
meee2_sign "$EXECUTABLE" --entitlements meee2.entitlements

# Sign the dylib as well
echo "Signing libMeee2PluginKit.dylib…"
meee2_sign "$INSTALL_DIR/libMeee2PluginKit.dylib"

echo ""
echo "Build complete!"
echo "  Executable: $EXECUTABLE"
echo "  PluginKit:  $INSTALL_DIR/libMeee2PluginKit.dylib"
echo "  Run with:   $EXECUTABLE"
