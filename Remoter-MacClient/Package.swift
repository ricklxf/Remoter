// swift-tools-version: 5.9
import Foundation
import PackageDescription

let cltTestingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPluginPath)
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginPath])]
    : []

let package = Package(
    name: "RemoterClient",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RemoterClient", targets: ["RemoterClient"])
    ],
    targets: [
        .executableTarget(
            name: "RemoterClient",
            path: "Sources/RemoterClient",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .testTarget(
            name: "RemoterClientTests",
            dependencies: ["RemoterClient"],
            path: "Tests/RemoterClientTests",
            swiftSettings: testSwiftSettings
        ),
    ]
)
