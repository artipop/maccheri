import Foundation
import MaccheriProtocol
import Network

/// What the menu bar shows.
public struct AgentStatus: Sendable, Equatable {
    public enum Connection: Sendable, Equatable {
        case connecting
        case online
        case offline(String)
    }

    public struct Activity: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case ci(repository: String)
            case simulator(DeviceSpec)
        }

        public enum Phase: Sendable, Equatable {
            /// Booting the VM or waiting for the guest.
            case starting
            /// CI job running; simulator session ready for (or connected to) the viewer.
            case running
            case finishing
        }

        public var id: UUID
        public var kind: Kind
        public var phase: Phase
        public var startedAt: Date
        public var usedWarmVM: Bool
    }

    public var connection: Connection = .connecting
    public var paused = false
    public var pool = PoolStatus(slots: 0, busy: 0, warm: 0, warmBooted: 0, paused: false)
    public var activities: [Activity] = []
    public var images: [String] = []
    public var lastError: String?

    public init() {}
}

/// The host agent: heartbeats, long-polls for work and runs each lease in a single-use VM from
/// the pool. CI: write `session.json`, wait for the guest to power off, report. Simulator:
/// report `starting`, wait for simstream on the guest's port, report `ready`, hand the guest to
/// the ``SimulatorPeer`` until the viewer leaves, then destroy the VM and report `ended`.
public actor Agent {
    public struct Timing: Sendable {
        public var heartbeat: Duration = .seconds(HostAPI.heartbeatIntervalSeconds)
        /// How often to check whether simstream accepts connections.
        public var readinessPoll: Duration = .milliseconds(500)
        /// Cap on guest boot + simulator start, within the lease's own timeout.
        public var readinessTimeout: Duration = .seconds(300)
        /// Back-off after a failed control plane call.
        public var retry: Duration = .seconds(5)
        /// How often to look again when there is no capacity or the agent is paused.
        public var idle: Duration = .seconds(1)

        public init() {}
    }

    public static let version = "0.1.0"

    private let controlPlane: any ControlPlane
    private let pool: VMPool
    private let peer: any SimulatorPeer
    private let timing: Timing
    private let log: @Sendable (String) -> Void
    private let onStatus: @Sendable (AgentStatus) -> Void
    private var status = AgentStatus()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var poll: Task<WorkLease?, any Error>?
    private var paused = false

    public init(
        controlPlane: any ControlPlane, pool: VMPool, peer: any SimulatorPeer, timing: Timing = Timing(),
        log: @escaping @Sendable (String) -> Void = { print($0) },
        onStatus: @escaping @Sendable (AgentStatus) -> Void = { _ in }
    ) {
        self.controlPlane = controlPlane
        self.pool = pool
        self.peer = peer
        self.timing = timing
        self.log = log
        self.onStatus = onStatus
    }

    /// Runs until cancelled, then tears down every VM it started.
    public func run() async {
        _ = await pool.observe { [weak self] pool in
            Task { await self?.poolChanged(pool) }
        }
        await pool.rescanImages()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.heartbeatLoop() }
            group.addTask { await self.workLoop() }
        }
        log("agent: stopping")
        for task in tasks.values { task.cancel() }
        for task in tasks.values { await task.value }
        await pool.shutdown()
    }

    public func setPaused(_ paused: Bool) async {
        guard paused != self.paused else { return }
        self.paused = paused
        status.paused = paused
        publish()
        if paused { poll?.cancel() }
        await pool.setPaused(paused)
        log(paused ? "agent: paused" : "agent: resumed")
        await sendHeartbeat()
    }

    /// Settings changed in the app.
    public func update(_ settings: PoolSettings) async {
        await pool.update(settings)
    }

    public func rescanImages() async {
        await pool.rescanImages()
    }

    public var currentStatus: AgentStatus { status }

    /// The control plane says the session is over (heartbeat `endedSessions`, `410 Gone`).
    public func end(sessionID: UUID) {
        guard let task = tasks[sessionID] else { return }
        log("session \(sessionID): ended by the control plane")
        task.cancel()
    }

    // MARK: Loops

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            await sendHeartbeat()
            try? await Task.sleep(for: timing.heartbeat)
        }
    }

    private func sendHeartbeat() async {
        let capacity = await capacity()
        do {
            let response = try await controlPlane.heartbeat(Heartbeat(agentVersion: Self.version, capacity: capacity))
            setConnection(.online)
            for id in response.endedSessions { end(sessionID: id) }
        } catch {
            if !Task.isCancelled { setConnection(.offline(String(describing: error))) }
        }
    }

    private func workLoop() async {
        while !Task.isCancelled {
            let available = await pool.status.available
            guard !paused, available > 0 else {
                try? await Task.sleep(for: timing.idle)
                continue
            }
            let request = LeaseRequest(labels: await labels(), freeSlots: available)
            let poll = Task { [controlPlane] in try await controlPlane.work(request) }
            self.poll = poll
            do {
                // The poll is its own task (pausing cancels just the poll), so pass stopping on.
                let lease = try await withTaskCancellationHandler {
                    try await poll.value
                } onCancel: {
                    poll.cancel()
                }
                self.poll = nil
                setConnection(.online)
                if let lease { await dispatch(lease) }
            } catch {
                self.poll = nil
                if Task.isCancelled { break }
                if paused { continue }
                setConnection(.offline(String(describing: error)))
                try? await Task.sleep(for: timing.retry)
            }
        }
    }

    private func capacity() async -> HostCapacity {
        let pool = await pool.status
        let images = Self.servable(await self.pool.images)
        return HostCapacity(
            freeSlots: paused ? 0 : pool.freeSlots,
            warmVMs: paused ? 0 : pool.warm,
            images: images.map(\.name),
            labels: Self.labels(images),
            devices: Self.devices(images)
        )
    }

    private func labels() async -> [String] {
        Self.labels(Self.servable(await pool.images))
    }

    /// Only images built for Maccheri (with `maccheri.json`, so with the guest daemon) take work.
    static func servable(_ images: [ImageInfo]) -> [ImageInfo] {
        images.filter { $0.metadata != nil }
    }

    static func labels(_ images: [ImageInfo]) -> [String] {
        var labels = [String]()
        for label in images.flatMap({ $0.metadata?.labels ?? [] }) where !labels.contains(label) {
            labels.append(label)
        }
        return labels
    }

    static func devices(_ images: [ImageInfo]) -> [DeviceSpec] {
        var devices = [DeviceSpec]()
        for device in images.flatMap({ $0.metadata?.devices ?? [] }) where !devices.contains(device) {
            devices.append(device)
        }
        return devices
    }

    // MARK: Dispatch

    private func dispatch(_ lease: WorkLease) async {
        switch lease {
        case let .ci(job):
            log("job \(job.jobID) (GitHub \(job.githubJobID), \(job.repository)) on \(job.image)")
            guard let reservation = await pool.reserve(image: job.image) else {
                log("job \(job.jobID): no capacity")
                return await detached { [controlPlane] in
                    try? await controlPlane.complete(jobID: job.jobID, CompleteRequest(outcome: .vmFailed, durationSeconds: 0, message: "host has no free VM slot"))
                }
            }
            track(job.jobID, kind: .ci(repository: job.repository), warm: reservation.isWarm) { agent in
                await agent.runCI(job, reservation)
            }

        case let .simulator(session):
            log("session \(session.sessionID): \(session.device.deviceType) on \(session.image)")
            guard let reservation = await pool.reserve(image: session.image) else {
                log("session \(session.sessionID): no capacity")
                return await detached { [controlPlane] in
                    try? await controlPlane.report(sessionID: session.sessionID, SessionStateReport(state: .failed, message: "host has no free VM slot"))
                }
            }
            track(session.sessionID, kind: .simulator(session.device), warm: reservation.isWarm) { agent in
                await agent.runSimulator(session, reservation)
            }
        }
    }

    private func track(_ id: UUID, kind: AgentStatus.Activity.Kind, warm: Bool, _ body: @escaping @Sendable (Agent) async -> Void) {
        status.activities.append(.init(id: id, kind: kind, phase: .starting, startedAt: Date(), usedWarmVM: warm))
        publish()
        tasks[id] = Task {
            await body(self)
            self.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        tasks[id] = nil
        status.activities.removeAll { $0.id == id }
        publish()
    }

    private func setPhase(_ id: UUID, _ phase: AgentStatus.Activity.Phase) {
        guard let index = status.activities.firstIndex(where: { $0.id == id }) else { return }
        status.activities[index].phase = phase
        publish()
    }

    // MARK: CI

    private func runCI(_ job: JobLease, _ reservation: VMPool.Reservation) async {
        let started = ContinuousClock.now
        var outcome = JobOutcome.vmFailed
        var message: String?
        do {
            let lease = try await pool.start(reservation, id: job.jobID)
            do {
                try Self.write(.ci(GuestCIJob(jitConfig: job.jitConfig)), to: lease.sharedDirectory)
                setPhase(job.jobID, .running)
                switch await Self.waitForExit(lease.vm, timeout: .seconds(job.timeoutSeconds)) {
                case .guestStopped: outcome = .finished
                case nil: outcome = .timedOut
                case .stoppedByHost: message = "the agent stopped"
                case let .failed(reason): message = reason
                }
            } catch {
                message = String(describing: error)
            }
            setPhase(job.jobID, .finishing)
            await pool.release(lease)
        } catch {
            message = String(describing: error)
        }
        let seconds = Self.seconds(ContinuousClock.now - started)
        log("job \(job.jobID) \(outcome.rawValue) in \(Int(seconds))s\(message.map { ": \($0)" } ?? "")")
        let request = CompleteRequest(outcome: outcome, durationSeconds: seconds, message: message)
        await detached { [controlPlane, log] in
            for attempt in 1...3 {
                do {
                    return try await controlPlane.complete(jobID: job.jobID, request)
                } catch {
                    log("job \(job.jobID): complete failed (\(attempt)/3): \(error)")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// nil when `timeout` passed first; the VM is stopped either way.
    public static func waitForExit(_ vm: any RunningVM, timeout: Duration) async -> VMExit? {
        await withTaskGroup(of: VMExit?.self) { group in
            group.addTask { await vm.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            await vm.stop()
            if first == nil, Task.isCancelled { return .stoppedByHost }
            return first
        }
    }

    // MARK: Simulator

    private enum SessionEnd: Sendable {
        case viewerLeft
        case peerFailed(String)
        case vmStopped(VMExit)
        case timedOut
        case cancelled
    }

    private func runSimulator(_ session: SimulatorSessionLease, _ reservation: VMPool.Reservation) async {
        let id = session.sessionID
        let deadline = ContinuousClock.now + .seconds(session.timeoutSeconds)
        var final = HostSessionState.ended
        var message: String?
        var lease: VMPool.Lease?
        do {
            do {
                try await controlPlane.report(sessionID: id, SessionStateReport(state: .starting))
            } catch {
                await pool.cancel(reservation)
                throw error
            }
            let started = try await pool.start(reservation, id: id)
            lease = started
            try Task.checkCancellation()
            try Self.write(.simulator(GuestSimulatorSession(sessionID: id, device: session.device)), to: started.sharedDirectory)
            try await waitForSimstream(started, until: min(deadline, .now + timing.readinessTimeout))
            try await controlPlane.report(sessionID: id, SessionStateReport(state: .ready))
            setPhase(id, .running)
            log("session \(id): ready\(started.wasWarm ? " (warm VM)" : "")")

            let port = try started.vm.guest.forward(guestPort: GuestAPI.simstreamPort)
            let end = await race(session, vm: started.vm, guestPort: port, until: deadline)
            switch end {
            case .viewerLeft: message = "viewer left"
            case let .peerFailed(reason): (final, message) = (.failed, "host peer: \(reason)")
            case let .vmStopped(exit): (final, message) = (.failed, "VM stopped: \(exit)")
            case .timedOut: message = "session timed out"
            case .cancelled: message = "ended by the control plane"
            }
        } catch ControlPlaneError.sessionGone {
            message = "ended by the control plane"
        } catch {
            if Task.isCancelled || error is CancellationError {
                message = "ended by the control plane"
            } else {
                (final, message) = (.failed, String(describing: error))
            }
        }
        setPhase(id, .finishing)
        if let lease { await pool.release(lease) }
        log("session \(id): \(final.rawValue)\(message.map { " (\($0))" } ?? "")")
        let report = SessionStateReport(state: final, message: message)
        await detached { [controlPlane] in try? await controlPlane.report(sessionID: id, report) }
    }

    /// Polls the guest's simstream port; throws if the VM dies or the deadline passes first.
    private func waitForSimstream(_ lease: VMPool.Lease, until deadline: ContinuousClock.Instant) async throws {
        while true {
            try Task.checkCancellation()
            if let exit = await lease.vm.currentExit() { throw SessionError.vmStopped(exit) }
            if await lease.vm.guest.isAccepting(port: GuestAPI.simstreamPort) { return }
            guard ContinuousClock.now < deadline else { throw SessionError.guestNotReady }
            try await Task.sleep(for: timing.readinessPoll)
        }
    }

    private func race(_ session: SimulatorSessionLease, vm: any RunningVM, guestPort: UInt16, until deadline: ContinuousClock.Instant) async -> SessionEnd {
        await withTaskGroup(of: SessionEnd.self) { [peer] group in
            group.addTask {
                do {
                    try await peer.run(signaling: session.signaling, sessionID: session.sessionID) {
                        try await NWConnection.loopback(port: guestPort)
                    }
                    return Task.isCancelled ? .cancelled : .viewerLeft
                } catch {
                    return Task.isCancelled ? .cancelled : .peerFailed(String(describing: error))
                }
            }
            group.addTask { .vmStopped(await vm.wait()) }
            group.addTask {
                do {
                    try await Task.sleep(until: deadline)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next()!
            group.cancelAll()
            await vm.stop()
            return first
        }
    }

    // MARK: Helpers

    static func write(_ session: GuestSession, to sharedDirectory: URL) throws {
        let data = try JSONEncoder.maccheri.encode(session)
        // Atomic: the guest polls for the file and must never read half of it.
        try data.write(to: sharedDirectory.appending(path: GuestAPI.sessionFile), options: .atomic)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Runs `body` outside this task's cancellation: final reports must go out even when the
    /// session was cancelled.
    private func detached(_ body: @escaping @Sendable () async -> Void) async {
        await Task.detached(operation: body).value
    }

    private func setConnection(_ connection: AgentStatus.Connection) {
        guard status.connection != connection else { return }
        if case let .offline(reason) = connection { log("agent: offline: \(reason)") }
        if connection == .online, status.connection != .connecting { log("agent: online") }
        status.connection = connection
        publish()
    }

    private func poolChanged(_ pool: PoolStatus) async {
        status.pool = pool
        status.images = await self.pool.images.map(\.name)
        publish()
    }

    private func publish() {
        onStatus(status)
    }
}

enum SessionError: Error, CustomStringConvertible {
    case vmStopped(VMExit)
    case guestNotReady

    var description: String {
        switch self {
        case let .vmStopped(exit): "VM stopped before simstream came up: \(exit)"
        case .guestNotReady: "simstream did not come up in time"
        }
    }
}
