#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h}
BUILD_DIR="$PROJECT_DIR/build-native/diagnostics"
/bin/mkdir -p "$BUILD_DIR"
/usr/bin/xcrun swiftc \
    -swift-version 5 \
    -parse-as-library \
    "$PROJECT_DIR/Sources/VoxLocal/Models.swift" \
    "$PROJECT_DIR/Sources/VoxLocal/AppPaths.swift" \
    "$PROJECT_DIR/Sources/VoxLocal/Repositories.swift" \
    "$PROJECT_DIR/Sources/VoxLocal/ModelCatalog.swift" \
    "$PROJECT_DIR/Diagnostics/main.swift" \
    -o "$BUILD_DIR/VoxLocalDiagnostics"
"$BUILD_DIR/VoxLocalDiagnostics"

if [[ "${VOXLOCAL_TEST_MIC:-0}" == "1" ]]; then
    /usr/bin/xcrun swiftc \
        -swift-version 5 \
        -parse-as-library \
        -framework AVFoundation \
        -framework AudioToolbox \
        -framework CoreAudio \
        "$PROJECT_DIR/Sources/VoxLocal/Models.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/AudioRecorder.swift" \
        "$PROJECT_DIR/Diagnostics/audio.swift" \
        -o "$BUILD_DIR/VoxLocalAudioDiagnostics"
    "$BUILD_DIR/VoxLocalAudioDiagnostics"
fi

if [[ "${VOXLOCAL_TEST_PIPELINE:-0}" == "1" ]]; then
    /usr/bin/xcrun swiftc \
        -swift-version 5 \
        -parse-as-library \
        -framework AppKit \
        -framework ApplicationServices \
        -framework Carbon \
        -framework AVFoundation \
        -framework AudioToolbox \
        -framework CoreAudio \
        "$PROJECT_DIR/Sources/VoxLocal/Models.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/AppPaths.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/Repositories.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/ModelCatalog.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/AudioRecorder.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/PlatformServices.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/Engines.swift" \
        "$PROJECT_DIR/Sources/VoxLocal/DictationPipeline.swift" \
        "$PROJECT_DIR/Diagnostics/pipeline.swift" \
        -o "$BUILD_DIR/VoxLocalPipelineDiagnostics"
    "$BUILD_DIR/VoxLocalPipelineDiagnostics"
fi
