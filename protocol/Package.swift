// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaccheriProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MaccheriProtocol", targets: ["MaccheriProtocol"]),
        .library(name: "SimStreamProtocol", targets: ["SimStreamProtocol"]),
    ],
    targets: [
        .target(name: "MaccheriProtocol"),
        .target(name: "SimStreamProtocol"),
        .testTarget(name: "MaccheriProtocolTests", dependencies: ["MaccheriProtocol"]),
        .testTarget(name: "SimStreamProtocolTests", dependencies: ["SimStreamProtocol"]),
    ]
)
