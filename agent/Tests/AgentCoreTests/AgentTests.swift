import Foundation
import MaccheriProtocol
import Network
import Testing
@testable import AgentCore

// MARK: Fakes

/// What the fake guest does once `session.json` shows up in its share.
enum GuestBehavior: Sendable {
    /// CI: power off; simulator: start accepting on simstream's port.
    case normal
    /// Never finishes (CI) / never serves (simulator).
    case hang
}

final class FakeLink: GuestLink, @unchecked Sendable {
    private let lock = NSLock()
    private var _accepting = false
    var accepting: Bool {
        get { lock.withLock { _accepting } }
        set { lock.withLock { _accepting = newValue } }
    }
    let echoPort: UInt16

    init(echoPort: UInt16) { self.echoPort = echoPort }

    func isAccepting(port: UInt16) async -> Bool { port == GuestAPI.simstreamPort && accepting }
    func forward(guestPort: UInt16) throws -> UInt16 { echoPort }
}

final class FakeVM: RunningVM, @unchecked Sendable {
    let link: FakeLink
    var guest: any GuestLink { link }
    private let lock = NSLock()
    private var exit: VMExit?
    private var waiters: [CheckedContinuation<VMExit, Never>] = []
    private(set) var sawSession: GuestSession?
    let bundle: VMBundle

    init(bundle: VMBundle, shared: URL, link: FakeLink, behavior: GuestBehavior) {
        self.bundle = bundle
        self.link = link
        // The guest daemon: poll the share every 10 ms.
        Task.detached { [weak self] in
            while let self, self.currentExitSync == nil {
                if let data = try? Data(contentsOf: shared.appending(path: GuestAPI.sessionFile)),
                   let session = try? JSONDecoder.maccheri.decode(GuestSession.self, from: data) {
                    self.lock.withLock { self.sawSession = session }
                    guard behavior == .normal else { return }
                    switch session {
                    case .ci: self.finish(.guestStopped)
                    case .simulator: self.link.accepting = true
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    var currentExitSync: VMExit? { lock.withLock { exit } }

    func wait() async -> VMExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exit {
                lock.unlock()
                continuation.resume(returning: exit)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func currentExit() async -> VMExit? { currentExitSync }
    func stop() async { finish(.stoppedByHost) }

    func finish(_ result: VMExit) {
        lock.lock()
        guard exit == nil else { return lock.unlock() }
        exit = result
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: result) }
    }
}

final class FakeRunner: VMRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _vms: [FakeVM] = []
    var vms: [FakeVM] { lock.withLock { _vms } }
    var behavior: GuestBehavior = .normal
    var echoPort: UInt16 = 1

    func start(_ bundle: VMBundle, sharedDirectory: URL, resources: VMResources) async throws -> any RunningVM {
        let vm = FakeVM(bundle: bundle, shared: sharedDirectory, link: FakeLink(echoPort: echoPort), behavior: behavior)
        lock.withLock { _vms.append(vm) }
        return vm
    }

    var running: Int { vms.filter { $0.currentExitSync == nil }.count }
}

actor FakeControlPlane: ControlPlane {
    var leases: [WorkLease] = []
    var heartbeats: [Heartbeat] = []
    var workRequests: [LeaseRequest] = []
    var completed: [UUID: CompleteRequest] = [:]
    var reports: [UUID: [SessionStateReport]] = [:]
    var ended: Set<UUID> = []
    var goneSessions: Set<UUID> = []

    func add(_ lease: WorkLease) { leases.append(lease) }
    func endSession(_ id: UUID) { ended.insert(id) }
    func markGone(_ id: UUID) { goneSessions.insert(id) }

    func heartbeat(_ heartbeat: Heartbeat) async throws -> HeartbeatResponse {
        heartbeats.append(heartbeat)
        return HeartbeatResponse(endedSessions: Array(ended))
    }

    func work(_ request: LeaseRequest) async throws -> WorkLease? {
        workRequests.append(request)
        if !leases.isEmpty { return leases.removeFirst() }
        try await Task.sleep(for: .milliseconds(20))
        return nil
    }

    func complete(jobID: UUID, _ request: CompleteRequest) async throws {
        completed[jobID] = request
    }

    func report(sessionID: UUID, _ report: SessionStateReport) async throws {
        reports[sessionID, default: []].append(report)
        if goneSessions.contains(sessionID) { throw ControlPlaneError.sessionGone }
    }
}

/// Connects to the guest once, then stays until cancelled or `leaveAfter`.
final class FakePeer: SimulatorPeer, @unchecked Sendable {
    let leaveAfter: Duration?
    private let lock = NSLock()
    private var _connected = 0
    private var _cancelled = 0
    var connected: Int { lock.withLock { _connected } }
    var cancelled: Int { lock.withLock { _cancelled } }

    init(leaveAfter: Duration?) { self.leaveAfter = leaveAfter }

    func run(signaling: SignalingInfo, sessionID: UUID, connectToGuest: @escaping @Sendable () async throws -> NWConnection) async throws {
        let connection = try await connectToGuest()
        lock.withLock { _connected += 1 }
        connection.cancel()
        do {
            try await Task.sleep(for: leaveAfter ?? .seconds(3600))
        } catch {
            lock.withLock { _cancelled += 1 }
            throw error
        }
    }
}

// MARK: Harness

struct Harness {
    let root: URL
    let store: ImageStore
    let runner = FakeRunner()
    let controlPlane = FakeControlPlane()
    let pool: VMPool
    let agent: Agent
    let listener: NWListener

    static let simulatorImage = ImageMetadata(labels: ["maccheri", "macos-27", "xcode-27.2"], devices: [.iPhone17Pro], guestVersion: "1")

    init(settings: PoolSettings = PoolSettings(maxVMs: 2, warmVMs: 1, memoryBudget: 12 << 30), peer: any SimulatorPeer = FakePeer(leaveAfter: .milliseconds(50)), behavior: GuestBehavior = .normal) async throws {
        root = try temporaryDirectory()
        let images = root.appending(path: "images")
        _ = try makeImage(in: images, name: "macos", metadata: Self.simulatorImage)
        store = ImageStore(imagesDirectory: images, workDirectory: root.appending(path: "work"))
        try FileManager.default.createDirectory(at: store.workDirectory, withIntermediateDirectories: true)
        listener = try await loopbackServer(echo)
        runner.echoPort = listener.port!.rawValue
        runner.behavior = behavior
        pool = VMPool(store: store, runner: runner, settings: settings, log: { _ in })
        var timing = Agent.Timing()
        timing.heartbeat = .milliseconds(30)
        timing.readinessPoll = .milliseconds(10)
        timing.readinessTimeout = .seconds(5)
        timing.retry = .milliseconds(20)
        timing.idle = .milliseconds(10)
        agent = Agent(controlPlane: controlPlane, pool: pool, peer: peer, timing: timing, log: { _ in })
    }

    var clones: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.workDirectory.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    func cleanUp() {
        listener.cancel()
        try? FileManager.default.removeItem(at: root)
    }
}

/// Polls `condition` for up to `timeout`.
func eventually(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

let signalingInfo = SignalingInfo(url: URL(string: "wss://example.invalid/v1/sessions/x/signal?role=host&token=t")!, token: "t", iceServers: [])

func simulatorLease(timeout: Int = 60) -> (UUID, WorkLease) {
    let id = UUID()
    return (id, .simulator(SimulatorSessionLease(sessionID: id, image: "macos", device: .iPhone17Pro, timeoutSeconds: timeout, signaling: signalingInfo)))
}

func ciLease(timeout: Int = 60) -> (UUID, WorkLease) {
    let id = UUID()
    return (id, .ci(JobLease(jobID: id, githubJobID: 7, repository: "o/r", image: "macos", jitConfig: "JIT", timeoutSeconds: timeout)))
}

// MARK: Pool

@Test func poolSlotsFollowLicenseAndMemory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let images = root.appending(path: "images")
    _ = try makeImage(in: images, name: "macos")
    let store = ImageStore(imagesDirectory: images, workDirectory: root.appending(path: "work"))

    let small = VMPool(store: store, runner: FakeRunner(), settings: PoolSettings(maxVMs: 5, warmVMs: 0, memoryBudget: 64 << 30))
    #expect(await small.status.slots == 2, "Apple's license caps at two")
    let tight = VMPool(store: store, runner: FakeRunner(), settings: PoolSettings(maxVMs: 2, warmVMs: 0, memoryBudget: 12 << 30))
    #expect(await tight.status.slots == 1, "12 GB fits one 8 GB guest")
    let override = VMPool(store: store, runner: FakeRunner(), settings: PoolSettings(maxVMs: 2, warmVMs: 0, memoryBudget: 12 << 30, resources: VMResources(memorySize: 6 << 30)))
    #expect(await override.status.slots == 2)
    let none = VMPool(store: store, runner: FakeRunner(), settings: PoolSettings(maxVMs: 2, warmVMs: 0, memoryBudget: 4 << 30))
    #expect(await none.status.slots == 0)
    #expect(await none.reserve(image: "macos") == nil)
}

@Test func warmVMCountsAgainstTheCapAndIsHandedOut() async throws {
    let harness = try await Harness()
    defer { harness.cleanUp() }
    await harness.pool.replenish()
    #expect(await eventually { await harness.pool.status.warmBooted == 1 })
    let status = await harness.pool.status
    #expect(status.slots == 1)
    #expect(status.freeSlots == 0)
    #expect(status.available == 1)

    let reservation = try #require(await harness.pool.reserve(image: "macos"))
    #expect(reservation.isWarm)
    #expect(await harness.pool.reserve(image: "macos") == nil, "the only slot is taken")
    let lease = try await harness.pool.start(reservation, id: UUID())
    #expect(lease.wasWarm)
    await harness.pool.release(lease)
    #expect(!FileManager.default.fileExists(atPath: lease.clone.url.path))
    // The freed slot is warmed again.
    #expect(await eventually { await harness.pool.status.warmBooted == 1 })
    await harness.pool.shutdown()
    #expect(harness.clones.isEmpty)
    #expect(harness.runner.running == 0)
}

@Test func evictsWarmGuestOfAnotherImage() async throws {
    let harness = try await Harness()
    defer { harness.cleanUp() }
    _ = try makeImage(in: harness.store.imagesDirectory, name: "other")
    await harness.pool.rescanImages()
    #expect(await eventually { await harness.pool.status.warmBooted == 1 })

    let reservation = try #require(await harness.pool.reserve(image: "other"))
    #expect(!reservation.isWarm)
    let lease = try await harness.pool.start(reservation, id: UUID())
    #expect(lease.image == "other")
    #expect(harness.runner.running == 1, "the warm guest went away first")
    await harness.pool.release(lease)
    await harness.pool.shutdown()
    #expect(harness.clones.isEmpty)
}

@Test func removesOrphanedClonesOnly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ImageStore(imagesDirectory: root, workDirectory: root.appending(path: "work"))
    let orphan = store.workDirectory.appending(path: UUID().uuidString)
    let foreign = store.workDirectory.appending(path: "notes")
    try FileManager.default.createDirectory(at: orphan.appending(path: "shared"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

    #expect(store.removeOrphans() == [orphan.lastPathComponent])
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: foreign.path))
}

@Test func workDirectoryLockIsExclusive() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try WorkDirectoryLock(workDirectory: root)
    // flock is per open file description, so a second open in the same process conflicts too.
    #expect(throws: AgentError.self) { try WorkDirectoryLock(workDirectory: root) }
    withExtendedLifetime(first) {}
}

// MARK: Agent

@Test func runsCIJobInWarmVMAndCleansUp() async throws {
    let harness = try await Harness()
    defer { harness.cleanUp() }
    let running = Task { await harness.agent.run() }
    #expect(await eventually { await harness.pool.status.warmBooted == 1 })
    #expect(await eventually { await harness.controlPlane.workRequests.last?.freeSlots == 1 })
    let heartbeat = try #require(await harness.controlPlane.heartbeats.last)
    #expect(heartbeat.capacity.warmVMs == 1)
    #expect(heartbeat.capacity.freeSlots == 0)
    #expect(heartbeat.capacity.labels == Harness.simulatorImage.labels)
    #expect(heartbeat.capacity.devices == [.iPhone17Pro])

    let (id, lease) = ciLease()
    await harness.controlPlane.add(lease)
    #expect(await eventually { await harness.controlPlane.completed[id] != nil })
    #expect(await harness.controlPlane.completed[id]?.outcome == .finished)
    #expect(harness.runner.vms.first?.sawSession == .ci(GuestCIJob(jitConfig: "JIT")))

    running.cancel()
    await running.value
    #expect(harness.clones.isEmpty)
    #expect(harness.runner.running == 0)
}

@Test func killsCIJobAtTimeout() async throws {
    let harness = try await Harness(behavior: .hang)
    defer { harness.cleanUp() }
    let running = Task { await harness.agent.run() }
    let (id, lease) = ciLease(timeout: 1)
    await harness.controlPlane.add(lease)
    #expect(await eventually(.seconds(4)) { await harness.controlPlane.completed[id] != nil })
    #expect(await harness.controlPlane.completed[id]?.outcome == .timedOut)
    running.cancel()
    await running.value
    #expect(harness.clones.isEmpty)
    #expect(harness.runner.running == 0)
}

@Test func runsSimulatorSessionStartToEnd() async throws {
    let peer = FakePeer(leaveAfter: .milliseconds(100))
    let harness = try await Harness(peer: peer)
    defer { harness.cleanUp() }
    let running = Task { await harness.agent.run() }
    let (id, lease) = simulatorLease()
    await harness.controlPlane.add(lease)
    #expect(await eventually { await harness.controlPlane.reports[id]?.last?.state == .ended })
    #expect(await harness.controlPlane.reports[id]?.map(\.state) == [.starting, .ready, .ended])
    #expect(peer.connected == 1)
    let session = try #require(harness.runner.vms.first?.sawSession)
    #expect(session == .simulator(GuestSimulatorSession(sessionID: id, device: .iPhone17Pro)))

    running.cancel()
    await running.value
    #expect(harness.clones.isEmpty)
    #expect(harness.runner.running == 0)
}

@Test func endsSessionListedInHeartbeat() async throws {
    let peer = FakePeer(leaveAfter: nil)
    let harness = try await Harness(peer: peer)
    defer { harness.cleanUp() }
    let running = Task { await harness.agent.run() }
    let (id, lease) = simulatorLease()
    await harness.controlPlane.add(lease)
    #expect(await eventually { peer.connected == 1 })
    await harness.controlPlane.endSession(id)
    #expect(await eventually { await harness.controlPlane.reports[id]?.last?.state == .ended })
    #expect(peer.cancelled == 1)
    #expect(await eventually { harness.runner.vms.first?.currentExitSync != nil })
    running.cancel()
    await running.value
    #expect(harness.clones.isEmpty)
}

@Test func goneOnStartingReleasesTheSlot() async throws {
    let harness = try await Harness(settings: PoolSettings(maxVMs: 1, warmVMs: 0, memoryBudget: 64 << 30))
    defer { harness.cleanUp() }
    let (id, lease) = simulatorLease()
    await harness.controlPlane.markGone(id)
    await harness.controlPlane.add(lease)
    let running = Task { await harness.agent.run() }
    #expect(await eventually { await harness.controlPlane.reports[id]?.count == 2 })
    #expect(await harness.controlPlane.reports[id]?.map(\.state) == [.starting, .ended])
    #expect(harness.runner.vms.isEmpty, "no VM for a session that is already over")
    #expect(await eventually { await harness.pool.status.freeSlots == 1 })
    running.cancel()
    await running.value
}

@Test func failsSessionWhenSimstreamNeverComesUp() async throws {
    let harness = try await Harness(behavior: .hang)
    defer { harness.cleanUp() }
    let running = Task { await harness.agent.run() }
    let (id, lease) = simulatorLease(timeout: 1)
    await harness.controlPlane.add(lease)
    #expect(await eventually(.seconds(4)) { await harness.controlPlane.reports[id]?.last?.state == .failed })
    running.cancel()
    await running.value
    #expect(harness.clones.isEmpty)
    #expect(harness.runner.running == 0)
}

@Test func pausedHostOffersNothing() async throws {
    let harness = try await Harness()
    defer { harness.cleanUp() }
    let running = Task { await harness.agent.run() }
    #expect(await eventually { await harness.pool.status.warmBooted == 1 })
    await harness.agent.setPaused(true)
    #expect(await eventually { harness.runner.running == 0 })
    let requests = await harness.controlPlane.workRequests.count
    #expect(await eventually { await harness.controlPlane.heartbeats.last?.capacity == HostCapacity(freeSlots: 0, warmVMs: 0, images: ["macos"], labels: Harness.simulatorImage.labels, devices: [.iPhone17Pro]) })
    try await Task.sleep(for: .milliseconds(100))
    #expect(await harness.controlPlane.workRequests.count <= requests + 1, "no polling while paused")
    await harness.agent.setPaused(false)
    #expect(await eventually { await harness.pool.status.warmBooted == 1 })
    running.cancel()
    await running.value
    #expect(harness.clones.isEmpty)
}
