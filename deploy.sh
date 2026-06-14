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

# Make sure the deployed binary has @executable_path/../Frameworks in
# its LC_RPATH so dyld can find Sparkle.framework (and any other
# frameworks we drop into Contents/Frameworks/ later). build.sh added
# a developer-machine-specific rpath; deploy.sh historically dropped
# dylibs in MacOS/ to dodge that, but Sparkle is a framework that
# MUST be in Frameworks/. The `|| true` is for re-deploy when the
# rpath is already present — install_name_tool is non-idempotent.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    /Applications/meee2.app/Contents/MacOS/meee2 2>/dev/null || true

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

# Sparkle.framework lives in xcframework artifact dir, not in BUILD_DIR.
# Find it then drop into the .app's Frameworks/ (deploy.sh historically
# put dylibs in MacOS/, but a framework MUST be in Frameworks/ for dyld
# to load it via @rpath/Sparkle.framework — which is how Sparkle is
# linked). Also walk inside-out signing so the local ad-hoc deploy
# works the same as a notarized release build.
SPARKLE_SRC=$(find .build -maxdepth 6 -name "Sparkle.framework" -type d -path "*/Sparkle.xcframework/macos-arm64_x86_64/*" 2>/dev/null | head -1)
if [ -n "$SPARKLE_SRC" ] && [ -d "$SPARKLE_SRC" ]; then
    mkdir -p /Applications/meee2.app/Contents/Frameworks
    rm -rf /Applications/meee2.app/Contents/Frameworks/Sparkle.framework
    cp -R "$SPARKLE_SRC" /Applications/meee2.app/Contents/Frameworks/
    SPARKLE_FW=/Applications/meee2.app/Contents/Frameworks/Sparkle.framework
    SPARKLE_V="$SPARKLE_FW/Versions/B"
    [ -d "$SPARKLE_V/XPCServices/Downloader.xpc" ] && meee2_sign "$SPARKLE_V/XPCServices/Downloader.xpc"
    [ -d "$SPARKLE_V/XPCServices/Installer.xpc"  ] && meee2_sign "$SPARKLE_V/XPCServices/Installer.xpc"
    [ -d "$SPARKLE_V/Updater.app" ] && meee2_sign "$SPARKLE_V/Updater.app"
    [ -f "$SPARKLE_V/Autoupdate" ] && meee2_sign "$SPARKLE_V/Autoupdate"
    meee2_sign "$SPARKLE_FW"
    echo "Bundled + signed Sparkle.framework"
else
    echo "WARN: Sparkle.framework not found under .build/artifacts — deployed app won't auto-update"
fi

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
    # CFBundleVersion 也跟着同步：原来源 plist 里硬编码 "1",会让 Sparkle
    # 拿 "1" 跟 appcast 里 "0.3.0-rc4" 比版本,SUStandardVersionComparator
    # 把 "1" 当 build number,排序常常跟 prerelease 字符串方向反着 →
    # Settings 显示 "Current 1.0.0 / Latest 0.3.0",看起来"已经超新版" 不
    # 弹更新。强制让两个版本字段一致,Sparkle 比的就是同一份语义版号。
    plutil -replace CFBundleVersion -string "$EXISTING_VERSION" \
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
for icon in Resources/meee2StatusTemplate.png Resources/meee2StatusTemplate@2x.png Resources/meee2StatusTemplate@3x.png; do
    cp "$icon" /Applications/meee2.app/Contents/Resources/ 2>/dev/null
done

# Copy hook bridge
cp Bridge/claude-hook-bridge.sh /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null
chmod +x /Applications/meee2.app/Contents/Resources/Bridge/claude-hook-bridge.sh 2>/dev/null

# Sync the MCP bridge server — resolveServerScriptPath() reads it from the
# bundle, and startup staging copies the BUNDLE version to ~/.meee2/mcp-meee2/
# for the Claude plugin launcher. Without this sync the bundle keeps an old
# server.js forever and every new MCP tool "vanishes": readiness then fails
# with "missing required planner tools" even though the repo has the tool.
mkdir -p /Applications/meee2.app/Contents/Resources/Bridge/mcp-meee2
for f in server.js package.json package-lock.json; do
  cp "Bridge/mcp-meee2/$f" "/Applications/meee2.app/Contents/Resources/Bridge/mcp-meee2/$f" 2>/dev/null
done
chmod +x /Applications/meee2.app/Contents/Resources/Bridge/mcp-meee2/server.js 2>/dev/null

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
