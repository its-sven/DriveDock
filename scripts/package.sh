#!/bin/zsh
# Builds a universal DriveDock.app and packages it for a release:
#   dist/DriveDock-<version>.dmg   drag-to-Applications installer
#   dist/DriveDock-<version>.zip   used by the Homebrew cask
#   dist/SHA256SUMS.txt
#
# Usage: VERSION=1.2.3 scripts/package.sh   (VERSION defaults to the one in Info.plist)
set -euo pipefail

cd "${0:A:h}/.."
APP_NAME="DriveDock"

scripts/build-app.sh --universal
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "build/$APP_NAME.app/Contents/Info.plist")"

DIST="dist"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$DMG" "$ZIP"

# ZIP: ditto keeps the code signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "build/$APP_NAME.app" "$ZIP"

# DMG: the app next to a link to /Applications.
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING:?}"' EXIT
cp -R "build/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO -fs APFS "$DMG" >/dev/null

(cd "$DIST" && shasum -a 256 "${DMG:t}" "${ZIP:t}" > SHA256SUMS.txt)
echo "Packaged:"
cat "$DIST/SHA256SUMS.txt"
