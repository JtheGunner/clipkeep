// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipkeep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipkeepCore", targets: ["ClipkeepCore"]),
        .executable(name: "Clipkeep", targets: ["Clipkeep"]),
        .executable(name: "clipkeep-eval", targets: ["ClipkeepEval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift", exact: "4.19.0")
    ],
    targets: [
        .target(
            name: "ClipkeepCore",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]),
        .executableTarget(name: "Clipkeep", dependencies: ["ClipkeepCore"]),
        .executableTarget(name: "ClipkeepEval", dependencies: ["ClipkeepCore"]),
        .testTarget(name: "ClipkeepCoreTests", dependencies: ["ClipkeepCore"]),
    ]
)
