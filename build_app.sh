#!/usr/bin/env bash
# Build HermesKeeper (SwiftPM) and assemble a hand-crafted .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HermesKeeper"
BIN=".build/release/$APP_NAME"
APPDIR="dist/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

cp "$BIN" "$APPDIR/Contents/MacOS/$APP_NAME"

cat > "$APPDIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HermesKeeper</string>
    <key>CFBundleDisplayName</key><string>HermesKeeper</string>
    <key>CFBundleIdentifier</key><string>com.linminhao.hermeskeeper</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>HermesKeeper</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# app icon
if [ -f scripts/AppIcon.icns ]; then
  cp scripts/AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APPDIR/Contents/Info.plist" 2>/dev/null || true
fi

xattr -cr "$APPDIR"
codesign --force --deep --sign - "$APPDIR"
echo "==> Built: $APPDIR"
