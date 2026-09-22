// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HumanDetector",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HumanDetectorCore", targets: ["HumanDetectorCore"]),
        .executable(name: "humandetector", targets: ["HumanDetectorCLI"]),
    ],
    targets: [
        .target(
            name: "HumanDetectorCore",
            path: "Sources/HumanDetectorCore"
        ),
        .executableTarget(
            name: "HumanDetectorCLI",
            dependencies: ["HumanDetectorCore"],
            path: "Sources/HumanDetectorCLI"
        ),
        .testTarget(
            name: "HumanDetectorCoreTests",
            dependencies: ["HumanDetectorCore"],
            path: "Tests/HumanDetectorCoreTests"
        ),
    ]
)
