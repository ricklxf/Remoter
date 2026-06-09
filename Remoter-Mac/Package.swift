// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoterAgent",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Google WebRTC prebuilt framework (stasel/WebRTC)
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "114.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "RemoterAgent",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources/RemoterAgent"
        )
    ]
)
