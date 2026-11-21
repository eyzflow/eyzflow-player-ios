// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EYZFlowPlayer",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        // Only so `swift test` runs on a Mac; the player targets iOS and tvOS.
        .macOS(.v13),
    ],
    products: [
        .library(name: "EYZFlowPlayer", targets: ["EYZFlowPlayer"]),
    ],
    targets: [
        .target(name: "EYZFlowPlayerCore"),
        .target(name: "EYZFlowPlayer", dependencies: ["EYZFlowPlayerCore"]),
        .testTarget(
            name: "EYZFlowPlayerCoreTests",
            dependencies: ["EYZFlowPlayerCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
