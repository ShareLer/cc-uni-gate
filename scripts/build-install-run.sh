#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CC Uni Gate"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
EXECUTABLE_NAME="UniGateApp"
ICON_FILE="AppIcon.icns"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_ONLY="${BUILD_ONLY:-0}"

# This script serves two purposes:
# 1) local packaging/install for development
# 2) the shared build path used by the GitHub release script
#
# Both paths derive the feed from origin and embed the repository public key,
# so a local build cannot silently differ from the published update channel.
# Both local and GitHub Release builds use the same ad-hoc signed bundle.
# Sparkle EdDSA authenticates update archives; first-time GitHub downloads
# require the user to remove the macOS quarantine attribute before launch.
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

stop_running_app() {
  osascript -e 'tell application "CC Uni Gate" to quit' 2>/dev/null || true
  pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true

  # Replacing a bundle while its old process is still registered can make
  # LaunchServices reuse the terminating instance instead of launching the new one.
  for _ in {1..40}; do
    if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
      return
    fi
    sleep 0.25
  done

  echo "$APP_NAME did not stop within 10 seconds." >&2
  exit 1
}

cd "$ROOT_DIR"

# Build the executable first, then assemble the app bundle manually.
# This keeps the local packaging flow close to the release flow while still
# letting us inject Sparkle configuration and bundle metadata explicitly.
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

SPARKLE_FEED_URL="$(default_sparkle_feed_url || true)"
SPARKLE_PUBLIC_ED_KEY="$(read_trimmed_file "$ROOT_DIR/config/sparkle-public-ed-key.txt")"

if [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "A GitHub origin and config/sparkle-public-ed-key.txt are required." >&2
  exit 1
fi
validate_sparkle_configuration "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

# Manually assemble the .app bundle so the bundle layout is obvious in one
# place and the release script can reuse the exact same output structure.
cp ".build/release/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "Resources/$ICON_FILE" "$APP_BUNDLE/Contents/Resources/$ICON_FILE"
cp -R "$SPARKLE_FRAMEWORK_PATH" "$APP_BUNDLE/Contents/Frameworks/"
# The rpath is required so the embedded executable can load Sparkle.framework
# from the bundle after we relocate it into /Applications.
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
fi

# Build the minimum required Info.plist fields explicitly so the bundle version
# always comes from VERSION before the mandatory update metadata is added.
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

# Update metadata is mandatory: every runnable build must exercise the same
# Sparkle configuration that users receive from GitHub Releases.
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string \"$SPARKLE_FEED_URL\"" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string \"$SPARKLE_PUBLIC_ED_KEY\"" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool false" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool false" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool true" "$APP_BUNDLE/Contents/Info.plist"

# Sign the app and every embedded Sparkle helper consistently. This is not an
# Apple trust signature; GitHub users still need the documented one-time xattr
# step after downloading the app for the first time.
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$BUILD_ONLY" == "1" ]]; then
  # BUILD_ONLY means "leave a build artifact for inspection", not "install it".
  # The release script packages this exact bundle and verifies its Sparkle key.
  echo "Built $APP_BUNDLE"
  exit 0
fi

# The install path is intentionally destructive because this is a developer
# convenience path, not a migration tool. It should never be used as the public
# update mechanism.
stop_running_app

rm -rf "$INSTALL_PATH"
ditto "$APP_BUNDLE" "$INSTALL_PATH"

# -n prevents stale LaunchServices state from swallowing a relaunch immediately
# after the previous process exits.
open -n "$INSTALL_PATH"

echo "Installed and launched $INSTALL_PATH"
