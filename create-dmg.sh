#!/bin/bash

# Create DMG for meee2
#
# Env overrides:
#   VERSION          — package version; defaults to 0.1.2. CI sets this from the
#                      git tag (strip leading "v").
#   SKIP_FINDER_UI=1 — skip the osascript Finder-window styling (useful in
#                      headless CI where Finder isn't available). The DMG still
#                      gets created, just without custom icon positioning.

set -e

cd "$(dirname "$0")"

APP_NAME="meee2"
VERSION="${VERSION:-0.2.0}"
APP_DIR=".build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_TEMP="/tmp/${APP_NAME}-temp.dmg"
VOLUME_NAME="${APP_NAME}"

echo "Packaging version: $VERSION"

echo "=== Building ${APP_NAME} ==="

# Build web frontend so WebDist is populated before swift build
echo "=== Building Web Board ==="
if command -v npm &>/dev/null; then
    (cd web && npm ci && npm run build)
    echo "Web Board built → Sources/Board/WebDist/"
else
    echo "Warning: npm not found; using existing WebDist (may be stale)"
fi

./build.sh

echo ""
echo "=== Creating App Bundle ==="

# Clean up old app bundle
rm -rf "$APP_DIR"

# Create app bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy executable
cp ".build/release/${APP_NAME}" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

# Copy dylib
DYLIB_SRC="$HOME/.meee2/lib/libMeee2PluginKit.dylib"
if [ -f "$DYLIB_SRC" ]; then
    cp "$DYLIB_SRC" "$APP_DIR/Contents/Frameworks/"
    echo "Copied libMeee2PluginKit.dylib"
else
    echo "Warning: libMeee2PluginKit.dylib not found at $DYLIB_SRC"
fi

# Copy SwiftPM resource bundle (contains WebDist etc.)
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/meee2_meee2Kit.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
    echo "Copied meee2_meee2Kit.bundle"
else
    echo "Warning: meee2_meee2Kit.bundle not found at $RESOURCE_BUNDLE"
fi

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "Copied AppIcon.icns"
fi

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

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>meee2</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.meee2.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>meee2</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
<string>__VERSION__</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Substitute runtime version into Info.plist (heredoc had __VERSION__ placeholder)
sed -i '' "s/__VERSION__/${VERSION}/" "$APP_DIR/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Fix rpath for dynamic library
echo ""
echo "=== Fixing Rpath ==="
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

# Sign the app bundle with entitlements
echo ""
echo "=== Signing App Bundle ==="

# Sign frameworks first
if [ -f "$APP_DIR/Contents/Frameworks/libMeee2PluginKit.dylib" ]; then
    codesign --force --sign - "$APP_DIR/Contents/Frameworks/libMeee2PluginKit.dylib"
fi

# Sign the app with entitlements
codesign --force --sign - --entitlements meee2.entitlements --deep "$APP_DIR"

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

# Sign the app bundle again after adding plugins
codesign --force --sign - --entitlements meee2.entitlements --deep "$APP_DIR"

echo "App bundle created: $APP_DIR"

# Create DMG with background
echo ""
echo "=== Creating DMG ==="

# Remove old files
rm -f "dist/$DMG_NAME"
rm -f "$DMG_TEMP"
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

echo ""
echo "=== Done ==="
echo "DMG created: dist/$DMG_NAME"
ls -lh "dist/$DMG_NAME"