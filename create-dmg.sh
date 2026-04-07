#!/bin/bash

# Create DMG for meee2

set -e

cd "$(dirname "$0")"

APP_NAME="meee2"
APP_DIR=".build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_TEMP="${APP_NAME}-temp.dmg"

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
DYLIB_SRC="$HOME/.peer-island/lib/libPeerPluginKit.dylib"
if [ -f "$DYLIB_SRC" ]; then
    cp "$DYLIB_SRC" "$APP_DIR/Contents/Frameworks/"
    echo "Copied libPeerPluginKit.dylib"
else
    echo "Warning: libPeerPluginKit.dylib not found at $DYLIB_SRC"
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
    <string>1.0.0</string>
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
if [ -f "$APP_DIR/Contents/Frameworks/libPeerPluginKit.dylib" ]; then
    codesign --force --sign - "$APP_DIR/Contents/Frameworks/libPeerPluginKit.dylib"
fi

# Sign the app with entitlements
codesign --force --sign - --entitlements meee2.entitlements --deep "$APP_DIR"

echo "App bundle created: $APP_DIR"

# Create DMG
echo ""
echo "=== Creating DMG ==="

# Remove old DMG
rm -f "dist/$DMG_NAME"
rm -f "/tmp/$DMG_TEMP"

# Create dist directory
mkdir -p dist

# Create temporary DMG
hdiutil create -volname "${APP_NAME}" -srcfolder "$APP_DIR" -ov -format UDRW "/tmp/$DMG_TEMP"

# Convert to compressed DMG
hdiutil convert "/tmp/$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "dist/$DMG_NAME"

# Clean up
rm -f "/tmp/$DMG_TEMP"

echo ""
echo "=== Done ==="
echo "DMG created: dist/$DMG_NAME"
ls -lh "dist/$DMG_NAME"