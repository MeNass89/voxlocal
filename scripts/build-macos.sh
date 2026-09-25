#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
PROJECT_DIR="${VOXLOCAL_DESKTOP_SOURCE_DIR:-$ROOT/mac/VoxLocal}"
[[ -x "$PROJECT_DIR/package-dmg.sh" ]] || { print -u2 "Source desktop introuvable: $PROJECT_DIR"; exit 2; }
# The DMG is named after the app version (CFBundleShortVersionString).
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/App/Info.plist")

VOXLOCAL_AGENT_SOURCE_DIR="${VOXLOCAL_AGENT_SOURCE_DIR:-$ROOT/agent}" \
VOXLOCAL_AGENT_DOC_SOURCE_DIR="${VOXLOCAL_AGENT_DOC_SOURCE_DIR:-$ROOT/docs}" \
VOXLOCAL_APP_DIR="${VOXLOCAL_APP_DIR:-/tmp/voxlocal-desktop-app/VoxLocal.app}" \
VOXLOCAL_SWIFT_BUILD_PATH="${VOXLOCAL_SWIFT_BUILD_PATH:-/tmp/voxlocal-desktop-swift}" \
VOXLOCAL_DMG_STAGING_PATH="${VOXLOCAL_DMG_STAGING_PATH:-/tmp/voxlocal-desktop-dmg}" \
VOXLOCAL_DMG_PATH="${VOXLOCAL_DMG_PATH:-$ROOT/VoxLocal-$VERSION.dmg}" \
  "$PROJECT_DIR/package-dmg.sh"
