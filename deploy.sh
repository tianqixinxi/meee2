#!/bin/bash
# deploy.sh - Build and deploy meee2 to /Applications. Preserves TCC
# (Accessibility) permissions across deploys IFF you sign with a stable
# identity — set IDENTITY env to your "Apple Development" or
# "Developer ID Application" cert. With ad-hoc (no IDENTITY), every deploy
# rotates the code signature and macOS revokes Accessibility permission.

cd "$(dirname "$0")"

. scripts/lib-codesign.sh

# Build (forwards IDENTITY through env; build.sh signs binary + PluginKit)
bash build.sh || exit 1

# Resolve the same BUILD_DIR build.sh used. Single-arch (host) →
# .build/release; UNIVERSAL=1 → .build/apple/Products/Release.
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_DIR=".build/apple/Products/Release"
else
    BUILD_DIR=".build/release"
fi

# Copy binary and dylibs without re-signing
echo ""
echo "Deploying to /Applications/meee2.app..."
killall meee2 2>/dev/null
sleep 0.5

cp "$BUILD_DIR/meee2" /Applications/meee2.app/Contents/MacOS/meee2

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
    if [ -f "$BUILD_DIR/$dylib" ]; then
        cp "$BUILD_DIR/$dylib" "/Applications/meee2.app/Contents/MacOS/$dylib"
    elif [[ "$dylib" == "libMeee2PluginKit.dylib" || "$dylib" == "libMeee2CommKit.dylib" ]]; then
        echo "Error: required dylib missing: $BUILD_DIR/$dylib" >&2
        exit 1
    fi
done

# Copy Info.plist —— deploy.sh 之前从来不更新 Info.plist，于是 dev iteration
# 时改了 App/Info.plist（加 NSAppleEventsUsageDescription 之类的）不会生效。
# 复制时保留 create-dmg.sh 写入的 CFBundleShortVersionString（如有），不
# 然 dev 部署会把版本号改回 0.2.0 之类的硬编码值。
if [ -f /Applications/meee2.app/Contents/Info.plist ] \
        && command -v plutil >/dev/null 2>&1; then
    EXISTING_VERSION=$(plutil -extract CFBundleShortVersionString raw \
        /Applications/meee2.app/Contents/Info.plist 2>/dev/null || true)
fi
cp App/Info.plist /Applications/meee2.app/Contents/Info.plist
if [ -n "${EXISTING_VERSION:-}" ] && command -v plutil >/dev/null 2>&1; then
    plutil -replace CFBundleShortVersionString -string "$EXISTING_VERSION" \
        /Applications/meee2.app/Contents/Info.plist 2>/dev/null || true
fi

# Copy SwiftPM resource bundle (contains WebDist).
# Single-arch builds drop it under `.build/arm64-apple-macosx/release/`;
# universal builds put it in `.build/apple/Products/Release/`. Glob picks
# whichever exists for this build mode.
RESOURCE_BUNDLE_SRC=$(find .build -maxdepth 4 -name "meee2_meee2Kit.bundle" -type d 2>/dev/null | head -1)
if [ -n "$RESOURCE_BUNDLE_SRC" ]; then
    cp -R "$RESOURCE_BUNDLE_SRC" /Applications/meee2.app/Contents/Resources/
else
    echo "Warning: meee2_meee2Kit.bundle not found under .build/"
fi

# Copy app icon
cp Resources/AppIcon.icns /Applications/meee2.app/Contents/Resources/AppIcon.icns 2>/dev/null

# Copy hook bridge
cp Bridge/claude-hook-bridge.sh /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null
chmod +x /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null

# Sign in the right order:
#   1) inner dylibs first (codesign rejects re-signing a bundle whose
#      contents change signature later)
#   2) bundle last
# Helper picks up IDENTITY env (real Developer ID + hardened runtime +
# secure timestamp) or falls back to ad-hoc with a warning.
echo "Signing dylibs + app bundle..."
for dylib in "${RUNTIME_DYLIBS[@]}"; do
    target="/Applications/meee2.app/Contents/MacOS/$dylib"
    [ -f "$target" ] && meee2_sign "$target"
done
meee2_sign /Applications/meee2.app --entitlements meee2.entitlements

echo "Launching..."
open /Applications/meee2.app

echo ""
if meee2_signing_real; then
    echo "Deployed with identity: $IDENTITY (Accessibility permissions retained)"
else
    echo "Deployed with ad-hoc signature. Each ad-hoc deploy invalidates"
    echo "Accessibility permissions (push-now etc. will re-prompt). Set"
    echo "IDENTITY env to keep them sticky."
fi
