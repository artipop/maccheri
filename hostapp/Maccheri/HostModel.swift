import Foundation
import MaccheriProtocol
import Observation

/// What the menu bar shows about this Mac. The agent is not wired in yet, so the model
/// only reports local resources and whether the host is willing to take jobs.
@Observable
final class HostModel {
    /// Apple's macOS license allows at most two macOS VMs per Mac.
    static let maxSlots = 2
    /// A macOS guest with Xcode needs roughly this much disk for its APFS clone to grow into.
    static let requiredFreeDiskGB = 80.0

    var isAccepting = false
    private(set) var resources = HostResources.current()

    var labels: [String] {
        ["maccheri", "macos-\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"]
    }

    var blockers: [String] {
        var result: [String] = []
        if resources.freeDiskGB < Self.requiredFreeDiskGB {
            result.append(String(localized: "Not enough disk: \(Int(resources.freeDiskGB)) GB free, \(Int(Self.requiredFreeDiskGB)) GB needed"))
        }
        return result
    }

    /// The request the agent will send once it is connected to the control plane.
    var leaseRequest: LeaseRequest {
        LeaseRequest(labels: labels, freeSlots: isAccepting && blockers.isEmpty ? Self.maxSlots : 0)
    }

    func refresh() {
        resources = HostResources.current()
    }
}

struct HostResources: Equatable {
    var cpuCount: Int
    var memoryGB: Double
    var freeDiskGB: Double

    static func current() -> HostResources {
        let info = ProcessInfo.processInfo
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let freeBytes = Double(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        return HostResources(
            cpuCount: info.activeProcessorCount,
            memoryGB: Double(info.physicalMemory) / 1_073_741_824,
            freeDiskGB: freeBytes / 1_000_000_000
        )
    }
}
