import Foundation
import MaccheriProtocol

public struct PoolSettings: Sendable, Equatable {
    /// Apple's macOS license: at most two macOS VMs per Mac.
    public static let licenseLimit = 2

    /// The owner's cap; never more than ``licenseLimit``.
    public var maxVMs: Int
    /// Guests kept booted and idle for the next session.
    public var warmVMs: Int
    /// RAM all VMs together may take.
    public var memoryBudget: UInt64
    public var resources: VMResources
    /// Image for warm guests; nil picks the first image that offers simulator devices.
    public var warmImage: String?

    public init(maxVMs: Int = PoolSettings.licenseLimit, warmVMs: Int = 1, memoryBudget: UInt64 = PoolSettings.defaultMemoryBudget, resources: VMResources = .init(), warmImage: String? = nil) {
        self.maxVMs = maxVMs
        self.warmVMs = warmVMs
        self.memoryBudget = memoryBudget
        self.resources = resources
        self.warmImage = warmImage
    }

    /// Everything but 4 GB for the owner: on a 16 GB Mac that is one 8 GB guest.
    public static var defaultMemoryBudget: UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        return physical > 8 << 30 ? physical - (4 << 30) : physical / 2
    }
}

public struct PoolStatus: Sendable, Equatable {
    /// How many VMs may run at once under the license, the owner's cap and RAM.
    public var slots: Int
    /// VMs doing work.
    public var busy: Int
    /// Warm guests, booted or still booting.
    public var warm: Int
    public var warmBooted: Int
    public var paused: Bool

    public var freeSlots: Int { paused ? 0 : max(0, slots - busy - warm) }
    /// What the agent can take on now: a free slot or a warm guest (``HostCapacity`` semantics).
    public var available: Int { paused ? 0 : freeSlots + warm }
}

/// Clones, boots and destroys VMs within the host's limits, and keeps warm guests ready:
/// booted from a fresh clone with an empty shared directory, so a session only has to write
/// `session.json`. Every VM is single-use; nothing goes back into the pool.
public actor VMPool {
    public struct Lease: Sendable {
        public var id: UUID
        public var image: String
        public var clone: VMBundle
        /// The host side of the guest's read-only share.
        public var sharedDirectory: URL
        public var vm: any RunningVM
        public var wasWarm: Bool
    }

    /// A promise of a VM, taken synchronously so capacity is accounted for before anything boots.
    public struct Reservation: Sendable {
        fileprivate enum Kind: Sendable {
            case warm(Task<Lease, any Error>)
            case cold(String)
        }
        fileprivate var kind: Kind
        public var isWarm: Bool {
            if case .warm = kind { return true }
            return false
        }
    }

    private final class Warm: @unchecked Sendable {
        let id = UUID()
        let image: String
        var boot: Task<Lease, any Error>!
        var booted = false
        init(image: String) { self.image = image }
    }

    public let store: ImageStore
    private let runner: any VMRunner
    private let log: @Sendable (String) -> Void
    private(set) var settings: PoolSettings
    private var warm: [Warm] = []
    private var busy = 0
    private var paused = false
    private var evictions: [Task<Void, Never>] = []
    private var observers: [UUID: @Sendable (PoolStatus) -> Void] = [:]

    public init(store: ImageStore, runner: any VMRunner, settings: PoolSettings, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.runner = runner
        self.settings = settings
        self.log = log
        images = store.images()
    }

    // MARK: Capacity

    public var status: PoolStatus {
        PoolStatus(slots: slots, busy: busy, warm: warm.count, warmBooted: warm.filter(\.booted).count, paused: paused)
    }

    /// Images found by the last ``rescanImages()``.
    public private(set) var images: [ImageInfo]

    public func rescanImages() {
        images = store.images()
        changed()
        replenish()
    }

    private var slots: Int {
        let cap = min(settings.maxVMs, PoolSettings.licenseLimit)
        guard let name = warmImageName, let image = images.first(where: { $0.name == name }) else { return 0 }
        let perVM = max(settings.resources.memorySize ?? image.config.memorySize, 1)
        return max(0, min(cap, Int(settings.memoryBudget / perVM)))
    }

    private var warmImageName: String? {
        if let name = settings.warmImage, images.contains(where: { $0.name == name }) { return name }
        return (images.first { !($0.metadata?.devices.isEmpty ?? true) } ?? images.first { $0.metadata != nil })?.name
    }

    /// Called on every capacity change (on the pool's executor).
    public func observe(_ observer: @escaping @Sendable (PoolStatus) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(status)
        return id
    }

    private func changed() {
        let status = status
        for observer in observers.values { observer(status) }
    }

    // MARK: Leasing

    /// Takes a warm guest of `image`, or a free slot, or evicts a warm guest of another image.
    /// nil when the host is full or paused. Pair with ``start(_:id:)`` or ``cancel(_:)``.
    public func reserve(image: String) -> Reservation? {
        guard !paused else { return nil }
        if let index = warm.firstIndex(where: { $0.image == image }) {
            let entry = warm.remove(at: index)
            busy += 1
            changed()
            return Reservation(kind: .warm(entry.boot))
        }
        if status.freeSlots > 0 {
            busy += 1
            changed()
            return Reservation(kind: .cold(image))
        }
        if let index = warm.indices.last {
            let entry = warm.remove(at: index)
            log("pool: evicting warm \(entry.image) for \(image)")
            evictions.append(Task { await Self.discard(entry.boot, store: store) })
            busy += 1
            changed()
            return Reservation(kind: .cold(image))
        }
        return nil
    }

    /// Boots (or hands over) the reserved VM. On failure the reservation is released.
    public func start(_ reservation: Reservation, id: UUID) async throws -> Lease {
        do {
            switch reservation.kind {
            case let .warm(boot):
                return try await boot.value
            case let .cold(image):
                let pending = evictions
                evictions.removeAll()
                for eviction in pending { await eviction.value }
                return try await boot(image: image, id: id, warm: false)
            }
        } catch {
            busy -= 1
            changed()
            replenish()
            throw error
        }
    }

    public func cancel(_ reservation: Reservation) {
        if case let .warm(boot) = reservation.kind {
            Task { await Self.discard(boot, store: store) }
        }
        busy -= 1
        changed()
        replenish()
    }

    /// Powers the VM off, deletes its clone and frees the slot.
    public func release(_ lease: Lease) async {
        await lease.vm.stop()
        store.destroy(lease.clone)
        busy -= 1
        changed()
        replenish()
    }

    // MARK: Warm guests

    public func update(_ settings: PoolSettings) async {
        self.settings = settings
        while warm.count > settings.warmVMs, let entry = warm.popLast() {
            await Self.discard(entry.boot, store: store)
        }
        changed()
        replenish()
    }

    public func setPaused(_ paused: Bool) async {
        self.paused = paused
        if paused {
            let entries = warm
            warm.removeAll()
            changed()
            for entry in entries { await Self.discard(entry.boot, store: store) }
        } else {
            changed()
            replenish()
        }
    }

    /// Stops warm guests; leased VMs are their owners' to release.
    public func shutdown() async {
        await setPaused(true)
        observers.removeAll()
    }

    /// Boots warm guests until the target is met or the host is full.
    public func replenish() {
        guard !paused, let image = warmImageName else { return }
        while warm.count < settings.warmVMs, busy + warm.count < slots {
            let entry = Warm(image: image)
            entry.boot = Task { try await self.bootWarm(entry) }
            warm.append(entry)
            log("pool: warming \(image)")
        }
        changed()
    }

    private func bootWarm(_ entry: Warm) async throws -> Lease {
        do {
            let lease = try await boot(image: entry.image, id: entry.id, warm: true)
            entry.booted = true
            changed()
            // A warm guest that dies on its own (crash, the owner's fault) is replaced.
            Task { [weak self] in
                _ = await lease.vm.wait()
                await self?.warmDied(entry)
            }
            return lease
        } catch {
            log("pool: warm \(entry.image) failed: \(error)")
            if let index = warm.firstIndex(where: { $0 === entry }) {
                warm.remove(at: index)
                changed()
                // Don't spin on a broken image; the next lease or settings change retries.
            }
            throw error
        }
    }

    private func warmDied(_ entry: Warm) async {
        guard let index = warm.firstIndex(where: { $0 === entry }) else { return }
        warm.remove(at: index)
        log("pool: warm \(entry.image) stopped by itself")
        await Self.discard(entry.boot, store: store)
        changed()
        replenish()
    }

    private func boot(image: String, id: UUID, warm: Bool) async throws -> Lease {
        let base = try store.baseImage(named: image)
        let clone = try store.clone(base, jobID: id)
        do {
            let shared = clone.url.appending(path: "shared", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            let vm = try await runner.start(clone, sharedDirectory: shared, resources: settings.resources)
            log("pool: booted \(image) as \(id)\(warm ? " (warm)" : "")")
            return Lease(id: id, image: image, clone: clone, sharedDirectory: shared, vm: vm, wasWarm: warm)
        } catch {
            store.destroy(clone)
            throw error
        }
    }

    private static func discard(_ boot: Task<Lease, any Error>, store: ImageStore) async {
        guard let lease = try? await boot.value else { return }
        await lease.vm.stop()
        store.destroy(lease.clone)
    }
}
