#!/usr/bin/env bash
# Builds llama.cpp for iOS without Metal into Packages/LlamaCpp/llama.xcframework.
set -euo pipefail
tag=b11869
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="${TMPDIR:-/tmp}/llama.cpp-$tag"
[ -d "$work" ] || git clone -q --depth 1 --branch $tag https://github.com/ggml-org/llama.cpp.git "$work"
cd "$work"
sed -e 's/^GGML_METAL=ON/GGML_METAL=OFF/' -e 's/^LLAMA_BUILD_MTMD=ON/LLAMA_BUILD_MTMD=OFF/' build-xcframework.sh > build-xcframework-cpu.sh
bash build-xcframework-cpu.sh ios-device ios-sim
rm -rf "$repo/Packages/LlamaCpp/llama.xcframework"
cp -R build-apple/llama.xcframework "$repo/Packages/LlamaCpp/"
