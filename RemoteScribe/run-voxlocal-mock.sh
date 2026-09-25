#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release --product RemoteScribeHost
exec .build/release/RemoteScribeHost --backend voxlocal "$@"
