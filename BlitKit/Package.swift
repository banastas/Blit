// swift-tools-version: 6.0
// BlitKit: Blit's transfer engine. The macOS app (M4) depends on this package.
import PackageDescription

let package = Package(
    name: "BlitKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BlitSFTP", targets: ["BlitSFTP"]),
        .library(name: "BlitRemote", targets: ["BlitRemote"]),
        .executable(name: "blit", targets: ["blit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
    ],
    targets: [
        // SFTP v3 wire protocol and read planning; no I/O.
        .target(
            name: "BlitSFTP",
            dependencies: [.product(name: "NIOCore", package: "swift-nio")]
        ),
        // SSH connections, SFTP client, parallel verified downloads.
        .target(
            name: "BlitRemote",
            dependencies: [
                "BlitSFTP",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .executableTarget(name: "blit", dependencies: ["BlitRemote", "BlitSFTP"]),
        .testTarget(name: "BlitSFTPTests", dependencies: ["BlitSFTP"]),
        .testTarget(name: "BlitRemoteTests", dependencies: ["BlitRemote", "BlitSFTP"]),
    ]
)
