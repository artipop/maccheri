// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Smoke",
    platforms: [.iOS(.v18)],
    products: [.library(name: "Smoke", targets: ["Smoke"])],
    targets: [
        .target(name: "Smoke"),
        .testTarget(name: "SmokeTests", dependencies: ["Smoke"]),
    ]
)
