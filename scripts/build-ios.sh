#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/RemoteScribePortable.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${VOXLOCAL_IOS_DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"

if [[ ! -d "$PROJECT" ]]; then
  echo "Projet Xcode introuvable: $PROJECT" >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode complet est requis (xcodebuild absent; les Command Line Tools ne suffisent pas)." >&2
  exit 2
fi

if [[ -n "${TEAM_ID:-}" ]]; then
  # Signed device build: -destination (e.g. platform=iOS,id=<UDID>) is only
  # honoured with a scheme, so this path keeps Xcode's scheme-based build.
  XCODE_ARGS=(
    -project "$PROJECT"
    -scheme RemoteScribePortable
    -configuration "$CONFIGURATION"
    -destination "${DESTINATION:-generic/platform=iOS}"
    -derivedDataPath "$DERIVED_DATA_PATH"
    build
    "DEVELOPMENT_TEAM=$TEAM_ID"
  )
else
  # Unsigned build (CI, first check): -target needs no shared scheme (the project
  # ships none). -derivedDataPath requires a scheme, so outputs go to the same
  # Products directory through SYMROOT/OBJROOT.
  XCODE_ARGS=(
    -project "$PROJECT"
    -target RemoteScribePortable
    -configuration "$CONFIGURATION"
    -sdk iphoneos
    build
    "SYMROOT=$DERIVED_DATA_PATH/Build/Products"
    "OBJROOT=$DERIVED_DATA_PATH/Build/Intermediates.noindex"
  )
fi
if [[ -n "${CODE_SIGNING_ALLOWED:-}" ]]; then
  XCODE_ARGS+=("CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED")
fi

xcodebuild "${XCODE_ARGS[@]}"

echo "Build iOS terminé dans $DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/"
