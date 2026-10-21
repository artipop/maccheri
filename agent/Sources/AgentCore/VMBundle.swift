import Foundation

/// A macOS VM on disk in Tart's layout, so images built with `tart create`/`tart clone`
/// can be used as base images directly:
///
///     <name>/config.json   cpu, memory, hardware model
///     <name>/disk.img      raw APFS disk image
///     <name>/nvram.bin     VZMacAuxiliaryStorage
public struct VMBundle: Sendable {
    public struct Config: Codable, Sendable, Equatable {
        public var os: String
        public var arch: String
        public var cpuCount: Int
        public var memorySize: UInt64
        /// `VZMacHardwareModel.dataRepresentation`, base64.
        public var hardwareModel: String?

        public init(os: String = "darwin", arch: String = "arm64", cpuCount: Int, memorySize: UInt64, hardwareModel: String?) {
            self.os = os
            self.arch = arch
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.hardwareModel = hardwareModel
        }
    }

    public let url: URL
    public let config: Config

    public var diskURL: URL { url.appending(path: "disk.img") }
    public var nvramURL: URL { url.appending(path: "nvram.bin") }
    public var configURL: URL { url.appending(path: "config.json") }

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url.appending(path: "config.json"))
        self.config = try JSONDecoder().decode(Config.self, from: data)
        guard config.os == "darwin", config.arch == "arm64" else {
            throw AgentError.unsupportedImage("\(config.os)/\(config.arch)")
        }
        guard config.hardwareModel != nil else {
            throw AgentError.unsupportedImage("config.json has no hardwareModel")
        }
    }

    public var hardwareModelData: Data? {
        config.hardwareModel.flatMap { Data(base64Encoded: $0) }
    }
}

public enum AgentError: Error, CustomStringConvertible {
    case unsupportedImage(String)
    case imageNotFound(String)
    case cloneFailed(path: String, errno: Int32)
    case invalidVMConfiguration(String)
    case workDirectoryBusy(String)
    case noCapacity

    public var description: String {
        switch self {
        case let .unsupportedImage(reason): "unsupported image: \(reason)"
        case let .imageNotFound(name): "image not found: \(name)"
        case let .cloneFailed(path, code): "clonefile(\(path)) failed: \(String(cString: strerror(code)))"
        case let .invalidVMConfiguration(reason): "invalid VM configuration: \(reason)"
        case let .workDirectoryBusy(path): "another agent is using \(path)"
        case .noCapacity: "no free VM slot"
        }
    }
}
