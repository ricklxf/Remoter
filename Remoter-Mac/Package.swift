// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoterAgent",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "RemoterAgent",
            path: "Sources/RemoterAgent"
        )
    ]
)
