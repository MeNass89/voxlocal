#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h}
JOBS="${VOXLOCAL_BUILD_JOBS:-8}"
command -v cmake >/dev/null || { print -u2 "CMake manque. Installer avec: brew install cmake"; exit 2; }
[[ -f "$PROJECT_DIR/Vendor/src/whisper.cpp/CMakeLists.txt" && -f "$PROJECT_DIR/Vendor/src/llama.cpp/CMakeLists.txt" ]] || {
    print -u2 "Sources natives absentes. Lancer: git submodule update --init --depth 1"; exit 2
}
/bin/mkdir -p "$PROJECT_DIR/Vendor/bin"

# GGML_NATIVE tunes the CPU kernels for the Apple Silicon generation of the
# build machine; Metal carries the heavy layers. The binaries are arm64 only.
COMMON_FLAGS=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=ON -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)

cmake -S "$PROJECT_DIR/Vendor/src/whisper.cpp" -B "$PROJECT_DIR/Vendor/build/whisper" "${COMMON_FLAGS[@]}" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON
cmake --build "$PROJECT_DIR/Vendor/build/whisper" --config Release --target whisper-cli -j "$JOBS"
/bin/cp "$PROJECT_DIR/Vendor/build/whisper/bin/whisper-cli" "$PROJECT_DIR/Vendor/bin/whisper-cli"

cmake -S "$PROJECT_DIR/Vendor/src/llama.cpp" -B "$PROJECT_DIR/Vendor/build/llama" "${COMMON_FLAGS[@]}" -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_UI=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_APP=OFF
cmake --build "$PROJECT_DIR/Vendor/build/llama" --config Release --target llama-cli llama-server -j "$JOBS"
for runtime in llama-cli llama-server; do
    /bin/cp "$PROJECT_DIR/Vendor/build/llama/bin/$runtime" "$PROJECT_DIR/Vendor/bin/$runtime"
done
print "Native runtimes rebuilt in Vendor/bin"
