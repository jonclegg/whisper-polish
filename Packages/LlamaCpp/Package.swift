// swift-tools-version:5.9
import PackageDescription

// llama.cpp's own prebuilt XCFramework, pinned to one release and verified by
// checksum, so the on-device cleanup model (S1-mini) runs without building
// llama.cpp from source. Bumping it means updating both the URL and the
// checksum: the checksum is the release asset's published sha256.
let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS(.v14)],
    products: [.library(name: "llama", targets: ["llama"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11433/llama-b11433-xcframework.zip",
            checksum: "42feed827d87cb03ebfb6c5c6a76bacd0f34ad34dacd5591a0f1bdc24e6e52ba"
        ),
    ]
)
