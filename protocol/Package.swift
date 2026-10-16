// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaccheriProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MaccheriProtocol", targets: ["MaccheriProtocol"]),
    ],
    targets: [
        .target(name: "MaccheriProtocol"),
        .testTarget(name: "MaccheriProtocolTests", dependencies: ["MaccheriProtocol"]),
    ]
)
