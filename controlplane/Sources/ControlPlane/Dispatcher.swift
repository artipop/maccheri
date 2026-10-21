import Fluent
import MaccheriProtocol
import Vapor

/// Picks work for a host that asked for it (DESIGN.md, "Подбор хоста"). Simulator sessions go
/// first: someone is waiting in front of the screen. Callers hold ``Maccheri/assignment``.
struct Dispatcher {
    let db: any Database
    let maccheri: Maccheri
    let logger: Logger

    func nextWork(for host: HostModel, request: LeaseRequest) async throws -> WorkLease? {
        guard request.freeSlots > 0 else { return nil }
        if let lease = try await nextSession(for: host) { return .simulator(lease) }
        if let lease = try await nextJob(labels: request.labels, hostID: host.id) { return .ci(lease) }
        return nil
    }

    func nextSession(for host: HostModel) async throws -> SimulatorSessionLease? {
        guard let capacity = host.capacity, !capacity.devices.isEmpty else { return nil }
        let settings = maccheri.settings
        let now = maccheri.now
        let queued = try await SessionModel.query(on: db).filter(\.$state == .queued).sort(\.$createdAt).all()

        for session in queued {
            if let pinned = session.requestedHostID, pinned != host.id { continue }
            guard let device = Self.device(for: session.requestedDevice, offered: capacity.devices) else { continue }
            if capacity.warmVMs == 0, session.requestedHostID == nil,
               now.timeIntervalSince(session.createdAt) < TimeInterval(settings.warmPreferenceSeconds),
               try await warmHostAvailable(other: host.id!, device: device, now: now) {
                continue
            }

            session.state = .starting
            session.hostID = host.id
            session.device = device
            session.image = capacity.images.contains(settings.defaultImage) ? settings.defaultImage : (capacity.images.first ?? settings.defaultImage)
            session.leasedAt = now
            try await session.update(on: db)
            logger.info("session leased", metadata: ["session": "\(session.id!)", "host": "\(host.id!)", "warm": "\(capacity.warmVMs > 0)"])
            return SimulatorSessionLease(
                sessionID: session.id!,
                image: session.image!,
                device: device,
                timeoutSeconds: max(0, Int(session.expiresAt.timeIntervalSince(now))),
                signaling: session.signalingInfo(for: .host, settings: settings)
            )
        }
        return nil
    }

    /// Hands out the oldest CI job the labels cover, with a fresh JIT runner config.
    func nextJob(labels: [String], hostID: UUID?) async throws -> JobLease? {
        guard let provisioner = maccheri.provisioner else { return nil }
        let hostLabels = Set(labels.map { $0.lowercased() })
        let pending = try await CIJobModel.query(on: db).filter(\.$state == .pending).sort(\.$enqueuedAt).all()
        guard let job = pending.first(where: { $0.requiredLabels.isSubset(of: hostLabels) }) else { return nil }

        job.state = .leased
        job.hostID = hostID
        job.leasedAt = maccheri.now
        try await job.update(on: db)

        let jitConfig: String
        do {
            jitConfig = try await provisioner.jitConfig(
                installationID: job.installationID,
                repository: job.repository,
                runnerName: "maccheri-\(job.id!.uuidString.prefix(8).lowercased())",
                labels: job.labels.filter { !GitHubDefaultLabels.all.contains($0) }
            )
        } catch {
            job.state = .pending
            job.hostID = nil
            job.leasedAt = nil
            try await job.update(on: db)
            logger.error("jit config failed", metadata: ["job": "\(job.githubJobID)", "error": "\(error)"])
            throw Abort(.badGateway, reason: "could not provision runner")
        }
        logger.info("job leased", metadata: ["job": "\(job.githubJobID)", "host": "\(hostID?.uuidString ?? "legacy")"])
        return JobLease(
            jobID: job.id!,
            githubJobID: job.githubJobID,
            repository: job.repository,
            image: maccheri.settings.defaultImage,
            jitConfig: jitConfig,
            timeoutSeconds: maccheri.settings.jobTimeoutSeconds
        )
    }

    /// The requested device if offered; with none requested, iPhone 17 Pro if offered, else the first.
    static func device(for requested: DeviceSpec?, offered: [DeviceSpec]) -> DeviceSpec? {
        if let requested { return offered.contains(requested) ? requested : nil }
        return offered.contains(.iPhone17Pro) ? .iPhone17Pro : offered.first
    }

    private func warmHostAvailable(other hostID: UUID, device: DeviceSpec, now: Date) async throws -> Bool {
        let cutoff = now.addingTimeInterval(-TimeInterval(maccheri.settings.offlineAfterSeconds))
        let online = try await HostModel.query(on: db).filter(\.$id != hostID).filter(\.$lastSeenAt >= cutoff).all()
        return online.contains { host in
            guard let capacity = host.capacity else { return false }
            return capacity.warmVMs > 0 && capacity.devices.contains(device)
        }
    }
}
