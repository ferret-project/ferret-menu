#!/bin/bash
# Builds a release of Ferret Menu into dist/: Ferret-Menu.zip, appcast.xml (Sparkle's update feed, signed) and
# SHA256SUMS. The release workflow runs it on a tag; it runs the same on a Mac.
#
#   scripts/release.sh <version> [download address prefix]
#
# The prefix is where the zip will be downloaded from (default: this version's GitHub release).
#
# Signing, from what's set:
#   DEVELOPER_ID_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)", in a keychain codesign can reach
#                           (CI imports it from secrets). Not set: signed to run locally (ad-hoc).
#   NOTARY_KEY_FILE, NOTARY_KEY_ID, NOTARY_ISSUER
#                           an App Store Connect API key: notarize and staple (needs DEVELOPER_ID_IDENTITY).
#   SPARKLE_KEY             the update-signing private key (CI's secret). Not set: Sparkle's tools use the one in
#                           this Mac's login Keychain (account "ferret-menu").
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?version, e.g. 0.2.0}"
PREFIX="${2:-https://github.com/ferret-project/ferret-menu/releases/download/v$VERSION/}"
SPARKLE_VERSION="2.10.1"
APP_NAME="Ferret Menu"
BUILD="build/release"
DIST="dist"

# Sparkle's tools (generate_appcast), the same version the app is built with.
tools="build/sparkle-$SPARKLE_VERSION"
if [ ! -x "$tools/bin/generate_appcast" ]; then
  mkdir -p "$tools"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar xJ -C "$tools"
fi

signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
if [ -n "${DEVELOPER_ID_IDENTITY:-}" ]; then
  team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$DEVELOPER_ID_IDENTITY")"
  signing=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=YES)
  echo "Signing with $DEVELOPER_ID_IDENTITY"
else
  echo "Signing to run locally (no Developer ID)"
fi

xcodegen -q
rm -rf "$BUILD" "$DIST"
xcodebuild -project FerretMenu.xcodeproj -scheme FerretMenu -configuration Release -derivedDataPath "$BUILD" \
  MARKETING_VERSION="$VERSION" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO "${signing[@]}" build | grep -E "error:|warning: .*ferret-menu/|BUILD" || true
app="$BUILD/Build/Products/Release/$APP_NAME.app"
test -d "$app" || { echo "build failed"; exit 1; }
codesign --verify --deep --strict "$app"
test "$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)" = "$VERSION"

mkdir -p "$DIST"
zip="$DIST/Ferret-Menu.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

if [ -n "${NOTARY_KEY_FILE:-}" ]; then
  test -n "${DEVELOPER_ID_IDENTITY:-}" || { echo "notarizing needs DEVELOPER_ID_IDENTITY"; exit 1; }
  echo "Notarizing"
  xcrun notarytool submit "$zip" --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$app"
  rm "$zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
fi

# The update feed: generate_appcast reads the version from the app in the zip and signs the zip with the key.
key=(--account ferret-menu)
if [ -n "${SPARKLE_KEY:-}" ]; then key=(--ed-key-file -); fi
printf '%s' "${SPARKLE_KEY:-}" | "$tools/bin/generate_appcast" "${key[@]}" --download-url-prefix "$PREFIX" \
  --link "https://github.com/ferret-project/ferret-menu" "$DIST"
test -f "$DIST/appcast.xml"

(cd "$DIST" && shasum -a 256 Ferret-Menu.zip appcast.xml > SHA256SUMS)
echo "Built $VERSION into $DIST/"
