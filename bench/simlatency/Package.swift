// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimLatency",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../simstream"),
    ],
    targets: [
        .executableTarget(
            name: "simlatency",
            dependencies: [.product(name: "SimulatorBridge", package: "simstream")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
