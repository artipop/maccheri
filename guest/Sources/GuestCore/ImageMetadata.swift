import Foundation
import MaccheriProtocol

/// `maccheri.json`: what a base image offers. `images/build.sh` writes it next to the image's
/// `config.json` on the host (the agent fills `HostCapacity` from it) and the same file into the
/// guest at ``guestPath`` (the daemon pre-boots `devices.first` from it).
public struct ImageMetadata: Codable, Sendable, Equatable {
    public static let fileName = "maccheri.json"
    public static let guestPath = "/Library/Application Support/Maccheri/maccheri.json"

    /// Runner labels the image satisfies, e.g. `["maccheri", "macos-27", "xcode-27.2"]`.
    public var labels: [String]
    /// Simulator devices created in the image; the first one is the default.
    public var devices: [DeviceSpec]
    /// Version of `maccheri-guestd` baked into the image.
    public var guestVersion: String

    public init(labels: [String], devices: [DeviceSpec], guestVersion: String) {
        self.labels = labels
        self.devices = devices
        self.guestVersion = guestVersion
    }

    public static func load(from url: URL) throws -> ImageMetadata {
        try JSONDecoder().decode(ImageMetadata.self, from: Data(contentsOf: url))
    }
}
