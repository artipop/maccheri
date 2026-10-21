import Foundation

/// Remote simulator sessions, as seen by the viewer.
///
///     POST   /v1/sessions        (user token) CreateSessionRequest → SessionInfo
///     GET    /v1/sessions/{id}   (user token) → SessionInfo
///     DELETE /v1/sessions/{id}   (user token) → 204
///
/// The viewer polls `GET` (or reconnects to signaling) until the state is `ready`, then opens the
/// signaling WebSocket from ``SessionInfo/signaling``.
public enum SessionAPI {
    public static let sessionsPath = "/v1/sessions"
    public static func sessionPath(_ id: UUID) -> String { "/v1/sessions/\(id.uuidString)" }
}

/// A simulator device: CoreSimulator identifiers, as `xcrun simctl list -j` prints them.
public struct DeviceSpec: Codable, Sendable, Hashable {
    /// e.g. `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`.
    public var deviceType: String
    /// e.g. `com.apple.CoreSimulator.SimRuntime.iOS-27-2`.
    public var runtime: String

    public init(deviceType: String, runtime: String) {
        self.deviceType = deviceType
        self.runtime = runtime
    }

    public static let iPhone17Pro = DeviceSpec(
        deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    )
}

public struct CreateSessionRequest: Codable, Sendable, Equatable {
    /// nil: any device the chosen host offers, preferring ``DeviceSpec/iPhone17Pro``.
    public var device: DeviceSpec?
    /// Pin the session to one host (for testing); nil lets the control plane choose.
    public var hostID: UUID?

    public init(device: DeviceSpec? = nil, hostID: UUID? = nil) {
        self.device = device
        self.hostID = hostID
    }
}

public enum SessionState: String, Codable, Sendable {
    /// Waiting for a host with a free slot.
    case queued
    /// A host took it and is preparing the guest and the simulator.
    case starting
    /// simstream is up; the viewer can connect.
    case ready
    /// Ended by the user, by timeout or because the host went away.
    case ended
    case failed
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var state: SessionState
    public var device: DeviceSpec?
    public var hostID: UUID?
    public var hostName: String?
    public var createdAt: Date
    /// When the control plane ends the session regardless of activity.
    public var expiresAt: Date
    /// Present from `starting` on; the viewer connects once the state is `ready`.
    public var signaling: SignalingInfo?
    /// Human-readable reason for `failed` / `ended`.
    public var message: String?

    public init(id: UUID, state: SessionState, device: DeviceSpec?, hostID: UUID?, hostName: String?, createdAt: Date, expiresAt: Date, signaling: SignalingInfo?, message: String?) {
        self.id = id
        self.state = state
        self.device = device
        self.hostID = hostID
        self.hostName = hostName
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.signaling = signaling
        self.message = message
    }
}
