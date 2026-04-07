#!/bin/bash

# Create DMG for meee2

set -e

cd "$(dirname "$0")"

APP_NAME="meee2"
APP_DIR=".build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_TEMP="/tmp/${APP_NAME}-temp.dmg"
VOLUME_NAME="${APP_NAME}"

echo "=== Building ${APP_NAME} ==="
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

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "Copied AppIcon.icns"
fi

# Copy Bridge scripts
if [ -d "Bridge" ]; then
    cp -R Bridge "$APP_DIR/Contents/Resources/"
    chmod +x "$APP_DIR/Contents/Resources/Bridge/claude-hook-bridge.sh"
    echo "Copied Bridge scripts"
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
    <string>0.0.2</string>
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
hdiutil create -size 200m -volname "${VOLUME_NAME}" -fs HFS+ -fsargs "-c c=64,a=16,e=16" "$DMG_TEMP"

# Mount the DMG
hdiutil attach "$DMG_TEMP" -readwrite -noverify -noautoopen

# Copy app to DMG
cp -R "$APP_DIR" "/Volumes/$VOLUME_NAME/"

# Create Applications symlink
ln -s /Applications "/Volumes/$VOLUME_NAME/Applications"

# Set DMG window appearance using AppleScript
echo ""
echo "=== Configuring DMG Window ==="
osascript << APPLESCRIPT
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
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

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