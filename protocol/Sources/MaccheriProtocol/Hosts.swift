import Foundation

/// Owners' Macs. Maccheri.app enrolls the Mac with the owner's user token once and from then on
/// talks to the control plane with the agent token it got back.
///
///     POST /v1/hosts/enroll     (user token)  HostEnrollRequest → HostEnrollment
///     GET  /v1/hosts            (user token)  → [HostInfo]
///     POST /agent/v1/heartbeat  (agent token) Heartbeat → HeartbeatResponse
///
/// A host that has not sent a heartbeat for ``HostAPI/offlineAfterSeconds`` is offline and gets no work.
public enum HostAPI {
    public static let enrollPath = "/v1/hosts/enroll"
    public static let listPath = "/v1/hosts"
    public static let heartbeatPath = "/agent/v1/heartbeat"
    public static let heartbeatIntervalSeconds = 15
    public static let offlineAfterSeconds = 45
}

public struct HostHardware: Codable, Sendable, Equatable {
    /// `hw.model`, e.g. `Mac16,10`.
    public var model: String
    /// e.g. `Apple M4`.
    public var chip: String
    public var cpuCount: Int
    public var memoryBytes: UInt64
    /// Host macOS version, e.g. `27.0.1`. Guests can't be newer than this.
    public var macOSVersion: String

    public init(model: String, chip: String, cpuCount: Int, memoryBytes: UInt64, macOSVersion: String) {
        self.model = model
        self.chip = chip
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.macOSVersion = macOSVersion
    }
}

/// v2: `POST /v1/hosts/enroll` needs no bearer token; ``code`` (from `POST /v1/teams/{id}/host-codes`)
/// says which team the Mac joins. v1 (Vapor, mini-prod): no code, `Authorization: Bearer <shared token>`.
public struct HostEnrollRequest: Codable, Sendable, Equatable {
    /// Owner-visible name, defaults to the Mac's computer name.
    public var name: String
    public var hardware: HostHardware
    /// v2: one-time enrollment code.
    public var code: String?

    public init(name: String, hardware: HostHardware, code: String? = nil) {
        self.name = name
        self.hardware = hardware
        self.code = code
    }
}

public struct HostEnrollment: Codable, Sendable, Equatable {
    public var hostID: UUID
    /// Bearer token for every `/agent/v1/...` call. Stored in the owner's keychain.
    public var agentToken: String
    /// v2: the team the Mac now serves, for the app to show.
    public var teamID: UUID?
    public var teamName: String?

    public init(hostID: UUID, agentToken: String, teamID: UUID? = nil, teamName: String? = nil) {
        self.hostID = hostID
        self.agentToken = agentToken
        self.teamID = teamID
        self.teamName = teamName
    }
}

/// What a host can take on right now.
public struct HostCapacity: Codable, Sendable, Equatable {
    /// VMs the host may still start (Apple's license caps a Mac at 2 macOS guests; the owner's
    /// settings and RAM may cap it lower).
    public var freeSlots: Int
    /// Booted, idle guests that can take a simulator session immediately.
    public var warmVMs: Int
    /// Base images present on the host, e.g. `["macos-27-xcode-27.2"]`.
    public var images: [String]
    /// Runner labels the host serves, e.g. `["maccheri", "macos-27", "xcode-27.2"]`.
    public var labels: [String]
    /// Simulator devices the images offer.
    public var devices: [DeviceSpec]

    public init(freeSlots: Int, warmVMs: Int, images: [String], labels: [String], devices: [DeviceSpec]) {
        self.freeSlots = freeSlots
        self.warmVMs = warmVMs
        self.images = images
        self.labels = labels
        self.devices = devices
    }
}

/// Capacity semantics: a warm VM counts against the host's VM cap. With a cap of 1 and one warm guest,
/// `freeSlots` is 0 and `warmVMs` is 1. In ``LeaseRequest`` the agent sends
/// `freeSlots = capacity.freeSlots + capacity.warmVMs`: how many pieces of work it can take right now.
public struct Heartbeat: Codable, Sendable, Equatable {
    public var agentVersion: String
    public var capacity: HostCapacity

    public init(agentVersion: String, capacity: HostCapacity) {
        self.agentVersion = agentVersion
        self.capacity = capacity
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var ownerName: String
    public var hardware: HostHardware
    public var online: Bool
    /// Last reported capacity; nil until the first heartbeat.
    public var capacity: HostCapacity?
    /// v2: owning team.
    public var teamID: UUID?

    public init(id: UUID, name: String, ownerName: String, hardware: HostHardware, online: Bool, capacity: HostCapacity?, teamID: UUID? = nil) {
        self.id = id
        self.name = name
        self.ownerName = ownerName
        self.hardware = hardware
        self.online = online
        self.capacity = capacity
        self.teamID = teamID
    }
}

public struct HeartbeatResponse: Codable, Sendable, Equatable {
    /// Sessions this host runs that the control plane has ended (user `DELETE`, expiry, failure).
    /// The agent tears them down. This is the reliable path; signaling `bye` and `410 Gone` on
    /// `POST /agent/v1/sessions/{id}/state` are the fast ones.
    public var endedSessions: [UUID]

    public init(endedSessions: [UUID] = []) {
        self.endedSessions = endedSessions
    }
}
