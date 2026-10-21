// swift-tools-version: 6.0
import PackageDescription

// The private-API code is plain C-style calls through the ObjC runtime; Swift 5 mode keeps it
// readable without wrapping every pointer for strict concurrency.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SimStream",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimulatorBridge", targets: ["SimulatorBridge"]),
        .library(name: "SimStreamClient", targets: ["SimStreamClient"]),
        /// `HostPeer`: WebRTC between the viewer and the guest's simstream (used by the agent).
        .library(name: "SimStreamPeer", targets: ["SimStreamPeer"]),
    ],
    dependencies: [
        .package(path: "../protocol"),
    ],
    targets: [
        .target(name: "SimulatorBridge", swiftSettings: v5),
        .target(name: "SimStreamClient", dependencies: [.product(name: "SimStreamProtocol", package: "protocol")], swiftSettings: v5),
        .executableTarget(
            name: "simstream",
            dependencies: ["SimulatorBridge", .product(name: "SimStreamProtocol", package: "protocol")],
            swiftSettings: v5
        ),
        .executableTarget(name: "simstream-bench", dependencies: ["SimStreamClient"], swiftSettings: v5),
        // libdatachannel + Mbed TLS, static; rebuilt by scripts/build-libdatachannel.sh.
        .binaryTarget(name: "LibDataChannel", path: "Vendor/LibDataChannel.xcframework"),
        .target(
            name: "SimStreamPeer",
            dependencies: [
                "LibDataChannel",
                .product(name: "SimStreamProtocol", package: "protocol"),
                .product(name: "MaccheriProtocol", package: "protocol"),
            ],
            swiftSettings: v5
        ),
        .executableTarget(name: "simstream-peer", dependencies: ["SimStreamPeer"], swiftSettings: v5),
        .testTarget(name: "SimStreamClientTests", dependencies: ["SimStreamClient"]),
        .testTarget(name: "SimStreamPeerTests", dependencies: ["SimStreamPeer"]),
    ]
)
