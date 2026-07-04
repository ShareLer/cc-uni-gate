#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CC Uni Gate"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
EXECUTABLE_NAME="UniGateApp"
OLD_INSTALL_PATH="/Applications/API Manager.app"
ICON_FILE="AppIcon.icns"
VERSION_FILE="$ROOT_DIR/VERSION"
SPARKLE_FEED_URL_INPUT="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY_INPUT="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_CONFIGURED=0
BUILD_ONLY="${BUILD_ONLY:-0}"

# This script serves two purposes:
# 1) local packaging/install for development
# 2) the shared build path used by the GitHub release script
#
# Sparkle config is intentionally resolved here so both flows use the same
# rules: explicit env vars win, otherwise we fall back to repository defaults.
read_trimmed_file() {
  tr -d '[:space:]' < "$1"
}

validate_sparkle_configuration() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import base64
import sys
from urllib.parse import urlparse

feed_url = sys.argv[1].strip()
public_key = sys.argv[2].strip()

parsed = urlparse(feed_url)
if not parsed.scheme:
    sys.exit("SPARKLE_FEED_URL must be an absolute URL.")
if parsed.scheme in ("http", "https") and not parsed.netloc:
    sys.exit("SPARKLE_FEED_URL must include a host for http/https URLs.")

try:
    key_data = base64.b64decode(public_key, validate=True)
except Exception:
    sys.exit("SPARKLE_PUBLIC_ED_KEY must be a base64-encoded Sparkle Ed25519 public key.")

if len(key_data) != 32:
    sys.exit(f"SPARKLE_PUBLIC_ED_KEY must decode to 32 bytes, got {len(key_data)} bytes.")
PY
}

default_sparkle_feed_url() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    return 1
  fi

  if [[ "$remote_url" =~ ^https://github.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf 'https://github.com/%s/%s/releases/latest/download/appcast.xml\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ "$remote_url" =~ ^git@github.com:([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf 'https://github.com/%s/%s/releases/latest/download/appcast.xml\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

# The public key is stored in the repository because it is not secret.
# The private key stays in the local Keychain via Sparkle's generate_keys tool.
default_sparkle_public_ed_key() {
  local key_file="$ROOT_DIR/config/sparkle-public-ed-key.txt"
  if [[ -f "$key_file" ]]; then
    tr -d '[:space:]' < "$key_file"
  fi
}

cd "$ROOT_DIR"

swift build -c release --product UniGateApp

APP_VERSION="$(read_trimmed_file "$VERSION_FILE")"
SPARKLE_FRAMEWORK_PATH="$(find .build -path '*/release/Sparkle.framework' -print -quit)"

if [[ -z "$APP_VERSION" ]]; then
  echo "VERSION file is empty: $VERSION_FILE" >&2
  exit 1
fi

if [[ -z "$SPARKLE_FRAMEWORK_PATH" ]]; then
  echo "Unable to locate Sparkle.framework in .build output" >&2
  exit 1
fi

SPARKLE_FEED_URL="${SPARKLE_FEED_URL_INPUT:-$(default_sparkle_feed_url || true)}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY_INPUT:-$(default_sparkle_public_ed_key || true)}"

# If both values are absent, we still build a runnable app bundle but leave the
# updater disabled. If only one value is present, fail early because that
# produces a half-configured bundle that Sparkle rejects at runtime.
if [[ -z "$SPARKLE_FEED_URL" && -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "Warning: Sparkle update configuration is empty; the built app will start with updater disabled." >&2
elif [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY must be set together." >&2
  exit 1
else
  validate_sparkle_configuration "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY"
  SPARKLE_CONFIGURED=1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp ".build/release/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "Resources/$ICON_FILE" "$APP_BUNDLE/Contents/Resources/$ICON_FILE"
cp -R "$SPARKLE_FRAMEWORK_PATH" "$APP_BUNDLE/Contents/Frameworks/"
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
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
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
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

if [[ "$SPARKLE_CONFIGURED" == "1" ]]; then
  # Only write Sparkle keys when configuration is complete and validated.
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string \"$SPARKLE_FEED_URL\"" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string \"$SPARKLE_PUBLIC_ED_KEY\"" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool false" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool false" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool true" "$APP_BUNDLE/Contents/Info.plist"
fi

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo "Built $APP_BUNDLE"
  exit 0
fi

pkill -f UniGateApp 2>/dev/null || true
pkill -f ApiManagerApp 2>/dev/null || true
osascript -e 'tell application "API Manager" to quit' 2>/dev/null || true
osascript -e 'tell application "CC Uni Gate" to quit' 2>/dev/null || true

rm -rf "$INSTALL_PATH"
rm -rf "$OLD_INSTALL_PATH"
cp -R "$APP_BUNDLE" "$INSTALL_PATH"

open "$INSTALL_PATH"

echo "Installed and launched $INSTALL_PATH"
