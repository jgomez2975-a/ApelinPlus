// swift-tools-version: 6.0
import PackageDescription

// ApelinPlus is built in Swift 6 language mode, which turns complete
// concurrency checking on by itself; no compiler flags are needed, and
// passing any would stop the package from being usable as a dependency.
//
// The UI is a separate target on purpose. The model layer has no SwiftUI
// import anywhere, so it can be linked into a worker or a test harness
// that has no window server, and a build that only needs the balance
// adapters leaves the views out.
let package = Package(
    name: "ApelinPlus",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ApelinPlus", targets: ["ApelinPlus"]),
        .library(name: "ApelinPlusUI", targets: ["ApelinPlusUI"]),
    ],
    targets: [
        .target(name: "ApelinPlus"),
        .target(
            name: "ApelinPlusUI",
            dependencies: ["ApelinPlus"]
        ),
        .testTarget(
            name: "ApelinPlusTests",
            dependencies: ["ApelinPlus"]
        ),
    ]
)
