// swift-tools-version: 6.0
import PackageDescription

// ApelinPlus is built in Swift 6 language mode, which turns complete
// concurrency checking on by itself; no compiler flags are needed, and
// passing any would stop the package from being usable as a dependency.
let package = Package(
    name: "ApelinPlus",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ApelinPlus", targets: ["ApelinPlus"]),
    ],
    targets: [
        .target(name: "ApelinPlus"),
        .testTarget(
            name: "ApelinPlusTests",
            dependencies: ["ApelinPlus"]
        ),
    ]
)
