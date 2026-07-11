#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
ARTIFACT_DIR="$ROOT_DIR/.build/release-artifacts"
TOOLS_DIR="$ROOT_DIR/.build/sparkle-tools"
APP_NAME="CC Uni Gate"
INSTALL_PATH="/Applications/$APP_NAME.app"
ACTION="${1:-build}"

# GitHub Releases are ad-hoc signed and rely on Sparkle EdDSA for update
# authenticity. Build and publish stay separate so the uploaded bytes are the
# exact zip and appcast that were installed and checked locally.

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
ZIP_NAME="CC-Uni-Gate-v${VERSION}-macos.zip"
SHA256_NAME="${ZIP_NAME}.sha256"
RELEASE_TAG="v${VERSION}"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
ZIP_PATH="$ARTIFACT_DIR/$ZIP_NAME"
SHA256_PATH="$ARTIFACT_DIR/$SHA256_NAME"
APPCAST_PATH="$ARTIFACT_DIR/appcast.xml"
APPCAST_INPUT_DIR="$ARTIFACT_DIR/appcast-input"
MANIFEST_PATH="$ARTIFACT_DIR/release-manifest.txt"
HEALTH_RESPONSE_PATH=""

cleanup() {
  rm -rf "$APPCAST_INPUT_DIR"
  if [[ -n "$HEALTH_RESPONSE_PATH" ]]; then
    rm -f "$HEALTH_RESPONSE_PATH"
  fi
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

repo_slug_from_remote() {
  local remote_url="$1"
  if [[ "$remote_url" =~ ^https://github.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$remote_url" =~ ^git@github.com:([^/]+)/([^/.]+)(\.git)?$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

release_installation_notes() {
  cat <<'EOF'
## 第一次安装

本项目不使用 Apple Developer ID，首次安装需要手动移除 macOS 添加的隔离属性：

1. 下载 `CC-Uni-Gate-*-macos.zip`。
2. 解压 zip。
3. 将 `CC Uni Gate.app` 移动到“应用程序”。
4. 打开终端并执行：

   ```bash
   xattr -cr "/Applications/CC Uni Gate.app"
   ```

5. 正常打开 `CC Uni Gate.app`。

请只对从本项目 GitHub Release 下载的应用执行上述命令。

## 应用内更新

首次安装并打开后，可以在 UniGate 设置中点击“检查更新”。发现新版本后点击“下载并更新”，Sparkle 会验证 EdDSA 签名、安装更新并重新启动应用，不需要再次执行 `xattr`。
EOF
}

ensure_appcast_tool() {
  if [[ -x "$TOOLS_DIR/Build/Products/Release/generate_appcast" \
        && -x "$TOOLS_DIR/Build/Products/Release/generate_keys" ]]; then
    return
  fi

  swift package resolve
  for scheme in generate_appcast generate_keys; do
    xcodebuild -project .build/checkouts/Sparkle/Sparkle.xcodeproj \
      -scheme "$scheme" \
      -configuration Release \
      -derivedDataPath "$TOOLS_DIR" \
      build
  done
}

validate_sparkle_key() {
  local configured_key keychain_key
  configured_key="$(tr -d '[:space:]' < "$ROOT_DIR/config/sparkle-public-ed-key.txt")"
  keychain_key="$("$TOOLS_DIR/Build/Products/Release/generate_keys" -p | tr -d '[:space:]')"

  # Rotating this key without a migration would strand every installed app.
  [[ -n "$configured_key" ]] || fail "Sparkle public key is empty."
  [[ "$configured_key" == "$keychain_key" ]] \
    || fail "Sparkle Keychain private key does not match config/sparkle-public-ed-key.txt."
}

validate_app_bundle() {
  local bundle_version bundle_public_key signature_details
  [[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  signature_details="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
  grep -q 'Signature=adhoc' <<<"$signature_details" \
    || fail "Release app must use the repository's ad-hoc signing flow."

  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
  bundle_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_BUNDLE/Contents/Info.plist")"
  [[ "$bundle_version" == "$VERSION" ]] \
    || fail "Bundle version $bundle_version does not match VERSION $VERSION."
  [[ "$bundle_public_key" == "$(tr -d '[:space:]' < "$ROOT_DIR/config/sparkle-public-ed-key.txt")" ]] \
    || fail "Bundle Sparkle public key does not match the repository key."

  [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Updater.app" ]] \
    || fail "Sparkle Updater.app is missing from the app bundle."
  [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/XPCServices" ]] \
    || fail "Sparkle XPC services are missing from the app bundle."
}

validate_appcast() {
  /usr/bin/python3 - "$APPCAST_PATH" "$VERSION" "$DOWNLOAD_PREFIX$ZIP_NAME" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, expected_version, expected_url = sys.argv[1:]
root = ET.parse(path).getroot()
channel = root.find("channel")
items = [] if channel is None else channel.findall("item")
if len(items) != 1:
    raise SystemExit(f"appcast must contain exactly one item, found {len(items)}")

item = items[0]
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
version = item.findtext(f"{namespace}shortVersionString")
enclosure = item.find("enclosure")
if version != expected_version:
    raise SystemExit(f"appcast version {version!r} does not match {expected_version!r}")
if enclosure is None:
    raise SystemExit("appcast enclosure is missing")
if enclosure.get("url") != expected_url:
    raise SystemExit(f"unexpected appcast URL: {enclosure.get('url')!r}")
if not enclosure.get(f"{namespace}edSignature"):
    raise SystemExit("appcast EdDSA signature is missing")
if int(enclosure.get("length", "0")) <= 0:
    raise SystemExit("appcast enclosure length is invalid")
PY
}

resolved_proxy_port() {
  /usr/bin/python3 - <<'PY'
import json
from pathlib import Path

path = Path.home() / "Library/Application Support/UniGate/preferences.json"
try:
    port = int(json.loads(path.read_text()).get("port") or 17888)
except Exception:
    port = 17888
print(port if port > 0 else 17888)
PY
}

install_and_check_app() {
  local port base_url
  pkill -f UniGateApp 2>/dev/null || true
  osascript -e 'tell application "CC Uni Gate" to quit' 2>/dev/null || true
  rm -rf "$INSTALL_PATH"
  ditto "$APP_BUNDLE" "$INSTALL_PATH"
  open "$INSTALL_PATH"

  port="$(resolved_proxy_port)"
  base_url="http://127.0.0.1:${port}"
  HEALTH_RESPONSE_PATH="$(mktemp)"
  for _ in {1..40}; do
    if curl -fsS --max-time 2 "$base_url/__manager/health" > "$HEALTH_RESPONSE_PATH" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
  curl -fsS --max-time 5 "$base_url/__manager/health" > "$HEALTH_RESPONSE_PATH"
  /usr/bin/python3 - "$HEALTH_RESPONSE_PATH" <<'PY'
import json
import sys

health = json.load(open(sys.argv[1], encoding="utf-8"))
if health.get("ok") is not True:
    raise SystemExit(f"UniGate health check failed: {health}")
print(f"Installed app is healthy: {health.get('providers', 0)} providers, {health.get('candidates', 0)} candidates")
PY

  local built_hash installed_hash
  built_hash="$(shasum -a 256 "$APP_BUNDLE/Contents/MacOS/UniGateApp" | awk '{print $1}')"
  installed_hash="$(shasum -a 256 "$INSTALL_PATH/Contents/MacOS/UniGateApp" | awk '{print $1}')"
  [[ "$built_hash" == "$installed_hash" ]] \
    || fail "Installed executable does not match the release app bundle."
}

write_manifest() {
  local zip_hash appcast_hash commit
  zip_hash="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
  appcast_hash="$(shasum -a 256 "$APPCAST_PATH" | awk '{print $1}')"
  commit="$(git rev-parse HEAD)"
  printf 'version=%s\ncommit=%s\nzip_sha256=%s\nappcast_sha256=%s\n' \
    "$VERSION" "$commit" "$zip_hash" "$appcast_hash" > "$MANIFEST_PATH"
}

manifest_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$MANIFEST_PATH"
}

build_release() {
  # A clean tree binds the artifact to one reproducible commit. Checking only
  # at publish time is too late because dirty source may already be in the zip.
  [[ -z "$(git status --porcelain)" ]] \
    || fail "The worktree must be clean before building a release."

  ensure_appcast_tool
  validate_sparkle_key

  BUILD_ONLY=1 "$ROOT_DIR/scripts/build-install-run.sh"
  validate_app_bundle

  mkdir -p "$ARTIFACT_DIR"
  rm -f "$ZIP_PATH" "$SHA256_PATH" "$APPCAST_PATH" "$MANIFEST_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  unzip -tq "$ZIP_PATH"
  (cd "$ARTIFACT_DIR" && shasum -a 256 "$ZIP_NAME" > "$SHA256_NAME")

  # A clean input directory prevents old zips and unusable delta references
  # from leaking into the new latest/download appcast.
  rm -rf "$APPCAST_INPUT_DIR"
  mkdir -p "$APPCAST_INPUT_DIR"
  cp "$ZIP_PATH" "$APPCAST_INPUT_DIR/$ZIP_NAME"
  "$TOOLS_DIR/Build/Products/Release/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    -o "$APPCAST_PATH" \
    "$APPCAST_INPUT_DIR"
  validate_appcast

  install_and_check_app
  # The manifest locks publish to the commit and hashes checked above.
  write_manifest

  echo "Release $RELEASE_TAG is built, installed, and verified."
  echo "Run './scripts/publish-github-release.sh publish' after checking the app locally."
}

publish_release() {
  [[ -f "$MANIFEST_PATH" ]] || fail "Release manifest is missing. Run the build action first."
  [[ -f "$ZIP_PATH" && -f "$SHA256_PATH" && -f "$APPCAST_PATH" ]] \
    || fail "Release artifacts are incomplete. Run the build action first."
  [[ -z "$(git status --porcelain)" ]] \
    || fail "The worktree must be clean before publishing."

  git fetch origin main
  local head_commit remote_commit
  head_commit="$(git rev-parse HEAD)"
  remote_commit="$(git rev-parse origin/main)"
  [[ "$head_commit" == "$remote_commit" ]] \
    || fail "HEAD must be pushed to origin/main before publishing."
  [[ "$(manifest_value version)" == "$VERSION" ]] \
    || fail "Built artifact version does not match VERSION."
  [[ "$(manifest_value commit)" == "$head_commit" ]] \
    || fail "Built artifacts do not match the current commit. Run the build action again."
  [[ "$(manifest_value zip_sha256)" == "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" ]] \
    || fail "Release zip changed after local verification."
  [[ "$(manifest_value appcast_sha256)" == "$(shasum -a 256 "$APPCAST_PATH" | awk '{print $1}')" ]] \
    || fail "appcast.xml changed after local verification."
  (cd "$ARTIFACT_DIR" && shasum -a 256 -c "$SHA256_NAME")
  validate_appcast

  if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    fail "GitHub Release $RELEASE_TAG already exists. Bump VERSION instead of replacing a published release."
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
    fail "Git tag $RELEASE_TAG already exists. Bump VERSION before publishing."
  fi

  gh release create "$RELEASE_TAG" "$ZIP_PATH" "$SHA256_PATH" "$APPCAST_PATH" \
    --target "$head_commit" \
    --title "CC Uni Gate $RELEASE_TAG" \
    --latest \
    --fail-on-no-commits \
    --generate-notes \
    --notes "$(release_installation_notes)"

  local asset_names
  asset_names="$(gh release view "$RELEASE_TAG" --json assets --jq '.assets[].name')"
  grep -qx "$ZIP_NAME" <<<"$asset_names" || fail "Release zip was not uploaded."
  grep -qx "$SHA256_NAME" <<<"$asset_names" || fail "Release SHA-256 file was not uploaded."
  grep -qx 'appcast.xml' <<<"$asset_names" || fail "Release appcast.xml was not uploaded."
  echo "Published $RELEASE_TAG to https://github.com/${REPO_SLUG}/releases/tag/$RELEASE_TAG"
}

cd "$ROOT_DIR"
[[ -n "$VERSION" ]] || fail "VERSION is empty."
REMOTE_URL="$(git remote get-url origin)"
REPO_SLUG="$(repo_slug_from_remote "$REMOTE_URL" || true)"
[[ -n "$REPO_SLUG" ]] || fail "Unsupported origin remote: $REMOTE_URL"
DOWNLOAD_PREFIX="https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}/"

case "$ACTION" in
  build)
    build_release
    ;;
  publish)
    publish_release
    ;;
  *)
    fail "Usage: $0 [build|publish]"
    ;;
esac
