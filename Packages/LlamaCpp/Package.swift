// swift-tools-version:5.9
import PackageDescription

// EXPERIMENT: llama.cpp's prebuilt b11869 with Metal, to measure GPU speed and memory.
let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [.library(name: "llama", targets: ["llama"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11869/llama-b11869-xcframework.zip",
            checksum: "1bd572b9ccf0829fd67e1d04e6ab8cafb7baca5459dc17cbfe6fcb2cce509d28"
        ),
    ]
)
