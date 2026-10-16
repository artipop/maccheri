// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControlPlane",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(path: "../protocol"),
    ],
    targets: [
        .executableTarget(
            name: "ControlPlane",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "MaccheriProtocol", package: "protocol"),
            ]
        ),
        .testTarget(
            name: "ControlPlaneTests",
            dependencies: [
                "ControlPlane",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
