// swift-tools-version: 6.0
import PackageDescription

/// Writes `controlplane/Tests/Fixtures/*.json` from the `MaccheriProtocol` types.
/// The web client (D) checks its TypeScript types against them; the server's tests check
/// that it encodes exactly this.
///
///     swift run --package-path controlplane/Tools/fixtures generate-fixtures
let package = Package(
    name: "Fixtures",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../protocol")],
    targets: [
        .executableTarget(
            name: "generate-fixtures",
            dependencies: [.product(name: "MaccheriProtocol", package: "protocol")]
        ),
    ]
)
