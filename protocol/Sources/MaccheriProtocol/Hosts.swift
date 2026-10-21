import Foundation

/// Owners' Macs. Maccheri.app enrolls the Mac with the owner's user token once and from then on
/// talks to the control plane with the agent token it got back.
///
///     POST /v1/hosts/enroll     (user token)  HostEnrollRequest → HostEnrollment
///     GET  /v1/hosts            (user token)  → [HostInfo]
///     POST /agent/v1/heartbeat  (agent token) Heartbeat → 204
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

public struct HostEnrollRequest: Codable, Sendable, Equatable {
    /// Owner-visible name, defaults to the Mac's computer name.
    public var name: String
    public var hardware: HostHardware

    public init(name: String, hardware: HostHardware) {
        self.name = name
        self.hardware = hardware
    }
}

public struct HostEnrollment: Codable, Sendable, Equatable {
    public var hostID: UUID
    /// Bearer token for every `/agent/v1/...` call. Stored in the owner's keychain.
    public var agentToken: String

    public init(hostID: UUID, agentToken: String) {
        self.hostID = hostID
        self.agentToken = agentToken
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

    public init(id: UUID, name: String, ownerName: String, hardware: HostHardware, online: Bool, capacity: HostCapacity?) {
        self.id = id
        self.name = name
        self.ownerName = ownerName
        self.hardware = hardware
        self.online = online
        self.capacity = capacity
    }
}
