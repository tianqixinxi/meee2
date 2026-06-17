#!/bin/bash

# Create DMG for meee2
#
# Env overrides:
#   VERSION          — package version; defaults to 0.0.0-dev. CI sets this from
#                      the git tag (strip leading "v").
#   SKIP_FINDER_UI=1 — skip the osascript Finder-window styling (useful in
#                      headless CI where Finder isn't available). The DMG still
#                      gets created, just without custom icon positioning.
#   IDENTITY         — Developer ID Application identity for codesign. Without
#                      this we sign ad-hoc (Gatekeeper-blocked unless the user
#                      right-click-Opens). Required for notarization.
#   NOTARIZE=1       — submit DMG to Apple notary service after build (requires
#                      IDENTITY + NOTARY_PROFILE in keychain; see scripts/
#                      notarize.sh for details). Skipped silently if either is
#                      missing.
#   NOTARY_PROFILE   — keychain profile alias for notarytool credentials.
#   UNIVERSAL=1      — fat arm64+x86_64 binary (slower, but Intel Macs need it).

set -e

cd "$(dirname "$0")"

. scripts/lib-codesign.sh

APP_NAME="meee2"
VERSION="${VERSION:-0.0.0-dev}"
APP_DIR=".build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_TEMP="/tmp/${APP_NAME}-temp.dmg"
VOLUME_NAME="${APP_NAME}"

echo "Packaging version: $VERSION"

echo "=== Building ${APP_NAME} ==="

# Build web frontend so WebDist is populated before swift build.
# `pnpm build` (no -F filter) walks the whole workspace in dep order so
# board-app's tsc can resolve @meee1/{board-cards,board-core,board-ui,
# board-persistence-http} via emitted .d.ts. -F filter alone fails on
# a clean runner because deps haven't been built yet.
echo "=== Building Web Board ==="
if command -v pnpm &>/dev/null; then
    pnpm install --frozen-lockfile=false
    pnpm build
    echo "Web Board built → Sources/Board/WebDist/"
else
    # Hard-fail instead of silently shipping empty WebDist (.gitkeep only)
    # which used to surface as "Open Board → 404". WebDist is required and
    # must be regenerated each release; release.yml installs pnpm via
    # corepack on macos-15 runner.
    echo "ERROR: pnpm not found — cannot build WebDist; refusing to ship empty Board" >&2
    exit 1
fi

SKIP_WEB_BUILD=1 ./build.sh

# Resolve build dir (universal mode lives in a different path tree)
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_DIR=".build/apple/Products/Release"
else
    BUILD_DIR=".build/release"
fi

echo ""
echo "=== Creating App Bundle ==="

# Clean up old app bundle
rm -rf "$APP_DIR"

# Create app bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/${APP_NAME}" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

# Copy dylibs the binary needs at runtime via @rpath.
# Both PluginKit and CommKit are dynamic libs (see meee2-*-kit/Package.swift),
# the binary itself was rpath'd to Frameworks/ a few lines down. Any new
# dynamic dependency added to Package.swift needs to be appended here too.
RUNTIME_DYLIBS=(
    "libMeee2PluginKit.dylib"
    "libMeee2CommKit.dylib"
)
for dylib in "${RUNTIME_DYLIBS[@]}"; do
    src="$BUILD_DIR/$dylib"
    if [ -f "$src" ]; then
        cp "$src" "$APP_DIR/Contents/Frameworks/"
        echo "Copied $dylib"
    else
        echo "ERROR: $dylib not found at $src — app will fail to launch"
        exit 1
    fi
done

# Sparkle.framework —— bundled separately because it's an xcframework
# binary artifact (lives under .build/artifacts/...) not a SwiftPM
# library output. Without this the binary links fine but the runtime
# Sparkle controller can't spawn its XPC Downloader/Installer subprocesses
# → "Unable to Check For Updates / The updater failed to start" on click.
SPARKLE_SRC=$(find .build -maxdepth 6 -name "Sparkle.framework" -type d -path "*/Sparkle.xcframework/macos-arm64_x86_64/*" 2>/dev/null | head -1)
if [ -z "$SPARKLE_SRC" ]; then
    # Fallback: SwiftPM may have copied it into BUILD_DIR
    SPARKLE_SRC="$BUILD_DIR/Sparkle.framework"
fi
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "WARN: Sparkle.framework not found — auto-update will not work in this build"
    echo "  expected at .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
else
    cp -R "$SPARKLE_SRC" "$APP_DIR/Contents/Frameworks/"
    echo "Copied Sparkle.framework (from $SPARKLE_SRC)"
fi

# Copy SwiftPM resource bundle (contains WebDist etc.). Path differs by
# build mode: single-arch lives under .build/<host-arch>/release, universal
# under .build/apple/Products/Release. `find` picks whichever exists.
RESOURCE_BUNDLE=$(find .build -maxdepth 4 -name "meee2_meee2Kit.bundle" -type d 2>/dev/null | head -1)
if [ -n "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
    echo "Copied meee2_meee2Kit.bundle (from $RESOURCE_BUNDLE)"
else
    echo "Warning: meee2_meee2Kit.bundle not found under .build/"
fi

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "Copied AppIcon.icns"
fi
for icon in Resources/meee2StatusTemplate.png Resources/meee2StatusTemplate@2x.png Resources/meee2StatusTemplate@3x.png; do
    if [ -f "$icon" ]; then
        cp "$icon" "$APP_DIR/Contents/Resources/"
    fi
done
echo "Copied menu bar template icon"

# Copy Bridge scripts and install MCP server dependencies
if [ -d "Bridge" ]; then
    if command -v npm &>/dev/null; then
        echo "Installing MCP server dependencies..."
        (cd Bridge/mcp-meee2 && npm ci --omit=dev)
    else
        echo "Warning: npm not found; MCP server will lack node_modules"
    fi
    cp -R Bridge "$APP_DIR/Contents/Resources/"
    chmod +x "$APP_DIR/Contents/Resources/Bridge/claude-hook-bridge.sh"
    echo "Copied Bridge scripts (with node_modules if available)"
    # Clean up node_modules from worktree (gitignored, not needed in repo)
    rm -rf Bridge/mcp-meee2/node_modules
fi

# Info.plist —— single source of truth is App/Info.plist (committed to repo,
# also used by deploy.sh). Just `cp` it then inject the build-time VERSION
# via plutil. Don't keep an inline heredoc: prior history had two copies
# of the plist that drifted (different keys, different version handling).
cp App/Info.plist "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" \
    "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" \
    "$APP_DIR/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Fix rpath for dynamic library
echo ""
echo "=== Fixing Rpath ==="
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

# Sign the app bundle with entitlements + (when IDENTITY is set) hardened
# runtime + secure timestamp via the shared helper.
echo ""
echo "=== Signing App Bundle ==="

# Sign frameworks first (codesign rejects re-signing a bundle whose
# contents change signature later → reverse-tree order).
for dylib in "${RUNTIME_DYLIBS[@]}"; do
    if [ -f "$APP_DIR/Contents/Frameworks/$dylib" ]; then
        meee2_sign "$APP_DIR/Contents/Frameworks/$dylib"
    fi
done

# Sparkle.framework needs deepest-first signing of its XPC services and
# Updater.app, then Autoupdate, then the framework itself. Order matters —
# codesign refuses to sign a parent whose contents already changed under
# a different signature. The framework comes from Sparkle's release with
# a Sparkle-team signature; we re-sign with our Developer ID so the
# host app's signature is consistent (notarization rejects mixed teams).
SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    SPARKLE_VERSIONS_DIR="$SPARKLE_FW/Versions/B"
    [ -d "$SPARKLE_VERSIONS_DIR/XPCServices/Downloader.xpc" ] && \
        meee2_sign "$SPARKLE_VERSIONS_DIR/XPCServices/Downloader.xpc"
    [ -d "$SPARKLE_VERSIONS_DIR/XPCServices/Installer.xpc" ] && \
        meee2_sign "$SPARKLE_VERSIONS_DIR/XPCServices/Installer.xpc"
    [ -d "$SPARKLE_VERSIONS_DIR/Updater.app" ] && \
        meee2_sign "$SPARKLE_VERSIONS_DIR/Updater.app"
    [ -f "$SPARKLE_VERSIONS_DIR/Autoupdate" ] && \
        meee2_sign "$SPARKLE_VERSIONS_DIR/Autoupdate"
    meee2_sign "$SPARKLE_FW"
fi

# Sign inner executable, then bundle. We don't pass --deep: it's officially
# discouraged and signs everything indiscriminately, which conflicts with
# explicit per-component signing above. Notarization is fine without it.
meee2_sign "$APP_DIR/Contents/MacOS/${APP_NAME}" --entitlements meee2.entitlements
meee2_sign "$APP_DIR" --entitlements meee2.entitlements

echo "App bundle created: $APP_DIR"

# Install builtin plugins
echo ""
echo "=== Installing Builtin Plugins ==="

# Cursor Plugin
CURSOR_DYLIB=".build/release/libCursorPlugin.dylib"
if [ -f "$CURSOR_DYLIB" ]; then
    # Create plugin directory in app bundle
    mkdir -p "$APP_DIR/Contents/Resources/Plugins/cursor"
    cp "$CURSOR_DYLIB" "$APP_DIR/Contents/Resources/Plugins/cursor/CursorPlugin.dylib"
    # Create plugin.json
    cat > "$APP_DIR/Contents/Resources/Plugins/cursor/plugin.json" << CURSOR_EOF
{
    "id": "com.meee2.plugin.cursor",
    "name": "Cursor",
"version": "${VERSION}",
    "dylib": "CursorPlugin.dylib",
    "helpUrl": "https://docs.cursor.com"
}
CURSOR_EOF
    echo "Installed Cursor plugin"
else
    echo "Warning: CursorPlugin.dylib not found"
fi

# OpenClaw Plugin
OPENCLAW_DYLIB=".build/release/libOpenClawPlugin.dylib"
if [ -f "$OPENCLAW_DYLIB" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/Plugins/openclaw"
    cp "$OPENCLAW_DYLIB" "$APP_DIR/Contents/Resources/Plugins/openclaw/OpenClawPlugin.dylib"
    cat > "$APP_DIR/Contents/Resources/Plugins/openclaw/plugin.json" << 'OPENCLAW_EOF'
{
    "id": "com.meee2.plugin.openclaw",
    "name": "OpenClaw",
    "version": "0.2.0",
    "dylib": "OpenClawPlugin.dylib"
}
OPENCLAW_EOF
    echo "Installed OpenClaw plugin"
else
    echo "Warning: OpenClawPlugin.dylib not found"
fi

# Sign plugin dylibs we just added, then re-seal the bundle. (Adding
# files inside Contents/Resources invalidates the bundle's seal.)
find "$APP_DIR/Contents/Resources/Plugins" -name "*.dylib" -type f 2>/dev/null \
    | while read -r dylib; do meee2_sign "$dylib"; done
meee2_sign "$APP_DIR" --entitlements meee2.entitlements

echo "App bundle created (signed): $APP_DIR"

# When we have a real Developer ID identity AND the user opted into
# notarization, staple the .app *before* it lands in the DMG so the DMG
# carries the notarized .app. Stapling later (via scripts/notarize.sh)
# also works but only staples the DMG itself; keeping both consistent
# avoids "the app inside this DMG isn't notarized" reports.
if meee2_signing_real && [ "${NOTARIZE_APP:-0}" = "1" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo ""
    echo "=== Notarizing .app (NOTARIZE_APP=1) ==="
    APP_ZIP="/tmp/${APP_NAME}-notarize-${VERSION}.zip"
    rm -f "$APP_ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    rm -f "$APP_ZIP"
    xcrun stapler staple "$APP_DIR"
fi

# Create DMG with background
echo ""
echo "=== Creating DMG ==="

# Remove old files
rm -f "dist/$DMG_NAME"
rm -f "$DMG_TEMP"

# 之前 run 没干净 detach 的话，/Volumes 里会有 read-only 的残留挂载（macOS
# 防意外覆盖），新 hdiutil attach 用相同 volname 时被自动改名 "meee2 1" /
# "meee2 2"，于是 cp 写到 /Volumes/$VOLUME_NAME 命中老的 read-only 挂载，
# 几千行 "Read-only file system" 报错。这里一次性把所有同名挂载清掉。
while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    echo "Detaching stale mount: $mp"
    hdiutil detach "$mp" -force 2>/dev/null || true
done < <(mount | awk -v vname="$VOLUME_NAME" '$3 ~ ("^/Volumes/" vname "( |$)") {
    # field 3 onward is the mount point; trim trailing " (...)" properties
    out=""; for (i=3; i<=NF; i++) { if ($i ~ /^\(/) break; out = (out=="" ? $i : out " " $i) } print out
}')
# rm -rf 在 mount 仍存在时是 no-op；确认清干净
rm -rf "/Volumes/$VOLUME_NAME" 2>/dev/null || true

# Create dist directory
mkdir -p dist

# Create temporary DMG (larger size for background)
hdiutil create -size 500m -volname "${VOLUME_NAME}" -fs HFS+ -fsargs "-c c=64,a=16,e=16" "$DMG_TEMP"

# Mount the DMG
hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen

# Copy app to DMG
cp -R "$APP_DIR" "/Volumes/$VOLUME_NAME/"

# Create Applications symlink
ln -s /Applications "/Volumes/$VOLUME_NAME/Applications"

# Create CLI install script
cat > "/Volumes/$VOLUME_NAME/install-cli.sh" << 'EOF'
#!/bin/bash
echo "Installing meee2 CLI to /usr/local/bin..."
sudo ln -sf /Applications/meee2.app/Contents/MacOS/meee2 /usr/local/bin/meee2
echo ""
echo "Done! You can now use 'meee2' command in terminal:"
echo "  meee2          - Start GUI (default)"
echo "  meee2 tui      - Start TUI dashboard"
echo "  meee2 list     - List sessions"
echo "  meee2 --help   - Show help"
EOF
chmod +x "/Volumes/$VOLUME_NAME/install-cli.sh"

# Set DMG window appearance using AppleScript. Needs a running Finder — skipped
# in CI (SKIP_FINDER_UI=1) where Finder isn't reachable from headless runners.
if [ "${SKIP_FINDER_UI:-0}" = "1" ]; then
    echo ""
    echo "=== SKIP_FINDER_UI=1 → skipping DMG window styling ==="
else
    echo ""
    echo "=== Configuring DMG Window ==="
    osascript <<APPLESCRIPT || echo "(osascript failed; DMG still usable without custom layout)"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 450}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "${APP_NAME}.app" of container window to {130, 180}
        set position of item "Applications" of container window to {370, 180}
        set position of item "install-cli.sh" of container window to {250, 280}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
fi

# Make sure it's not busy
sync

# Unmount
hdiutil detach "/Volumes/$VOLUME_NAME"

# Convert to compressed DMG
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "dist/$DMG_NAME"

# Clean up
rm -f "$DMG_TEMP"

# Sign the DMG itself with the same identity. Gatekeeper checks both the
# .app inside AND the DMG envelope —— an unsigned DMG with a signed app
# inside still nags users. With ad-hoc the helper just no-ops effectively.
echo ""
echo "=== Signing DMG ==="
meee2_sign "dist/$DMG_NAME"

# Optional: notarize the DMG. Gated on NOTARIZE=1 + NOTARY_PROFILE +
# real identity. scripts/notarize.sh contains the actual call so it can
# also be run standalone for an existing DMG.
if [ "${NOTARIZE:-0}" = "1" ]; then
    if ! meee2_signing_real; then
        echo "[notarize] SKIP: NOTARIZE=1 but no real IDENTITY — ad-hoc DMGs cannot be notarized."
    elif [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "[notarize] SKIP: NOTARIZE=1 but NOTARY_PROFILE unset."
        echo "          Create one with: xcrun notarytool store-credentials <ALIAS> --apple-id ... --team-id ... --password ..."
    else
        echo ""
        echo "=== Notarizing DMG ==="
        bash scripts/notarize.sh "dist/$DMG_NAME"
    fi
fi

echo ""
echo "=== Done ==="
echo "DMG created: dist/$DMG_NAME"
ls -lh "dist/$DMG_NAME"
shasum -a 256 "dist/$DMG_NAME"
