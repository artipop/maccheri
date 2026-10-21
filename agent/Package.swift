// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaccheriAgent",
    platforms: [.macOS(.v15)],
    products: [
        // Maccheri.app links it and runs the agent in-process.
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    dependencies: [
        .package(path: "../protocol"),
        .package(path: "../simstream"),
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [
                .product(name: "MaccheriProtocol", package: "protocol"),
                .product(name: "SimStreamPeer", package: "simstream"),
            ]
        ),
        .executableTarget(name: "maccheri-agent", dependencies: ["AgentCore"], path: "Sources/MaccheriAgent"),
        .executableTarget(name: "maccheri-vm", dependencies: ["AgentCore"], path: "Sources/MaccheriVM"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ]
)
