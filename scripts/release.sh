#!/bin/zsh
# Builds, signs (Developer ID), notarizes and staples slopMTP, then zips it for a GitHub release.
#
#   scripts/release.sh            # uses MARKETING_VERSION from project.yml
#
# Requires a notarytool keychain profile named "slopmtp-notary":
#   xcrun notarytool store-credentials slopmtp-notary --apple-id <apple id> --team-id G2743AT3J4
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
BUILD=.build/Release
APP="$BUILD/Build/Products/Release/SlopMTP.app"
DIST=dist
ZIP="$DIST/SlopMTP-$VERSION.zip"

echo "==> Building slopMTP $VERSION"
rm -rf "$BUILD" "$DIST"
mkdir -p "$DIST"
xcodegen generate --quiet
xcodebuild -project SlopMTP.xcodeproj -scheme SlopMTP -configuration Release \
  -derivedDataPath "$BUILD" build | grep -E "error:|BUILD" || true
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags="

echo "==> Notarizing"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile slopmtp-notary --wait
rm "$DIST/notarize.zip"

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP"
