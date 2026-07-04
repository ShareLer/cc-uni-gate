#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
ARTIFACT_DIR="$ROOT_DIR/.build/release-artifacts"
TOOLS_DIR="$ROOT_DIR/.build/sparkle-tools"
APP_NAME="CC Uni Gate"
ZIP_NAME="CC-Uni-Gate-v$(tr -d '[:space:]' < "$VERSION_FILE")-macos.zip"

# GitHub Releases is the public distribution channel.
# Sparkle reads the appcast from:
#   https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
# so we derive <owner>/<repo> from the configured `origin` remote instead of
# hardcoding the repository name in multiple places.
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

cd "$ROOT_DIR"

# The repository version is the single source of truth for both the app bundle
# and the published release tag. Keeping the tag and bundle version aligned
# makes Sparkle appcasts deterministic and prevents accidental mismatches.
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$VERSION" ]]; then
  echo "VERSION file is empty: $VERSION_FILE" >&2
  exit 1
fi

REMOTE_URL="$(git remote get-url origin)"
REPO_SLUG="$(repo_slug_from_remote "$REMOTE_URL" || true)"
if [[ -z "$REPO_SLUG" ]]; then
  echo "Unsupported origin remote: $REMOTE_URL" >&2
  exit 1
fi

DOWNLOAD_PREFIX="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/"
RELEASE_TAG="v${VERSION}"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
ZIP_PATH="$ARTIFACT_DIR/$ZIP_NAME"
APPCAST_PATH="$ARTIFACT_DIR/appcast.xml"

# Sparkle's appcast generator is built from the checked-out Sparkle project.
# Build it once into a stable local derived-data directory and reuse the tool
# across releases to avoid repeatedly rebuilding Sparkle command-line tools.
if [[ ! -x "$TOOLS_DIR/Build/Products/Release/generate_appcast" ]]; then
  xcodebuild -project .build/checkouts/Sparkle/Sparkle.xcodeproj \
    -scheme generate_appcast \
    -configuration Release \
    -derivedDataPath "$TOOLS_DIR" \
    build
fi

# Rebuild the app bundle in release mode first. This script intentionally
# reuses the same build-and-install logic as local packaging so that the
# uploaded zip matches the app the developer can run locally.
BUILD_ONLY=1 ./scripts/build-install-run.sh

mkdir -p "$ARTIFACT_DIR"
rm -f "$ZIP_PATH" "$APPCAST_PATH"

# Sparkle expects a zipped app bundle. `ditto` preserves the macOS resource
# fork and code-signing structure that Sparkle needs when validating archives.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# Generate/refresh appcast.xml using the versioned zip file above. The download
# URL prefix must point at the versioned GitHub Release asset directory so that
# Sparkle can resolve each enclosure URL correctly.
"$TOOLS_DIR/Build/Products/Release/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$APPCAST_PATH" \
  "$ARTIFACT_DIR"

# Publish step:
# - if the release tag already exists, update the existing assets in place
# - otherwise create the release and attach appcast.xml + the zip asset
# This keeps the release page and Sparkle feed in sync with a single command.
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release upload "$RELEASE_TAG" "$ZIP_PATH" "$APPCAST_PATH" --clobber
else
  gh release create "$RELEASE_TAG" "$ZIP_PATH" "$APPCAST_PATH" \
    --title "CC Uni Gate $RELEASE_TAG" \
    --generate-notes
fi

echo "Published $RELEASE_TAG to GitHub Releases."
