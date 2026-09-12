// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenSelection",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "OpenSelection",
            targets: ["OpenSelection"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OpenSelection",
            dependencies: []
        ),
        .testTarget(
            name: "OpenSelectionTests",
            dependencies: ["OpenSelection"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
