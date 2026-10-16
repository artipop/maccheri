import Foundation
import Virtualization

/// Runs a cloned VM until the guest powers itself off or the deadline passes.
public protocol VMRunner: Sendable {
    func run(_ bundle: VMBundle, sharedDirectory: URL, timeout: Duration) async throws -> VMExit
}

public enum VMExit: Sendable, Equatable {
    case guestStopped
    case timedOut
}

/// Virtualization.framework implementation. The binary needs the
/// `com.apple.security.virtualization` entitlement (see `scripts/build.sh`).
public struct VirtualizationRunner: VMRunner {
    /// Guests see the job directory at `/Volumes/My Shared Files/maccheri`.
    public static let sharedDirectoryName = "maccheri"

    public init() {}

    public func run(_ bundle: VMBundle, sharedDirectory: URL, timeout: Duration) async throws -> VMExit {
        let configuration = try Self.configuration(for: bundle, sharedDirectory: sharedDirectory)
        return try await MachineSession(configuration: configuration).run(timeout: timeout)
    }

    static func configuration(for bundle: VMBundle, sharedDirectory: URL) throws -> VZVirtualMachineConfiguration {
        guard let modelData = bundle.hardwareModelData, let model = VZMacHardwareModel(dataRepresentation: modelData) else {
            throw AgentError.invalidVMConfiguration("bad hardware model")
        }
        guard model.isSupported else {
            throw AgentError.invalidVMConfiguration("hardware model not supported on this host")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        // Fresh identity per job: no state ties one job's guest to the next.
        platform.machineIdentifier = VZMacMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.nvramURL)

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = min(max(bundle.config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        config.memorySize = min(max(bundle.config.memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        // Prototype networking; replaced by the socketpair + WireGuard pipe later.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = .randomLocallyAdministered()
        config.networkDevices = [network]

        let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share = VZMultipleDirectoryShare(directories: [
            sharedDirectoryName: VZSharedDirectory(url: sharedDirectory, readOnly: true),
        ])
        config.directorySharingDevices = [share]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 80)]
        config.graphicsDevices = [graphics]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        do {
            try config.validate()
        } catch {
            throw AgentError.invalidVMConfiguration(error.localizedDescription)
        }
        return config
    }
}

/// Owns one `VZVirtualMachine`. VZ objects must be used from the queue they were created on,
/// so everything here is main-actor isolated.
@MainActor
private final class MachineSession: NSObject, VZVirtualMachineDelegate {
    private let machine: VZVirtualMachine
    private var stopped: CheckedContinuation<Void, any Error>?

    init(configuration: VZVirtualMachineConfiguration) {
        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
    }

    private var timedOut = false

    func run(timeout: Duration) async throws -> VMExit {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, any Error>) in
            machine.start { result in started.resume(with: result) }
        }
        let deadline = Task { @MainActor [weak self] in
            try await Task.sleep(for: timeout)
            self?.forceStop()
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { stopped = $0 }
        return timedOut ? .timedOut : .guestStopped
    }

    /// `stop()` does not call the delegate, so the waiter is resumed here.
    private func forceStop() {
        timedOut = true
        guard machine.canStop else { return finish(nil) }
        machine.stop { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard let stopped else { return }
        self.stopped = nil
        if let error { stopped.resume(throwing: error) } else { stopped.resume() }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }
}
