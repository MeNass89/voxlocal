#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/RemoteScribePortable.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
DERIVED_DATA_PATH="${VOXLOCAL_IOS_DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"

if [[ ! -d "$PROJECT" ]]; then
  echo "Projet Xcode introuvable: $PROJECT" >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode complet est requis (xcodebuild absent; les Command Line Tools ne suffisent pas)." >&2
  exit 2
fi

XCODE_ARGS=(
  -project "$PROJECT"
  -scheme RemoteScribePortable
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  build
)
if [[ -n "${TEAM_ID:-}" ]]; then
  XCODE_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi
if [[ -n "${CODE_SIGNING_ALLOWED:-}" ]]; then
  XCODE_ARGS+=("CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED")
fi

xcodebuild "${XCODE_ARGS[@]}"

echo "Build iOS terminé dans $DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/"
