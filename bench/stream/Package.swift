// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StreamBench",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "vtbench", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
