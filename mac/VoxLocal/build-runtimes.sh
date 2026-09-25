#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h}
command -v cmake >/dev/null || { print -u2 "CMake manque. Installer avec: brew install cmake"; exit 2; }

cmake -S "$PROJECT_DIR/Vendor/src/whisper.cpp" -B "$PROJECT_DIR/Vendor/build/whisper" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$PROJECT_DIR/Vendor/build/whisper" --config Release --target whisper-cli -j 4
/bin/cp "$PROJECT_DIR/Vendor/build/whisper/bin/whisper-cli" "$PROJECT_DIR/Vendor/bin/whisper-cli"

cmake -S "$PROJECT_DIR/Vendor/src/llama.cpp" -B "$PROJECT_DIR/Vendor/build/llama" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_UI=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_APP=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$PROJECT_DIR/Vendor/build/llama" --config Release --target llama-cli -j 4
/bin/cp "$PROJECT_DIR/Vendor/build/llama/bin/llama-cli" "$PROJECT_DIR/Vendor/bin/llama-cli"
print "Native runtimes rebuilt in Vendor/bin"
