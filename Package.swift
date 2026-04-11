// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Digger",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Digger",
            targets: ["Digger"],
        ),
    ],
    targets: [
        .target(name: "Digger"),
        .testTarget(
            name: "DiggerTests",
            dependencies: ["Digger"],
        ),
    ],
    swiftLanguageModes: [.v6],
)
