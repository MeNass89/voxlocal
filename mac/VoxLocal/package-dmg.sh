#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
APP="${VOXLOCAL_APP_DIR:-$PROJECT_DIR/dist/VoxLocal.app}"
DMG="${VOXLOCAL_DMG_PATH:-$PROJECT_DIR/dist/VoxLocal-Agent-2026-09-24.dmg}"
STAGING="${VOXLOCAL_DMG_STAGING_PATH:-$PROJECT_DIR/.build-dmg/VoxLocal}"

"$PROJECT_DIR/build.sh"
[[ -x "$APP/Contents/Resources/Agent/bin/voxlocal-agent" ]] || {
  print -u2 "Bundle agent absent; relancer ./build.sh avec le dossier agent disponible."; exit 4
}
/bin/rm -rf -- "$STAGING"
/bin/mkdir -p "$STAGING"
/bin/cp -R "$APP" "$STAGING/VoxLocal.app"
/usr/bin/xattr -cr "$STAGING/VoxLocal.app" 2>/dev/null || true
/bin/ln -s /Applications "$STAGING/Applications"
/bin/rm -f -- "$DMG"
/usr/bin/hdiutil create -volname "VoxLocal" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
print "DMG créé : $DMG"
