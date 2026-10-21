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
        .testTarget(name: "SimStreamClientTests", dependencies: ["SimStreamClient"]),
    ]
)
