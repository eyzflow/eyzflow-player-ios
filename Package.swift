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
    dependencies: [
        // Google IMA, for the ads in the player config: one package for
        // iPhone and iPad, another for Apple TV. Both frameworks are named
        // `GoogleInteractiveMediaAds`, each linked on its platform only.
        .package(
            url: "https://github.com/googleads/swift-package-manager-google-interactive-media-ads-ios",
            from: "3.34.1"
        ),
        .package(
            url: "https://github.com/googleads/swift-package-manager-google-interactive-media-ads-tvos",
            from: "4.18.1"
        ),
    ],
    targets: [
        .target(name: "EYZFlowPlayerCore"),
        .target(
            name: "EYZFlowPlayer",
            dependencies: [
                "EYZFlowPlayerCore",
                .product(
                    name: "GoogleInteractiveMediaAds",
                    package: "swift-package-manager-google-interactive-media-ads-ios",
                    condition: .when(platforms: [.iOS])
                ),
                .product(
                    name: "GoogleInteractiveMediaAdsTvOS",
                    package: "swift-package-manager-google-interactive-media-ads-tvos",
                    condition: .when(platforms: [.tvOS])
                ),
            ]
        ),
        .testTarget(
            name: "EYZFlowPlayerCoreTests",
            dependencies: ["EYZFlowPlayerCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
