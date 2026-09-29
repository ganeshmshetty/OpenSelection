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
        .executable(
            name: "openselection-diagnose",
            targets: ["openselection-diagnose"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "OpenSelection",
            dependencies: []
        ),
        .executableTarget(
            name: "openselection-diagnose",
            dependencies: ["OpenSelection"]
        ),
        .testTarget(
            name: "OpenSelectionTests",
            dependencies: ["OpenSelection"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
