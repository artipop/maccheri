import Foundation
import Virtualization

/// Boots cloned VMs. The returned handle stays valid until the guest stops or ``RunningVM/stop()``.
public protocol VMRunner: Sendable {
    func start(_ bundle: VMBundle, sharedDirectory: URL, resources: VMResources) async throws -> any RunningVM
}

public protocol RunningVM: AnyObject, Sendable {
    /// The agent's way into the guest; the guest itself only sees the internet.
    var guest: any GuestLink { get }
    /// Returns once the VM is gone, however that happened.
    func wait() async -> VMExit
    /// How the VM ended, or nil while it runs.
    func currentExit() async -> VMExit?
    /// Powers the VM off (no-op once it has stopped).
    func stop() async
}

/// How the agent reaches services inside the guest.
public protocol GuestLink: Sendable {
    /// Whether something in the guest accepts TCP connections on `port`.
    func isAccepting(port: UInt16) async -> Bool
    /// A host port on 127.0.0.1 that relays to `port` in the guest.
    func forward(guestPort: UInt16) throws -> UInt16
}

extension GuestNetwork: GuestLink {
    public func isAccepting(port: UInt16) async -> Bool { await probe(port: port) }
    public func forward(guestPort: UInt16) throws -> UInt16 { try forward(guestPort: guestPort, hostPort: 0) }
}

/// Owner overrides for the image's `config.json`.
public struct VMResources: Sendable, Equatable {
    public var cpuCount: Int?
    public var memorySize: UInt64?

    public init(cpuCount: Int? = nil, memorySize: UInt64? = nil) {
        self.cpuCount = cpuCount
        self.memorySize = memorySize
    }

    public func memory(for bundle: VMBundle) -> UInt64 { memorySize ?? bundle.config.memorySize }
}

public enum VMExit: Sendable, Equatable {
    /// The guest powered itself off.
    case guestStopped
    /// ``RunningVM/stop()`` turned it off.
    case stoppedByHost
    case failed(String)
}

/// Virtualization.framework implementation. The binary needs the
/// `com.apple.security.virtualization` entitlement (see `scripts/build.sh`).
public struct VirtualizationRunner: VMRunner {
    /// Guests see the job directory at `/Volumes/My Shared Files/maccheri`.
    public static let sharedDirectoryName = "maccheri"

    private let network: GuestNetwork.Configuration
    private let log: @Sendable (String) -> Void

    public init(network: GuestNetwork.Configuration = .init(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.network = network
        self.log = log
    }

    public func start(_ bundle: VMBundle, sharedDirectory: URL, resources: VMResources) async throws -> any RunningVM {
        let mac = VZMACAddress.randomLocallyAdministered()
        let guestNetwork = try GuestNetwork(guestMAC: MACAddress(mac.string)!, configuration: network, log: log)
        let configuration: VZVirtualMachineConfiguration
        do {
            configuration = try Self.configuration(for: bundle, sharedDirectory: sharedDirectory, resources: resources, network: guestNetwork, macAddress: mac)
        } catch {
            guestNetwork.stop()
            throw error
        }
        guestNetwork.start()
        let session = await MachineSession(configuration: configuration, network: guestNetwork)
        do {
            try await session.start()
        } catch {
            guestNetwork.stop()
            throw error
        }
        return VirtualMachineHandle(session: session, guest: guestNetwork)
    }

    static func configuration(for bundle: VMBundle, sharedDirectory: URL, resources: VMResources, network: GuestNetwork, macAddress: VZMACAddress) throws -> VZVirtualMachineConfiguration {
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
        let cpus = resources.cpuCount ?? bundle.config.cpuCount
        config.cpuCount = min(max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = resources.memory(for: bundle) / (1 << 20) * (1 << 20)
        config.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        // The NIC is wired to the agent's own network stack: internet only, no LAN, no host.
        let nic = VZVirtioNetworkDeviceConfiguration()
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: network.guestFileHandle)
        attachment.maximumTransmissionUnit = network.configuration.mtu
        nic.attachment = attachment
        nic.macAddress = macAddress
        config.networkDevices = [nic]

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

private final class VirtualMachineHandle: RunningVM, @unchecked Sendable {
    let session: MachineSession
    let guest: any GuestLink

    init(session: MachineSession, guest: any GuestLink) {
        self.session = session
        self.guest = guest
    }

    func wait() async -> VMExit { await session.wait() }
    func currentExit() async -> VMExit? { await session.exit }
    func stop() async { await session.stop() }
}

/// Owns one `VZVirtualMachine`. VZ objects must be used from the queue they were created on,
/// so everything here is main-actor isolated.
@MainActor
private final class MachineSession: NSObject, VZVirtualMachineDelegate {
    private let machine: VZVirtualMachine
    private let network: GuestNetwork
    private(set) var exit: VMExit?
    private var waiters: [CheckedContinuation<VMExit, Never>] = []

    init(configuration: VZVirtualMachineConfiguration, network: GuestNetwork) {
        machine = VZVirtualMachine(configuration: configuration)
        self.network = network
        super.init()
        machine.delegate = self
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, any Error>) in
            machine.start { result in started.resume(with: result) }
        }
    }

    func wait() async -> VMExit {
        if let exit { return exit }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// `stop()` does not call the delegate, so waiters are resumed here.
    func stop() async {
        guard exit == nil else { return }
        if machine.canStop {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                machine.stop { _ in done.resume() }
            }
        }
        finish(.stoppedByHost)
    }

    private func finish(_ result: VMExit) {
        guard exit == nil else { return }
        exit = result
        network.stop()
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(.guestStopped) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated { finish(.failed(error.localizedDescription)) }
    }
}
