#!/usr/bin/env bash
set -euo pipefail

# Build signed macOS .app for Tome (Swift)
# Usage:
#   ./scripts/build_swift_app.sh
#
# For CI / explicit identity:
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_swift_app.sh
#
# For notarization:
#   APPLE_ID="name@example.com"
#   APPLE_TEAM_ID="TEAMID123"
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/Tome"
APP_NAME="Tome"
BUNDLE_ID="com.dloomis.tome"

echo "=== Building $APP_NAME (Swift) ==="

# Build release binary (arm64 only — FluidAudio ASR models require Apple Silicon)
# Use CLT Swift 6.2 explicitly; Xcode's 6.3 has stricter concurrency that breaks FluidAudio
SWIFT="${TOOLCHAINS_SWIFT:-/Library/Developer/CommandLineTools/usr/bin/swift}"
cd "$SWIFT_DIR"
# EXTRA_SWIFT_BUILD_FLAGS lets an instrumented build inject diagnostics, e.g.
#   EXTRA_SWIFT_BUILD_FLAGS="-Xswiftc -enable-actor-data-race-checks" ./scripts/build_swift_app.sh
# See scripts/build_instrumented.sh.
# shellcheck disable=SC2086
"$SWIFT" build -c release ${EXTRA_SWIFT_BUILD_FLAGS:-} 2>&1
BINARY_PATH=".build/release/Tome"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

echo "Binary built: $BINARY_PATH"

# Create .app bundle
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/Tome"

# Make the SwiftPM-built executable behave like a normal app bundle by
# teaching dyld to search the app's embedded Frameworks directory.
APP_BINARY="$APP_DIR/Contents/MacOS/Tome"
if ! otool -l "$APP_BINARY" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
  echo "Added app Frameworks rpath to executable"
fi

# Copy Info.plist
cp "$SWIFT_DIR/Sources/Tome/Info.plist" "$APP_DIR/Contents/Info.plist"

# Stamp the version from git onto the COPY, leaving the committed source
# Info.plist untouched. The release workflow (release-dmg.yml) patches
# CFBundleVersion/CFBundleShortVersionString with PlistBuddy too, but only in
# its ephemeral CI checkout — that bump is never committed back, so the
# checked-in Info.plist is just a placeholder. Deriving it here means a local
# build always reflects the real version instead of whatever was last
# hand-edited into that placeholder.
LATEST_TAG=$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n "$LATEST_TAG" ]]; then
  SHORT_VERSION="${LATEST_TAG#v}"
  GIT_DESCRIBE=$(git -C "$ROOT_DIR" describe --tags --dirty --always 2>/dev/null || echo "$LATEST_TAG")
  BUILD_VERSION="${GIT_DESCRIBE#v}"
  PLIST="$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$PLIST"
  echo "Stamped version: $SHORT_VERSION (build $BUILD_VERSION)"
else
  echo "No git tags found — leaving Info.plist version as committed"
fi

# Copy app icon (legacy .icns — used by Finder previews and as fallback)
ICON_PATH="$SWIFT_DIR/Sources/Tome/Assets/AppIcon.icns"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "App icon copied"
fi

# Compile the macOS 26 Liquid Glass icon (.icon → Assets.car). Without this,
# Tahoe renders the legacy .icns shrunken inside a system tile ("icon jail").
# Needs Xcode 26's actool; CLT alone doesn't ship it, so resolve Xcode
# explicitly and fall back to the .icns-only bundle when unavailable.
ICON_BUNDLE="$SWIFT_DIR/Sources/Tome/Assets/AppIcon.icon"
ACTOOL_DEV_DIR="${ACTOOL_DEVELOPER_DIR:-}"
if [[ -z "$ACTOOL_DEV_DIR" ]]; then
  if xcrun --find actool >/dev/null 2>&1; then
    ACTOOL_DEV_DIR="$(xcode-select -p)"   # already pointing at an Xcode (CI)
  elif [[ -d /Applications/Xcode.app ]]; then
    ACTOOL_DEV_DIR="/Applications/Xcode.app"
  fi
fi
if [[ -d "$ICON_BUNDLE" && -n "$ACTOOL_DEV_DIR" ]]; then
  if DEVELOPER_DIR="$ACTOOL_DEV_DIR" xcrun actool "$ICON_BUNDLE" \
      --compile "$APP_DIR/Contents/Resources" \
      --app-icon AppIcon --include-all-app-icons \
      --minimum-deployment-target 26.0 --platform macosx \
      --output-format human-readable-text \
      --output-partial-info-plist /dev/null >/dev/null 2>&1 \
      && [[ -f "$APP_DIR/Contents/Resources/Assets.car" ]]; then
    echo "Liquid Glass icon compiled (Assets.car)"
  else
    echo "Warning: actool failed (Xcode license not accepted?) — shipping legacy .icns only"
  fi
else
  echo "Warning: Xcode/actool not found — shipping legacy .icns only"
fi

# Copy Sparkle framework
SPARKLE_ARTIFACT_DIR="$SWIFT_DIR/.build/artifacts/sparkle"
SPARKLE_FW=$(find "$SPARKLE_ARTIFACT_DIR" -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [[ -n "$SPARKLE_FW" ]]; then
  cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
  echo "Sparkle.framework copied"
else
  echo "Warning: Sparkle.framework not found in build artifacts"
fi

# Add PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"

# Auto-detect signing identity if not set
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  fi
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    # Stable self-signed code-signing cert (free, no Apple account). Matched by name
    # (default "Tome Self-Signed", override with SELF_SIGNED_IDENTITY) so a local build
    # picks it up automatically once imported — letting macOS keep Screen Recording /
    # Microphone grants across updates instead of re-prompting every release.
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "${SELF_SIGNED_IDENTITY:-Tome Self-Signed}" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  fi
fi

ENTITLEMENTS="$SWIFT_DIR/Sources/Tome/Tome.entitlements"

# Decide how to sign:
#   developerid — a real "Developer ID Application" cert → hardened runtime + secure
#                 timestamp: the notarizable, Gatekeeper-clean path.
#   stable      — any other real identity (a self-signed code-signing cert, or an
#                 "Apple Development" cert). A *stable* signing identity is all macOS
#                 TCC needs to keep Screen Recording / Microphone grants across updates,
#                 so this is the "free, no $99 account, but stop re-prompting" path. We
#                 sign plainly (entitlements only) — hardened runtime + secure timestamp
#                 are notarization-only and would add library-validation / network risk
#                 for a cert that can't be notarized anyway.
#   adhoc       — no identity → ad-hoc (`-`): free and launchable, but its code hash
#                 changes every build, so macOS re-prompts for permissions each update.
#                 (Re-signing ad-hoc is still required: the install_name_tool call above
#                 invalidates the linker's automatic signature, and an invalid signature
#                 makes macOS report the app as "damaged" rather than merely
#                 "from an unidentified developer".)
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  SIGN_MODE="adhoc"
  echo "No signing identity found — applying an ad-hoc signature (free, unsigned distribution)."
  echo "Users will see an 'unidentified developer' prompt on first launch; see README ▸ Install."
elif [[ "$CODESIGN_IDENTITY" == *"Developer ID Application"* ]]; then
  SIGN_MODE="developerid"
  echo "Signing with Developer ID (notarizable): $CODESIGN_IDENTITY"
else
  SIGN_MODE="stable"
  echo "Signing with a stable identity (no hardened runtime, not notarized): $CODESIGN_IDENTITY"
fi

# Sign one path. Hardened runtime + secure timestamp are notarization prerequisites
# and apply only to a real Developer ID signature. Extra args (e.g. --entitlements)
# are passed through before the path.
sign_path() {
  local path="$1"; shift
  case "$SIGN_MODE" in
    adhoc)       codesign --force "$@" --sign - "$path" ;;
    stable)      codesign --force "$@" --sign "$CODESIGN_IDENTITY" "$path" ;;
    developerid) codesign --force --options runtime --timestamp "$@" --sign "$CODESIGN_IDENTITY" "$path" ;;
  esac
}

# Sign Sparkle components inside-out (innermost first)
SPARKLE_FW_BUNDLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW_BUNDLE" ]]; then
  # Sign XPC service executables, then their bundles
  for xpc in "$SPARKLE_FW_BUNDLE"/Versions/B/XPCServices/*.xpc; do
    if [[ -d "$xpc" ]]; then
      sign_path "$xpc/Contents/MacOS/$(basename "${xpc%.xpc}")"
      sign_path "$xpc"
    fi
  done

  # Sign Autoupdate helper
  AUTOUPDATE="$SPARKLE_FW_BUNDLE/Versions/B/Autoupdate"
  if [[ -f "$AUTOUPDATE" ]]; then
    sign_path "$AUTOUPDATE"
  fi

  # Sign Updater.app
  UPDATER_APP="$SPARKLE_FW_BUNDLE/Versions/B/Updater.app"
  if [[ -d "$UPDATER_APP" ]]; then
    sign_path "$UPDATER_APP/Contents/MacOS/Updater"
    sign_path "$UPDATER_APP"
  fi

  # Sign the framework dylib, then the framework bundle
  sign_path "$SPARKLE_FW_BUNDLE/Versions/B/Sparkle"
  sign_path "$SPARKLE_FW_BUNDLE"
fi

# Sign the main app bundle (entitlements apply in both modes)
sign_path "$APP_DIR" --entitlements "$ENTITLEMENTS"

echo "Code signing complete (mode: $SIGN_MODE)"
codesign -vvv "$APP_DIR" 2>&1 || true

# Install to /Applications
cp -R "$APP_DIR" /Applications/
echo "Installed to /Applications/$APP_NAME.app"

echo "=== Build complete ==="
