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
cp .build/release/libMeee2PluginKit.dylib /Applications/meee2.app/Contents/MacOS/ 2>/dev/null
cp .build/release/libCursorPlugin.dylib /Applications/meee2.app/Contents/MacOS/ 2>/dev/null
cp .build/release/libOpenClawPlugin.dylib /Applications/meee2.app/Contents/MacOS/ 2>/dev/null

# Copy SwiftPM resource bundle (contains WebDist)
cp -R .build/arm64-apple-macosx/release/meee2_meee2Kit.bundle /Applications/meee2.app/Contents/Resources/ 2>/dev/null

# Copy hook bridge
cp Bridge/claude-hook-bridge.sh /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null
chmod +x /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null

echo "Launching..."
open /Applications/meee2.app

echo ""
echo "Deployed! (signature preserved from build.sh)"
