#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
ARTIFACT_DIR="$ROOT_DIR/.build/release-artifacts"
TOOLS_DIR="$ROOT_DIR/.build/sparkle-tools"
APP_NAME="CC Uni Gate"
ZIP_NAME="CC-Uni-Gate-v$(tr -d '[:space:]' < "$VERSION_FILE")-macos.zip"
TEMP_ZIP_NAME="CC-Uni-Gate-v$(tr -d '[:space:]' < "$VERSION_FILE")-macos.notary.zip"
DEVELOPER_ID_IDENTITY_INPUT="${APPLE_DEVELOPER_ID_IDENTITY:-${DEVELOPER_ID_IDENTITY:-}}"
NOTARYTOOL_PROFILE_INPUT="${NOTARYTOOL_PROFILE:-${APPLE_NOTARYTOOL_PROFILE:-}}"
NOTARIZE_RELEASE="${NOTARIZE_RELEASE:-1}"
UPLOAD_TO_GITHUB="${UPLOAD_TO_GITHUB:-1}"

# GitHub Releases is the public distribution channel.
# Sparkle reads the appcast from:
#   https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
# so we derive <owner>/<repo> from the configured `origin` remote instead of
# hardcoding the repository name in multiple places.
# This keeps the release artifact URLs, the appcast URL, and the release page
# aligned even if the repository is renamed or forked.
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
# If version, tag, and appcast drift apart, users can end up with "up to date"
# messages pointing at the wrong release, which is exactly the class of issue we
# want to eliminate here.
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
TEMP_ZIP_PATH="$ARTIFACT_DIR/$TEMP_ZIP_NAME"
APPCAST_PATH="$ARTIFACT_DIR/appcast.xml"
APPCAST_INPUT_DIR="$ARTIFACT_DIR/appcast-input"
trap 'rm -f "$TEMP_ZIP_PATH"; rm -rf "$APPCAST_INPUT_DIR"' EXIT

# Sparkle's appcast generator is built from the checked-out Sparkle project.
# Build it once into a stable local derived-data directory and reuse the tool
# across releases to avoid repeatedly rebuilding Sparkle command-line tools.
# The helper binary is part of the release toolchain, not the shipped app.
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
# Any mismatch here would produce a release asset that differs from the bundle
# you inspected in development, which is how "it works locally but not after
# download" regressions tend to sneak in.
BUILD_ONLY=1 ./scripts/build-install-run.sh
mkdir -p "$ARTIFACT_DIR"

resolve_developer_id_identity() {
  local identity="$1"
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
    return 0
  fi

# Public releases must use a Developer ID Application certificate.
# The local machine in this workspace may not have one, so we auto-detect
# the first usable identity and fail with a concrete message if it is absent.
# This explicit failure is intentional: silently falling back to ad-hoc signing
# would create downloadable artifacts that macOS can still block on open.
security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
}

sign_app_for_distribution() {
  local identity="$1"

  if [[ -z "$identity" ]]; then
    echo "A Developer ID Application identity is required to sign public releases." >&2
    echo "Set APPLE_DEVELOPER_ID_IDENTITY or install a Developer ID certificate." >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
  fi

# Re-sign the already-built bundle with the distribution identity.
# - runtime + timestamp are required for notarization
# - --deep keeps Sparkle.framework and nested helpers aligned with the app
# We re-sign here instead of in build-install-run.sh so local developer builds
# stay fast and usable even when Apple signing credentials are unavailable.
codesign --force --deep --options runtime --timestamp --sign "$identity" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

submit_for_notarization() {
  local profile="$1"

  if [[ -z "$profile" ]]; then
    echo "NOTARYTOOL_PROFILE must be set to a keychain profile name." >&2
    echo "Create one with: xcrun notarytool store-credentials <profile> ..." >&2
    exit 1
  fi

# We notarize a temporary zip and then re-zip the stapled app bundle for the
# final release asset. This keeps the shipped zip identical to the stapled app.
# If notarization fails, stop immediately: shipping an unstapled public build
# is exactly the failure mode that causes "can't open" reports after download.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$TEMP_ZIP_PATH"
  xcrun notarytool submit "$TEMP_ZIP_PATH" \
    --keychain-profile "$profile" \
    --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  rm -f "$TEMP_ZIP_PATH"
}

if [[ "$NOTARIZE_RELEASE" == "1" ]]; then
  # Formal release path: re-sign, notarize, staple, then package.
  DEVELOPER_ID_IDENTITY="$(resolve_developer_id_identity "$DEVELOPER_ID_IDENTITY_INPUT")"
  sign_app_for_distribution "$DEVELOPER_ID_IDENTITY"
  submit_for_notarization "$NOTARYTOOL_PROFILE_INPUT"
else
  # Local package mode keeps the ad-hoc bundle from build-install-run.sh.
  # This is useful for inspecting the archive contents or running a non-public
  # validation pass before Apple signing credentials are available.
  echo "Skipping Apple notarization for local package build." >&2
fi

rm -f "$ZIP_PATH" "$APPCAST_PATH"

# Sparkle expects a zipped app bundle. `ditto` preserves the macOS resource
# fork and code-signing structure that Sparkle needs when validating archives.
# This zip is what users download manually and what Sparkle uses in the update
# feed, so it must be produced only after the bundle is in its final state.
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# Generate/refresh appcast.xml using the versioned zip file above. The download
# URL prefix must point at the versioned GitHub Release asset directory so that
# Sparkle can resolve each enclosure URL correctly.
rm -rf "$APPCAST_INPUT_DIR"
mkdir -p "$APPCAST_INPUT_DIR"
cp "$ZIP_PATH" "$APPCAST_INPUT_DIR/$ZIP_NAME"
"$TOOLS_DIR/Build/Products/Release/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$APPCAST_PATH" \
  "$APPCAST_INPUT_DIR"

if [[ "$UPLOAD_TO_GITHUB" == "1" ]]; then
  # Publish step:
  # - if the release tag already exists, update the existing assets in place
  # - otherwise create the release and attach appcast.xml + the zip asset
  # This keeps the release page and Sparkle feed in sync with a single command.
  # Upload is deliberately blocked unless notarization is enabled so we never
  # publish a zip that is known to trigger Gatekeeper on first open.
  if [[ "$NOTARIZE_RELEASE" != "1" ]]; then
    echo "UPLOAD_TO_GITHUB=1 requires NOTARIZE_RELEASE=1." >&2
    exit 1
  fi

  if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "$ZIP_PATH" "$APPCAST_PATH" --clobber
  else
    gh release create "$RELEASE_TAG" "$ZIP_PATH" "$APPCAST_PATH" \
      --title "CC Uni Gate $RELEASE_TAG" \
      --generate-notes
  fi

  echo "Published $RELEASE_TAG to GitHub Releases."
else
  # Local-only mode is for validation and inspection. It still generates the
  # release zip and appcast so the artifact layout can be tested without
  # publishing anything publicly.
  echo "Built local release artifacts:" >&2
  echo "  $ZIP_PATH" >&2
  echo "  $APPCAST_PATH" >&2
fi
