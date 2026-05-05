#!/bin/bash
# deploy.sh - Build and deploy meee2 to /Applications without re-signing
# This preserves the code signature from build.sh, so TCC (accessibility) permissions persist.

cd "$(dirname "$0")"

# Build
bash build.sh || exit 1

# Copy binary and dylibs without re-signing
echo ""
echo "Deploying to /Applications/meee2.app..."
killall meee2 2>/dev/null
sleep 0.5

cp .build/release/meee2 /Applications/meee2.app/Contents/MacOS/meee2

# Runtime dylibs the binary loads via @rpath. CommKit was extracted out of
# Sources/Core into the meee2-comm-kit subpackage in 2026-04 — must be
# bundled or `dyld[]: Library not loaded: @rpath/libMeee2CommKit.dylib`
# crashes meee2.app at launch. Same list lives in create-dmg.sh; keep them
# in sync. Missing one isn't fatal here (some plugins are optional), but
# we hard-fail if the core kits aren't present so we don't ship a broken
# app silently.
RUNTIME_DYLIBS=(
    "libMeee2PluginKit.dylib"
    "libMeee2CommKit.dylib"
    "libCursorPlugin.dylib"
    "libOpenClawPlugin.dylib"
    "libCodexPlugin.dylib"
)
for dylib in "${RUNTIME_DYLIBS[@]}"; do
    if [ -f ".build/release/$dylib" ]; then
        cp ".build/release/$dylib" "/Applications/meee2.app/Contents/MacOS/$dylib"
    elif [[ "$dylib" == "libMeee2PluginKit.dylib" || "$dylib" == "libMeee2CommKit.dylib" ]]; then
        echo "Error: required dylib missing: .build/release/$dylib" >&2
        exit 1
    fi
done

# Copy SwiftPM resource bundle (contains WebDist)
cp -R .build/arm64-apple-macosx/release/meee2_meee2Kit.bundle /Applications/meee2.app/Contents/Resources/ 2>/dev/null

# Copy app icon
cp Resources/AppIcon.icns /Applications/meee2.app/Contents/Resources/AppIcon.icns 2>/dev/null

# Copy hook bridge
cp Bridge/claude-hook-bridge.sh /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null
chmod +x /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null

echo "Signing app bundle..."
codesign --force --deep --sign - --entitlements meee2.entitlements /Applications/meee2.app

echo "Launching..."
open /Applications/meee2.app

echo ""
echo "Deployed! (signature preserved from build.sh)"
