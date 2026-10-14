// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeHider",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "EdgeHider",
            path: "Sources/EdgeHider"
        ),
        .testTarget(name: "EdgeHiderTests", dependencies: ["EdgeHider"])
    ]
)
