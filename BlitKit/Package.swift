// swift-tools-version: 6.0
// BlitKit: Blit's transfer engine. The macOS app (M4) depends on this package.
import PackageDescription

let package = Package(
    name: "BlitKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BlitSFTP", targets: ["BlitSFTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "BlitSFTP",
            dependencies: [.product(name: "NIOCore", package: "swift-nio")]
        ),
        .testTarget(name: "BlitSFTPTests", dependencies: ["BlitSFTP"]),
    ]
)
