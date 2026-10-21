import Darwin
import Foundation
import MaccheriProtocol

/// A base image the host can boot, with what it offers.
public struct ImageInfo: Sendable, Equatable {
    public var name: String
    public var config: VMBundle.Config
    /// nil for images built before `maccheri.json` existed.
    public var metadata: ImageMetadata?
}

extension ImageStore {
    /// Every valid image in ``imagesDirectory``, sorted by name.
    public func images() -> [ImageInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        return names.sorted().compactMap { name in
            guard let bundle = try? baseImage(named: name) else { return nil }
            let metadataURL = bundle.url.appending(path: ImageMetadata.fileName)
            let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(ImageMetadata.self, from: $0) }
            return ImageInfo(name: name, config: bundle.config, metadata: metadata)
        }
    }
}

public enum HostInventory {
    public static func hardware() -> HostHardware {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HostHardware(
            model: sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
    }

    public static var computerName: String {
        Host.current().localizedName ?? sysctlString("kern.hostname") ?? "Mac"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
