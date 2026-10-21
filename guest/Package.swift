// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaccheriGuest",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../protocol"),
    ],
    targets: [
        .target(
            name: "GuestCore",
            dependencies: [.product(name: "MaccheriProtocol", package: "protocol")]
        ),
        .executableTarget(name: "maccheri-guestd", dependencies: ["GuestCore"]),
        .testTarget(name: "GuestCoreTests", dependencies: ["GuestCore"]),
    ]
)
