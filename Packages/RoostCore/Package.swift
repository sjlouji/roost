// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RoostCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "RoostCore", targets: ["RoostCore"])],
    targets: [
        .target(name: "RoostCore"),
        .testTarget(name: "RoostCoreTests", dependencies: ["RoostCore"]),
    ]
)
