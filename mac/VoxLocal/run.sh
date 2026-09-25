#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h}
APP="$PROJECT_DIR/dist/VoxLocal.app"
[[ -d "$APP" ]] || "$PROJECT_DIR/build.sh"
exec /usr/bin/open -n "$APP"
