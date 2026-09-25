#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h}

for command in /usr/bin/xcrun /usr/bin/swift /usr/bin/codesign; do
    [[ -x "$command" ]] || { print -u2 "Outil Apple manquant: $command"; exit 2; }
done

for runtime in whisper-cli llama-cli; do
    [[ -x "$PROJECT_DIR/Vendor/bin/$runtime" ]] || { print -u2 "Runtime manquant: Vendor/bin/$runtime (lancer ./build-runtimes.sh)"; exit 3; }
done

print "VoxLocal Swift est prêt. Lancez ./run.sh"
