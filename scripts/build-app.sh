#!/bin/zsh
# Builds build/DriveDock.app.
#
# Usage: scripts/build-app.sh [--universal] [--install]
#   --universal   arm64 + x86_64 (used for releases)
#   --install     copy to ~/Applications and launch
#
# Environment:
#   VERSION        marketing version (default: CFBundleShortVersionString from Resources/Info.plist)
#   BUILD_NUMBER   CFBundleVersion (default: number of git commits, or 1)
#   SIGN_IDENTITY  codesign identity; "-" = ad hoc. Default: "DriveDock Local Signing" if it
#                  exists in the keychain (see scripts/setup-signing.sh), otherwise ad hoc.
set -euo pipefail

cd "${0:A:h}/.."
APP_NAME="DriveDock"
APP="build/$APP_NAME.app"
PLIST_BUDDY=/usr/libexec/PlistBuddy

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

ARCH_FLAGS=(--arch arm64)
(( UNIVERSAL )) && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations: English is the development language, the others are *.lproj folders.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

VERSION="${VERSION:-$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
$PLIST_BUDDY -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PLIST_BUDDY -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# A stable identity keeps keychain access across updates; ad hoc signing changes the
# app's identity with every build, so macOS asks for keychain access again.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-certificate -c "DriveDock Local Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="DriveDock Local Signing"
  else
    SIGN_IDENTITY="-"
    echo "Note: signing ad hoc – run scripts/setup-signing.sh once to avoid keychain prompts after updates."
  fi
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER, signed with: $SIGN_IDENTITY)"

if (( INSTALL )); then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/$APP_NAME.app"
  echo "Installed and launched $DEST/$APP_NAME.app"
fi
