// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaccheriAgent",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../protocol"),
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [.product(name: "MaccheriProtocol", package: "protocol")]
        ),
        .executableTarget(name: "maccheri-agent", dependencies: ["AgentCore"], path: "Sources/MaccheriAgent"),
        .executableTarget(name: "maccheri-vm", dependencies: ["AgentCore"], path: "Sources/MaccheriVM"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ]
)
