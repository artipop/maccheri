// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimLatency",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "simlatency", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
