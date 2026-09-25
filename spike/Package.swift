// swift-tools-version: 6.0
// M1 spike: measure SwiftNIO SSH + a minimal pipelined SFTP client against a real server.
// Throwaway code; the real engine is written in M2.
import PackageDescription

let package = Package(
    name: "blit-spike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "blit-spike",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
