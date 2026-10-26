// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipkeep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipkeepCore", targets: ["ClipkeepCore"]),
        .executable(name: "Clipkeep", targets: ["Clipkeep"]),
    ],
    targets: [
        .target(name: "ClipkeepCore"),
        .executableTarget(name: "Clipkeep", dependencies: ["ClipkeepCore"]),
        .testTarget(name: "ClipkeepCoreTests", dependencies: ["ClipkeepCore"]),
    ]
)
