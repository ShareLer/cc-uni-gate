#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CC Uni Gate"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
EXECUTABLE_NAME="UniGateApp"
OLD_INSTALL_PATH="/Applications/API Manager.app"
ICON_FILE="AppIcon.icns"

cd "$ROOT_DIR"

swift build -c release --product UniGateApp

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "Resources/$ICON_FILE" "$APP_BUNDLE/Contents/Resources/$ICON_FILE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>UniGateApp</string>
  <key>CFBundleIdentifier</key>
  <string>local.unigate</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CC Uni Gate</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.8</string>
  <key>CFBundleVersion</key>
  <string>7</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

pkill -f UniGateApp 2>/dev/null || true
pkill -f ApiManagerApp 2>/dev/null || true
osascript -e 'tell application "API Manager" to quit' 2>/dev/null || true
osascript -e 'tell application "CC Uni Gate" to quit' 2>/dev/null || true

rm -rf "$INSTALL_PATH"
rm -rf "$OLD_INSTALL_PATH"
cp -R "$APP_BUNDLE" "$INSTALL_PATH"

open "$INSTALL_PATH"

echo "Installed and launched $INSTALL_PATH"
