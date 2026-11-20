// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoterAgent",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "114.0.0")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "PamAuthHelper",
            path: "Sources/PamAuthHelper",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("pam")]
        ),
        .executableTarget(
            name: "RemoterAgent",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                "PamAuthHelper",
                .product(name: "NIO",          package: "swift-nio"),
                .product(name: "NIOCore",      package: "swift-nio"),
                .product(name: "NIOPosix",     package: "swift-nio"),
                .product(name: "NIOHTTP1",     package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL",       package: "swift-nio-ssl"),
            ],
            path: "Sources/RemoterAgent"
        )
    ]
)
