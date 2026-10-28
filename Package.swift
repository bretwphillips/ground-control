// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GroundControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GroundControl", path: "Sources/GroundControl")
    ]
)
