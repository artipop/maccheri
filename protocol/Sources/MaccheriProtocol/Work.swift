import Foundation

/// Work for a host: CI jobs and simulator sessions through one long-poll.
///
///     POST /agent/v1/work                      (agent token) LeaseRequest → 200 WorkLease | 204
///     POST /agent/v1/jobs/{id}/complete        (agent token) CompleteRequest → 204
///     POST /agent/v1/sessions/{id}/state       (agent token) SessionStateReport → 204 | 410 Gone
///
/// `410 Gone` on a state report means the session is already over on the control plane's side:
/// the agent tears it down. Ended sessions also arrive in ``HeartbeatResponse/endedSessions`` and
/// as `bye` on the host's signaling channel.
public enum WorkAPI {
    public static let workPath = "/agent/v1/work"
    public static func sessionStatePath(sessionID: UUID) -> String { "/agent/v1/sessions/\(sessionID.uuidString)/state" }
    /// How long the control plane holds a `work` request open before answering 204.
    public static let longPollSeconds = 25
}

public enum WorkLease: Codable, Sendable, Equatable {
    case ci(JobLease)
    case simulator(SimulatorSessionLease)
}

public struct SimulatorSessionLease: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var image: String
    public var device: DeviceSpec
    /// Hard limit after which the agent kills the VM.
    public var timeoutSeconds: Int
    /// The host's side of the signaling channel (``SignalingRole/host``).
    public var signaling: SignalingInfo

    public init(sessionID: UUID, image: String, device: DeviceSpec, timeoutSeconds: Int, signaling: SignalingInfo) {
        self.sessionID = sessionID
        self.image = image
        self.device = device
        self.timeoutSeconds = timeoutSeconds
        self.signaling = signaling
    }
}

/// The agent's view of a session it leased. The control plane maps it to ``SessionState``.
public enum HostSessionState: String, Codable, Sendable {
    /// Guest booting or simulator starting.
    case starting
    /// simstream is up and the host peer is waiting on signaling.
    case ready
    /// The viewer went away, the session timed out or was cancelled; the VM is gone.
    case ended
    case failed
}

public struct SessionStateReport: Codable, Sendable, Equatable {
    public var state: HostSessionState
    public var message: String?

    public init(state: HostSessionState, message: String? = nil) {
        self.state = state
        self.message = message
    }
}
