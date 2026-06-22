// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MultitrackCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MultitrackCore", targets: ["MultitrackCore"]),
    ],
    targets: [
        .target(name: "MultitrackCore"),
        .testTarget(name: "MultitrackCoreTests", dependencies: ["MultitrackCore"]),
    ]
)
