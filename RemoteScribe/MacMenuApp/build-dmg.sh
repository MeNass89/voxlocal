#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Remote Scribe.app"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-root"
APP="$STAGE/$APP_NAME"
DMG="$DIST/Remote-Scribe-Mac.dmg"
UNIVERSAL_BUILD="$ROOT/.build-dmg"

cd "$ROOT"
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/RemoteScribeModuleCache" \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift build -c release --product RemoteScribeMac --arch x86_64 --arch arm64 --scratch-path "$UNIVERSAL_BUILD"

/bin/rm -rf "$STAGE"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$UNIVERSAL_BUILD/apple/Products/Release/RemoteScribeMac" "$APP/Contents/MacOS/RemoteScribeMac"
/bin/cp "$ROOT/MacMenuApp/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/../VoxLocal/assets/VoxLocal.icns" ]]; then
  /bin/cp "$ROOT/../VoxLocal/assets/VoxLocal.icns" "$APP/Contents/Resources/RemoteScribe.icns"
fi
/bin/ln -s /Applications "$STAGE/Applications"
/usr/bin/codesign --force --deep --sign - "$APP"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create -volname "Remote Scribe" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "$DMG"
