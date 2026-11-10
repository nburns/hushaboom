// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "oceanmatch",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../../NoiseKit")],
    targets: [
        .executableTarget(name: "oceanmatch", dependencies: ["NoiseKit"]),
    ]
)
