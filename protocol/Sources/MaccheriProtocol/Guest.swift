import Foundation

/// Host → guest hand-off. The agent writes ``GuestSession`` as JSON to ``GuestAPI/sessionFile`` in the
/// VM's read-only shared directory before boot; the guest daemon reads it after login and does
/// exactly one thing: run one CI job, or serve one simulator session. Then it shuts the guest down.
public enum GuestAPI {
    /// Where the share appears inside the guest (virtiofs automount, tag `maccheri`).
    public static let sharePath = "/Volumes/My Shared Files/maccheri"
    public static let sessionFile = "session.json"
    /// TCP port simstream listens on inside the guest.
    public static let simstreamPort: UInt16 = 7300
}

public enum GuestSession: Codable, Sendable, Equatable {
    case ci(GuestCIJob)
    case simulator(GuestSimulatorSession)
}

public struct GuestCIJob: Codable, Sendable, Equatable {
    /// `encoded_jit_config`, passed verbatim to `run.sh --jitconfig`.
    public var jitConfig: String

    public init(jitConfig: String) {
        self.jitConfig = jitConfig
    }
}

public struct GuestSimulatorSession: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var device: DeviceSpec
    public var simstreamPort: UInt16

    public init(sessionID: UUID, device: DeviceSpec, simstreamPort: UInt16 = GuestAPI.simstreamPort) {
        self.sessionID = sessionID
        self.device = device
        self.simstreamPort = simstreamPort
    }
}
