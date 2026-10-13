// swift-tools-version:5.10
// Runs the keyboard's prediction benchmarks and tests on Linux. The keyboard
// sources are copied in by sync.sh; UIKitShim stands in for the two UIKit types.
import PackageDescription

let package = Package(
    name: "KeyboardBench",
    targets: [
        .testTarget(name: "Bench", path: "Tests/Bench"),
    ]
)
