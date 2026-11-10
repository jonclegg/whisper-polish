// swift-tools-version:5.9
import PackageDescription

// llama.cpp b11869 with Metal. llama.cpp's own release ships no iOS Simulator
// library, so this zip pairs the release's iPhone library, unchanged, with a
// simulator build of the same tag (built with build-xcframework.sh); the
// headers are identical. Hosted next to the polish model.
let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [.library(name: "llama", targets: ["llama"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://d36t08oi3ecji2.cloudfront.net/frameworks/llama-b11869-ios-sim.xcframework.zip",
            checksum: "9abb6e3293f6e117f4d7228e67079bf9a87cc9f204b9afbbc4b0c763a164b4af"
        ),
    ]
)
