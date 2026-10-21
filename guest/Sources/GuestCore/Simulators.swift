import Foundation
import MaccheriProtocol

/// The devices of `xcrun simctl list -j devices`.
public struct SimulatorList: Decodable, Sendable {
    public struct Device: Decodable, Sendable, Equatable {
        public var udid: String
        public var name: String
        public var state: String
        public var isAvailable: Bool?
        public var deviceTypeIdentifier: String?
    }

    /// Runtime identifier → devices.
    public var devices: [String: [Device]]

    /// An available device of the spec's type and runtime; a booted one wins, so a pre-booted
    /// device is reused.
    public func device(matching spec: DeviceSpec) -> Device? {
        let candidates = (devices[spec.runtime] ?? []).filter {
            $0.deviceTypeIdentifier == spec.deviceType && $0.isAvailable != false
        }
        return candidates.first { $0.state == "Booted" } ?? candidates.first
    }

    public var booted: [Device] {
        devices.values.flatMap { $0 }.filter { $0.state == "Booted" }
    }
}

/// `xcrun simctl` for the guest daemon.
public struct Simulators: Sendable {
    public var xcrun = "/usr/bin/xcrun"

    public init() {}

    public func list() async throws -> SimulatorList {
        let json = try await Subprocess.run(xcrun, ["simctl", "list", "-j", "devices"])
        return try JSONDecoder().decode(SimulatorList.self, from: Data(json.utf8))
    }

    /// The image's device for `spec`, or a new one if the image has none.
    public func device(for spec: DeviceSpec) async throws -> String {
        if let device = try await list().device(matching: spec) { return device.udid }
        let name = spec.deviceType.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? "maccheri"
        let output = try await Subprocess.run(xcrun, ["simctl", "create", name, spec.deviceType, spec.runtime])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Boots the device and waits until it has finished booting.
    public func boot(_ udid: String) async throws {
        // "Unable to boot device in current state: Booted" is fine; bootstatus tells the truth.
        _ = try? await Subprocess.run(xcrun, ["simctl", "boot", udid])
        try await Subprocess.run(xcrun, ["simctl", "bootstatus", udid, "-b"])
    }

    public func shutdown(_ udid: String) async throws {
        try await Subprocess.run(xcrun, ["simctl", "shutdown", udid])
    }

    public func shutdownAll() async throws {
        try await Subprocess.run(xcrun, ["simctl", "shutdown", "all"])
    }
}
