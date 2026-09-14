// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoiseKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "NoiseKit", targets: ["NoiseKit"]),
    ],
    targets: [
        .target(name: "NoiseKit"),
        .testTarget(name: "NoiseKitTests", dependencies: ["NoiseKit"]),
    ]
)
