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
APP="$BUILD/Build/Products/Release/slopMTP.app"
DIST=dist
ZIP="$DIST/slopMTP-$VERSION.zip"

echo "==> Building slopMTP $VERSION"
rm -rf "$BUILD" "$DIST"
mkdir -p "$DIST"
xcodegen generate --quiet
xcodebuild -project slopMTP.xcodeproj -scheme slopMTP -configuration Release \
  -derivedDataPath "$BUILD" build | grep -E "error:|BUILD" || true
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags="
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "The app still has the get-task-allow entitlement; notarization would fail."
  exit 1
fi

echo "==> Notarizing"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/notarize.zip"
RESULT=$(xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile slopmtp-notary --wait --output-format json)
rm "$DIST/notarize.zip"
STATUS=$(echo "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
SUBMISSION=$(echo "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "Notarization: $STATUS ($SUBMISSION)"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$SUBMISSION" --keychain-profile slopmtp-notary
  exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP"
